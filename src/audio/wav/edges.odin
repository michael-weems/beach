package wav

import "core:log"
import "core:math"
import "core:mem"
import "core:slice"
import "core:time"

// Edge detection — onset/offset detection on a WAV's PCM-float buffer.
//
// Two-stage architecture:
//   Stage 1 (source-dependent): RMS envelope → dB → Q25/Q75/IQR.
//     Cached as Edge_Analysis on the Wav. Only recomputed when audio changes.
//   Stage 2 (param-dependent): IQR-anchored thresholds → hysteretic state
//     machine → debounce → leading[]/trailing[].
//     Recomputed when K values change — cheap, uses cached analysis.

// ─── Defaults ────────────────────────────────────────────────────
// Constants used as initial values for new files. Per-file params
// can diverge from these after live tuning.

EDGE_DEFAULT_K_HIGH :: f32(0.7)
EDGE_DEFAULT_K_LOW :: f32(0.4)
EDGE_DEFAULT_HOP_MS :: f32(10.0)
EDGE_DEFAULT_WIN_MS :: f32(20.0)
EDGE_DEFAULT_MIN_GAP_MS :: f32(50.0)
EDGE_DEFAULT_DB_FLOOR :: f32(-60.0)
EDGE_DEFAULT_MIN_HIGH_GAP_DB :: f32(6.0)

EDGE_LIN_EPS :: f32(1e-6)
EDGE_POWER_EPS :: EDGE_LIN_EPS * EDGE_LIN_EPS

SECTION_WINDOW_SECONDS :: f32(10.0)
SECTION_MIN_SECONDS :: f32(2.0)
SECTION_Q25_SHIFT_DB :: f32(6.0)
SECTION_SNAP_SECONDS :: f32(1.0)

// ─── Types ────────────────────────────────────────────────────────

Edge_Params :: struct {
  k_high:          f32,
  k_low:           f32,
  hop_ms:          f32,
  win_ms:          f32,
  min_gap_ms:      f32,
  db_floor:        f32,
  min_high_gap_db: f32,
}

Edge_Analysis :: struct {
  env_db:       []f32,
  q25_db:       f32,
  q75_db:       f32,
  sample_rate:  f32,
  hop_frames:   i32,
  win_frames:   i32,
  total_frames: i32,
  dirty:        bool,
}

Edges :: struct {
  leading:     [dynamic]i32,
  trailing:    [dynamic]i32,
  dirty:       bool,
  params_used: Edge_Params,
  t_high_db:   f32,
  t_low_db:    f32,
}

Edge_Status :: enum {
  Uncomputed,
  Queued,
  Computing,
  Ready,
  Failed,
}

Section_Stats :: struct {
  q10_db:    f32,
  q25_db:    f32,
  q50_db:    f32,
  q75_db:    f32,
  q90_db:    f32,
  iqr_db:    f32,
  hop_count: i32,
}

Edge_Section :: struct {
  start_hop:   i32,
  end_hop:     i32,
  start_frame: i32,
  end_frame:   i32,
  stats:       Section_Stats,
  params:      Edge_Params,
  auto_fit:    bool,
  leading:     [dynamic]i32,
  trailing:    [dynamic]i32,
}

// ─── Defaults / equality ─────────────────────────────────────────

default_edge_params :: proc() -> Edge_Params {
  return Edge_Params{
    k_high          = EDGE_DEFAULT_K_HIGH,
    k_low           = EDGE_DEFAULT_K_LOW,
    hop_ms          = EDGE_DEFAULT_HOP_MS,
    win_ms          = EDGE_DEFAULT_WIN_MS,
    min_gap_ms      = EDGE_DEFAULT_MIN_GAP_MS,
    db_floor        = EDGE_DEFAULT_DB_FLOOR,
    min_high_gap_db = EDGE_DEFAULT_MIN_HIGH_GAP_DB,
  }
}

// ─── Stage 1: Source-dependent analysis ──────────────────────────
// Builds the dB envelope and computes Q25/Q75. This is the expensive
// pass — O(total_frames) — and only needs to run when audio changes.

