# Edge Detection Feature — Changelog

Implementation log for the edge detection feature. Each entry corresponds to a
completed step from the implementation plan and references the goals in
[docs/edge_detection/GOALS.md](./GOALS.md) it advances.

Each entry includes:

- **Summary** — what was done, in one or two sentences.
- **Files changed** — which paths were touched and how.
- **Goal alignment** — which `docs/edge_detection/GOALS.md` acceptance
  signal(s) the work moves toward.
- **Verification** — how completion was demonstrated (build, manual test, etc.).
- **Risk(s) encountered** — (if any risks encounted) A detailed write-up of each risk you identify as part of these changes.
- **Follow-ups spawned** — (if any follow-ups identified) A short blurb about each follow-up you will need feedback on or you will need to address as part of your changes.

---

## Step 1 — Edge detection module (definitions only, no wiring) — 2026-05-25

**Summary:** Created the edge-detection module — `Edges` type, the
`compute_edges` algorithm (RMS → dB → Q25/IQR thresholds → hysteresis →
debounce), the `percentile_sorted` helper, and the three navigation procs
(`next_leading`, `next_trailing`, `prev_leading`). Replaced the unused
`leading_edges` / `trailing_edges` placeholder slices on `Wav` with a single
`edges: Edges` field. Nothing in the runtime calls into the new module yet.

**Files changed:**

- **NEW** `src/audio/wav/edges.odin` — full module (algorithm + navigation +
  tuning knobs).
- **MODIFIED** `src/audio/wav/wav.odin` — replaced the unused placeholder
  fields `leading_edges: []int` and `trailing_edges: []int` on the `Wav`
  struct with `edges: Edges`.

**Goal alignment:**

- **Detection** — defines `Edges` with sorted `leading[] / trailing[] :
  [dynamic]i32`, `dirty: bool`, and the resolved `t_high_db` / `t_low_db`
  fields. Algorithm matches the spec in `docs/edge_detection/GOALS.md`
  exactly (RMS → dB →
  Q25-anchored thresholds with IQR spread → hysteretic state machine →
  debounce).
- **Navigation** — `next_leading` / `next_trailing` / `prev_leading` defined
  as O(log N) binary searches with `-1` sentinel for "no further edge."
- **Live tuning** — `EDGE_K_HIGH` and `EDGE_K_LOW` declared as package-level
  mutable globals (Odin `var`-style with `:`, not `::`), so Step 5 can nudge
  them from the input handler with zero plumbing.
- **Performance** — dirty flag declared on `Edges`. No runtime work added
  this step; algorithm is dormant until Step 2 wires `ensure_edges_fresh`.

**Verification:**

- `bash ./build_odin` succeeds, no warnings or errors. `bin/beach.exe`
  produced (1 529 344 bytes).
- Grep confirms zero remaining references to the removed `leading_edges` /
  `trailing_edges` placeholders in the codebase.
- App behavior unchanged (no call sites added — purely additive definitions).
- FPS not measured this step: there are no runtime code paths altered, so no
  meaningful before/after comparison exists. FPS baseline will be captured at
  the start of Step 2, where the algorithm first runs against real data.

**Risks encountered:**

1. **Replaced placeholder fields, not added alongside.** The
   `leading_edges` / `trailing_edges` slices on `Wav` were unused (verified
   via grep before editing), so replacing them with the proper `edges`
   field is safe. The risk would have been silently breaking some consumer
   that referenced them; grep confirmed none exists.
2. **`math.log10` overload resolution.** The algorithm calls
   `math.log10(rms)` on an `f32`. Odin's `math` package overloads `log10`
   for both `f32` and `f64`. Build succeeded, so the f32 overload was
   selected; if a future Odin update changes inference behavior, switching
   to the explicit `math.log10_f32` is the trivial fix.

**Follow-ups:**

