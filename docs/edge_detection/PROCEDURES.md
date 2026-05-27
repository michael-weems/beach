# Development Procedures

The "how we work" doc for the edge-detection feature. The "what we're
building" is in [docs/edge_detection/FEATURE.md](./FEATURE.md); "what
done means" in [docs/edge_detection/GOALS.md](./GOALS.md); "what's been
done" in [docs/edge_detection/CHANGELOG.md](./CHANGELOG.md); the
technical verification commands in
[docs/edge_detection/VERIFICATIONS.md](./VERIFICATIONS.md).

## Context references at the start of each step

Before writing any code for a step, refer to the documents needed to preserve
correctness without overloading the context window. Do not blindly re-read
every document if the current context packet already captures the relevant
facts.

Use these as the canonical sources:

1. **docs/edge_detection/FEATURE.md** — planned scope, step order, noted risks.
2. **docs/edge_detection/PROCEDURES.md** (this file) — process.
3. **docs/edge_detection/GOALS.md** — acceptance signals and hard rules.
4. **docs/edge_detection/CHANGELOG.md** — historical implementation record and follow-ups.
5. **docs/edge_detection/VERIFICATIONS.md** — technical checks.
6. **docs/edge_detection/SUMMARY.md** — compact project/feature orientation.

Read only the relevant sections when possible. When context is stale,
ambiguous, compacted, or contradicted by recent changes, refresh from the
source documents before editing code.

## Step lifecycle

Each step proceeds through these phases. Communicate at every
transition; **do not advance to the next step without explicit user
sign-off**.

### Phase 0 — Context packet

Create or update a concise step context packet before planning implementation.
Default location: `docs/edge_detection/CURRENT_STEP.md`.

The packet should be short enough to survive context compaction and useful
enough to avoid repeatedly loading the full documentation set. Target 80–150
lines unless the step is unusually complex.

Include:

- Current step objective and status.
- `docs/edge_detection/GOALS.md` acceptance signal(s) advanced.
- Files expected to change.
- Relevant code paths and current behavior.
- Invariants to preserve.
- Verification commands and expected pass criteria.
- Decisions already made and rejected alternatives.
- Open risks/questions.

During the step, update the packet with important facts discovered while
reading code or debugging. At the end, distill the packet into the
`docs/edge_detection/CHANGELOG.md` entry. The packet can then remain as the
latest working-state handoff or be reset for the next step.

### Phase 1 — Plan

- [ ] Refer to the canonical docs and current context packet as needed.
- [ ] Create/update `docs/edge_detection/CURRENT_STEP.md`.
- [ ] State which `docs/edge_detection/GOALS.md` acceptance signal(s) the step advances.
- [ ] List the files expected to change and the shape of each change.
- [ ] Flag any ambiguity to the user before writing code.

### Phase 2 — Implement

- [ ] Make minimal, focused changes to the listed files.
- [ ] Build frequently from the repo root (`bash ./build_odin`) — it's cheap.
- [ ] If a planned approach turns out wrong, stop and re-plan rather
      than improvising.

### Phase 3 — Verify

Run the technical checks from `docs/edge_detection/VERIFICATIONS.md`. The phase isn't
complete until each applicable check passes:

- [ ] Build clean.
- [ ] FPS check against all three test fixtures (see borderline
      protocol below if any delta is ≥5 %).
- [ ] Edge-output sanity (only when `compute_edges` is touched).
- [ ] Manual UI checklist drafted (only when keys/drawing/overlay
      changes).

### Phase 4 — Record

Append a `docs/edge_detection/CHANGELOG.md` entry with these sections:

- **Summary** — one or two sentences.
- **Files changed** — each path with a one-line description.
- **Goal alignment** — which `docs/edge_detection/GOALS.md` acceptance signal(s) advanced.
- **Verification** — build status; FPS table where applicable;
  edge-sanity numbers where applicable; references to retained log
  files.
- **Risks encountered** — anything that bit during the work or could
  bite later.
- **Follow-ups spawned** — work flagged for a future step or revisit.

Also update `docs/edge_detection/CURRENT_STEP.md` to either summarize the
final state or prepare it for the next step.

### Phase 5 — Stop and review

Summarize for the user. List:

- What changed.
- What the verification showed.
- What needs the user's eyes (manual UI verification, decisions).