compute_edge_analysis :: proc(w: ^Wav, params: Edge_Params, allocator: mem.Allocator) -> Edge_Analysis {
  out: Edge_Analysis
  if w == nil || w.num_samples == 0 do return out

  channels := int(w.channels)
  if channels <= 0 do return out

  sr := f32(w.frequency)
  hop_frames := max(1, int(params.hop_ms * 0.001 * sr))
  win_frames := max(hop_frames, int(params.win_ms * 0.001 * sr))
  total := int(total_frames(w))
  if total < win_frames do return out

  num_hops := (total - win_frames) / hop_frames + 1
  env_db := make([]f32, num_hops, allocator)

  // Rolling RMS window — avoids rescanning overlapping samples.
  window_power: f32 = 0
  for f in 0 ..< win_frames {
    window_power += frame_energy(w, f)
  }

  for h in 0 ..< num_hops {
    mean_power := window_power / f32(win_frames)
    env_db[h] = 10.0 * math.log10(max(mean_power, EDGE_POWER_EPS))

    if h == num_hops - 1 do break

    old_start := h * hop_frames
    add_start := old_start + win_frames
    for i in 0 ..< hop_frames {
      window_power -= frame_energy(w, old_start + i)
      if add_start + i < total {
        window_power += frame_energy(w, add_start + i)
      }
    }
  }

  sorted := make([]f32, num_hops, allocator)
  defer delete(sorted, allocator)
  copy(sorted, env_db)
  slice.sort(sorted)

  out.env_db = env_db
  out.q25_db = percentile_sorted(sorted, 0.25)
  out.q75_db = percentile_sorted(sorted, 0.75)
  out.sample_rate = sr
  out.hop_frames = i32(hop_frames)
  out.win_frames = i32(win_frames)
  out.total_frames = i32(total)
  out.dirty = false
  return out
}

// Channel-safe per-frame energy: sum of squares across channels.
// Avoids energy cancellation from stereo phase differences.
frame_energy :: proc(w: ^Wav, frame: int) -> f32 {
  channels := int(w.channels)
  base := frame * channels
  sum_sq: f32 = 0
  for c in 0 ..< channels {
    s := w.samples_raw[base + c]
    sum_sq += s * s
  }
  return sum_sq / f32(channels)
}

// ─── Stage 2: Param-dependent classification ─────────────────────
// Runs the hysteretic state machine over a cached analysis. This is
// the cheap pass — O(num_hops) — and runs on every K change.

