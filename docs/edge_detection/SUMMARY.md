# Beach — Edge Detection Feature: Session Summary

Single-page context for picking up this feature in a new session. Pulls
from the Markdown files in `docs/edge_detection/`:
`GOALS.md`, `FEATURE.md`, `PROCEDURES.md`, `VERIFICATIONS.md`,
`CHANGELOG.md`, `EDGES.md`, `K_LEVEL_OVERVIEW.md`, `REVIEW.md`, and
decisions made in conversation that weren't formally documented elsewhere.

## Table of Contents

1. [What this is](#1-what-this-is)
2. [Hard rules](#2-hard-rules)
3. [Status & next step](#3-status--next-step)
4. [Development process](#4-development-process)
5. [Verification protocol](#5-verification-protocol)
6. [Algorithm essentials](#6-algorithm-essentials)
7. [Key findings & decisions](#7-key-findings--decisions)
8. [Conventions & files inventory](#8-conventions--files-inventory)
9. [Open risks & follow-ups](#9-open-risks--follow-ups)
10. [Where to look first in a new session](#10-where-to-look-first-in-a-new-session)

---

## 1. What this is

Beach is a GUI tool for ingesting raw field-recording `.wav` files
(built with Odin + Sokol on Windows). Goal: skim long recordings, find
interesting moments, isolate them as clips.

The current feature adds **vim-style edge navigation**: detect onsets
(leading edges) and offsets (trailing edges) of audio activity per
file, expose `w` / `e` / `b` motions to jump between them, draw
ticks on the waveform, and allow live K tuning.

Editing (`dw`/`de`/`db`) is **out of scope** — that needs separate
architecture work (immutable sources, undo/redo, save-as-new-file).

## 2. Hard rules

- **Source files are sacrosanct.** Edits must produce new files; never
  overwrite originals.
- **60 FPS minimum target** (120+ preferred). Step 7 brought the 5min
  representative waveform draw into the same FPS range as the smaller files;
  Step 12 replaces that temporary draw with a proper min/max envelope.
- **Lazy/cached state must invalidate on source change.** Edges have
  a `dirty` flag; staleness is a bug.
- **One step at a time.** Wait for explicit user sign-off before beginning next step in the development plan.
- **Plan changes go in `docs/edge_detection/FEATURE.md`**, with
  acceptance-signal changes mirrored in `docs/edge_detection/GOALS.md`, not
  `docs/edge_detection/CHANGELOG.md` (retrospective).

## 3. Status & next step

| # | Step | Status |
|---|---|---|
| 1 | Edge detection module (types + algo + nav procs) | ✅ |
| A+B | Edges allocator + FPS instrumentation | ✅ |
| 2 | Lazy recompute + dirty flag | ✅ |
| 3 | `w`/`e`/`b` navigation | ✅ |
| 4 | Edge tick visualization | ✅ (alignment fix bundled into Step 5) |
| 5 | Debug overlay + live K tuning (+ Step 3/4 bug fixes) | 🟡 Manual verification complete; follow-ups planned |
| 6 | Unit tests for current `compute_edges` behavior | ✅ |
| 7 | Tick-position audit/fix | ✅ |
| 8 | Remove first-edge-calculation stutter | ✅ |
| 9 | Refactor K globals into per-file edge params + analysis cache | ✅ |
| 10 | Automatic section discovery for adaptive edge params | ✅ |
| 11 | Automatic per-section K fitting + per-section classification | ✅ |
| 12 | `draw_wavelength` min/max envelope downsampler | ✅ |

**Current pause:** Step 12 is implemented. The waveform draw is now
O(screen_width) per frame via a pre-computed min/max cache. The ~50 FPS cap was
an Nvidia control panel setting, not an app issue — after enabling 120 FPS in
the GPU driver, all files run at ~120 FPS. The 60 FPS GOALS.md target is met.
Steps 9a (tick flicker fix) and 11a (bulk K via Shift+keys) are also complete.
All planned edge detection steps are done. ~120 FPS confirmed after Nvidia
control panel fix.

## 4. Development process

**Context references at the start of any step:**

Use `docs/edge_detection/CURRENT_STEP.md` as the compact working context for
the active step. Refer to the canonical docs below as needed; do not blindly
re-read all of them if the current packet already preserves the relevant
facts.

1. `docs/edge_detection/FEATURE.md` (plan + status)
2. `docs/edge_detection/PROCEDURES.md` (this process)
3. `docs/edge_detection/GOALS.md` (acceptance signals)
4. `docs/edge_detection/CHANGELOG.md` (recent entries)
5. `docs/edge_detection/VERIFICATIONS.md` (technical checks)
6. `docs/edge_detection/SUMMARY.md` (this file)

**Per-step lifecycle (`docs/edge_detection/PROCEDURES.md`):**

0. **Context packet** — create/update `docs/edge_detection/CURRENT_STEP.md`
   with objective, files, invariants, decisions, risks, and verification.
1. **Plan** — quote which `docs/edge_detection/GOALS.md` signal advances, list files to
   change, flag ambiguity.
2. **Implement** — minimal focused changes; build often.
3. **Verify** — build clean; FPS check (see §5); edge sanity if
   `compute_edges` touched; draft manual-UI checklist if UI changed.
4. **Record** — append `docs/edge_detection/CHANGELOG.md` entry with Summary, Files changed,
   Goal alignment, Verification (FPS table), Risks, Follow-ups.
5. **Stop & review** — hand off; wait for sign-off.

## 5. Verification protocol

**Build:** run `bash ./build_odin` from the repo root → clean, no
warnings, `bin/beach.exe` produced.

**FPS (standard 3-second window):**

```bash
# Capture
BEACH_RUN_SECONDS=3 BEACH_FRAME_LOG=./logs/<step>_2sec.csv  ./claude_make test/2sec
BEACH_RUN_SECONDS=3 BEACH_FRAME_LOG=./logs/<step>_30sec.csv ./claude_make test/30sec
BEACH_RUN_SECONDS=3 BEACH_FRAME_LOG=./logs/<step>_5min.csv  ./claude_make test/5min

# Compare
./claude_fps logs/<prev>_<dir>.csv logs/<step>_<dir>.csv
```

**Acceptance:** steady-state median within ±5 % of prior step.

**Borderline protocol** (Δ ≥ 5 % on any file):

1. Re-run affected file 2–3 more times, same binary, same window.
2. Spread ≤ 1 % across runs → original was sampling noise; passes.
3. Spread > 1 % → real regression or unreliable measurement;
   investigate.

**Step 12 inverts the bar:** 5min FPS must *improve measurably*
(target ≥60 FPS), not just stay flat.

**Edge sanity (when `compute_edges` is touched):** check the
`ensure_edges_fresh` debug line — `leading == trailing` count
(paired-state-machine invariant); compute duration bounded.

**Manual UI verification** (when UI/input changes): document
"press X → expect Y" checklist in the CHANGELOG entry; wait for
user sign-off.

## 6. Algorithm essentials

**Location:** `src/audio/wav/edges.odin`

**Three passes:**

1. **RMS envelope → dB.** 10 ms hop, 20 ms window. Mono mixdown per
   frame. `env_db[h] = 20 · log10(max(rms, 1e-6))`.
2. **IQR-anchored thresholds.** Sort env_db, compute Q25 and Q75.
   - `T_high = Q25 + K_HIGH × IQR`  (K_HIGH default 0.7)
   - `T_low  = Q25 + K_LOW  × IQR`  (K_LOW  default 0.4)
   - Clamps: `T_high ≥ -48 dB`; `T_low ≥ -54 dB`; `T_high − T_low ≥ 6 dB`.
3. **Hysteretic state machine + 50 ms debounce.**
   - `SILENT → ACTIVE` when env ≥ T_high → record leading edge.
   - `ACTIVE → SILENT` when env ≤ T_low → record trailing edge.
   - EOF: if still ACTIVE, append final trailing so counts pair.

**Result:** `Edges.leading[]` / `Edges.trailing[]` — paired, sorted
`[dynamic]i32` of frame indices; `t_high_db` / `t_low_db` cached for
the overlay; `dirty` flag for lazy recompute.

**Compute durations observed:** 2.5 ms (2sec, 91K frames), 31.9 ms
(30sec, 1.2M frames), and 341.2 ms (5min, 12.7M frames). Since Step 8, that
work runs on the edge worker; the 5min FPS capture max frame was 39.205 ms,
not a compute-sized 300+ ms spike.

**Public procs (wav package):**

- `default_edge_params() -> Edge_Params` — returns default params.
- `compute_edge_analysis(w, params, allocator) -> Edge_Analysis` — Stage 1:
  builds dB envelope, Q25/Q75. Cached on Wav; only rerun on source change.
- `classify_edges(analysis, params, allocator) -> Edges` — Stage 2:
  hysteretic state machine from cached analysis. Cheap, runs on K changes.
- `compute_edges(w, allocator) -> Edges` — convenience, runs both stages.
- `compute_edges_with_params(w, allocator, k_high, k_low) -> Edges` — same,
  with caller-owned K values.
- `copy_edge_analysis(src, allocator) -> Edge_Analysis` — deep copy for
  classify-only worker jobs.
- `mark_edges_dirty(w)` — deletes stale edge arrays, sets status to
  `uncomputed`, advances `edge_generation`. Preserves analysis cache.
- `delete_edge_analysis(analysis, allocator)` — frees cached envelope.
- `analysis_is_cached(w) -> bool` — true when analysis is valid (not dirty,
  has env_db).
- `ensure_edges_fresh(w, allocator)` — synchronous two-stage recompute
  retained for tests/tools.
- `next_leading`, `next_trailing`, `prev_leading` — O(log N) binary searches,
  unchanged.

**Per-file tuning (Step 9):**

- Each `Wav` has `edge_params: Edge_Params` (k_high, k_low, hop/win/gap/floor/gap-db).
- Defaults: `EDGE_DEFAULT_K_HIGH = 0.7`, `EDGE_DEFAULT_K_LOW = 0.4`.
- `[` / `]` nudge K_HIGH ± 0.05; `-` / `=` nudge K_LOW. All modify per-file
  params and call `mark_edges_dirty(playing)`. Analysis cache stays valid so
  the scheduler runs a classify-only pass.
- Test mutex removed — no more mutable globals.

**Planned adaptive tuning model (Steps 10–11):**

- Store non-overlapping `Edge_Section`s on each file; each section has its own
  `(K_HIGH, K_LOW)`, thresholds, dirty state, and edge results or merged edge
  output.
- Discover sections from cached envelope statistics: local noise floor,
  dynamic range, activity density, and sustained distribution shifts.
- Fit each section's K values from local robust stats plus edge-quality
  scoring. Live tuning applies to the section under the playhead and marks
  only that section dirty.

## 7. Key findings & decisions

### Odin SOA + `using` compiler bug

`arr[i].x` panics the Odin compiler when `arr: #soa[]T` and `T` has
`using sub: SubType` and `SubType` has field `x`. Error:
`un-gep-able type [^]SubType`. **Workaround:** write one explicit
field step (`arr[i].sub.x`); the `using` declarations themselves
can stay. All SOA-indexed expressions in the codebase follow this
pattern.

### SOA storage + `^Entity` is fundamentally incompatible

A regular pointer cannot point into `#soa[]` because the entity's
fields are split across columns — there is no single address for
"entity at index i." Design uses **handles** (`Entity_Handle ::
distinct int` indexing into `g.entities: #soa[]Entity`), not
pointers. Procs take handles and look up via the SOA slice.

### Heap allocator for edges (not arena)

Arena allocators can't free individual allocations. K-tuning and
edits trigger recomputes, which `delete` old edge arrays and
allocate new ones. Hence `alloc.edges_allocator =
runtime.default_allocator()` (heap). All other allocators on
`Alloc` remain arenas.

### `BEACH_RUN_SECONDS=3` is the standard window

1 s produces n=5 frames on the 5min file (~3 % run-to-run noise) —
too loose for the ±5 % FPS bar. 3 s gives n≈34 with ≤1 % spread.
1 s was used in earlier steps and the older log files remain as
historical record but aren't comparison points anymore.

### Tick alignment math (Step 4/5 → fixed in Step 7)

Step 5 corrected the first visible tick-scale bug, but Step 7 found the
waveform loop still had implicit frame-to-x behavior because it mutated its
frame counter inside the downsample loop. Current code uses
`waveform_x_for_frame` for both waveform buckets and leading/trailing ticks.

### `b` back-tolerance (Step 3 → fixed in Step 5)

Audio plays forward between `b` presses; without a back-tolerance,
`prev_leading(cursor)` re-finds the just-landed-on edge ("stuck").
Fix: search from `cursor − sample_rate/10` (~100 ms). The
`prev_leading` proc itself stays strict-less-than (matches
`docs/edge_detection/GOALS.md` primitive contract); the tolerance lives
at the `.B` key handler.

### Otsu's method — considered, rejected for now

Bimodal-histogram threshold finder. Pros: no tuning constant.
Cons: (1) unimodal noise-only files produce false positives; (2) no
natural hysteresis; (3) loses the K sensitivity knob that Step 5
makes live-tunable. Re-evaluate only if real files prove IQR+K
insufficient.

### Global K is not sufficient

Step 5 manual verification showed that different files and different sections
within the same file want different K values. The plan now keeps IQR+K as the
core detector but moves K ownership from package globals to per-file/per-section
params, with automatic section discovery and per-section K fitting.

### Tick placement audit completed

Step 7 made waveform buckets and edge ticks share `waveform_x_for_frame`, and
Michael manually verified the alignment. Remaining perceived early/late edges
should now be treated as detector/tuning behavior rather than render mapping
drift.

### Initial edge calculation stutters on long files

`compute_edges` still runs lazily on first access. The 5min fixture takes about
331 ms, so switching to it can visibly freeze while edges are calculated. Step
8 now addresses this before the adaptive K refactor. Serial full-library
precompute is rejected because directories can contain hundreds of WAVs and the
app should boot/interact immediately. Preferred direction is a simple
background worker queue that streams results back to the main thread; fallback
is frame-budgeted incremental compute if threading becomes too complex.

### Editing deferred

`delete_range`, `d`-prefix verb, `dw`/`de`/`db` are out of scope.
Needs immutable-source architecture + undo/redo + save-as-new-file
design pass first.

## 8. Conventions & files inventory

### Scripts (repo root, executable)

- `build_odin`, `build_shaders`, `make` — build helpers (existing).
- `claude_make <dir>` — build + run with `<dir>` as audio source.
- `claude_fps <csv> [<csv>...]` — parse frame logs, print
  median/p95/max + FPS; multi-arg invocation shows a comparison
  table (first file = baseline).

### Env vars (gated, defaults off)

- `BEACH_FRAME_LOG=<path>` — append per-frame CSV
  (`frame,t_ms,duration_ms,fps`) to `<path>`.
- `BEACH_RUN_SECONDS=<n>` — self-quit after `n` seconds of frames.

### Logs

- Location: `./logs/` from the repo root (gitignored).
- Naming: `<step-id>_<test-dir>[_runN].csv` — e.g.,
  `step5_5min.csv`, `step5_5min_run2.csv`.
- Old logs retained as historical record; new steps add new files.

### Test fixtures

- `test/2sec/2sec.wav` (539 KB, 24-bit PCM, 1.9 s) — baseline 49.6 FPS.
- `test/30sec/250813_0074.wav` (9.3 MB, IEEE float, 27.6 s) — 49.6 FPS.
- `test/5min/250813_0062.wav` (98 MB, IEEE float, 4:48) — Step 7 median
  20.303 ms / 49.3 FPS with representative waveform drawing; Step 12 should
  preserve or improve this while restoring min/max peak fidelity.

### Doc structure (`docs/edge_detection/`)

| File | Purpose |
|---|---|
| `docs/edge_detection/GOALS.md` | What done means; application context; hard rules; out-of-scope. |
| `docs/edge_detection/FEATURE.md` | Implementation plan + per-step status. |
| `docs/edge_detection/PROCEDURES.md` | How we work; step/review lifecycles. |
| `docs/edge_detection/CURRENT_STEP.md` | Compact working context for the active step. |
| `docs/edge_detection/VERIFICATIONS.md` | Exact verification commands & pass criteria. |
| `docs/edge_detection/CHANGELOG.md` | Per-step retrospective work log. Never retroactively edited except path-reference maintenance. |
| `docs/edge_detection/EDGES.md` | User's mid-plan tweak notes (Otsu rejection, editing constraint, etc.). |
| `docs/edge_detection/K_LEVEL_OVERVIEW.md` | Description of the K-Level tuning for the IQR algorithm. |
| `docs/edge_detection/REVIEW.md` | Review of the current `compute_edges` technique and recommended architecture. |
| `docs/edge_detection/SUMMARY.md` | This file. |
| `CLAUDE.md` | Repo-root codebase docs (project-wide, not feature-specific). |

### Code organization

- `src/audio/wav/wav.odin` — file parsing, `Wav` struct (now with
  `edges: Edges` field).
- `src/audio/wav/edges.odin` — algorithm + nav procs + tuning vars.
- `src/main.odin` — app loop, allocators, input, drawing, FPS
  instrumentation, debug overlay.

## 9. Open risks & follow-ups

Tagged with originating step in parentheses. Full text in
`docs/edge_detection/CHANGELOG.md`.

1. **Remaining startup/file-load latency** (Step 8 follow-up). WAV files are
   read in parallel, but app initialization still waits for the directory load
   to finish before the GUI becomes interactive. Step 8 removed edge-analysis
   frame stutter, not startup streaming.
2. **Representative waveform draw can miss peaks** (Step 7). 5min FPS is now
   aligned with other files, but the waveform uses one representative
   left-channel sample per bucket. Step 12 replaces this with a min/max
   envelope downsampler.
3. **`compute_edges` duration log line** (Step 2 follow-up). Debug
   temp at DEBUG level. Remove or `when ODIN_DEBUG`-guard before
   feature is "done."
4. **K can be pushed arbitrarily negative** (Step 5). Algorithm
   self-clamps; overlay shows wild values. Add input clamp before
   shipping to users; fine for dev tuning.
5. **Color collision** (Step 4): leading ticks share waveform's
   green. Orientation distinguishes them in practice; revisit if
   manual verification finds it hard to read.
6. **Most ticks off-screen** (Step 4). Waveform x extent exceeds
   visible viewport (`14 × half_w` wide). Existing app behavior, not
   a bug. Future scroll/zoom or Step 12 rework may restructure.
7. **Edge scheduler scale** (Step 8). The current scheduler intentionally uses
   one outstanding job for simple ownership. Revisit worker count or queue
   depth only if measurement shows pre-warm latency is too high.
8. **Per-file K is the current granularity** (Step 9). Different sections
   within the same file may still need different K values. Steps 10–11 add
   section discovery and per-section K fitting.
9. **Tick placement rendering math** (Step 5 verification). Step 7 isolated
   and fixed the rendering-position math; remaining early/late behavior should
   be investigated through detector tuning.
10. **Persisting tuned K** (Step 5). Per-file K values will still reset per
    launch until persistence is designed. Out of scope unless explicitly added.
11. **Full analysis ~22% slower than Step 8** (Step 9). `frame_energy`
    function-call overhead. One-time cost per file load; classify-only path
    compensates on K changes. Can be improved with `#force_inline` if needed.
12. **Tick flicker on K change** (Step 9 verification). `mark_edges_dirty`
    deletes old edges immediately, causing tickless frames before classify-only
    result is installed. Step 9a retains old edges until new ones are ready.

## 10. Where to look first in a new session

1. **This file (`docs/edge_detection/SUMMARY.md`)** — high-level orientation.
2. **`docs/edge_detection/FEATURE.md`** — current step, recent status.
3. **`docs/edge_detection/K_LEVEL_OVERVIEW.md`** — contains an overview of the K-Level tuning
4. **`docs/edge_detection/CHANGELOG.md` (last entry)** — most recent step's full work record.
5. **`docs/edge_detection/PROCEDURES.md`** — when ready to start a new step.

**Resume sequence after pause:**

- Wait for user go-ahead to begin Step 10.
- Step 10: automatic section discovery for adaptive edge params.
- Step 11: automatic per-section K fitting.
- Step 12: `draw_wavelength` min/max envelope downsampler for 60+ FPS on 5min.
