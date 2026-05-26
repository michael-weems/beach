package wav

import "core:log"
import "core:math"
import "core:mem"
import "core:slice"
import "core:time"

// Edge detection — onset/offset detection on a WAV's PCM-float buffer.
//
// Algorithm: RMS envelope (per hop) → dB → IQR-anchored thresholds
// (Q25 + K * IQR) → hysteretic state machine → debounce.
//
// dB-domain makes the envelope distribution more symmetric across
// content regimes (silent / noisy / mixed); Q25-anchored thresholds
// stay robust when events become frequent enough that a median would
// fall inside the loud cluster.

// ─── Tuning knobs ─────────────────────────────────────────────────
// K_HIGH and K_LOW are package-level mutable globals so the rest of
// the app can nudge them live for per-file sensitivity tuning.
// Everything else is a compile-time constant for now.

EDGE_K_HIGH: f32 = 0.7 // fraction of IQR above Q25 to enter ACTIVE
EDGE_K_LOW: f32 = 0.4 // fraction of IQR above Q25 to leave  ACTIVE

EDGE_HOP_MS :: 10.0 // envelope hop in milliseconds
EDGE_WIN_MS :: 20.0 // RMS window length (50% overlap with hop)
EDGE_MIN_GAP_MS :: 50.0 // suppress edges closer than this
EDGE_DB_FLOOR :: f32(-60.0) // anything below is treated as silence
EDGE_LIN_EPS :: f32(1e-6) // log epsilon → -120 dB silence floor
EDGE_MIN_HIGH_GAP_DB :: f32(6.0) // T_high must be at least this much above T_low

// ─── Types ────────────────────────────────────────────────────────

Edges :: struct {
  leading:   [dynamic]i32, // sorted frame indices where ACTIVE begins
  trailing:  [dynamic]i32, // sorted frame indices where ACTIVE ends
  dirty:     bool, // true → recompute on next access
  t_high_db: f32, // resolved thresholds, exposed for the debug overlay
  t_low_db:  f32,
}

// ─── Algorithm ────────────────────────────────────────────────────

compute_edges :: proc(w: ^Wav, allocator: mem.Allocator) -> Edges {
  out := Edges {
    leading  = make([dynamic]i32, allocator),
    trailing = make([dynamic]i32, allocator),
  }
  if w == nil || w.num_samples == 0 do return out

  channels := int(w.channels)
  if channels <= 0 do return out

  sr := f32(w.frequency)
  hop_frames := max(1, int(EDGE_HOP_MS * 0.001 * sr))
  win_frames := max(hop_frames, int(EDGE_WIN_MS * 0.001 * sr))
  min_gap := i32(EDGE_MIN_GAP_MS * 0.001 * sr)

  total := int(total_frames(w))
  if total < win_frames do return out

  // ── Pass 1: RMS envelope, converted to dB ─────────────────────
  num_hops := (total - win_frames) / hop_frames + 1
  env_db := make([]f32, num_hops, allocator)
  defer delete(env_db, allocator)

  for h in 0 ..< num_hops {
    start := h * hop_frames
    sum_sq: f32 = 0
    for fi in 0 ..< win_frames {
      base := (start + fi) * channels
      // Mono mixdown — average across channels per frame.
      acc: f32 = 0
      for c in 0 ..< channels {
        acc += w.samples_raw[base + c]
      }
      mean := acc / f32(channels)
      sum_sq += mean * mean
    }
    rms := math.sqrt(sum_sq / f32(win_frames))
    env_db[h] = 20.0 * math.log10(max(rms, EDGE_LIN_EPS))
  }

  // ── Pass 2: IQR-anchored thresholds ───────────────────────────
  // Q25 anchors at "the floor or quieter cluster"; IQR measures the
  // spread between background and active content. Robust to both
  // outliers (only the percentile rank moves, not the mean) and
  // bimodal distributions (Q25 stays in the lower cluster even when
  // events are frequent).
  sorted := make([]f32, len(env_db), allocator)
  defer delete(sorted, allocator)
  copy(sorted, env_db)
  slice.sort(sorted)

  q25 := percentile_sorted(sorted, 0.25)
  q75 := percentile_sorted(sorted, 0.75)
  iqr := q75 - q25

  t_high := q25 + EDGE_K_HIGH * iqr
  t_low := q25 + EDGE_K_LOW * iqr

  // Floors keep thresholds above silence; min-gap keeps hysteresis
  // meaningful when IQR is tiny (silent or uniform files).
  t_high = max(t_high, EDGE_DB_FLOOR + 12.0)
  t_low = max(t_low, EDGE_DB_FLOOR + 6.0)
  if t_high - t_low < EDGE_MIN_HIGH_GAP_DB {
    t_high = t_low + EDGE_MIN_HIGH_GAP_DB
  }
  out.t_high_db = t_high
  out.t_low_db = t_low

  // ── Pass 3: hysteretic state machine + debounce ───────────────
  State :: enum {
    SILENT,
    ACTIVE,
  }
  state := State.SILENT
  last_edge := i32(-min_gap)

  for v, h in env_db {
    frame := i32(h * hop_frames)
    switch state {
    case .SILENT:
      if v >= t_high && (frame - last_edge) >= min_gap {
        append(&out.leading, frame)
        last_edge = frame
        state = .ACTIVE
      }
    case .ACTIVE:
      if v <= t_low && (frame - last_edge) >= min_gap {
        append(&out.trailing, frame)
        last_edge = frame
        state = .SILENT
      }
    }
  }

  // Close an unterminated active region at EOF so leading/trailing pair.
  if state == .ACTIVE {
    append(&out.trailing, i32(total - 1))
  }

  out.dirty = false
  return out
}