classify_edges :: proc(analysis: ^Edge_Analysis, params: Edge_Params, allocator: mem.Allocator) -> Edges {
  out := Edges{
    leading     = make([dynamic]i32, allocator),
    trailing    = make([dynamic]i32, allocator),
    params_used = params,
  }

  if analysis == nil || len(analysis.env_db) == 0 do return out

  iqr := analysis.q75_db - analysis.q25_db
  t_high := analysis.q25_db + params.k_high * iqr
  t_low := analysis.q25_db + params.k_low * iqr

  t_high = max(t_high, params.db_floor + 12.0)
  t_low = max(t_low, params.db_floor + 6.0)
  if t_high - t_low < params.min_high_gap_db {
    t_high = t_low + params.min_high_gap_db
  }
  out.t_high_db = t_high
  out.t_low_db = t_low

  min_gap := i32(params.min_gap_ms * 0.001 * analysis.sample_rate)

  State :: enum { SILENT, ACTIVE }
  state := State.SILENT
  last_edge := i32(-min_gap)

  for v, h in analysis.env_db {
    frame := i32(h) * analysis.hop_frames
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

  if state == .ACTIVE {
    append(&out.trailing, analysis.total_frames - 1)
  }

  out.dirty = false
  return out
}

// ─── Per-section K fitting ────────────────────────────────────────
// Derives K values from each section's local envelope stats. Sections
// with wide IQR (clear events) get standard K; sections with narrow
// IQR (uniform floor) get high K to suppress false positives.

SECTION_MIN_IQR_DB :: f32(3.0)

fit_section_params :: proc(section: ^Edge_Section, base_params: Edge_Params) {
  iqr := section.stats.iqr_db

  if iqr < SECTION_MIN_IQR_DB {
    section.params.k_high = 2.0
    section.params.k_low = 1.5
  } else {
    range_db := section.stats.q90_db - section.stats.q10_db
    if range_db > 20.0 {
      section.params.k_high = max(0.3, base_params.k_high - 0.2)
      section.params.k_low = max(0.1, base_params.k_low - 0.2)
    } else {
      section.params.k_high = base_params.k_high
      section.params.k_low = base_params.k_low
    }
  }
  section.auto_fit = true
}

// ─── Per-section classification + merge ──────────────────────────

classify_section :: proc(
  section: ^Edge_Section,
  analysis: ^Edge_Analysis,
  allocator: mem.Allocator,
) {
  delete(section.leading)
  delete(section.trailing)
  section.leading = make([dynamic]i32, allocator)
  section.trailing = make([dynamic]i32, allocator)

  if analysis == nil || len(analysis.env_db) == 0 do return
  if section.end_hop <= section.start_hop do return

  env_slice := analysis.env_db[section.start_hop:section.end_hop]
  iqr := section.stats.iqr_db
  t_high := section.stats.q25_db + section.params.k_high * iqr
  t_low := section.stats.q25_db + section.params.k_low * iqr

  t_high = max(t_high, section.params.db_floor + 12.0)
  t_low = max(t_low, section.params.db_floor + 6.0)
  if t_high - t_low < section.params.min_high_gap_db {
    t_high = t_low + section.params.min_high_gap_db
  }

  min_gap := i32(section.params.min_gap_ms * 0.001 * analysis.sample_rate)

  State :: enum { SILENT, ACTIVE }
  state := State.SILENT
  last_edge := i32(-min_gap)

  for v, h in env_slice {
    frame := i32(section.start_hop + i32(h)) * analysis.hop_frames
    switch state {
    case .SILENT:
      if v >= t_high && (frame - last_edge) >= min_gap {
        append(&section.leading, frame)
        last_edge = frame
        state = .ACTIVE
      }
    case .ACTIVE:
      if v <= t_low && (frame - last_edge) >= min_gap {
        append(&section.trailing, frame)
        last_edge = frame
        state = .SILENT
      }
    }
  }

  if state == .ACTIVE {
    append(&section.trailing, section.end_frame - 1)
  }
}

fit_and_classify_sections :: proc(
  sections: []Edge_Section,
  analysis: ^Edge_Analysis,
  base_params: Edge_Params,
  allocator: mem.Allocator,
) {
  for &s in sections {
    if s.auto_fit do fit_section_params(&s, base_params)
    classify_section(&s, analysis, allocator)
  }
}

merge_section_edges :: proc(sections: []Edge_Section, allocator: mem.Allocator) -> Edges {
  out := Edges{
    leading  = make([dynamic]i32, allocator),
    trailing = make([dynamic]i32, allocator),
  }
  for s in sections {
    for l in s.leading do append(&out.leading, l)
    for t in s.trailing do append(&out.trailing, t)
  }
  out.dirty = false
  return out
}

// ─── Combined convenience ────────────────────────────────────────
// Full compute from raw samples. Used by tests and tools.

compute_edges :: proc(w: ^Wav, allocator: mem.Allocator) -> Edges {
  return compute_edges_with_params(w, allocator, EDGE_DEFAULT_K_HIGH, EDGE_DEFAULT_K_LOW)
}

compute_edges_with_params :: proc(w: ^Wav, allocator: mem.Allocator, k_high, k_low: f32) -> Edges {
  params := default_edge_params()
  params.k_high = k_high
  params.k_low = k_low
  analysis := compute_edge_analysis(w, params, allocator)
  defer delete(analysis.env_db, allocator)
  edges := classify_edges(&analysis, params, allocator)
  return edges
}

// ─── Lifecycle ───────────────────────────────────────────────────

delete_edges :: proc(edges: ^Edges) {
  if edges == nil do return
  delete(edges.leading)
  delete(edges.trailing)
  edges^ = {}
}

delete_edge_analysis :: proc(analysis: ^Edge_Analysis, allocator: mem.Allocator) {
  if analysis == nil do return
  delete(analysis.env_db, allocator)
  analysis^ = {}
}

copy_edge_analysis :: proc(src: ^Edge_Analysis, allocator: mem.Allocator) -> Edge_Analysis {
  out := src^
  if len(src.env_db) > 0 {
    out.env_db = make([]f32, len(src.env_db), allocator)
    copy(out.env_db, src.env_db)
  }
  return out
}

// ─── Dirty management ────────────────────────────────────────────

// Mark edges dirty. Old edges are retained for display until new ones
// are installed — avoids tick flicker between the dirty mark and the
// scheduler installing fresh results.
mark_edges_dirty :: proc(w: ^Wav) {
  if w == nil do return
  w.edges.dirty = true
  w.edge_status = .Uncomputed
  w.edge_generation += 1
}

edges_need_analysis :: proc(w: ^Wav) -> bool {
  if w == nil || !w.edges.dirty do return false
  return w.edge_status == .Uncomputed || w.edge_status == .Failed
}

analysis_is_cached :: proc(w: ^Wav) -> bool {
  if w == nil do return false
  return !w.edge_analysis.dirty && len(w.edge_analysis.env_db) > 0
}

edge_status_string :: proc(status: Edge_Status) -> string {
  switch status {
  case .Uncomputed: return "uncomputed"
  case .Queued: return "queued"
  case .Computing: return "computing"
  case .Ready: return "ready"
  case .Failed: return "failed"
  }
  return "unknown"
}

// ─── Helpers ─────────────────────────────────────────────────────

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

// ─── Synchronous recompute ───────────────────────────────────────
// Runtime edge analysis is scheduled by the main-thread edge scheduler.
// This helper remains for tests/tools or direct synchronous callers.

ensure_edges_fresh :: proc(w: ^Wav, allocator: mem.Allocator) {
  if w == nil || !w.edges.dirty do return

  if w.edge_analysis.dirty || len(w.edge_analysis.env_db) == 0 {
    delete(w.edge_analysis.env_db, allocator)
    start := time.now()
    w.edge_analysis = compute_edge_analysis(w, w.edge_params, allocator)
    duration_ms := time.duration_milliseconds(time.since(start))
    log.debugf("edge analysis: %s, %.2f ms", w.file_name, duration_ms)
  }

  delete(w.edges.leading)
  delete(w.edges.trailing)
  w.edges = classify_edges(&w.edge_analysis, w.edge_params, allocator)
  w.edge_status = .Ready

  frames := i32(0)
  if w.channels > 0 do frames = w.num_samples / i32(w.channels)
  log.debugf(
    "classify_edges: %s, %d frames, leading=%d trailing=%d t_high=%.2f t_low=%.2f",
    w.file_name,
    frames,
    len(w.edges.leading),
    len(w.edges.trailing),
    w.edges.t_high_db,
    w.edges.t_low_db,
  )
}

// ─── Section discovery ───────────────────────────────────────────
// Analyzes the cached dB envelope to find regions with distinct noise
// floor / dynamic range. Output: sorted, non-overlapping sections
// covering the whole file.

discover_sections :: proc(
  analysis: ^Edge_Analysis,
  base_params: Edge_Params,
  allocator: mem.Allocator,
) -> [dynamic]Edge_Section {
  out := make([dynamic]Edge_Section, allocator)

  if analysis == nil || len(analysis.env_db) == 0 do return out

  num_hops := i32(len(analysis.env_db))
  hops_per_window := max(1, i32(SECTION_WINDOW_SECONDS * analysis.sample_rate / f32(analysis.hop_frames)))
  min_section_hops := max(1, i32(SECTION_MIN_SECONDS * analysis.sample_rate / f32(analysis.hop_frames)))
  snap_radius := max(1, i32(SECTION_SNAP_SECONDS * analysis.sample_rate / f32(analysis.hop_frames)))

  // Need at least 2 windows for boundary detection. Scale window size
  // down for short files so they can still have sections.
  effective_window := hops_per_window
  if num_hops <= hops_per_window * 2 && num_hops > min_section_hops * 2 {
    effective_window = max(min_section_hops, num_hops / 3)
  } else if num_hops <= min_section_hops * 2 {
    append(&out, section_from_range(analysis, 0, num_hops, base_params, allocator))
    return out
  }

  num_windows := (num_hops + effective_window - 1) / effective_window
  win_q25 := make([]f32, num_windows, allocator)
  defer delete(win_q25, allocator)

  for i in 0 ..< num_windows {
    start := i * effective_window
    end := min((i + 1) * effective_window, num_hops)
    win_q25[i] = slice_percentile(analysis.env_db[start:end], 0.25, allocator)
  }

  boundaries := make([dynamic]i32, allocator)
  defer delete(boundaries)

  for i in 1 ..< num_windows {
    shift := win_q25[i] - win_q25[i - 1]
    if shift > SECTION_Q25_SHIFT_DB || shift < -SECTION_Q25_SHIFT_DB {
      raw_hop := i * effective_window
      snapped := snap_to_trough(analysis.env_db[:], raw_hop, snap_radius)
      append(&boundaries, snapped)
    }
  }

  if len(boundaries) == 0 {
    append(&out, section_from_range(analysis, 0, num_hops, base_params, allocator))
    return out
  }

  append(&out, section_from_range(analysis, 0, boundaries[0], base_params, allocator))
  for i in 1 ..< len(boundaries) {
    append(&out, section_from_range(analysis, boundaries[i - 1], boundaries[i], base_params, allocator))
  }
  append(&out, section_from_range(analysis, boundaries[len(boundaries) - 1], num_hops, base_params, allocator))

  merge_short_sections(&out, min_section_hops, analysis, base_params, allocator)
  return out
}

section_from_range :: proc(
  analysis: ^Edge_Analysis,
  start_hop, end_hop: i32,
  params: Edge_Params,
  allocator: mem.Allocator,
) -> Edge_Section {
  end_frame: i32
  if end_hop >= i32(len(analysis.env_db)) {
    end_frame = analysis.total_frames
  } else {
    end_frame = end_hop * analysis.hop_frames
  }
  return Edge_Section{
    start_hop   = start_hop,
    end_hop     = end_hop,
    start_frame = start_hop * analysis.hop_frames,
    end_frame   = end_frame,
    stats       = compute_section_stats(analysis.env_db[start_hop:end_hop], allocator),
    params      = params,
    auto_fit    = true,
  }
}

compute_section_stats :: proc(env_slice: []f32, allocator: mem.Allocator) -> Section_Stats {
  if len(env_slice) == 0 do return {}
  sorted := make([]f32, len(env_slice), allocator)
  defer delete(sorted, allocator)
  copy(sorted, env_slice)
  slice.sort(sorted)
  q25 := percentile_sorted(sorted, 0.25)
  q75 := percentile_sorted(sorted, 0.75)
  return Section_Stats{
    q10_db    = percentile_sorted(sorted, 0.10),
    q25_db    = q25,
    q50_db    = percentile_sorted(sorted, 0.50),
    q75_db    = q75,
    q90_db    = percentile_sorted(sorted, 0.90),
    iqr_db    = q75 - q25,
    hop_count = i32(len(env_slice)),
  }
}

slice_percentile :: proc(data: []f32, p: f32, allocator: mem.Allocator) -> f32 {
  if len(data) == 0 do return 0
  sorted := make([]f32, len(data), allocator)
  defer delete(sorted, allocator)
  copy(sorted, data)
  slice.sort(sorted)
  return percentile_sorted(sorted, p)
}

snap_to_trough :: proc(env_db: []f32, hop: i32, radius: i32) -> i32 {
  n := i32(len(env_db))
  lo := max(0, hop - radius)
  hi := min(n, hop + radius)
  if lo >= hi do return hop

  best := lo
  for h in lo + 1 ..< hi {
    if env_db[h] < env_db[best] do best = h
  }
  return best
}

merge_short_sections :: proc(
  sections: ^[dynamic]Edge_Section,
  min_hops: i32,
  analysis: ^Edge_Analysis,
  base_params: Edge_Params,
  allocator: mem.Allocator,
) {
  i := 0
  for i < len(sections^) {
    hops := sections^[i].end_hop - sections^[i].start_hop
    if hops < min_hops && len(sections^) > 1 {
      if i == 0 {
        sections^[1].start_hop = sections^[0].start_hop
        sections^[1].start_frame = sections^[0].start_frame
        sections^[1].stats = compute_section_stats(
          analysis.env_db[sections^[1].start_hop:sections^[1].end_hop], allocator,
        )
        ordered_remove(sections, 0)
      } else {
        sections^[i - 1].end_hop = sections^[i].end_hop
        sections^[i - 1].end_frame = sections^[i].end_frame
        sections^[i - 1].stats = compute_section_stats(
          analysis.env_db[sections^[i - 1].start_hop:sections^[i - 1].end_hop], allocator,
        )
        ordered_remove(sections, i)
      }
    } else {
      i += 1
    }
  }
}

section_for_frame :: proc(sections: []Edge_Section, frame: i32) -> int {
  for s, i in sections {
    if frame >= s.start_frame && frame < s.end_frame do return i
  }
  if len(sections) > 0 do return len(sections) - 1
  return -1
}

delete_all_sections :: proc(sections: ^[dynamic]Edge_Section) {
  for &s in sections {
    delete(s.leading)
    delete(s.trailing)
  }
  delete(sections^)
}

// ─── Navigation ──────────────────────────────────────────────────
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
