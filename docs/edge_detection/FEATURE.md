# Edge Detection Feature — Implementation Plan

The forward-looking plan for the edge-detection feature. Per-step work
log lives in [docs/edge_detection/CHANGELOG.md](./CHANGELOG.md);
goals/acceptance signals in [docs/edge_detection/GOALS.md](./GOALS.md);
how to execute a step in
[docs/edge_detection/PROCEDURES.md](./PROCEDURES.md); the technical
verification checks in
[docs/edge_detection/VERIFICATIONS.md](./VERIFICATIONS.md).

## Status

| # | Step | Status |
|---|---|---|
| 1 | Edge detection module (types + algorithm + nav procs) | ✅ Complete |
| A+B | Edges allocator + FPS instrumentation (micro-step) | ✅ Complete |
| 2 | Lazy recompute + initial dirty flag | ✅ Complete |
| 3 | `w` / `e` / `b` navigation | ✅ Complete |
| 4 | Edge tick visualization on sgl waveform | ✅ Complete (alignment fix in Step 5) |
| 5 | Debug overlay + live K tuning (+ Step 3/4 bug fixes) | 🟡 Manual verification complete; follow-ups planned |
| 6 | Unit tests for current `compute_edges` behavior | ✅ Complete |
| 7 | Tick-position audit/fix | ✅ Complete |
| 8 | Remove first-edge-calculation stutter | ✅ Complete |
| 9 | Refactor K globals into per-file edge params + analysis cache | ✅ Complete |
| 9a | Smooth tick transition on K change (retain old edges until new ready) | ✅ Complete |
| 10 | Automatic section discovery for adaptive edge params | ✅ Complete |
| 11 | Automatic per-section K fitting + per-section classification | ✅ Complete |
| 11a | Bulk K adjustment across all sections (Shift+keys) | ✅ Complete |
| 12 | `draw_wavelength` min/max envelope downsampler | ✅ Complete (~120 FPS confirmed) |

## Latest manual verification findings

Michael completed the Step 5 checklist in
[`docs/edge_detection/K_LEVEL_OVERVIEW.md`](./K_LEVEL_OVERVIEW.md). The important
findings are:

- A single `(K_HIGH, K_LOW)` does **not** work across all 3 test files.
  Different files want different settings, and different sections inside
  the same file can want different settings.
- Tick placement is inconsistent by eye/ear: sometimes behind an event,
  sometimes ahead, sometimes correct. This may be a rendering-position issue
  rather than an edge-detection issue.
- K-extreme tests were stable: no crashes, freezes, or rendering weirdness.

Plan impact: Step 6 protected the current algorithm with tests, and Step 7
removed a rendering-alignment confounder. Michael's Step 7 manual verification
confirmed the 5min waveform now aligns with the other files' FPS, but it also
confirmed a visible first-edge-calculation stutter when switching to the 5min
file. Step 8 moved edge work to a small background scheduler. Step 9 replaced
package-level K globals with per-file `Edge_Params` and introduced a two-stage
analysis/classify pipeline with a cached source envelope.

## Step details

### Step 1 — Edge detection module ✅

Define the algorithm and types; nothing wired into runtime.

- **What:** `Edges` struct, `compute_edges` proc (RMS → dB → Q25/IQR
  thresholds → hysteresis → debounce), `percentile_sorted` helper,
  navigation procs (`next_leading`, `next_trailing`, `prev_leading`).
  Replace placeholder `leading_edges` / `trailing_edges` fields on
  `Wav` with `edges: Edges`. `EDGE_K_HIGH` and `EDGE_K_LOW` are
  package-level mutable globals.
- **Files:** new `src/audio/wav/edges.odin`; modified
  `src/audio/wav/wav.odin`.
- **Goal alignment:** Detection, Navigation, Live tuning, Performance
  (dirty flag declared; no per-frame work).

### Micro-step A+B — Allocator + FPS instrumentation ✅

Scaffolding required before runtime steps.

- **What:** Add `edges_allocator: mem.Allocator` to `Alloc`, backed by
  `runtime.default_allocator()` (heap supports individual `delete`).
  Add env-var-gated frame logger (`BEACH_FRAME_LOG=<path>`) and
  self-terminate (`BEACH_RUN_SECONDS=<n>`). Establish FPS baselines
  for the three test fixtures.
- **Files:** `src/main.odin`, `.gitignore`.

### Step 2 — Lazy recompute + initial dirty flag ✅

Make `compute_edges` actually run, but only when stale.

- **What:** Set `wave.edges.dirty = true` at end of
  `wav.read_from_file`. Add `ensure_edges_fresh(w, allocator)`; call
  it once per frame in `update_gui` on the playing wav. Free old
  `leading` / `trailing` arrays before reassigning.
- **Files:** `src/audio/wav/wav.odin`, `src/audio/wav/edges.odin`,
  `src/main.odin`.
- **Goal alignment:** Performance (steady-state overhead = 1 bool
  check); Detection (edges actually computed on real files).

### Step 3 — `w` / `e` / `b` navigation ✅

Wire the vim-style edge motions.