// `sorted` must be ascending. Linear interpolation between adjacent
// samples — slightly less coarse than nearest-index.
percentile_sorted :: proc(sorted: []f32, p: f32) -> f32 {
  n := len(sorted)
  if n == 0 do return 0
  if n == 1 do return sorted[0]
  pos := p * f32(n - 1)
  lo := int(pos)
  hi := min(lo + 1, n - 1)
  frac := pos - f32(lo)
  return sorted[lo] + (sorted[hi] - sorted[lo]) * frac
}

// ─── Lazy recompute ───────────────────────────────────────────────
// `ensure_edges_fresh` is the only entry point the rest of the app
// calls. It guards on the `dirty` flag, frees the previous edge
// arrays (heap-allocated via `edges_allocator`), then recomputes.

ensure_edges_fresh :: proc(w: ^Wav, allocator: mem.Allocator) {
  if w == nil || !w.edges.dirty do return

  // delete() on a zero-init [dynamic]T is a no-op (Odin checks for
  // a nil allocator procedure internally), so this is safe even on
  // the very first call when leading/trailing have never been
  // populated.
  delete(w.edges.leading)
  delete(w.edges.trailing)

  // Temporary instrumentation (removed after Step 4 or when we trust
  // the per-file compute cost). Times the algorithm only — caller-side
  // delete/assign is fast.
  start := time.now()
  w.edges = compute_edges(w, allocator)
  duration_ms := time.duration_milliseconds(time.since(start))

  frames := i32(0)
  if w.channels > 0 do frames = w.num_samples / i32(w.channels)
  log.debugf(
    "compute_edges: %s, %d frames, %.2f ms, leading=%d trailing=%d t_high=%.2f t_low=%.2f",
    w.file_name,
    frames,
    duration_ms,
    len(w.edges.leading),
    len(w.edges.trailing),
    w.edges.t_high_db,
    w.edges.t_low_db,
  )
}

// ─── Navigation ───────────────────────────────────────────────────
// Binary search over the sorted edge arrays. O(log N) per call.
// All return -1 when there is no satisfying edge.

// Smallest leading edge strictly > cursor.
next_leading :: proc(w: ^Wav, cursor: i32) -> i32 {
  if w == nil do return -1
  arr := w.edges.leading[:]
  lo, hi := 0, len(arr)
  for lo < hi {
    mid := (lo + hi) / 2
    if arr[mid] <= cursor do lo = mid + 1
    else do hi = mid
  }
  if lo >= len(arr) do return -1
  return arr[lo]
}

// Smallest trailing edge strictly > cursor.
next_trailing :: proc(w: ^Wav, cursor: i32) -> i32 {
  if w == nil do return -1
  arr := w.edges.trailing[:]
  lo, hi := 0, len(arr)
  for lo < hi {
    mid := (lo + hi) / 2
    if arr[mid] <= cursor do lo = mid + 1
    else do hi = mid
  }
  if lo >= len(arr) do return -1
  return arr[lo]
}

// Largest leading edge strictly < cursor.
prev_leading :: proc(w: ^Wav, cursor: i32) -> i32 {
  if w == nil do return -1
  arr := w.edges.leading[:]
  lo, hi := 0, len(arr)
  for lo < hi {
    mid := (lo + hi) / 2
    if arr[mid] < cursor do lo = mid + 1
    else do hi = mid
  }
  if lo == 0 do return -1
  return arr[lo - 1]
}
