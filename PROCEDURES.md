# Development Procedures

The "how we work" doc for the edge-detection feature. The "what we're
building" is in [FEATURE.md](./FEATURE.md); "what done means" in
[GOALS.md](./GOALS.md); "what's been done" in
[CHANGELOG.md](./CHANGELOG.md); the technical verification commands in
[VERIFICATIONS.md](./VERIFICATIONS.md).

## Read order at the start of each step

Before writing any code for a step:

1. **FEATURE.md** — confirm the step's planned scope and noted risks.
2. **PROCEDURES.md** (this file) — refresh on the process.
3. **GOALS.md** — confirm the step still maps to a stated goal.
4. **CHANGELOG.md** — what's done already, what open follow-ups apply.
5. **VERIFICATIONS.md** — the technical checks the step must pass.

## Step lifecycle

Each step proceeds through these five phases. Communicate at every
transition; **do not advance to the next step without explicit user
sign-off**.

### Phase 1 — Plan

- [ ] Re-read the five docs in the read-order above.
- [ ] State which GOALS.md acceptance signal(s) the step advances.
- [ ] List the files expected to change and the shape of each change.
- [ ] Flag any ambiguity to the user before writing code.

### Phase 2 — Implement

- [ ] Make minimal, focused changes to the listed files.
- [ ] Build frequently (`bash ./build_odin`) — it's cheap.
- [ ] If a planned approach turns out wrong, stop and re-plan rather
      than improvising.

### Phase 3 — Verify

Run the technical checks from VERIFICATIONS.md. The phase isn't
complete until each applicable check passes:

- [ ] Build clean.
- [ ] FPS check against all three test fixtures (see borderline
      protocol below if any delta is ≥5 %).
- [ ] Edge-output sanity (only when `compute_edges` is touched).
- [ ] Manual UI checklist drafted (only when keys/drawing/overlay
      changes).

### Phase 4 — Record

Append a CHANGELOG.md entry with these sections:

- **Summary** — one or two sentences.
- **Files changed** — each path with a one-line description.
- **Goal alignment** — which GOALS.md acceptance signal(s) advanced.
- **Verification** — build status; FPS table where applicable;
  edge-sanity numbers where applicable; references to retained log
  files.
- **Risks encountered** — anything that bit during the work or could
  bite later.
- **Follow-ups spawned** — work flagged for a future step or revisit.

### Phase 5 — Stop and review

Summarize for the user. List:

- What changed.
- What the verification showed.
- What needs the user's eyes (manual UI verification, decisions).

Wait for explicit go before starting the next step.

## Borderline FPS protocol

If the FPS check produces a delta ≥5 % on any file:

1. **Don't assume sampling noise** — verify it.
2. Re-run the affected file 2–3 more times with the same binary and
   the same `BEACH_RUN_SECONDS=3` window.
   - if needed, can use `BEACH_RUN_SECONDS=10` to further reduce noise
3. Compute the spread across the 3+ runs:
   - **Spread ≤1 %** → the original delta was sampling noise; the step
     passes. Document the re-run evidence in the CHANGELOG.
   - **Spread >1 %** → either the measurement is unreliable for this
     file (e.g., n is too small) or there's a real regression.
     Investigate. Possibilities: widen the window, profile the change,
     revert, etc.
4. Step 7 is the exception — its acceptance bar is "5min file improves
   measurably," not "stays flat" (see FEATURE.md).

## When plans change mid-stream

If the user requests a plan change during a step (new sub-step,
reordering, different approach):

1. Acknowledge.
2. Update FEATURE.md to reflect the new plan.
3. Don't update CHANGELOG.md — that's a per-step retrospective, not a
   plan doc.
4. Confirm the change with the user before resuming code work.

## Communication conventions

- One step at a time. Don't pre-empt or batch.
- At the start of a step, quote the specific GOALS.md acceptance
  signal(s) being advanced.
- Surface risks and decisions up front, not after the fact.
- If a step requires manual UI verification, write a clear "press X →
  expect Y" checklist in the CHANGELOG entry and explicitly hand off
  to the user.
- When citing FPS numbers, always include the steady-state median
  (not max or mean) and the sample count (n=…). Use `claude_fps`
  output verbatim where possible.

## Logging conventions

- Frame logs live under `./logs/` (gitignored).
- Naming: `<step-id>_<test-dir>[_runN].csv`.
- Old logs are retained as historical record; new steps add new files
  rather than overwriting.
- `BEACH_RUN_SECONDS=3` is the standard window (rationale in
  VERIFICATIONS.md).