- **What:** Replace the `.E`/`.B` placeholder blocks (which called
  `wav.scan_forward`/`wav.scan_backward`) and add a `.W` block. Each
  calls the corresponding nav proc and assigns the returned frame
  index to `playing.frame_cursor` when it's `>= 0`. Cursor stays put
  on out-of-range return (`-1`).
- **Files:** `src/main.odin`.
- **Goal alignment:** Navigation.

### Step 4 — Edge tick visualization ✅

Draw vertical ticks at each detected edge on the live sgl waveform.

- **What:** After the waveform's line strip in `draw_wavelength`,
  draw a green vertical line at each `leading[]` frame and a red
  vertical line at each `trailing[]` frame. Tick x-coordinate uses
  the same `x_step` as the waveform; tick y-span is a small fraction
  of the visible vertical range.
- **Files:** `src/main.odin`.
- **Goal alignment:** Visualization.
- **Risks:** sgl vertex budget — current `draw_wavelength` already
  pushes ~25 M verts on the 5min file. Each edge adds 2 more verts
  per tick × dozens of edges. Negligible by comparison, but worth
  noting.

### Step 5 — Debug overlay + live K tuning 🟡

Surface the algorithm's tunable knobs.

- **What:** sdtx lines for `K_HIGH`, `K_LOW`, `t_high_db`,
  `t_low_db`, and `len(leading)`/`len(trailing)`. Bind `[` / `]` to
  nudge `K_HIGH ± 0.05` and mark the playing wav's edges dirty.
  Optional: `-` / `=` for `K_LOW`.
- **Files:** `src/main.odin`.
- **Goal alignment:** Live tuning.
- **Manual verification result:** controls are stable under extreme K values,
  but a single global K is not sufficient across files or within long files.
  Follow-up work is now planned in Steps 8–11.

### Step 6 — Unit tests for current `compute_edges` behavior ✅

Lock in algorithm correctness with code.

- **What:** Added an Odin package test suite for synthetic `compute_edges`
  inputs (silent buffer, single transient, separated events, debounce,
  bimodal/outlier mix), strict navigation-proc behavior, and current
  global-K threshold behavior. The global-K characterization is protected by
  a test mutex because Odin runs tests concurrently by default.
- **Files:** new `src/audio/wav/edges_test.odin`; new `test_odin` script.
- **Goal alignment:** `docs/edge_detection/GOALS.md` acceptance signal #7.

### Step 7 — Tick-position audit/fix ✅

Separate rendering alignment from detection quality before changing the
algorithm.

- **What:** Added a shared `waveform_x_for_frame` helper and routed both
  waveform bucket vertices and edge ticks through it. Reworked the waveform
  loop to use explicit `bucket_start` / `bucket_end` frame ranges instead of
  mutating the loop counter inside the downsample loop. The waveform now spans
  the visible width and reads a representative left-channel frame per bucket.
- **Files:** `src/main.odin`.
- **Goal alignment:** Visualization; protects the edge-tuning workflow from
  misdiagnosing a rendering bug as an algorithm bug.

### Step 8 — Remove first-edge-calculation stutter ✅

Move edge computation out of the interactive file-switch frame.

- **What:** Added explicit per-WAV edge status/generation, a one-worker
  scheduler, and a main-thread result-install path. The scheduler pre-warms
  the active file, paging file, and nearby files without blocking the
  render/audio frame.
- **Behavior:** Dirty files show pending status until results are ready. Ticks
  are absent while pending, and `w`/`e`/`b` keep their safe no-op behavior when
  no edge array is available.
- **Coherency:** `mark_edges_dirty` deletes stale edge arrays, sets status to
  `uncomputed`, and advances `edge_generation`. Worker jobs capture K values
  at schedule time, and stale generations are dropped instead of installed.
- **Files:** `src/audio/wav/edges.odin`, `src/audio/wav/wav.odin`,
  `src/main.odin`, `src/audio/wav/edges_test.odin`.
- **Goal alignment:** Performance (no first-select stutter; no per-frame
  recompute), Detection (cache remains coherent), and future Live tuning
  (section K changes can reuse cached analysis).
- **Verification:** `./test_odin` passed with 8 tests; `bash ./build_odin`
  passed; 3 s FPS captures did not show a 5min compute-sized frame spike even
  though the worker did 341.22 ms of total edge analysis.

### Step 9 — Refactor K globals into per-file edge params + analysis cache ✅

Replace package-level mutable K globals with per-file `Edge_Params`. Split the
algorithm into two stages with a cached source envelope.

- **What:** Introduced `Edge_Params` and `Edge_Analysis` types. Split
  `compute_edges` into `compute_edge_analysis` (source-dependent, cached) and
  `classify_edges` (param-dependent, O(num_hops)). Each `Wav` now carries its
  own `edge_params` and `edge_analysis`. K tuning modifies per-file params and
  marks only edges dirty, letting the scheduler take a classify-only path.
  Fixed stereo energy calculation (sum-of-squares per channel). Removed test
  mutex. Added two-stage equivalence and classify-reuse tests.
