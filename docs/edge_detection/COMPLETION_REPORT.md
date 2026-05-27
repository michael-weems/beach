# Edge Detection Feature — Completion Report

Feature: vim-style edge navigation for Beach (onset/offset detection on WAV files).
Completed: 2026-05-26. Implementation: Steps 1–12 plus 9a and 11a.

## What It Does

Detects audio event boundaries (onsets and offsets) in loaded WAV files and
exposes `w`/`e`/`b` vim-style motions to jump between them. Each file is
automatically split into sections with distinct noise characteristics, and K
sensitivity values are fitted per-section. The user can override K values per
section or shift all sections uniformly.

## Architecture

### Algorithm: IQR-Anchored Hysteretic Edge Detection

The detector uses robust percentile statistics to set thresholds that adapt to
each section's noise floor without being skewed by outliers or bimodal content.

**Why this algorithm:** Mean/stddev fails when rare loud transients inflate the
threshold and suppress normal events. Otsu's method has no natural hysteresis
pair (one threshold, not two), forces false positives on unimodal silent files,
and removes the tunable K knob. IQR+K gives robust adaptive thresholds, clean
hysteresis, and a single intuitive sensitivity parameter.

**Trade-offs:** Assumes a roughly stationary noise floor within each section
(addressed by section discovery). Cannot detect events defined by spectral
change rather than amplitude change (e.g., a bird call at the same loudness as
wind). The 10ms hop resolution limits edge placement precision to ~441 samples
at 44.1kHz.

```
ALGORITHM: Per-Section Edge Detection

INPUT:  samples_raw[]    — interleaved PCM float audio
        section          — start/end hop range + fitted K values
OUTPUT: leading[], trailing[] — paired frame indices

── Stage 1: Source Analysis (cached, runs once per file load) ──

hop_frames  = sample_rate * 0.010        // 10ms
win_frames  = sample_rate * 0.020        // 20ms
num_hops    = (total_frames - win_frames) / hop_frames + 1

// Rolling RMS envelope in dB (channel-energy, not averaged)
window_power = sum(frame_energy(f) for f in 0..win_frames)
for each hop h:
    env_db[h] = 10 * log10(window_power / win_frames)
    slide window: subtract old frames, add new frames

// Robust statistics
sort(env_db) → compute Q25, Q75
IQR = Q75 - Q25

── Stage 2: Classification (runs on every K change) ──

// Per-section thresholds from local stats
T_high = section.Q25 + K_HIGH * section.IQR
T_low  = section.Q25 + K_LOW  * section.IQR
clamp: T_high >= db_floor + 12, T_low >= db_floor + 6, gap >= 6 dB

// Hysteretic state machine with 50ms debounce
state = SILENT
for each hop h in section:
    frame = h * hop_frames
    if state == SILENT and env_db[h] >= T_high and gap_ok:
        leading.append(frame)
        state = ACTIVE
    if state == ACTIVE and env_db[h] <= T_low and gap_ok:
        trailing.append(frame)
        state = SILENT
if state == ACTIVE:
    trailing.append(section.end_frame - 1)    // close at EOF
```

### Two-Stage Pipeline

1. **Source analysis** (`compute_edge_analysis`) — expensive, O(total_frames).
   Builds a rolling-RMS dB envelope (10ms hops, 20ms window), computes
   Q25/Q75/IQR. Cached on `Wav.edge_analysis`; only recomputes when audio
   source changes.

2. **Classification** (`classify_edges` / `classify_section`) — cheap,
   O(num_hops). Runs the hysteretic state machine over the cached envelope
   using per-section K values. Reruns instantly on K changes.

### Section Discovery

`discover_sections` divides the cached envelope into coarse windows, detects
Q25 shifts (≥6 dB), snaps boundaries to low-energy troughs, and merges
sections shorter than 2 seconds. Each section carries local `Section_Stats`
and independently-fitted `Edge_Params`.

### Per-Section K Fitting

`fit_section_params` derives K from local envelope statistics:
- Narrow IQR (<3 dB, uniform floor): high K → suppresses false positives.
- Wide dynamic range (>20 dB Q10–Q90): lower K → more sensitive detection.
- Normal sections: default K values.

### Background Scheduler

A one-worker thread pool handles initial edge analysis without blocking the
render/audio frame. Results are installed on the main thread with generation-
based staleness checks. K tuning bypasses the scheduler entirely — reclassify
and merge runs synchronously on the same frame.

### Waveform Rendering

Pre-computed min/max envelope cache (256-frame buckets) computed at file load.
Per-frame draw reads O(screen_width) cached values. Preserves narrow peaks that
single-sample downsampling misses.

## Code Layout