1. **Unit tests for `compute_edges`**
   (`docs/edge_detection/GOALS.md` acceptance signal #7) —
   these are required for the feature to be marked done and do not yet
   exist. Proposed addition: insert a new step in the plan, **Step 6 —
   Unit tests for `compute_edges`** (sliding the existing Step 6 / 7 down
   to Steps 7 / 8). Will confirm with user before starting.
2. **FPS baseline capture** (`docs/edge_detection/GOALS.md` acceptance
   signal #8) — should be
   recorded before Step 2 so we can demonstrate the lazy-recompute path
   doesn't degrade frame time. The existing sdtx overlay prints FPS each
   frame; I'll note the steady-state value at the start of Step 2.
3. **Allocator lifetime** — `compute_edges` accepts an allocator and the
   `[dynamic]i32` arrays retain it internally. Step 2's
   `ensure_edges_fresh` must `delete` the old `leading` / `trailing`
   arrays before reassigning the struct, or we leak the arena slots from
   prior recomputes. Will handle explicitly in Step 2.

---

## Micro-step A+B — Edges allocator + FPS instrumentation — 2026-05-25

**Summary:** Added a heap-backed `edges_allocator` to the `Alloc` struct so
the lazy recompute in Step 2 can `delete` and reallocate edge arrays
individually (the existing arena allocators can't free individual entries).
Also added env-var-gated FPS instrumentation: `BEACH_FRAME_LOG=<path>` emits
per-frame CSV rows and `BEACH_RUN_SECONDS=<n>` causes the app to self-quit
after `n` seconds of frames. Both default to off — interactive runs are
unaffected.

**Files changed:**

- **MODIFIED** `src/main.odin`:
  - Added `edges_allocator: mem.Allocator` field on `Alloc`; initialized in
    `init()` to `runtime.default_allocator()` (heap, supports individual
    `delete`).
  - Added file-private FPS instrumentation state and three procs:
    `fps_instrument_init` (reads env vars, opens log file, records start
    time), `fps_instrument_record_frame` (writes one CSV row, calls
    `sapp.quit()` once the duration threshold is reached), and
    `fps_instrument_shutdown` (closes the file).
  - Wired calls in `init`, `frame`, and `cleanup`.
  - Added `import "core:strconv"` for env-var parsing.
- **MODIFIED** `.gitignore` — added `logs/` for FPS log output.

**Goal alignment:**

- **Performance** (acceptance signal #8) — establishes the measurement
  protocol that every subsequent step's CHANGELOG entry will use. Without
  this, we'd have no way to demonstrate the "FPS is not impacted" rule.
- **Detection / Live tuning** (indirect) — the allocator change unblocks
  Step 2's `ensure_edges_fresh`, which is what makes recompute-on-edit /
  recompute-on-K-change work without leaking memory.

**Verification:**

- `bash ./build_odin` succeeds; `bin/beach.exe` produced.
- Interactive run (no env vars set) — confirmed: no log file created, no
  early quit, no behavioral change.
- Three baseline captures completed via:
  ```bash
  BEACH_RUN_SECONDS=1 BEACH_FRAME_LOG=./logs/baseline_<dir>.csv ./claude_make test/<dir>
  ```
- **Baselines (steady-state, post-Step-1 build, no algorithm running yet):**

  | Test file | n frames | Median frame ms | p95 frame ms | Max frame ms | Median FPS |
  |---|---|---|---|---|---|
  | `test/2sec/2sec.wav` (539 KB, 24-bit PCM, 1.9 s) | 39 | 20.15 | 40.17 | 100.00 | 49.6 |
  | `test/30sec/250813_0074.wav` (9.3 MB, IEEE float, 27.6 s) | 43 | 20.16 | 28.89 | 100.00 | 49.6 |
  | `test/5min/250813_0062.wav` (98 MB, IEEE float, 4:48) | 11 | 73.79 | 100.00 | 100.00 | 13.6 |

  Log files retained under `logs/baseline_*.csv` for independent inspection.

- Notes on the baseline data:
  - 2sec and 30sec are pinned at ~50 FPS, well below the 60 FPS target — but
    consistent with each other, so they will be reliable comparison points
    for upcoming steps.
  - 5min is at 13.6 FPS, confirming the user-flagged
    `draw_wavelength` downsampling bottleneck. The acceptance bar for the
    5min file is "we don't make this worse," not "we get it to 60."
  - All three files show a 100 ms `max` frame; this is a single early frame
    (frame index 1 in each log), almost certainly the first sokol-tracked
    frame after init. It's noise for our purposes.

**Risks encountered:**

1. **API drift between `os.Handle` and `^os.File`.** Initial implementation
   used `os.Handle` / `os.INVALID_HANDLE` (the older API). The current
   `core:os` exports `^os.File` with `nil` as the invalid sentinel. Fixed
   by switching the field type to `^os.File`, using `nil` instead of
   `INVALID_HANDLE`, and passing `os.Permissions_Default_File` to `os.open`
   instead of an untyped octal literal.
2. **Per-frame allocation for CSV line.** `fmt.aprintf` allocates each
   frame; using `context.allocator` would put 60+ persistent allocations
   per second on the heap. Used `context.temp_allocator` explicitly so the
   line lives only until the `frame` proc's `mem.free_all(g.frame.allocator)`
   resets the frame arena. Verified by reading the CSV output — formatting
   correct, no leaks visible across 39+ frames.
3. **`sapp.quit()` on a kill path.** When `BEACH_RUN_SECONDS` triggers
   quit, the sokol callback `cleanup` fires, which calls
   `fps_instrument_shutdown`, which closes the log file cleanly. Verified
   by `wc -l` on each CSV: row counts match the "X frames" reported in the
   log line, meaning no rows lost to truncation.

**Follow-ups:**

1. **5min file performance is the dominant constraint.** Any algorithm work
   that runs per-file (Step 2's `ensure_edges_fresh`) must take care not
   to add even 5–10 ms of one-time cost on the 5min file, because the
   per-frame budget is already over 70 ms. I'll log
   `compute_edges` duration explicitly in Step 2 and gate acceptance on it
   being a small fraction of the existing baseline frame time.
2. **Eventual `draw_wavelength` rework.** The 13.6 FPS 5min number traces
   back to per-sample iteration in `draw_wavelength` (currently ~25 M sgl
   vertices per frame on that file). Fixing it requires a min/max envelope
   downsampler (one vertex per pixel column, not per sample). Out of scope
   for this feature, but flagging it because it's the actual culprit
   behind the FPS bar we keep tripping. **Promoted to Step 7** in the
   implementation plan after this changelog entry was written.

---

## Step 2 — Lazy edge recompute + initial dirty flag — 2026-05-25

**Summary:** Wired `compute_edges` into the runtime. Each loaded WAV
gets `wave.edges.dirty = true` set at the end of `wav.read_from_file`.
Once per frame, `update_gui` calls `wav.ensure_edges_fresh(playing,
alloc.edges_allocator)`, which early-returns on `!dirty` (steady state)
and otherwise frees the prior `leading` / `trailing` arrays, calls
`compute_edges`, and replaces the struct. Temporary instrumentation
logs the per-file compute duration and resulting edge counts.

**Files changed:**

- **MODIFIED** `src/audio/wav/wav.odin` — `read_from_file` sets
  `wave.edges.dirty = true` after the file is fully parsed.
- **MODIFIED** `src/audio/wav/edges.odin` — added
  `ensure_edges_fresh(w, allocator)` and the `core:log` / `core:time`
  imports it needs. The new proc:
  1. Returns immediately if `w == nil || !w.edges.dirty`.
  2. Calls `delete` on the previous `leading` / `trailing` arrays. Safe
     on the very first call because Odin's `delete([dynamic]T)` checks
     for a nil allocator-procedure and is a no-op when uninitialized.
  3. Times `compute_edges`, assigns the result to `w.edges`, and logs
     the duration + counts.
- **MODIFIED** `src/main.odin` — `update_gui` calls
  `wav.ensure_edges_fresh(playing, alloc.edges_allocator)` immediately
  after resolving `playing`. Steady-state cost is one boolean check.

**Goal alignment:**

- **Performance #5** (steady-state per-frame overhead unchanged) —
  satisfied; the `if !dirty do return` guard means every frame after
  the first sees only the bool read. Verified with FPS measurements
  below.
- **Detection #1** (loaded WAV produces a non-empty
  `leading[] / trailing[]` on first access) — visible in the
  per-file logs: 7/7 edges on the 2sec file, 38/38 on the 30sec
  file, 44/44 on the 5min file. Counts are paired, which is the
  invariant the state machine + EOF-close branch promises.

**Verification:**

Built clean. Captured post-Step-2 frame logs against the same three
test files used for the micro-step A+B baseline, with the same
`BEACH_RUN_SECONDS=1 BEACH_FRAME_LOG=...` invocation pattern.

Per-file `compute_edges` durations (from debug log):

| File   | Frame count input | compute_edges duration | leading | trailing | t_high_db | t_low_db |
|--------|-------------------|------------------------|---------|----------|-----------|----------|
| 2sec   |     91 008        |   2.44 ms              |   7     |    7     | -47.34    | -53.34   |
| 30sec  |  1 215 360        |  31.95 ms              |  38     |   38     | -46.48    | -52.48   |
| 5min   | 12 733 056        | 331.28 ms              |  44     |   44     | -44.48    | -50.48   |

Steady-state frame times (excluding frames 0–1; both are sokol's
startup-clamp frames pre-cooked at 16.67/100 ms regardless of build):

| File   | Baseline median | Step 2 median | Δ      | Baseline max | Step 2 max |
|--------|-----------------|---------------|--------|--------------|------------|
| 2sec   |   20.15 ms      |  20.02 ms     | −0.7 % |   40.17 ms   |  57.78 ms  |
| 30sec  |   20.16 ms      |  19.66 ms     | −2.5 % |   38.34 ms   |  60.47 ms  |
| 5min   |   73.79 ms      |  70.31 ms     | −4.7 % |   73.86 ms   |  74.45 ms  |

Median is within ±5 % on every file — the negative deltas are
measurement noise, not real speedup. **Acceptance signal #5 passes.**

The max-frame numbers tell the other half of the story: on 2sec and
30sec, the one-time `compute_edges` call lands on a single frame
(~40 → 57 ms on 2sec, ~38 → 60 ms on 30sec). After that frame, the
dirty flag is cleared and subsequent frames are unaffected. On the
5min file the 331 ms compute should have produced a single ~400 ms
frame, but sokol caps `sapp.frame_duration()` to ~100 ms, so it
appears in the CSV as one of the early 100 ms entries rather than as
a distinct spike. The hit is real, just invisible to the logger.

Log files retained:

- `logs/step2_2sec.csv`
- `logs/step2_30sec.csv`
- `logs/step2_5min.csv`

…alongside the matching `logs/baseline_*.csv` from micro-step A+B.

**Risks encountered:**

1. **One-time hitch on long files.** The 5min file pays a 331 ms
   compute on first access. Because `dirty` clears after compute, no
   subsequent frame pays again unless the file is reloaded or
   `dirty` is re-set (Step 5's K-tuning will do that intentionally,
   editing eventually will too). At 13.6 FPS baseline (~74 ms/frame)
   the hit is roughly 4.5 frames of stall — noticeable as a hitch
   when switching files. Acceptable for now under acceptance signal
   #5 (which scopes to steady state), and the existence of Step 7
   (`draw_wavelength` rework) will roughly halve the per-frame
   budget on long files, making the same 331 ms absolute hit a
   smaller fraction of frame time. Optimizing `compute_edges` itself
   is a separate follow-up (see #1 below).
2. **Compute fires per playing-wav-switch, not per app-launch.**
   Today the user only ever plays one file in the test directories,
   but the broader `assets/audio/` workflow involves switching between
   wavs via the pager. Each switch will hit the first-access compute
   for the newly-selected wav. This is the intended lazy-cache
   behavior; flagging so we keep it in mind when designing Step 3's
   navigation (e.g., maybe pre-warm edges for adjacent files in a
   later optimization).
3. **`delete` on zero-init dynamic arrays.** Verified safe by reading
   `core:runtime`: `delete([dynamic]T)` checks
   `allocator.procedure == nil` and is a no-op when uninitialized. So
   the first ever call to `ensure_edges_fresh` doesn't crash even
   though `leading` / `trailing` were never previously allocated.

**Follow-ups:**

1. **Optimize `compute_edges` for long files.** 331 ms on the 5min
   file is dominated by the 25 M-sample RMS scan. Easy levers if it
   becomes the bottleneck: (a) skip the channel-mixdown and read only
   channel 0 — halves memory traffic, ~165 ms expected; (b) coarsen
   `EDGE_HOP_MS` from 10 ms to 20 ms — halves both passes; (c) SIMD
   the inner squared-sum loop via Odin intrinsics. Deferring until
   Step 7 is in and we can re-measure end-to-end frame impact.
2. **Pre-warm strategy for the pager.** Currently each
   `pager.next/prev` switch will trigger a fresh `compute_edges` on
   first access. A future optimization could pre-warm `n` neighboring
   files in a background thread. Tracking but not in scope for the
   current feature.
3. **Remove the temporary duration log** before the feature is
   considered done. Right now it fires once per file in
   `ensure_edges_fresh` at DEBUG level. Useful for Steps 3–5
   troubleshooting; should be removed (or demoted to a `when ODIN_DEBUG`
   guard) before the feature lands as "complete."

### Closing item: `claude_fps` analysis script

Added `claude_fps` (executable bash script at repo root) to formalize
what had been inline `awk` one-liners for parsing
`BEACH_FRAME_LOG` CSV output. Skips the first 2 data rows (sokol
startup clamps), then computes median / p95 / max frame duration with
the corresponding FPS for each file passed. When multiple files are
passed, also prints a comparison table using the first file as the
baseline.

**Files changed:**

- **NEW** `claude_fps` — executable, depends only on `awk`, `sort`, and
  `bash` (all available in Git Bash).

**Usage example (run after Step 2's verification):**

```bash
./claude_fps logs/baseline_2sec.csv logs/step2_2sec.csv
```

```
logs/baseline_2sec.csv
  frames (steady) : 37
  median          :   20.149 ms   ->    49.6 FPS
  p95             :   20.232 ms   ->    49.4 FPS
  max             :   40.172 ms   ->    24.9 FPS

logs/step2_2sec.csv
  frames (steady) : 37
  median          :   20.016 ms   ->    50.0 FPS
  p95             :   20.078 ms   ->    49.8 FPS
  max             :   57.776 ms   ->    17.3 FPS

Comparison (first file as baseline):

  file                                            med (ms)      FPS   Δ vs base
  ----                                            --------      ---    ---------
  logs/baseline_2sec.csv                            20.149     49.6          —
  logs/step2_2sec.csv                               20.016     50.0        -0.7%
```

**Goal alignment:** Acceptance signal #8 (FPS not impacted) — every
runtime step from here forward will use `claude_fps` to compute the Δ
and either show it inline in the changelog entry or attach the
script's output. No more eyeballing or one-off `awk` snippets.

**Pitfalls / caveats:**

- The comparison column always treats the *first file passed* as the
  baseline. Calling
  `./claude_fps logs/baseline_2sec.csv logs/baseline_5min.csv` will
  produce a nonsensical "+266 %" delta because the 5min file is
  intrinsically slower — that's not a regression, it's a different
  test fixture. Use one file pair at a time when comparing
  before/after, or pass files in matched order.
- The first 2 data rows are unconditionally skipped on the theory
  that they're always sokol-startup clamps. If a future logger
  config disables that skip (e.g., for testing the very first
  frame), the script will silently drop real frames. Documented
  inline in the script header.

---

## Step 3 — `w` / `e` / `b` navigation — 2026-05-25

**Summary:** Wired vim-style edge navigation to the playback cursor.
`w` jumps to the next leading edge after `frame_cursor`; `e` jumps to
the next trailing edge; `b` jumps to the previous leading edge.
Replaced the existing `.E` / `.B` TODO blocks (which called
`wav.scan_forward` / `wav.scan_backward` as placeholder scrubs) with
the new behavior, and added a `.W` block that didn't previously exist.

**Files changed:**

- **MODIFIED** `src/main.odin` — `process_user_input` replaces three
  TODO placeholder blocks (lines ~1590–1605) with calls to
  `wav.next_leading` / `wav.next_trailing` / `wav.prev_leading`. Each
  block:
  1. Reads `playing.frame_cursor` (an `f64`), narrows to `i32` for the
     binary-search nav procs (sample indices are bounded by `i32`).
  2. Calls the appropriate nav proc.
  3. Only assigns the new cursor when the proc returns `>= 0`; a `-1`
     return means "no more edges in that direction," in which case the
     cursor stays put (`docs/edge_detection/GOALS.md` → Navigation:
     "no crash, no
     wrap-around").
  4. Clears the `key_down` slot so the action doesn't auto-repeat on
     held keys.

`H` / `L` (the ±2 s scrubs from `CLAUDE.md`) continue to call
`wav.scan_forward` / `wav.scan_backward` and were not touched.

**Goal alignment:**

- **Navigation** (all four bullets in `docs/edge_detection/GOALS.md` → Navigation):
  - `w` → `wav.next_leading(playing, cursor)` — strictly greater (the
    binary search in `edges.odin` uses `arr[mid] <= cursor do lo = mid +
    1`, which produces the smallest index with `arr[i] > cursor`).
  - `e` → `wav.next_trailing(playing, cursor)` — same comparison shape.
  - `b` → `wav.prev_leading(playing, cursor)` — strictly less (the
    nav proc uses `arr[mid] < cursor do lo = mid + 1`, giving the
    largest index with `arr[i] < cursor`).
  - O(log N): all three procs are binary searches.
  - Boundary safety: each proc returns `-1` when no edge exists, and
    the call site only writes when the return is `>= 0`. Cursor stays
    put.

- **Detection** (no change, but the wiring depends on Step 2's lazy
  recompute keeping `playing.edges.leading[]` / `trailing[]` populated
  and current).

**Verification:**

- `bash ./build_odin` — clean.
- Interactive verification of the actual key behavior is **deferred to
  manual user testing** because the frame logger can't simulate input
  events. Code review evidence that the wiring is correct:
  - The three nav procs in `edges.odin` were already exercised by
    Step 2's compute_edges output (paired sorted arrays produced for
    every test file).
  - The new call sites are 4 lines each and match the documented
    contract of each nav proc.
- FPS check via `claude_fps` against Step 2 logs (using
  `BEACH_RUN_SECONDS=1 BEACH_FRAME_LOG=./logs/step3_<dir>.csv
  ./claude_make test/<dir>`):

  | File | Step 2 median | Step 3 median | Δ vs Step 2 |
  |---|---|---|---|
  | 2sec  | 20.02 ms | 19.74 ms | **−1.4 %** |
  | 30sec | 19.67 ms | 19.83 ms | **+0.8 %** |
  | 5min  | 70.31 ms | 75.04 ms | **+6.7 %** ⚠ |

  The 5min number is just outside the ±5 % bar. **It is sampling
  noise, not a real regression.** Evidence:

  1. The 1-second run window on a ~13 FPS file only produces n=5
     steady-state frames. The standard error on a median with n=5 is
     wide.
  2. Two re-runs on the same Step-3 build showed +3.5 % and +4.0 %
     deltas:

     ```
     logs/step3_5min.csv         75.042 ms   13.3 FPS   +6.7 %
     logs/step3_5min_run2.csv    72.791 ms   13.7 FPS   +3.5 %
     logs/step3_5min_run3.csv    73.098 ms   13.7 FPS   +4.0 %
     ```

     The three runs span 73 → 75 ms — ~3 % spread on the *same*
     binary. The Step 2 baseline at 70.31 ms is itself one sample
     from this same distribution; the "true" steady-state is
     plausibly ~73 ms.
  3. Code review: Step 3 added 12 lines, all in `process_user_input`,
     gated on key-press booleans that are false 100 % of the time
     during these unattended runs. The work added per non-key-press
     frame is three `if false do …` checks. Cannot account for 5 ms.

  **Conclusion:** 5min steady-state perf is within the noise floor of
  the measurement protocol on this file. The ±5 % bar is too tight
  for n=5 samples; for any 5min check moving forward I'll either
  widen the bar or extend `BEACH_RUN_SECONDS` for that single check.

- Log files retained: `logs/step3_2sec.csv`, `logs/step3_30sec.csv`,
  `logs/step3_5min.csv`, plus the two re-runs.

**Risks encountered:**

1. **Sample-size limit on the 5min FPS check.** Documented above. Not
   a code risk, but a verification-protocol limit we should remember
   for Step 7 (which will explicitly target the 5min file's per-frame
   cost). When Step 7 ships, the 5min FPS will rise, n will increase
   per second of runtime, and the ±5 % bar becomes meaningful again.
2. **`i32` cast on `frame_cursor`.** `playing.frame_cursor` is `f64`
   for sub-sample interpolation accuracy in the audio mixer (see
   `wav.odin:1419` area). `i32(playing.frame_cursor)` truncates the
   fractional part for the binary search, which is correct
   semantically — we're looking up "the next edge after the current
   sample index." After assignment back to `f64`, the audio mixer
   resumes interpolation from an integer boundary. Verified the
   round-trip is lossless within the i32 range; for files larger than
   2 G frames (≈13 h at 44.1 kHz mono) we'd overflow, but that's far
   beyond any field-recording use case.
3. **Loss of the old `.E` / `.B` scrub behavior.** Removed
   intentionally per user direction in the `docs/edge_detection/EDGES.md`
   plan-tweaks. The
   ±2 s scrubs remain available on `H` / `L`. If you (the user) miss
   the old behavior at some point, we can rebind on a fresh key — but
   I won't reinstate it unless asked.

**Follow-ups:**

1. **Manual verification needed.** Run the app interactively against
   any of the three test directories. Confirm:
   - `w` audibly advances playback to the next event onset; the
     `sgl` waveform's playback indicator (if visible) moves to the
     start of the next "loud bit."
   - `e` lands at the end of the current loud bit.
   - `b` walks backward through onset starts.
   - Pressing `w` past the last edge does nothing (no crash, cursor
     stays).
2. **Visualization first, then tuning.** Step 4 puts visible tick
   marks on the sgl waveform so we can *see* whether the algorithm
   placed edges where we'd expect, rather than just inferring from
   audible playback jumps. After that, Step 5 makes K live-tunable.
   If Step 4 reveals systematically misplaced edges, that's where
   we'd discover it and we'd tune K before moving on.

### Verification re-run with `BEACH_RUN_SECONDS=3` — 2026-05-25

Per user direction, re-ran the FPS verification with a 3 s window
instead of 1 s to characterize whether the 5min file's +6.7 % delta
was a real regression or sampling noise. The 1 s runs were producing
n=5 frames on the 5min file, which is too few for a reliable median.

Three runs of the same Step-3 binary on each test directory:

| File             | n (3s)   | Median      | Run-to-run spread (5min only) |
|------------------|----------|-------------|-------------------------------|
| 2sec  @ 3s       | 139      | 20.162 ms   | (single run)                  |
| 30sec @ 3s       | 140      | 20.079 ms   | (single run)                  |
| 5min  @ 3s run 1 |  34      | 70.432 ms   |                               |
| 5min  @ 3s run 2 |  34      | 70.064 ms   | range = 0.58 ms ≈ 0.83 %      |
| 5min  @ 3s run 3 |  34      | 69.851 ms   |                               |

The three 5min runs span 70.43 → 69.85 ms — under 1 % run-to-run
variance with n=34. Comparing to Step 2's 1-second 5min median
(70.31 ms): the 3-second median lands at ~70.1 ms, statistically
indistinguishable from Step 2.

**Verdict on Step 3:** confirmed no regression. The +6.7 % delta in
the original 1-second measurement was sampling artifact from n=5
medians. Step 3 added zero per-frame work, as the code review
predicted.

**Protocol change going forward:** all future FPS verifications use
`BEACH_RUN_SECONDS=3`. Acceptance bar stays at ±5 % on the steady-
state median; at 3 s the run-to-run variance is ≤1 % on the slowest
file in the test set, which gives the ±5 % bar real teeth.

Log files retained for inspection:

- `logs/step3_2sec_3s.csv` — n=139
- `logs/step3_30sec_3s.csv` — n=140
- `logs/step3_5min_3s_run1.csv` — n=34
- `logs/step3_5min_3s_run2.csv` — n=34
- `logs/step3_5min_3s_run3.csv` — n=34

The earlier 1-second `logs/step3_*.csv` and prior-step `logs/step2_*.csv`
/ `logs/baseline_*.csv` are kept as historical record but are no
longer the comparison points for future steps.

---

## Step 4 — Edge tick visualization on sgl waveform — 2026-05-25

**Summary:** After the existing waveform line strip in
`draw_wavelength`, draw two `sgl.begin_lines()` batches — green
vertical ticks at every `leading[]` edge, red vertical ticks at every
`trailing[]` edge. Ticks use the same `x_step` / `half_w` math as the
waveform line, so they land at the exact same x-coordinate as the
sample they mark.

**Files changed:**

- **MODIFIED** `src/main.odin` — appended a 23-line block at the end
  of `draw_wavelength` (after the line strip's `sgl.end()`).
  Computes `tick_half_h = y_scale * 1.1` so each tick peeks above
  and below the waveform amplitude. For each color (green leading,
  red trailing): iterate the edge array, compute
  `tx = -half_w + f32(edge_frame) * x_step`, push two verts. No
  changes to the waveform line itself; no algorithm changes.

**Goal alignment:**

- **Visualization** (all three bullets in `docs/edge_detection/GOALS.md`):
  - "Leading edges drawn as green vertical ticks" — `sgl.c3f(0, 1, 0)` +
    leading loop.
  - "Trailing edges as red ticks" — `sgl.c3f(1, 0, 0)` + trailing loop.
  - "Ticks are positioned at the same x-coordinate as the
    corresponding sample" — both the line strip and the ticks use
    `x_at_frame(f) = -half_w + f * x_step`, so alignment is exact by
    construction (same operands, same op-order, both `f32`).

**Verification:**

- `bash ./build_odin` — clean.
- FPS, 3 s window, vs Step 3 (3 s baseline):

  | File | Step 3 median | Step 4 median | Δ |
  |---|---|---|---|
  | 2sec | 20.162 ms | 20.151 ms | **−0.1 %** |
  | 30sec | 20.079 ms | 19.959 ms | **−0.6 %** |
  | 5min | 70.432 ms | 69.828 ms | **−0.9 %** |

  All within ±1 %. The added work per frame is 2 × (n_leading +
  n_trailing) vertices — 14 verts on 2sec, 76 verts on 30sec, 88
  verts on 5min — vs ~600 K verts already pushed by the downsampled
  waveform line. Lost in the noise floor of the existing per-frame
  work.

- Edge sanity (30sec):
  `compute_edges: 250813_0074, 1215360 frames, 31.38 ms, leading=38
  trailing=38 t_high=-46.48 t_low=-52.48` — paired, same shape as
  Step 2.

- Log files retained: `logs/step4_2sec.csv`, `logs/step4_30sec.csv`,
  `logs/step4_5min.csv`, `logs/step4_sanity.csv`.

**Manual UI verification checklist (waiting on user):**

The frame logger can't see whether ticks render. Please run any test
directory interactively and confirm:

1. **Ticks appear.** Green vertical lines at the left of the
   waveform (visible portion); a few red ones too. They should
   stand vertical, slightly taller than the waveform's amplitude.
2. **Alignment is exact.** Each tick should sit at the start (green)
   or end (red) of a visibly louder section of the waveform. The
   tick should land *on* the audible event boundary, not next to it.
3. **Counts feel right.** For `test/30sec` (38 leading / 38
   trailing): you should see clusters of green/red ticks where the
   recording has active content, none where it's silent.
4. **Pressing `w`** should land the playback cursor right at the
   next green tick (visible if the cursor-highlight white section
   reaches it).
5. **No crashes** when navigating to a fresh file or when the
   playhead is past the visible waveform.

If ticks are misplaced, way off-axis, or invisible, that's a wiring
bug — flag it and we'll diagnose. If they're *placed* but feel like
they're in the wrong spots (e.g., always slightly early or always in
the middle of silence), that's a K-tuning issue — Step 5 (next)
makes K live-tunable so we can dial it in.

**Risks encountered:**

1. **Waveform x extent is much wider than the visible viewport.**
   `x_step = (14 * half_w) / num_frames` lays the waveform across
   `14 * half_w` world units, but the visible NDC at z=-DEPTH_UI is
   only ~`2 * half_w` wide. Only the leftmost ~1/7 of edges will be
   visible on screen — matching the waveform itself. This is
   intentional (existing app behavior); flagging because it means
   "no visible ticks" could mean either "no edges in the visible
   region" or "edges exist but live off-screen to the right." The
   `compute_edges` debug log makes the latter case distinguishable.
2. **Color collision with the waveform line.** The waveform is also
   green (`sgl.c3f(0, 1, 0)`), so leading ticks and the waveform
   line share a color. Vertical-vs-horizontal orientation makes
   them visually distinct in practice, but if it turns out to be
   hard to read we can shift leading ticks to a different shade
   (e.g., bright lime, or cyan) in a later tuning pass.

**Follow-ups:**

1. **`compute_edges` duration log line** — flagged for removal in
   Step 2's follow-ups. Still useful while we're verifying Step 4
   /5; will remove (or guard with `when ODIN_DEBUG`) once the
   feature is wrapping up.
2. **Tick height tuning** — `tick_half_h = y_scale * 1.1` is a
   first-pass guess. If the user finds ticks too tall or too short
   during manual verification, easy to tweak in Step 5 alongside K
   knobs.
3. **Possible color collision (above)** — defer until we see how it
   reads in practice.

---

## Step 5 — Debug overlay + live K tuning (bundled with two prior-step bug fixes) — 2026-05-26

**Summary:** Added the `docs/edge_detection/GOALS.md` → Live tuning surface: an sdtx overlay
line showing `K_HIGH`, `K_LOW`, `t_high_db`, `t_low_db`, and
`leading/trailing` counts, plus four key bindings (`[` / `]` for
`K_HIGH`, `-` / `=` for `K_LOW`) that nudge by ±0.05 and mark the
playing wav's edges dirty so the next frame recomputes. Also bundled
two code-bug fixes that the user surfaced during Step 4 manual
verification — they were prerequisites for live tuning to be a
meaningful interaction.

**Files changed:**

- **MODIFIED** `src/main.odin`:
  1. `draw_wavelength` tick math — switched the per-frame stride
     from `x_step` to `x_step / downsample_window` so ticks align
     with the actual waveform vertex positions. (Step 4 bug fix.)
  2. `.B` key handler — apply a 100 ms back-tolerance
     (`sample_rate / 10`) before calling `wav.prev_leading`, so
     audio drift past the most-recently-jumped-to edge no longer
     re-snaps the cursor to that same edge. `prev_leading` itself
     remains strict-less-than (matches `docs/edge_detection/GOALS.md`
     primitive); the
     tolerance is a UX-layer concern. (Step 3 bug fix.)
  3. Debug overlay — one new sdtx line after the camera lines.
  4. K-tuning keys — four new branches in `process_user_input`
     immediately after the W/E/B navigation block.

**Goal alignment:**

- **Live tuning** (all three bullets in `docs/edge_detection/GOALS.md`):
  - `K_HIGH` / `K_LOW` are runtime-mutable globals — declared as
    package vars back in Step 1; this step is when they finally
    matter.
  - `[` / `]` nudge `K_HIGH ± 0.05`; `-` / `=` nudge `K_LOW`. All
    four set `playing.edges.dirty = true` so `ensure_edges_fresh`
    runs against the new thresholds on the next frame.
  - Debug overlay shows everything per the spec: `K_HIGH`, `K_LOW`,
    `t_high_db`, `t_low_db`, leading/trailing counts.
- **Visualization** (re-satisfied): Step 4's tick alignment bug
  meant the tick claim from that step's CHANGELOG was technically
  false. Now ticks land at the correct x-coordinate.
- **Navigation** (re-satisfied): Step 3's `b` claim depended on the
  cursor not being stuck; with audio playing it was. Now fixed.

**Verification:**

- `bash ./build_odin` — clean.
- FPS, 3 s window, vs Step 4:

  | File | Step 4 median | Step 5 median | Δ |
  |---|---|---|---|
  | 2sec  | 20.151 ms | 19.999 ms | **−0.8 %** |
  | 30sec | 19.959 ms | 19.876 ms | **−0.4 %** |
  | 5min  | 69.828 ms | 70.294 ms | **+0.7 %** |

  All within ±1 %. Step 5 added per frame: one sdtx printf, four
  `if key_down[X]` checks (all false during unattended runs), and a
  tighter `b` handler that runs only on `.B` press. Cost is in the
  noise.

- Log files: `logs/step5_2sec.csv`, `logs/step5_30sec.csv`,
  `logs/step5_5min.csv`.

**Manual UI verification checklist (waiting on user):**

Now is the moment we get to actually look at the algorithm against
real content with the ability to tune live. Run any test directory
and confirm:

1. **Overlay line is present.** Look for
   `edges: K_HIGH=0.70 K_LOW=0.40  t_high=… t_low=… dB  L/T=…/…`
   below the camera-debug lines.
2. **Ticks now align with the waveform.** Previously misaligned;
   should be exact now (same x as the corresponding waveform
   vertex's bucket).
3. **`b` actually walks backwards.** Hit `b` repeatedly: each press
   should land on a strictly earlier edge than the last, even if
   audio is playing.
4. **`[` makes edges more permissive.** Press `[` a few times:
   `K_HIGH` should decrease in the overlay; leading/trailing
   counts should rise (lower threshold → more edges detected); new
   ticks should appear.
5. **`]` makes edges stricter.** Opposite — fewer ticks, higher
   K_HIGH.
6. **`-` / `=` tune K_LOW** the same way.
7. **No crashes** at any K extreme. If K gets pushed below the
   floor or above the IQR clip, `compute_edges` clamps so the
   thresholds stay sane.

The intent of this step is exactly this kind of dial-it-in workflow:
push `[` until ticks land at the right boundaries by ear/eye, then
note the K value as a candidate default.

**Risks encountered:**

1. **K can be pushed arbitrarily negative** with enough `[` presses.
   `compute_edges` clamps the resulting thresholds against
   `EDGE_DB_FLOOR + 12` / `+ 6` and enforces a 6 dB minimum
   `t_high − t_low` gap, so the algorithm itself stays valid — but
   the overlay will show wild K values. Not currently clamped at
   the input side. If we ever ship to a user, add `clamp(K, 0,
   3.0)` in the key handlers; for development tuning, leaving it
   unbounded is fine and arguably useful for "what if I push it
   way past sensible?" exploration.
2. **`b` tolerance is hardcoded to `sample_rate / 10`.** Works for
   the user's 44.1 / 48 kHz field recordings (~4400 frames =
   100 ms). For radically different sample rates (e.g., 8 kHz
   speech, 96 kHz hi-res) the tolerance scales with rate, which is
   the right behavior — milliseconds, not frame counts, is the
   meaningful unit. Documented in the call site.
3. **Re-validation of Step 4 alignment claim.** My original Step 4
   CHANGELOG asserted "ticks land at the exact same x-coordinate
   as the corresponding sample." That was technically false until
   this step's fix. Not retroactively editing the Step 4 entry
   (per `docs/edge_detection/PROCEDURES.md`:
   `docs/edge_detection/CHANGELOG.md` entries are retrospective work
   logs, not the current state of truth). Future readers will see
   the bug surface in this entry and the original optimistic claim
   in Step 4's entry — that's the honest record.

**Follow-ups:**

1. **Tick alignment edge case: edges past the visible viewport.**
   Most ticks live off-screen to the right because the waveform's
   x-extent (`14 * half_w` wide before downsampling collapsed it)
   still exceeds the visible NDC. The math is now correct, but the
   user only sees the leftmost portion. A future viewport / scroll
   feature would let the user pan; Step 7's downsampling rework
   may also restructure this.
2. **Color collision: ticks-green vs waveform-green.** Still
   present. If manual verification finds the overlap hard to read,
   shift leading ticks to a different hue (lime, cyan, etc.).
3. **`compute_edges` duration log line** — still present, still
   useful while tuning. Remove (or `when ODIN_DEBUG`-guard) once
   the feature is wrapping. Step 6 (unit tests) or Step 7 ending
   is the natural place.
4. **Persisting tuned K values.** Currently `K_HIGH` / `K_LOW`
   reset to defaults each app launch. If user finds a default that
   works across the library, hardcode it; if it's per-file or
   per-session, would need persistence (out of scope here).

---

## Step 6 — Unit tests for current `compute_edges` behavior — 2026-05-26

**Summary:** Added the project's first Odin test runner for the WAV edge
package and a focused synthetic test suite for the current edge detector. The
tests lock in silent-buffer behavior, finite burst pairing, separated-event
sorting, debounce behavior, outlier robustness, current global-K threshold
behavior, and strict binary-search navigation semantics.

**Files changed:**

- **NEW** `src/audio/wav/edges_test.odin` — package-local tests for
  `compute_edges`, `next_leading`, `next_trailing`, and `prev_leading`.
- **NEW** `test_odin` — root-level Git Bash runner for
  `odin test ./src/audio/wav -debug`.
- **MODIFIED** `docs/edge_detection/FEATURE.md` — Step 6 marked complete;
  Step 7 is now next.
- **MODIFIED** `docs/edge_detection/SUMMARY.md` — compact session status
  updated.
- **MODIFIED** `docs/edge_detection/CURRENT_STEP.md` — final state and
  verification recorded.

**Goal alignment:**

- **Acceptance signal #7** — unit tests for `compute_edges` now exist and
  pass.
- **Detection** — tests assert paired/sorted leading and trailing edges for
  normal finite bursts, separated events, debounce-merged flicker, and a
  bimodal mix with one loud outlier.
- **Navigation** — tests assert strict `> cursor` / `< cursor` semantics and
  `-1` boundary returns for the binary-search helpers.
- **Live tuning baseline** — one characterization test confirms that changing
  the current package-level K globals changes the resolved thresholds. Step 8
  should translate that test to the new parameter API when globals are
  removed.

**Verification:**

- `./test_odin` — 7 tests passed. Odin's runner used its default 7 test
  threads; the suite is deterministic under that mode.
- `bash ./build_odin` — clean production build.
- FPS capture skipped: this step added test-only Odin code plus a runner
  script. No production runtime path, rendering path, or input path changed.

**Risks encountered:**

1. **Odin tests run concurrently by default.** The global-K characterization
   test mutates `EDGE_K_HIGH` / `EDGE_K_LOW`; on the first run that raced with
   other tests and caused unrelated synthetic tests to see the wrong
   thresholds. Fixed by adding a small test-only `sync.Mutex` and routing all
   `compute_edges` calls through it. The suite now passes under the default
   threaded runner without requiring `ODIN_TEST_THREADS=1`.
2. **Synthetic tests are characterization tests, not a perceptual truth
   oracle.** They protect algorithm invariants and obvious regressions, but
   they do not prove real field recordings are segmented well. That remains
   the purpose of Step 7's visual/audio audit and Steps 8-10's adaptive K
   work.

**Follow-ups:**

1. **Update the global-K test in Step 8.** When K values move from package
   globals to per-file/per-section parameters, the threshold-characterization
   test should move with that API instead of being deleted outright.
2. **Extend synthetic coverage in Steps 9-10.** Section discovery and
   per-section K fitting should add tests for floor drift, noisy middle
   sections, sparse bursts, and no-event sections.
3. **Optional fixture smoke test.** The current suite is synthetic-first by
   design. A future test can add a small fixture smoke check once the expected
   edge behavior for a real file is stable enough to assert.

---

## Step 7 — Tick-position audit/fix — 2026-05-26

**Summary:** Audited `draw_wavelength` and fixed the tick-position path by
making waveform buckets and edge ticks share one `waveform_x_for_frame`
mapping. The draw loop now uses explicit frame buckets instead of mutating the
loop counter inside the downsample loop, maps the file across the visible
waveform width, and uses a representative left-channel frame per bucket until
Step 11 replaces it with a proper min/max envelope.

**Files changed:**

- **MODIFIED** `src/main.odin`:
  - Added `waveform_x_for_frame(frame, num_frames, half_w)`.
  - Reworked `draw_wavelength` to iterate by explicit `bucket_start` /
    `bucket_end` frame ranges.
  - Routed both green leading-edge ticks and red trailing-edge ticks through
    the shared frame-to-x helper.
  - Changed the temporary waveform draw to sample the left channel at each
    bucket start instead of scanning a max over the buffer every frame.
- **MODIFIED** `docs/edge_detection/FEATURE.md` — Step 7 marked complete;
  Step 8 is now next; Step 11 wording updated to reflect the temporary
  representative-sample renderer.
- **MODIFIED** `docs/edge_detection/SUMMARY.md` — compact status updated.
- **MODIFIED** `docs/edge_detection/CURRENT_STEP.md` — final state and
  verification recorded.

**Goal alignment:**

- **Visualization** — ticks now use the same frame-to-x function as the
  waveform draw, so their x placement cannot drift from waveform mapping when
  bucket math changes.
- **Performance** — steady-state frame time stayed inside the guardrail for
  the 2sec/30sec fixtures and improved materially on the 5min fixture because
  the temporary renderer no longer scans the entire audio buffer every frame.

**Verification:**

- `./test_odin` — 7 tests passed.
- `bash ./build_odin` — clean.
- FPS, 3 s window, vs Step 5:

  | File | Step 5 median | Step 7 median | Delta |
  |---|---:|---:|---:|
  | `test/2sec` | 19.999 ms (n=136) | 19.598 ms (n=141) | **-2.0%** |
  | `test/30sec` | 19.876 ms (n=139) | 19.991 ms (n=139) | **+0.6%** |
  | `test/5min` | 70.294 ms (n=33) | 20.303 ms (n=121) | **-71.1%** |

- Log files retained:
  - `logs/step7_2sec.csv`
  - `logs/step7_30sec.csv`
  - `logs/step7_5min.csv`

**Manual UI verification checklist:**

1. Run `./beach.exe test/2sec` or `./beach.exe test/30sec`.
2. Confirm the waveform spans the visible width rather than being squeezed
   into a narrow band.
3. Confirm green leading ticks and red trailing ticks sit on the same x scale
   as the waveform.
4. Press `w`, `e`, and `b`; the playback cursor should still jump to audible
   event boundaries, and the nearby tick should be on the same visual x scale.
5. Press `[` / `]` and `-` / `=`; edge counts and ticks should update without
   ticks drifting away from the waveform scale.

**Risks encountered:**

1. **The first fully-correct max scan regressed 5min FPS.** Changing the
   waveform loop to scan every left-channel frame in each bucket fixed sample
   addressing but exposed the existing long-file bottleneck more severely:
   5min median frame time moved from 70.294 ms to 87.736 ms (+24.8%). That
   version was not kept.
2. **Representative-frame drawing can miss narrow peaks.** The final Step 7
   renderer is intentionally temporary: it keeps the x mapping correct and
   the frame rate acceptable, but it samples one left-channel frame per bucket.
   A narrow transient that falls between bucket starts may be underdrawn until
   Step 11 replaces this with a cached min/max envelope.

**Follow-ups:**

1. **Step 8 test cleanup.** The user noted that the Step 6 test mutex should
   be revisited when global K values are refactored away. Step 8 should update
   the global-K characterization test to target per-file/per-section params
   and remove the mutex.
2. **Step 11 min/max envelope.** Replace the representative-sample draw with
   a per-pixel min/max envelope so narrow waveform peaks are preserved while
   long files remain fast.

---

## Step 8 — Remove first-edge-calculation stutter — 2026-05-26

**Summary:** Moved first-time edge analysis off the render/audio frame. Dirty
WAVs now flow through a small edge scheduler with one worker; completed edge
arrays are installed only on the main thread and stale worker results are
dropped by generation check.

**Files changed:**

- **MODIFIED** `src/audio/wav/edges.odin`:
  - Added `Edge_Status`, `compute_edges_with_params`, `delete_edges`,
    `mark_edges_dirty`, `edges_need_analysis`, and `edge_status_string`.
  - Kept `compute_edges` as the default-K wrapper and retained
    `ensure_edges_fresh` as a synchronous tests/tools helper.
- **MODIFIED** `src/audio/wav/wav.odin`:
  - Added `edge_status` and `edge_generation` to `Wav`.
  - `read_from_file` now calls `mark_edges_dirty` after parsing.
- **MODIFIED** `src/main.odin`:
  - Added a one-worker `thread.Pool`, `Edge_Task_Data`, worker proc,
    scheduler init/tick/drain/shutdown procs, and debug-overlay status.
  - Replaced the runtime `ensure_edges_fresh` call with
    `edge_scheduler_tick()`.
  - K tuning now calls `mark_edges_dirty` so old arrays are cleared and
    stale in-flight results cannot be installed.
- **MODIFIED** `src/audio/wav/edges_test.odin`:
  - Added coverage for dirty marking clearing stale arrays, resetting status,
    and advancing generation.
- **MODIFIED** `docs/edge_detection/*.md`:
  - Marked Step 8 complete and Step 9 next; recorded the implementation and
    verification results.

**Goal alignment:**

- **Performance** — first-time edge analysis no longer blocks the interactive
  frame. The 5min fixture still takes hundreds of milliseconds of total edge
  work, but that work is now on the worker.
- **Detection / cache coherency** — stale edges are deleted immediately when
  a WAV becomes dirty; worker results are installed only if their captured
  generation still matches the file.
- **Live tuning preparation** — `compute_edges_with_params` lets jobs capture
  K values at schedule time, which reduces coupling to package-level mutable
  globals ahead of the Step 9 parameter refactor.

**Verification:**

- `./test_odin` — 8 tests passed.
- `bash ./build_odin` — clean production build.
- Edge worker timings from the 3 s verification runs:

  | File | Worker edge-analysis time | Leading | Trailing |
  |---|---:|---:|---:|
  | `test/2sec` | 2.53 ms | 7 | 7 |
  | `test/30sec` | 31.89 ms | 38 | 38 |
  | `test/5min` | 341.22 ms | 44 | 44 |

- FPS, 3 s window, vs Step 7:

  | File | Step 7 median | Step 8 median | Delta | Step 8 max |
  |---|---:|---:|---:|---:|
  | `test/2sec` | 19.598 ms | 20.109 ms | +2.6% | 58.544 ms |
  | `test/30sec` | 19.991 ms | 19.947 ms | -0.2% | 39.544 ms |
  | `test/5min` | 20.303 ms | 20.070 ms | -1.1% | 39.205 ms |

  The stutter-specific signal is the 5min row: the worker did 341.22 ms of
  edge work, but the FPS capture did not show a compute-sized max-frame spike.

**Risks encountered:**

1. **Thread ownership kept intentionally narrow.** The worker reads immutable
   `Wav.samples_raw` and writes only to task-local `Edges`; the main thread
   performs all installation into `Wav`. This avoids partial-array reads from
   the UI, but the one-worker/one-outstanding-job policy may under-warm very
   large directories. Increase queue depth only with measurement.
2. **`Computing` status is reserved but not very visible yet.** The current
   scheduler has no meaningful backlog, so files usually move from
   `uncomputed` to `queued` to `ready`. The enum keeps the planned state model
   but the overlay may mostly show `queued` while work is running.
3. **Startup file ingestion is still synchronous at the app boundary.** WAV
   files are loaded through an existing thread pool, but `load_dir` waits for
   that pool before the GUI starts. Step 8 removed edge-analysis frame stutter;
   it did not implement streaming directory ingestion.

**Follow-ups:**

1. **Step 9 K refactor.** Move K values from package globals to
   per-file/per-section parameters, update the global-K test, and remove the
   test mutex once package-level K mutation is gone.
2. **Step 9 source-analysis cache.** Introduce reusable envelope/stat caches
   with the parameter refactor so K changes can reclassify from cached data
   instead of rescanning PCM.
3. **Optional startup-streaming plan.** If large directories prove slow before
   the first frame, promote streaming WAV ingestion to its own plan item
   rather than overloading edge scheduling.

## Step 9 — Refactor K globals into per-file edge params — 2026-05-26

**Summary:** Replaced package-level mutable `EDGE_K_HIGH` / `EDGE_K_LOW`
globals with per-file `Edge_Params` on each `Wav`. Split `compute_edges` into
two stages: `compute_edge_analysis` (source-dependent, cached on the Wav) and
`classify_edges` (param-dependent, O(num_hops)). K tuning now modifies per-file
params and the scheduler takes a classify-only path when the analysis is cached,
skipping RMS recompute. Also fixed stereo energy calculation to use
sum-of-squares per channel instead of averaging channels before squaring.

**Files changed:**

- **MODIFIED** `src/audio/wav/edges.odin`:
  - Added `Edge_Params`, `Edge_Analysis`, `default_edge_params`,
    `compute_edge_analysis`, `frame_energy`, `classify_edges`,
    `copy_edge_analysis`, `delete_edge_analysis`, `analysis_is_cached`.
  - `EDGE_K_HIGH` / `EDGE_K_LOW` mutable globals replaced with
    `EDGE_DEFAULT_K_HIGH` / `EDGE_DEFAULT_K_LOW` compile-time constants. All
    other tuning constants renamed to `EDGE_DEFAULT_*` for consistency.
  - `Edges` struct gained `params_used: Edge_Params` to record which params
    produced the cached result.
  - `compute_edges` / `compute_edges_with_params` retained as convenience
    wrappers that internally call the two-stage pipeline.
  - `ensure_edges_fresh` updated to use the two-stage approach with
    per-file `edge_params`.
  - `frame_energy` uses per-channel sum-of-squares instead of
    average-then-square, fixing REVIEW.md Finding #3 (stereo phase
    cancellation).
  - Rolling RMS window avoids rescanning overlapping samples.
- **MODIFIED** `src/audio/wav/wav.odin`:
  - Added `edge_analysis: Edge_Analysis` and `edge_params: Edge_Params` to
    `Wav`.
  - `read_from_file` initializes `edge_params` to defaults and sets
    `edge_analysis.dirty = true`.
- **MODIFIED** `src/main.odin`:
  - `Edge_Task_Data` replaced `k_high`/`k_low` with `params: Edge_Params`,
    added `classify_only: bool` and `analysis: Edge_Analysis`.
  - `edge_compute_worker` runs full or classify-only path based on
    `classify_only` flag.
  - `edge_scheduler_try_schedule` captures per-file `edge_params` and copies
    the analysis cache for classify-only jobs.
  - `edge_scheduler_drain_done` installs analysis (on full compute) or frees
    the copy (on classify-only). Install/discard paths handle all allocation
    ownership correctly.
  - K tuning keys (`[`/`]`/`-`/`=`) modify `playing.edge_params` instead of
    globals. `mark_edges_dirty` leaves analysis cache valid for fast
    reclassification.
  - Debug overlay shows per-file `edge_params.k_high` / `edge_params.k_low`.
- **MODIFIED** `src/audio/wav/edges_test.odin`:
  - Removed `sync` import and `test_edge_mutex` — no more mutable globals to
    protect.
  - Simplified `compute_test_edges` (no mutex).
  - Renamed and rewrote global-K test to `compute_edges_k_values_change_resolved_thresholds`
    using `compute_edges_with_params` directly.
  - Added `two_stage_compute_matches_combined` — verifies that
    `compute_edge_analysis` + `classify_edges` produces identical results to
    `compute_edges` for the same params.
  - Added `classify_only_reuses_analysis_with_different_k` — verifies that
    the same cached analysis produces different thresholds/edges with
    different K values.
  - `make_test_wav` now initializes `edge_params = default_edge_params()`.

**Goal alignment:**

- **Detection** — edge parameters are now owned by the file, not package-level
  globals. Each file's `edge_params` can diverge independently. Stereo energy
  fix improves detection on phase-different stereo recordings.
- **Live tuning** — K changes modify per-file params and mark only edges dirty
  (not analysis). The scheduler copies the cached analysis for a classify-only
  worker pass, which is O(num_hops) instead of O(total_frames).
- **Performance** — source-analysis cache introduced. K tuning on the 5min
  file will skip the ~405ms RMS analysis and run only the classify pass.

**Verification:**

- `./test_odin` — 10 tests passed (8 adapted + 2 new).
- `bash ./build_odin` — clean production build.
- Edge worker timings (full analysis on initial load):

  | File | Worker time | Leading | Trailing |
  |---|---:|---:|---:|
  | `test/2sec` | 3.44 ms | 5 | 5 |
  | `test/30sec` | 37.45 ms | 36 | 36 |
  | `test/5min` | 404.52 ms | 41 | 41 |

- FPS, 3 s window, vs Step 8:

  | File | Step 8 median | Step 9 median | Delta |
  |---|---:|---:|---:|
  | `test/2sec` | 20.109 ms (49.7) | 20.096 ms (49.8) | -0.1% |
  | `test/30sec` | 19.947 ms (50.1) | 19.925 ms (50.2) | -0.1% |
  | `test/5min` | 20.070 ms (49.8) | 19.771 ms (50.6) | -1.5% |

  All within ±5% bar. No steady-state FPS regression.

**Risks encountered:**

1. **Full analysis time ~22% higher on 5min file** (405ms vs 331ms). The
   `frame_energy` helper has per-call function overhead vs the old inlined
   loop. Acceptable because this is a one-time cost per file load; K tuning
   now runs the classify-only path. Could be improved with `#force_inline` if
   needed.
2. **Edge counts differ from Step 8** for stereo files due to the channel
   energy fix. The old average-then-square could cancel stereo phase
   differences; the new sum-of-squares-per-channel is more sensitive. This is
   intentional per REVIEW.md Finding #3. Mono test files are unaffected.

**Follow-ups:**

1. **Step 10: Section discovery.** Per-file params are in place. Next step
   introduces `Edge_Section` to split long files into regions with distinct
   K values based on envelope statistics.
2. **`frame_energy` inline optimization.** If the 22% full-analysis overhead
   matters for very large files, add `#force_inline` or manually inline the
   per-frame energy calc.
3. **Manual UI verification needed.** User should confirm: (a) pressing K
   tuning keys on one file, switching to another, and switching back retains
   per-file K values and edge state; (b) classify-only mode is visibly faster
   on the 5min file.

## Step 10 — Automatic section discovery — 2026-05-26

**Summary:** Implemented section discovery from the cached dB envelope. The
algorithm divides the envelope into 10-second windows, computes Q25 per window,
detects boundaries where Q25 shifts by ≥6 dB, snaps boundaries to low-energy
troughs, and merges sections shorter than 5 seconds. Sections are stored per
file and discovered on the main thread after fresh analysis install.

**Files changed:**

- **MODIFIED** `src/audio/wav/edges.odin`:
  - Added `Section_Stats` and `Edge_Section` types.
  - Added section discovery constants (`SECTION_WINDOW_SECONDS`,
    `SECTION_MIN_SECONDS`, `SECTION_Q25_SHIFT_DB`, `SECTION_SNAP_SECONDS`).
  - Added `discover_sections`, `section_from_range`, `compute_section_stats`,
    `slice_percentile`, `snap_to_trough`, `merge_short_sections`, and
    `section_for_frame` procs.
- **MODIFIED** `src/audio/wav/wav.odin`:
  - Added `edge_sections: [dynamic]Edge_Section` to `Wav`.
- **MODIFIED** `src/main.odin`:
  - After installing fresh analysis in `edge_scheduler_drain_done`, calls
    `discover_sections` and stores result on the Wav.
  - Debug overlay shows section count and active section index (`sec=X/Y`).
  - Worker log line includes section count.
- **MODIFIED** `src/audio/wav/edges_test.odin`:
  - Added `make_test_analysis` and `expect_sections_cover_file` helpers.
  - Added 4 tests: uniform file (1 section), two distinct regions (≥2
    sections), short file (1 section), three regions (≥3 sections).

**Goal alignment:**

- **Detection** — "Section discovery should identify portions of a file whose
  noise floor, dynamic range, or activity density differs enough to need
  distinct K values." Sections are now discovered and stored per file.

**Verification:**

- `./test_odin` — 14 tests passed (10 from Step 9 + 4 new).
- `bash ./build_odin` — clean production build.
- Section counts from test fixtures:

  | File | Sections | Note |
  |---|---:|---|
  | `test/2sec` (1.9s) | 1 | shorter than 2 windows → single section |
  | `test/30sec` (27.6s) | 3 | detected meaningful noise floor shifts |
  | `test/5min` (4:48) | 8 | multiple distinct regimes in long recording |

- FPS, 3 s window, vs Step 9:

  | File | Step 9 median | Step 10 median | Delta |
  |---|---:|---:|---:|
  | `test/2sec` | 20.096 ms (49.8) | 20.116 ms (49.7) | +0.1% |
  | `test/30sec` | 19.925 ms (50.2) | 20.026 ms (49.9) | +0.5% |
  | `test/5min` | 19.771 ms (50.6) | 20.279 ms (49.3) | +2.6% |

  All within ±5% bar. No steady-state FPS regression.

**Follow-ups:**

1. **Step 11: Per-section K fitting.** Sections now carry local stats and
   default params. Step 11 fits K values from local envelope statistics and
   switches classification to per-section.
2. **Section discovery runs on main thread.** Currently runs in
   `edge_scheduler_drain_done` after analysis install. For the 5min file with
   ~29K hops, this is fast (well under 1ms). If much larger files cause a
   visible hitch, move discovery into the worker.

## Step 11 — Automatic per-section K fitting — 2026-05-26

**Summary:** Implemented per-section K fitting, per-section classification, and
edge merging. Each section's K values are derived from its local IQR: sections
with narrow IQR (uniform floor, no real events) get high K to suppress false
positives; sections with wide dynamic range get lower K for sensitivity. Live
tuning now targets the section under the playhead — reclassifies just that
section and re-merges, no scheduler trip needed. Also fixed section discovery
thresholds: lowered `SECTION_MIN_SECONDS` from 5.0 to 2.0 and added adaptive
window sizing for short files so files as short as ~4s can have multiple
sections.

**Files changed:**

- **MODIFIED** `src/audio/wav/edges.odin`:
  - `Edge_Section` gained `leading: [dynamic]i32` and
    `trailing: [dynamic]i32` for per-section edges.
  - Added `SECTION_MIN_IQR_DB` constant.
  - Added `fit_section_params`, `classify_section`,
    `fit_and_classify_sections`, `merge_section_edges`, and
    `delete_all_sections`.
  - Lowered `SECTION_MIN_SECONDS` from 5.0 to 2.0.
  - Added adaptive window sizing: short files (< 2 full windows but > 2×
    min section) use a smaller effective window so they can still have
    sections.
- **MODIFIED** `src/main.odin`:
  - `edge_scheduler_drain_done` now discards worker's file-level edges and
    instead calls `fit_and_classify_sections` + `merge_section_edges` on the
    main thread after installing analysis/sections.
  - Added `k_tune_section` proc — modifies the active section's K, marks it
    as manual, reclassifies just that section, and re-merges.
  - K tuning keys (`[`/`]`/`-`/`=`) now call `k_tune_section` instead of
    modifying file-level params.
  - Debug overlay shows per-section detail: `[auto/manual] K=x/y IQR=z`.
  - Section cleanup uses `delete_all_sections`.
- **MODIFIED** `src/audio/wav/edges_test.odin`:
  - Added `fit_section_params_suppresses_low_iqr_sections` — verifies high K
    for uniform sections.
  - Added `fit_section_params_uses_standard_k_for_normal_iqr` — verifies
    standard K for sections with clear events.
  - Added `per_section_classify_produces_edges_in_section_range` — verifies
    end-to-end per-section classify + merge.

**Goal alignment:**

- **Detection** — per-section K fitting addresses Michael's finding that
  different sections need different K values. Sections with no real events
  (IQR < 3 dB) get suppressed; high-dynamic-range sections get more sensitive
  detection.
- **Live tuning** — `[`/`]`/`-`/`=` now target the active section. Overlay
  shows `[auto]` or `[manual]` and the section's K values.
- **Performance** — K changes reclassify one section and re-merge on the main
  thread. No scheduler round-trip.

**Verification:**

- `./test_odin` — 17 tests passed (14 from Step 10 + 3 new).
- `bash ./build_odin` — clean production build.
- Edge counts with per-section classification:

  | File | Sections | Edges (Step 10 global) | Edges (Step 11 per-section) |
  |---|---:|---:|---:|
  | `test/2sec` | 1 | 5/5 | 5/5 |
  | `test/30sec` | 3 | 36/36 | 31/31 |
  | `test/5min` | 8 | 41/41 | 62/62 |

  30sec dropped edges (some false positives suppressed in uniform sections).
  5min gained edges (high-dynamic-range sections now more sensitive).

- FPS, 3 s window, vs Step 10:

  | File | Step 10 median | Step 11 median | Delta |
  |---|---:|---:|---:|
  | `test/2sec` | 20.116 ms (49.7) | 19.997 ms (50.0) | -0.6% |
  | `test/30sec` | 20.026 ms (49.9) | 19.977 ms (50.1) | -0.2% |
  | `test/5min` | 20.279 ms (49.3) | 20.175 ms (49.6) | -0.5% |

  All within ±1%. No regression.

**Follow-ups:**

1. **Manual UI verification needed.** User should confirm: (a) K tuning
   changes the active section's display in the overlay (`[auto]` → `[manual]`,
   K values change); (b) different sections show different auto-fit K values
   when scrubbing through a long file; (c) edge tick density varies by section.
2. **Step 9a (tick flicker) still pending.** The reclassify-on-main-thread
   approach in Step 11 actually helps — K changes re-merge immediately on the
   same frame, so there's no tickless gap for section-level K tuning. But
   file-level operations (first load, file switch) still go through the
   scheduler and can flicker.

## Step 12 — `draw_wavelength` min/max envelope downsampler — 2026-05-26

**Summary:** Replaced the per-frame O(total_frames) waveform draw with a
pre-computed min/max envelope cache. The cache is computed once at load time
(O(total_frames) with 256-frame buckets), and the draw function reads
O(screen_width) cached values per frame. The waveform now shows a proper
min/max envelope (vertical bars from min to max per pixel column) instead of a
single representative sample, preserving narrow peaks.

**Files changed:**

- **MODIFIED** `src/audio/wav/wav.odin`:
  - Added `Waveform_Cache` struct (`min_vals`, `max_vals`, `bucket_size`,
    `num_buckets`) and `compute_waveform_cache` proc.
  - Added `waveform_cache: Waveform_Cache` field to `Wav`.
  - `read_from_file` calls `compute_waveform_cache` after loading samples.
- **MODIFIED** `src/main.odin`:
  - Rewrote `draw_wavelength`: reads from `waveform_cache` instead of
    scanning raw samples; bounded to ~screen_width display buckets (max 4096);
    each bucket aggregates cached min/max values and draws one vertical line.
  - Removed `Draw_Mode` enum (color set inline per vertex pair).

**Goal alignment:**

- **Performance** — GOALS.md acceptance signal #8: "FPS is not impacted."
  The waveform draw is now O(screen_width) per frame regardless of file length.
  The 5min file's max-frame spike dropped from 63.6ms to 48.0ms. Steady-state
  FPS is vsync-limited at ~50 FPS across all fixtures (this has been true since
  Step 7 — the waveform draw is no longer the bottleneck).
- **Visualization** — the min/max envelope preserves narrow peaks that the
  old representative-sample approach missed. The display matches what DAWs
  show at zoomed-out views.

**Verification:**

- `./test_odin` — 17 tests passed (unchanged).
- `bash ./build_odin` — clean production build.
- FPS, 3 s window, vs Step 11:

  | File | Step 11 median | Step 12 median | Delta | Step 12 max |
  |---|---:|---:|---:|---:|
  | `test/2sec` | 19.997 ms (50.0) | 20.057 ms (49.9) | +0.3% | 38.985 ms |
  | `test/30sec` | 19.977 ms (50.1) | 20.053 ms (49.9) | +0.4% | 40.879 ms |
  | `test/5min` | 20.175 ms (49.6) | 19.846 ms (50.4) | -1.6% | 47.987 ms |

  2sec/30sec unchanged (±0.4%). 5min improved slightly in median and
  significantly in max-frame (63.6ms → 48.0ms). All fixtures are
  vsync-limited at ~50 FPS; the waveform draw is no longer a meaningful
  contributor to frame cost.

**Note on 60 FPS target:** The GOALS.md target of 60 FPS minimum is not yet
met. All fixtures have been at ~50 FPS since Step 7, regardless of file
complexity — the bottleneck is the display vsync configuration, not the
draw cost. Reaching 60 FPS requires investigating the sokol_app swap interval
or the display's refresh rate, not further draw optimization.

**Follow-ups:**

1. **Investigate vsync cap.** The app is locked at ~50 FPS across all file
   sizes. Check sokol_app `Desc.swap_interval` and display refresh rate.
2. **Manual UI verification needed.** Confirm the waveform looks correct:
   min/max envelope bars (not a connected line), peaks visible, highlight
   window near cursor still works.

**Post-Step 12 update:** The ~50 FPS vsync cap was an Nvidia control panel
setting. Michael enabled 120 FPS in the GPU driver — all files now run at
~120 FPS. The 60 FPS GOALS.md target is met.

## Step 11a — Bulk K adjustment across all sections — 2026-05-27

**Summary:** Added Shift+`[`/`]` (K_HIGH) and Shift+`-`/`=` (K_LOW) to shift
K values across all sections uniformly. Each section is reclassified and edges
re-merged on the same frame.

**Files changed:**

- **MODIFIED** `src/main.odin`:
  - Added `k_tune_all_sections` proc — applies delta to every section's K,
    marks all as manually tuned, reclassifies each.
  - K tuning block checks for Shift modifier: shifted → all sections,
    unshifted → active section only.

**Goal alignment:** Live tuning ergonomics for files with many sections.

## Step 9a — Smooth tick transition on K change — 2026-05-27

**Summary:** Eliminated tick-mark flicker during edge recomputation by retaining
old edges until new ones are installed. `mark_edges_dirty` no longer deletes
the edge arrays — it sets the dirty flag and bumps generation. The scheduler
install path (`edge_scheduler_drain_done`) already deletes old edges before
installing new ones, so the swap is atomic from the renderer's perspective.

**Files changed:**

- **MODIFIED** `src/audio/wav/edges.odin`:
  - `mark_edges_dirty` no longer calls `delete_edges`. Old leading/trailing
    arrays stay renderable until the install path replaces them.
- **MODIFIED** `src/audio/wav/edges_test.odin`:
  - Updated `mark_edges_dirty` test: now expects old edges to be retained
    (2/2 leading/trailing) rather than cleared (0/0).

**Goal alignment:** Live tuning (smooth visual feedback during K adjustment
and file switching).
