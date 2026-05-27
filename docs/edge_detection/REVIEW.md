# Review: `compute_edges`

Review date: 2026-05-26

Scope: review the edge-detection technique implemented in
`src/audio/wav/edges.odin`, cross-check it against
`docs/edge_detection/GOALS.md` and the history recorded in
`docs/edge_detection/CHANGELOG.md`, and recommend whether the current
algorithm/architecture should stand or change.

This is a review artifact only. I did not change implementation code and did
not run build/FPS verification. That matches the requested scope: review and
recommendation, not the next implementation step.

## Process Alignment

I followed the repo's step discipline as far as it applies to a review:

- Re-read `docs/edge_detection/FEATURE.md`,
  `docs/edge_detection/PROCEDURES.md`,
  `docs/edge_detection/GOALS.md`,
  `docs/edge_detection/CHANGELOG.md`,
  `docs/edge_detection/VERIFICATIONS.md`,
  `docs/edge_detection/SUMMARY.md`, and the edge decision notes.
- Reviewed `src/audio/wav/edges.odin` and the runtime call sites in
  `src/main.odin`.
- Skipped implementation and verification phases because this task is a
  review/write-up, not Step 6 or Step 7.

The relevant acceptance signals are:

- Detection: produce sorted `leading[]` and `trailing[]` frame indices using
  RMS -> dB -> Q25/IQR thresholds -> hysteresis -> debounce.
- Navigation: make those arrays suitable for O(log N) jumps.
- Live tuning: allow K values to change at runtime.
- Performance: avoid per-frame recompute and keep cached state coherent.

## Executive Take

Claude's `compute_edges` technique is a solid first-pass detector for the
feature as written. It matches `docs/edge_detection/GOALS.md` closely,
and the design choices are appropriate for keyboard-driven skimming:

- RMS envelope is cheap and relevant to perceived loudness.
- dB scale is the right domain for thresholding audio level.
- Q25/IQR is more robust than mean/stddev for rare loud events.
- Hysteresis plus debounce is the right shape for paired onset/offset edges.
- Sorted arrays are exactly what the vim-style navigation needs.
- Lazy recompute keeps steady-state frame cost low.

I would not replace it with Otsu, spectral flux, or a complex onset detector
right now. The current algorithm is the right baseline to finish Step 5 and
write Step 6 tests against.

However, I would not call the current implementation optimal. The biggest
improvements are architectural, not algorithmic:

1. Split expensive, source-dependent analysis from cheap, K-dependent edge
   classification.
2. Reuse the envelope when K changes instead of recomputing RMS and sorting.
3. Fix cross-file invalidation if `EDGE_K_HIGH` and `EDGE_K_LOW` remain
   globals.
4. Compute channel energy as sum-of-squares instead of averaging channels
   before squaring.
5. Consider rolling RMS to avoid scanning overlapping windows from scratch.

Those changes keep the same user-facing algorithm while making tuning faster,
cache correctness stronger, and future editing/visualization work easier.

## Cross-Check Against `docs/edge_detection/GOALS.md`

The implementation in `src/audio/wav/edges.odin` matches the specified
algorithm:

- RMS envelope: `compute_edges` builds 20 ms windows every 10 ms.
- dB conversion: each RMS value becomes `20 * log10(max(rms, eps))`.
- Robust thresholds: it sorts the envelope and computes Q25/Q75/IQR.
- Hysteresis: `SILENT -> ACTIVE` at `t_high`, `ACTIVE -> SILENT` at `t_low`.
- Debounce: edges closer than 50 ms are suppressed.
- Pairing: EOF closes an unterminated active region.
- Navigation: `next_leading`, `next_trailing`, and `prev_leading` are binary
  searches over sorted arrays.

The implementation also matches the `docs/edge_detection/CHANGELOG.md` account:

- Step 1 added the algorithm and navigation procs.
- Step 2 wired lazy recompute and measured real compute costs.
- Step 5 wired K tuning and marks the playing wav dirty after each K change.

The measured costs from Step 2 are important:

| Fixture | Frames | `compute_edges` duration |
|---|---:|---:|
| `test/2sec` | 91,008 | 2.44 ms |
| `test/30sec` | 1,215,360 | 31.95 ms |
| `test/5min` | 12,733,056 | 331.28 ms |

