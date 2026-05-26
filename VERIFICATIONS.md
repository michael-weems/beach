# Verification Protocol

The technical checks applied after each step. Process around these
checks (when to run them, how to report results, how to handle
borderline outcomes) lives in [PROCEDURES.md](./PROCEDURES.md).

## 1. Build

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
PROCEDURES.md.

**Step 7 exception:** FPS on the 5min file must *improve measurably*
(target ≥60 FPS), not just stay flat. The ±5 % bar still applies to
2sec/30sec — they shouldn't regress as collateral damage.

## 3. Edge sanity (only when `compute_edges` is touched)

Inspect the `ensure_edges_fresh` debug log emitted during each
verification run (visible in `claude_make` stderr):

- `leading == trailing` count — paired state-machine invariant.
- Compute duration order-of-magnitude reasonable for the file size:
  ms-scale on 2sec/30sec; hundreds-of-ms acceptable on 5min pre-Step-7.

## 4. Manual user verification (only when UI or input is touched)

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
- Log file naming and retention rules are in PROCEDURES.md →
  "Logging conventions."
