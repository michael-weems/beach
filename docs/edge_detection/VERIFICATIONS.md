# Verification Protocol

The technical checks applied after each step. Process around these
checks (when to run them, how to report results, how to handle
borderline outcomes) lives in
[docs/edge_detection/PROCEDURES.md](./PROCEDURES.md).

## 1. Build

Run from the repo root:

```bash
bash ./build_odin
```

**Pass:** exit zero with no warnings; `bin/beach.exe` produced.

## 2. FPS

Capture per-frame durations against the three reference files via the
env-var-gated logger, then summarize and compare with `claude_fps`.

```bash
# Capture
BEACH_RUN_SECONDS=3 BEACH_FRAME_LOG=./logs/<step>_2sec.csv  ./claude_make test/2sec
BEACH_RUN_SECONDS=3 BEACH_FRAME_LOG=./logs/<step>_30sec.csv ./claude_make test/30sec
BEACH_RUN_SECONDS=3 BEACH_FRAME_LOG=./logs/<step>_5min.csv  ./claude_make test/5min

# Compare against the most-recent prior step's logs
./claude_fps logs/<prev>_2sec.csv  logs/<step>_2sec.csv
./claude_fps logs/<prev>_30sec.csv logs/<step>_30sec.csv
./claude_fps logs/<prev>_5min.csv  logs/<step>_5min.csv
```

**Pass:** steady-state median within ±5 % of the prior step on each
file.

**On a borderline delta (≥5 %):** see the borderline FPS protocol in
`docs/edge_detection/PROCEDURES.md`.

**Step 12 exception:** FPS on the 5min file must *improve measurably*
(target ≥60 FPS), not just stay flat. The ±5 % bar still applies to
2sec/30sec — they shouldn't regress as collateral damage.

## 3. Initial edge-calculation stutter

When a step changes edge scheduling, cache invalidation, file switching, or
first-edge access, verify that long-file edge analysis no longer blocks an
interactive frame.

Suggested checks:

- Manual: switch to `test/5min` and confirm there is no visible
  hundreds-of-ms freeze while edges become available.
- Log-based: capture a run that exercises the first edge calculation and
  inspect `p95` / `max` as well as the median. A `compute_edges`-sized max
  frame spike means the stutter still exists.
- Behavior: if edges are still pending, ticks may be absent and `w`/`e`/`b`
  may leave the cursor unchanged, but the UI/audio thread must remain
  responsive.

## 4. Edge sanity (only when `compute_edges` or edge scheduling is touched)

Inspect the edge-analysis debug log emitted during each verification run
(visible in `claude_make` stderr). Runtime Step 8+ runs should emit the
`edge worker:` line; direct synchronous tests/tools may still emit
`compute_edges:` from `ensure_edges_fresh`.

- `leading == trailing` count — paired state-machine invariant.
- Compute duration order-of-magnitude reasonable for the file size:
  ms-scale on 2sec/30sec; hundreds-of-ms total work can exist on 5min, but
  it must not occur as one blocking interactive frame after Step 8.

## 5. Manual user verification (only when UI or input is touched)

Frame logger can't exercise key presses or visual output. For steps
that change keybindings, drawing, or the debug overlay, write a clear
"press X → expect Y" checklist in the step's CHANGELOG entry and wait
for explicit user sign-off.

## Conventions

- All FPS commands use `BEACH_RUN_SECONDS=3`. Rationale: 1 s produced
  n=5 medians on the 5min file with ~3 % run-to-run noise — too
  loose for the ±5 % bar; 3 s gives n≈34 with ≤1 % spread.
- `claude_fps` always treats the *first* file argument as the
  baseline. Pair files explicitly: don't mix test fixtures in one
  invocation.
- Log file naming and retention rules are in `docs/edge_detection/PROCEDURES.md` →
  "Logging conventions."