| File | Role |
|---|---|
| `src/audio/wav/edges.odin` | Algorithm, types, section discovery, navigation |
| `src/audio/wav/edges_test.odin` | 17 unit tests |
| `src/audio/wav/wav.odin` | `Wav` struct (edges, analysis, params, sections, cache) |
| `src/main.odin` | Scheduler, K tuning, overlay, waveform draw |

## Key Types

- `Edge_Params` — k_high, k_low, hop/win/gap/floor/gap_db per section.
- `Edge_Analysis` — cached env_db[], Q25, Q75, hop/win metadata.
- `Edge_Section` — start/end hops+frames, local stats, params, per-section edges.
- `Edges` — merged leading[]/trailing[] for file-level navigation.
- `Waveform_Cache` — pre-computed min/max for rendering.

## Key Bindings

| Key | Action |
|---|---|
| `w` | Jump to next leading edge |
| `e` | Jump to next trailing edge |
| `b` | Jump to previous leading edge |
| `[` / `]` | Adjust active section K_HIGH ±0.05 |
| `-` / `=` | Adjust active section K_LOW ±0.05 |
| Shift+`[`/`]` | Adjust ALL sections K_HIGH ±0.05 |
| Shift+`-`/`=` | Adjust ALL sections K_LOW ±0.05 |

## Constraints and Hard Rules

- **Source files are never modified.** All edge data is derived and cached.
- **Lazy/cached state must stay coherent.** Two dirty dimensions: analysis
  dirty (source changed) and edges dirty (K changed). Generation counter
  prevents stale worker results from installing.
- **No per-frame recompute.** Steady-state cost: one dirty check + bounded
  scheduler poll per frame.
- **60+ FPS minimum, 120+ preferred.** Achieved: ~120 FPS on all fixtures
  after Nvidia control panel fix.

## Decisions and Rationale

| Decision | Why |
|---|---|
| IQR+K over Otsu | Otsu has no natural hysteresis, forces false positives on unimodal files, and removes the tunable K knob |
| Per-section over global K | Manual verification proved a single K fails across files and within long files |
| Heap allocator for edges | Arena can't free individual allocations; K tuning needs delete+realloc |
| Rolling RMS | Avoids rescanning overlapping windows in the envelope pass |
| Channel energy (sum-of-squares) | Prevents stereo phase cancellation from hiding events |
| One worker, main-thread install | Simple ownership model; no shared mutable state between threads |
| Retain old edges on dirty | Eliminates tick flicker between mark-dirty and install |
| Pre-computed waveform cache | Bounds per-frame draw cost to O(screen_width) regardless of file length |

## Verification Protocol

- **Build:** `bash ./build_odin` — exit zero, no warnings.
- **Tests:** `bash ./test_odin` — 17 tests, all passing.
- **FPS:** 3-second captures via `BEACH_RUN_SECONDS=3 BEACH_FRAME_LOG=<path>`.
  Compare with `./claude_fps`. Accept ±5% delta between steps.
- **Edge sanity:** leading == trailing count (paired invariant); compute
  duration bounded for file size.
- **Manual UI:** "press X → expect Y" checklist when input/drawing changes.

## Test Fixtures

| File | Duration | Format | Sections |
|---|---|---|---:|
| `test/2sec/2sec.wav` | 1.9s | 24-bit PCM, 48kHz stereo | 1 |
| `test/30sec/250813_0074.wav` | 27.6s | IEEE float, 44.1kHz stereo | 3 |
| `test/5min/250813_0062.wav` | 4:48 | IEEE float, 44.1kHz stereo | 8 |

## Known Limitations and Future Work

- **K values don't persist across launches.** Per-section params reset to
  auto-fit defaults on every load. Needs a sidecar file or config system.
- **Audio editing is out of scope.** `dw`/`de`/`db` cut operations require
  immutable-source architecture, undo/redo, and save-as-new-file design.
  Edges provide the boundary data that editing will eventually consume.
- **K input not clamped.** Can be pushed arbitrarily negative. Algorithm
  self-clamps thresholds, but overlay shows wild numbers. Low priority.
- **Alternative algorithms.** Spectral flux, sliding-window adaptive
  thresholds, and event-boundary refinement are documented future options.
  IQR+K remains sufficient for the keyboard-skimming use case.

## Odin-Specific Lessons

- **SOA + `using` compiler bug:** `arr[i].x` panics compiler when `arr:
  #soa[]T` with `using sub: SubType`. Workaround: explicit field step
  (`arr[i].sub.x`).
- **SOA produces value copies:** `e := arr[i]` for `#soa[]T` copies; use
  `&arr[i]` for mutation.
- **`thread.pool_finish` vs `pool_join`:** `finish` drains the queue;
  `join` abandons unprocessed tasks.
- **Dynamic arrays track their allocator;** slices do not. Pass explicit
  allocator when freeing slices.
- **Bool defaults to false.** Initialize explicitly when "true" is the
  intended starting state (e.g., `auto_fit = true`).