The steady-state FPS rule is satisfied because the expensive work is lazy.
But the 331 ms long-file recompute matters for tuning and file switching.

## Findings

### 1. The Algorithm Is Reasonable, But Global K Creates Cache Staleness

Current Step 5 behavior changes package-level globals:

```odin
wav.EDGE_K_HIGH += 0.05
playing.edges.dirty = true
```

Only the currently playing file is marked dirty. If another file already had
edges computed at the old K values, switching back to it will keep stale edge
arrays even though `EDGE_K_HIGH`/`EDGE_K_LOW` changed globally.

This is the main correctness issue I see. Either:

- K is global, and changing it must invalidate every cached `Wav.edges`; or
- K is per-file/per-cache, and `Edges` must record the K values used to
  compute it.

The second option is stronger because it makes cache validity explicit.

### 2. K Tuning Recomputes Too Much

Changing K does not change the audio envelope. It only changes:

- `t_high_db`
- `t_low_db`
- the state-machine pass over `env_db`

The current implementation recomputes the whole RMS envelope and re-sorts it
on every K press. On the 5min file, that means a visible 331 ms hitch per
threshold tweak.

The better architecture is two-stage:

1. Source-dependent analysis:
   - envelope
   - Q25
   - Q75
   - hop/window metadata
2. Parameter-dependent classification:
   - thresholds
   - leading/trailing edge arrays

Then K tuning only reruns stage 2, which should be very cheap.

### 3. Stereo Mixdown Can Cancel Energy

The current RMS pass averages channels first:

```odin
acc: f32 = 0
for c in 0 ..< channels {
  acc += w.samples_raw[base + c]
}
mean := acc / f32(channels)
sum_sq += mean * mean
```

That can undercount or cancel energy when channels have opposite polarity or
strong phase differences. For edge detection, the safer default is energy
across channels:

```odin
sum_sq += (left * left + right * right) / f32(channels)
```

This matters because field recordings are not guaranteed to be phase-coherent
mono content. For detection, "any channel got loud" is usually more useful
than "the stereo average got loud."

### 4. The RMS Pass Re-Scans Overlapping Windows

The current pass uses a 20 ms window and 10 ms hop. With 50 percent overlap,
most samples are read twice. That is acceptable at current fixture sizes, but
it explains why the 5min file takes hundreds of milliseconds.

A rolling energy window would preserve the same envelope semantics while
reducing memory traffic.

### 5. Absolute dB Floors May Miss Quietly Recorded Events

The current clamps force:

- `t_high >= -48 dB`
- `t_low >= -54 dB`
- `t_high - t_low >= 6 dB`

This is useful for avoiding noise-only false positives, but it can miss real
events in very quiet raw recordings. Field-recorder gain can vary a lot.

I would keep the clamps for now because Step 5 manual tuning will reveal if
they are too strict. Longer term, I would make this policy explicit in
`Edge_Params`, not hardwired into the algorithm.

### 6. Global Percentiles Assume a Mostly Stationary File

Q25/IQR over the whole file is robust to outliers, but it assumes the file has
one broad noise-floor distribution. Long field recordings can drift: wind,
traffic, water, handling noise, or room tone can change over minutes.

If manual verification shows "works in one section, fails in another," the
next algorithmic upgrade should be local/adaptive thresholds, not Otsu.

## Is Otsu Better?

Not as the primary detector.

Otsu's method finds a threshold that best separates two histogram classes. It
can work when the envelope histogram is clearly bimodal: quiet background and
loud events. But Beach needs robust behavior across:

- sparse events in silence
- noisy files with frequent events
- files with no meaningful events
- files with a drifting noise floor

Otsu has three practical problems here:

1. Noise-only or unimodal files still get a threshold, so false positives are
   likely.
2. It gives one threshold, not a natural hysteresis pair.
3. It removes the simple K tuning model that Step 5 is built around.

If Otsu is used later, I would use it only as an optional way to propose an
initial `K_HIGH`, not as the core edge detector.

## Better Architecture

The main improvement is to split analysis from classification.

Proposed shape:

```odin
Edge_Params :: struct {
  k_high:        f32,
  k_low:         f32,
  hop_ms:        f32,
  win_ms:        f32,
  min_gap_ms:    f32,
  db_floor:      f32,
  min_gap_db:    f32,
}

Edge_Analysis :: struct {
  env_db:     []f32,
  q25_db:     f32,
  q75_db:     f32,
  sample_rate: f32,
  hop_frames: i32,
  win_frames: i32,
  total:      i32,
  dirty:      bool,
}

Edges :: struct {
  leading:     [dynamic]i32,
  trailing:    [dynamic]i32,
  dirty:       bool,
  params_used: Edge_Params,
  t_high_db:   f32,
  t_low_db:    f32,
}
```

With that model:

- Editing or reloading audio marks `analysis.dirty = true`.
- K changes mark only `edges.dirty = true`.
- `ensure_edges_fresh` recomputes the envelope only when source audio changes.
- `ensure_edges_fresh` recomputes leading/trailing when params change.
- Cached edge arrays can never silently disagree with the K values that
  produced them.

### Current-Architecture Minimum Fix

If the current global-K design stays, the simplest correctness fix is to mark
all loaded wavs dirty when K changes:

```odin
mark_all_edges_dirty :: proc() {
  for i in 1 ..= g.num_waves {
    w := get_wav(Wave_Handle(i))
    if w != nil {
      w.edges.dirty = true
    }
  }
}

if key_down[.RIGHT_BRACKET] {
  wav.EDGE_K_HIGH += 0.05
  mark_all_edges_dirty()
  key_down[.RIGHT_BRACKET] = false
}
```

That is not ideal because it makes future file switches pay recompute cost,
but it keeps global K semantically honest.

### Preferred Fix: Cache Params Used

Better is to make edge validity depend on params:

```odin
edge_params_current :: proc() -> Edge_Params {
  return {
    k_high     = EDGE_K_HIGH,
    k_low      = EDGE_K_LOW,
    hop_ms     = f32(EDGE_HOP_MS),
    win_ms     = f32(EDGE_WIN_MS),
    min_gap_ms = f32(EDGE_MIN_GAP_MS),
    db_floor   = EDGE_DB_FLOOR,
    min_gap_db = EDGE_MIN_HIGH_GAP_DB,
  }
}

edge_params_equal :: proc(a, b: Edge_Params) -> bool {
  return a.k_high == b.k_high &&
         a.k_low == b.k_low &&
         a.hop_ms == b.hop_ms &&
         a.win_ms == b.win_ms &&
         a.min_gap_ms == b.min_gap_ms &&
         a.db_floor == b.db_floor &&
         a.min_gap_db == b.min_gap_db
}

ensure_edges_fresh :: proc(w: ^Wav, allocator: mem.Allocator) {
  if w == nil do return

  params := edge_params_current()
  if !w.edges.dirty && edge_params_equal(w.edges.params_used, params) {
    return
  }

  delete(w.edges.leading)
  delete(w.edges.trailing)
  w.edges = compute_edges_with_params(w, params, allocator)
}
```

This still recomputes the full algorithm, but it prevents stale caches.

## Better Implementation: Reuse Analysis

The next step up is to introduce a source-analysis cache and classify edges
from that cache.

### Channel-Safe Per-Frame Energy

Use channel energy, not averaged samples:

```odin
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
```

### Rolling RMS Envelope

This preserves the current 20 ms window / 10 ms hop semantics while avoiding
full re-scan of every overlapping window:

```odin
EDGE_POWER_EPS :: EDGE_LIN_EPS * EDGE_LIN_EPS

compute_edge_analysis :: proc(w: ^Wav, allocator: mem.Allocator) -> Edge_Analysis {
  out: Edge_Analysis
  if w == nil || w.num_samples == 0 || w.channels <= 0 do return out

  sr := f32(w.frequency)
  hop_frames := max(1, int(EDGE_HOP_MS * 0.001 * sr))
  win_frames := max(hop_frames, int(EDGE_WIN_MS * 0.001 * sr))
  total := int(total_frames(w))
  if total < win_frames do return out

  num_hops := (total - win_frames) / hop_frames + 1
  env_db := make([]f32, num_hops, allocator)

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
      window_power += frame_energy(w, add_start + i)
    }
  }

  sorted := make([]f32, len(env_db), allocator)
  defer delete(sorted, allocator)
  copy(sorted, env_db)
  slice.sort(sorted)

  out.env_db = env_db
  out.q25_db = percentile_sorted(sorted, 0.25)
  out.q75_db = percentile_sorted(sorted, 0.75)
  out.sample_rate = sr
  out.hop_frames = i32(hop_frames)
  out.win_frames = i32(win_frames)
  out.total = i32(total)
  out.dirty = false
  return out
}
```