- **Files:** `src/audio/wav/edges.odin`, `src/audio/wav/wav.odin`,
  `src/main.odin`, `src/audio/wav/edges_test.odin`.
- **Goal alignment:** Detection (per-file params, stereo energy fix),
  Live tuning (classify-only on K change), Performance (analysis cache).

### Step 9a — Smooth tick transition on K change ⏳

Eliminate the tick-mark flicker when K values change.

- **What:** Currently `mark_edges_dirty` deletes old edge arrays immediately,
  causing one or more tickless frames before the scheduler installs the new
  classify-only result. Fix by retaining old edges as "stale but renderable"
  until the new edges are installed, then swapping atomically on the main
  thread. No threading changes needed since display reads and installs both
  happen on the main thread.
- **Files:** `src/audio/wav/edges.odin`, `src/main.odin`.
- **Goal alignment:** Live tuning (smooth visual feedback during K adjustment).

### Step 10 — Automatic section discovery for adaptive edge params ✅

Identify which portions of a file need distinct edge parameters.

- **What:** Analyzes the cached dB envelope in 10-second windows. Computes
  Q25 per window, detects boundaries where Q25 shifts by ≥6 dB, snaps
  boundaries to nearby low-energy troughs, merges sections shorter than 5
  seconds. Each section carries local `Section_Stats` (Q10–Q90, IQR) and
  default params. Sections stored on `Wav.edge_sections`, discovered on the
  main thread after fresh analysis install.
- **Output:** `[dynamic]Edge_Section` covering the whole file, sorted and
  non-overlapping. Observed: 2sec→1, 30sec→3, 5min→8 sections.
- **Files:** `src/audio/wav/edges.odin`, `src/audio/wav/wav.odin`,
  `src/main.odin`, `src/audio/wav/edges_test.odin`.
- **Goal alignment:** Detection robustness across files and within a single
  long file.

### Step 11 — Automatic per-section K fitting ⏳

Choose good K values for each discovered section without hardcoding one global
default. Also fix the section discovery minimum-length thresholds so short files
can have multiple sections.

- **Pre-work:** Lower `SECTION_MIN_SECONDS` from 5.0 to 2.0 (200 hops is
  plenty for meaningful stats) and lower the short-file gate so files as short
  as ~6 seconds can have multiple sections. This ensures section boundaries
  are correct before fitting K values.
- **What:** For each `Edge_Section`, fit `k_high` and `k_low` from local
  envelope statistics. Start with the existing Q25/IQR model, but search a
  bounded grid of candidate `(k_high, k_low)` values and score the resulting
  edge set. Candidate score should reward paired leading/trailing counts,
  plausible event durations, edges landing on strong envelope slopes, and
  low false-positive density in locally quiet regions. It should penalize
  excessive edge count, unpaired edges, tiny flicker events, and sections with
  no real separation between floor and active content. If a section is
  unimodal/no-event, allow `0/0` edges instead of forcing activity.
- **Classification switch:** Move classification from file-level to
  per-section. Each section classifies independently using its own fitted K
  values and local Q25/IQR. Merge per-section edges into file-level
  leading[]/trailing[] for navigation.
- **Manual override:** Keep live tuning, but apply it to the active section.
  Overlay should show section index/range, local K values, thresholds, counts,
  and whether params were auto-fit or user-adjusted.
- **Files:** `src/audio/wav/edges.odin`, `src/main.odin`, and tests.
- **Goal alignment:** Detection, Live tuning, Performance. This addresses
  Michael's finding that different files and sections need different K values.

### Step 11a — Bulk K adjustment across all sections ⏳

Add a keybinding to shift all section K values uniformly, for files where the
auto-fit is directionally correct but the overall sensitivity is too high or
too low.

- **What:** New key combo (e.g., Shift+`[`/`]` for K_HIGH, Shift+`-`/`=` for
  K_LOW) that adds a delta to every section's K value, reclassifies all
  sections, and re-merges. Sections retain their relative offsets (auto-fit
  sections keep their fitted base; manually tuned sections keep their manual
  offset). Overlay could show a "global K offset" indicator.
- **Files:** `src/main.odin`, possibly `src/audio/wav/edges.odin`.
- **Goal alignment:** Live tuning ergonomics for files with many sections.

### Step 12 — `draw_wavelength` min/max envelope downsampler ⏳

Replace Step 7's temporary representative-frame waveform renderer with a
proper envelope renderer.

- **What:** Replace the representative left-channel sample in each current
  `draw_wavelength` bucket with a min/max envelope downsampler — one vertical
  span per pixel column showing the min and max sample value in that column's
  frame range. This preserves narrow peaks that a representative-sample draw
  can miss, while keeping draw cost bounded by screen width rather than audio
  length.
- **Files:** `src/main.odin`.
- **Goal alignment:** `docs/edge_detection/GOALS.md` acceptance signal #8
  (60 FPS minimum).
  The 5min file should reach the 60 FPS bar after this lands.
- **Verification quirk:** Step 12 is the only step where FPS on the
  5min file must *improve measurably*, not just stay flat. ±5 % bar
  still applies to 2sec/30sec (they shouldn't regress as collateral).
