# Beach — Edge Detection Feature: Session Summary

Single-page context for picking up this feature in a new session. Pulls
from GOALS.md, FEATURE.md, PROCEDURES.md, VERIFICATIONS.md, CHANGELOG.md,
EDGES.md, MICHAEL-TODO.md, and decisions made in conversation that
weren't formally documented elsewhere.

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
- **60 FPS minimum target** (120+ preferred). Currently below on long
  files / data-dense files (IEEE 32-bit float vs 24 bit PCM); Step 7 addresses.
- **Lazy/cached state must invalidate on source change.** Edges have
  a `dirty` flag; staleness is a bug.
- **One step at a time.** Wait for explicit user sign-off before beginning next step in the development plan.
- **Plan changes go in FEATURE.md**, not CHANGELOG.md (retrospective).

## 3. Status & next step

| # | Step | Status |
|---|---|---|
| 1 | Edge detection module (types + algo + nav procs) | ✅ |
| A+B | Edges allocator + FPS instrumentation | ✅ |
| 2 | Lazy recompute + dirty flag | ✅ |
| 3 | `w`/`e`/`b` navigation | ✅ |
| 4 | Edge tick visualization | ✅ (alignment fix bundled into Step 5) |
| 5 | Debug overlay + live K tuning (+ Step 3/4 bug fixes) | 🟡 Awaiting user tuning verification |
| 6 | Unit tests for `compute_edges` | ⏳ |
| 7 | `draw_wavelength` min/max envelope downsampler | ⏳ |

**Currently paused at Step 5 manual verification.** User has
[MICHAEL-TODO.md](./MICHAEL-TODO.md) checklist + three questions to
answer before Step 5 can be marked ✅. On resume: confirm answers,
update FEATURE.md, proceed to Step 6.

## 4. Development process

**Read order at the start of any step:**

1. FEATURE.md (plan + status)
2. PROCEDURES.md (this process)
3. GOALS.md (acceptance signals)
4. CHANGELOG.md (recent entries)
5. VERIFICATIONS.md (technical checks)
6. SUMMARY.md (this file)

**Per-step lifecycle (PROCEDURES.md):**

1. **Plan** — quote which GOALS.md signal advances, list files to
   change, flag ambiguity.
2. **Implement** — minimal focused changes; build often.
3. **Verify** — build clean; FPS check (see §5); edge sanity if
   `compute_edges` touched; draft manual-UI checklist if UI changed.
4. **Record** — append CHANGELOG entry with Summary, Files changed,
   Goal alignment, Verification (FPS table), Risks, Follow-ups.
5. **Stop & review** — hand off; wait for sign-off.

## 5. Verification protocol

**Build:** `bash ./build_odin` → clean, no warnings, `bin/beach.exe`
produced.

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

**Step 7 inverts the bar:** 5min FPS must *improve measurably*
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

**Compute durations observed:** 2.4 ms (2sec, 91K frames), 32 ms
(30sec, 1.2M frames), **331 ms (5min, 12.7M frames — known issue)**.

**Public procs (wav package):**

- `compute_edges(w, allocator) -> Edges` — pure algorithm.
- `ensure_edges_fresh(w, allocator)` — lazy guard on `w.edges.dirty`;
  frees old arrays and recomputes. Called once per frame in
  `update_gui`.
- `next_leading(w, cursor) -> i32` — smallest leading edge strictly
  > cursor; returns `-1` if none.
- `next_trailing(w, cursor) -> i32` — same shape.
- `prev_leading(w, cursor) -> i32` — largest leading edge strictly
  < cursor; returns `-1` if none.

**Tunable globals (package-level `var`s in `wav`):**

- `EDGE_K_HIGH: f32 = 0.7`
- `EDGE_K_LOW:  f32 = 0.4`

`[` / `]` nudge K_HIGH ± 0.05; `-` / `=` nudge K_LOW. All set
`playing.edges.dirty = true` to force recompute next frame.

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

### Tick alignment math (Step 4 → fixed in Step 5)

The waveform line strip's `x_step` advances *per outer iteration*;
each outer iteration consumes `downsample_window = 20` frames
internally. Effective per-frame x-stride is `x_step /
downsample_window`. Ticks now use this corrected stride.

### `b` back-tolerance (Step 3 → fixed in Step 5)

