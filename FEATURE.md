# Edge Detection Feature — Implementation Plan

The forward-looking plan for the edge-detection feature. Per-step work
log lives in [CHANGELOG.md](./CHANGELOG.md); goals/acceptance signals
in [GOALS.md](./GOALS.md); how to execute a step in
[PROCEDURES.md](./PROCEDURES.md); the technical verification checks in
[VERIFICATIONS.md](./VERIFICATIONS.md).

## Status

| # | Step | Status |
|---|---|---|
| 1 | Edge detection module (types + algorithm + nav procs) | ✅ Complete |
| A+B | Edges allocator + FPS instrumentation (micro-step) | ✅ Complete |
| 2 | Lazy recompute + initial dirty flag | ✅ Complete |
| 3 | `w` / `e` / `b` navigation | ✅ Complete |
| 4 | Edge tick visualization on sgl waveform | ✅ Complete (alignment fix in Step 5) |
| 5 | Debug overlay + live K tuning (+ Step 3/4 bug fixes) | 🟡 Awaiting user verification |
| 6 | Unit tests for `compute_edges` | ⏳ Pending |
| 7 | `draw_wavelength` min/max envelope downsampler | ⏳ Pending |

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

### Step 4 — Edge tick visualization 🟡 Next

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

### Step 5 — Debug overlay + live K tuning ⏳

Surface the algorithm's tunable knobs.

- **What:** sdtx lines for `K_HIGH`, `K_LOW`, `t_high_db`,
  `t_low_db`, and `len(leading)`/`len(trailing)`. Bind `[` / `]` to
  nudge `K_HIGH ± 0.05` and mark the playing wav's edges dirty.
  Optional: `-` / `=` for `K_LOW`.
- **Files:** `src/main.odin`.
- **Goal alignment:** Live tuning.

### Step 6 — Unit tests for `compute_edges` ⏳

Lock in algorithm correctness with code.

- **What:** Add an Odin test binary that exercises `compute_edges`
  on synthetic input (silent buffer, single transient, dense
  events, bimodal mix) and asserts paired-and-sorted output. May
  also include one fixture file (e.g., `test/2sec/2sec.wav`) for an
  end-to-end smoke test.
- **Files:** new `src/audio/wav/edges_test.odin` (or similar);
  optionally a `test_odin` script alongside `build_odin`.
- **Goal alignment:** GOALS.md acceptance signal #7.

### Step 7 — `draw_wavelength` min/max envelope downsampler ⏳

Fix the 5min FPS bottleneck identified during micro-step A+B
baselines.

- **What:** Replace per-sample iteration in `draw_wavelength` with a
  min/max envelope downsampler — one vertex per pixel column showing
  the min and max sample value in that column's frame range. Drops
  sgl vertex count from ~25 M to ~screen-width × 2 (a few thousand).
- **Files:** `src/main.odin`.
- **Goal alignment:** GOALS.md acceptance signal #8 (60 FPS minimum).
  The 5min file should reach the 60 FPS bar after this lands.
- **Verification quirk:** Step 7 is the only step where FPS on the
  5min file must *improve measurably*, not just stay flat. ±5 % bar
  still applies to 2sec/30sec (they shouldn't regress as collateral).