Wait for explicit go before starting the next step.

## Review lifecycle

Use this process when the user asks for a review, design critique,
algorithm assessment, architecture assessment, or similar analysis.
Reviews are not implementation steps unless the user explicitly asks
for code changes.

### Phase 1 — Orient

- [ ] Refer to the normal step-start docs as needed:
      `docs/edge_detection/FEATURE.md`,
      `docs/edge_detection/PROCEDURES.md`,
      `docs/edge_detection/GOALS.md`,
      `docs/edge_detection/CHANGELOG.md`,
      `docs/edge_detection/VERIFICATIONS.md`.
- [ ] Create/update `docs/edge_detection/CURRENT_STEP.md` if the review is
      substantial or likely to span context compaction.
- [ ] State which `docs/edge_detection/GOALS.md` acceptance signal(s) the review evaluates
      or protects.
- [ ] List the code and docs being reviewed.
- [ ] State up front which normal phases are intentionally skipped
      because this is a review-only task. Usually this means no
      implementation, build, FPS run, edge sanity run, or CHANGELOG
      entry.

### Phase 2 — Inspect

- [ ] Compare the implementation against `docs/edge_detection/GOALS.md`
      and the relevant `docs/edge_detection/CHANGELOG.md` entries.
- [ ] Verify that documented claims match the current code.
- [ ] Identify correctness risks, performance risks, architecture
      risks, missing tests, and unclear assumptions.
- [ ] Distinguish confirmed issues from hypotheses and tradeoffs.

### Phase 3 — Evaluate alternatives

- [ ] Explain whether the current approach is sufficient for the
      current step's acceptance signals.
- [ ] Compare plausible alternatives against the project's constraints:
      keyboard-first workflow, heterogeneous field recordings, lazy
      cached state, source-file immutability, and FPS targets.
- [ ] Suggest architecture re-write changes if you deem them the best solution.
      Or suggest smaller, incremental changes if you deem them the best solution.
      Use your best judgement here. 
- [ ] If recommending code, provide real Odin snippets that are scoped
      enough to be actionable, but do not edit source files unless the
      user asked for implementation.

### Phase 4 — Record

- [ ] Write the requested review artifact, such as
      `docs/edge_detection/REVIEW.md`, if the
      user asked for one.
- [ ] Lead with findings and recommendations, then supporting reasoning.
- [ ] Include file/line references where useful.
- [ ] Include any suggested verification or test cases as follow-ups.
- [ ] Do not append to `docs/edge_detection/CHANGELOG.md` for a
      review-only task; `docs/edge_detection/CHANGELOG.md` remains a
      retrospective implementation log.

### Phase 5 — Hand off

Summarize for the user. List:

- What was reviewed.
- The main conclusions.
- Any recommended follow-up work.
- Which verification or implementation phases were intentionally not
  run.

Wait for explicit user direction before converting review
recommendations into code changes.

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
4. Step 12 is the exception — its acceptance bar is "5min file improves
   measurably," not "stays flat" (see `docs/edge_detection/FEATURE.md`).

## When plans change mid-stream

If the user requests a plan change during a step (new sub-step,
reordering, different approach):

1. Acknowledge.
2. Update `docs/edge_detection/FEATURE.md` to reflect the new plan.
3. Don't update `docs/edge_detection/CHANGELOG.md` — that's a per-step retrospective, not a
   plan doc.
4. Confirm the change with the user before resuming code work.

## Communication conventions

- One step at a time. Don't pre-empt or batch.
- At the start of a step, quote the specific `docs/edge_detection/GOALS.md` acceptance
  signal(s) being advanced.
- Surface risks and decisions up front, not after the fact.
- If a step requires manual UI verification, write a clear "press X →
  expect Y" checklist in the CHANGELOG entry and explicitly hand off
  to the user.
- When citing FPS numbers, always include the steady-state median
  (not max or mean) and the sample count (n=…). Use `claude_fps`
  output verbatim where possible.

## Logging conventions

- Frame logs live under `./logs/` from the repo root (gitignored).
- Naming: `<step-id>_<test-dir>[_runN].csv`.
- Old logs are retained as historical record; new steps add new files
  rather than overwriting.
- `BEACH_RUN_SECONDS=3` is the standard window (rationale in
  `docs/edge_detection/VERIFICATIONS.md`).