Audio plays forward between `b` presses; without a back-tolerance,
`prev_leading(cursor)` re-finds the just-landed-on edge ("stuck").
Fix: search from `cursor − sample_rate/10` (~100 ms). The
`prev_leading` proc itself stays strict-less-than (matches GOALS.md
primitive contract); the tolerance lives at the `.B` key handler.

### Otsu's method — considered, rejected for now

Bimodal-histogram threshold finder. Pros: no tuning constant.
Cons: (1) unimodal noise-only files produce false positives; (2) no
natural hysteresis; (3) loses the K sensitivity knob that Step 5
makes live-tunable. Re-evaluate only if real files prove IQR+K
insufficient.

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

- Location: `./logs/` (gitignored).
- Naming: `<step-id>_<test-dir>[_runN].csv` — e.g.,
  `step5_5min.csv`, `step5_5min_run2.csv`.
- Old logs retained as historical record; new steps add new files.

### Test fixtures

- `test/2sec/2sec.wav` (539 KB, 24-bit PCM, 1.9 s) — baseline 49.6 FPS.
- `test/30sec/250813_0074.wav` (9.3 MB, IEEE float, 27.6 s) — 49.6 FPS.
- `test/5min/250813_0062.wav` (98 MB, IEEE float, 4:48) — **13.6 FPS** (Step 7 target).

### Doc structure (repo root)

| File | Purpose |
|---|---|
| `GOALS.md` | What done means; application context; hard rules; out-of-scope. |
| `FEATURE.md` | Implementation plan + per-step status. |
| `PROCEDURES.md` | How we work; 5-phase step lifecycle. |
| `VERIFICATIONS.md` | Exact verification commands & pass criteria. |
| `CHANGELOG.md` | Per-step retrospective work log. Never retroactively edited. |
| `EDGES.md` | User's mid-plan tweak notes (Otsu rejection, editing constraint, etc.). |
| `MICHAEL-TODO.md` | User's pending Step-5 tuning checklist. |
| `SUMMARY.md` | This file. |
| `CLAUDE.md` | Codebase docs (project-wide, not feature-specific). |

### Code organization

- `src/audio/wav/wav.odin` — file parsing, `Wav` struct (now with
  `edges: Edges` field).
- `src/audio/wav/edges.odin` — algorithm + nav procs + tuning vars.
- `src/main.odin` — app loop, allocators, input, drawing, FPS
  instrumentation, debug overlay.

## 9. Open risks & follow-ups

Tagged with originating step in parentheses. Full text in
CHANGELOG.md.

1. **5min file at 14 FPS** (Step 2, micro-step A+B). Real perf issue;
   Step 7 explicitly addresses via min/max envelope downsampler in
   `draw_wavelength`. Acceptance bar inverts for Step 7: 5min must
   *improve* to ≥60 FPS.
2. **`compute_edges` 331 ms on 5min** (Step 2). One-time hitch per
   file load. Optimization levers if needed: channel skip
   (`samples_raw[i*channels]` only, no mixdown), coarser hop, SIMD.
   Defer until Step 7 lands and we can re-measure end-to-end.
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
   a bug. Future scroll/zoom or Step 7 rework may restructure.
7. **Pager pre-warm** (Step 2). Each file switch re-incurs the
   compute hitch. Could pre-warm neighbors in background. Out of
   scope here.
8. **Persisting tuned K** (Step 5). Resets per launch. If a single K
   works for the library, hardcode it; if per-file, need persistence
   (out of scope).
9. **Unit tests for `compute_edges`** (GOALS.md #7 / Step 6). Step 6
   open. Synthetic + fixture-based tests planned.

## 10. Where to look first in a new session

1. **This file (SUMMARY.md)** — high-level orientation.
2. **FEATURE.md** — current step, recent status.
3. **MICHAEL-TODO.md** — if Step 5 still 🟡, user has open tuning
   work; pick that up first.
4. **CHANGELOG.md (last entry)** — most recent step's full work record.
5. **PROCEDURES.md** — when ready to start a new step.

**Resume sequence after pause:**

- User reports MICHAEL-TODO.md outcomes (single K vs per-file; tick
  placement quality; K-extreme crash check).
- Update FEATURE.md to mark Step 5 ✅ (or flag the algorithm/UI
  issue to fix first).
- Start Step 6 (unit tests for `compute_edges`) per PROCEDURES.md
  read order.