Notes:

- This uses `10 * log10(power)` instead of `20 * log10(rms)`. They are
  equivalent because `power = rms * rms`.
- The rolling window assumes each next hop still has a full window, which is
  true for `num_hops := (total - win_frames) / hop_frames + 1`.

### Classify Edges From Cached Analysis

Now K tuning can rerun only this pass:

```odin
compute_edges_from_analysis :: proc(
  analysis: ^Edge_Analysis,
  params: Edge_Params,
  allocator: mem.Allocator,
) -> Edges {
  out := Edges {
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
  if t_high - t_low < params.min_gap_db {
    t_high = t_low + params.min_gap_db
  }

  out.t_high_db = t_high
  out.t_low_db = t_low

  min_gap := i32(params.min_gap_ms * 0.001 * analysis.sample_rate)

  State :: enum {
    SILENT,
    ACTIVE,
  }

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
    append(&out.trailing, analysis.total - 1)
  }

  out.dirty = false
  return out
}
```

### Source Dirty vs Params Dirty

The full guard becomes:

```odin
ensure_edges_ready :: proc(w: ^Wav, allocator: mem.Allocator) {
  if w == nil do return

  params := edge_params_current()

  if w.edge_analysis.dirty || len(w.edge_analysis.env_db) == 0 {
    delete(w.edge_analysis.env_db, allocator)
    w.edge_analysis = compute_edge_analysis(w, allocator)
    w.edges.dirty = true
  }

  if w.edges.dirty || !edge_params_equal(w.edges.params_used, params) {
    delete(w.edges.leading)
    delete(w.edges.trailing)
    w.edges = compute_edges_from_analysis(&w.edge_analysis, params, allocator)
  }
}
```

This is the architecture I would move toward before adding more sophisticated
detectors.

## Future Algorithm Options

I would rank possible upgrades this way:

1. Keep IQR+hysteresis, split/cache the envelope, and fix channel energy.
   This is the best next move.
2. Add local adaptive thresholds if real long files show drifting noise-floor
   failures.
3. Add event-boundary refinement after coarse edge detection if future editing
   needs sample-level cut points.
4. Consider spectral flux only if amplitude-level detection misses important
   perceptual events. It is better for transients but more complex and less
   directly tied to trim boundaries.
5. Use Otsu only as a helper/default-estimator, not as the main detector.

## Test Implications For Step 6

Step 6 tests should not only assert "some edges exist." They should lock down
the edge invariants that matter to the UI:

- Silent input yields `0/0`.
- A single burst yields exactly `1/1`.
- Leading and trailing arrays are sorted.
- Leading/trailing counts match.
- `next_leading`, `next_trailing`, and `prev_leading` obey strict boundary
  semantics.
- A loud outlier does not suppress ordinary events.
- Stereo anti-phase input is still detected if channel-energy RMS is adopted.
- K changes alter edge counts without changing the source envelope if the
  two-stage cache is implemented.

## Recommendation

Do not throw away the current technique. It is a good baseline and matches
the current written goals. The best path is:

1. Finish Step 5 manual verification.
2. Write Step 6 tests against the current behavior.
3. Before or during Step 7, decide whether to split edge analysis from edge
   classification. This will make live K tuning much smoother and will line up
   naturally with the planned waveform downsampler.
4. Fix K cache validity either by marking all files dirty on global K changes
   or by storing params used in each cache.
5. Replace averaged-channel RMS with channel-energy RMS unless manual testing
   proves the current mixdown is intentionally desired.

The algorithm choice is good. The cache and analysis architecture is the part
that should evolve.
