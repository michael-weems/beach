# Michael's Tuning + Verification To-Do — Step 5

Hand-off checklist for verifying Step 5 (debug overlay + live K tuning,
plus the Step 3/4 bug fixes bundled into it). Walk through these
sections in order; report back on the questions at the bottom.

---

## Mental model — how the algorithm works

The algorithm builds a per-file **envelope** in dB (RMS over 20 ms
windows) and computes two key statistics:

- **Q25** — the 25th percentile of the envelope. Roughly: "the quiet
  baseline of this file."
- **IQR** — the spread (Q75 − Q25). Roughly: "the dynamic range
  between baseline and active content."

Then it derives two thresholds:

```
T_high (dB) = Q25 + K_HIGH × IQR    ← onset threshold
T_low  (dB) = Q25 + K_LOW  × IQR    ← offset threshold
```

The state machine walks the envelope:

- **SILENT → ACTIVE** when the envelope crosses **above** `T_high` →
  records a **leading** edge.
- **ACTIVE → SILENT** when it drops **below** `T_low` → records a
  **trailing** edge.
- Values between `T_low` and `T_high` don't change state (the
  **hysteresis window**).

The overlay shows the resolved `t_high_db` / `t_low_db` *after*
clamping (there's a `T_high − T_low ≥ 6 dB` floor and an absolute
silence-floor clamp).

---

## What each knob does

### `K_HIGH` controls **onset sensitivity**

It's the only thing deciding *whether* something gets called an event
in the first place.

- **Lower K_HIGH** (`[`) → `T_high` drops → quieter content qualifies
  → **more leading edges**, more ticks.
- **Higher K_HIGH** (`]`) → `T_high` rises → only loud content
  qualifies → **fewer leading edges**, sparser ticks.

Tune K_HIGH against: *"Is this a thing I want to find, or is it
background?"*

### `K_LOW` controls **how cleanly events end**

It decides *when* an active region is declared over.

- **Lower K_LOW** (`-`) → `T_low` drops closer to silence → active
  region has to fade further before it ends → **trailing edges land
  later**, longer active regions.
- **Higher K_LOW** (`=`) → `T_low` rises closer to `T_high` → tiny
  dips end the active region → **trailing edges land earlier**,
  shorter regions, potentially chopping the tail off events.

Tune K_LOW against: *"How far down does the level have to drop before
I consider the event over?"*

### The K-window (the gap between them)

`K_HIGH − K_LOW` is the **hysteresis width** in IQR-multiples.
Default is `0.7 − 0.4 = 0.3 × IQR`, with a hard floor of 6 dB
enforced by the algorithm.

- **Wide window** (e.g. K_HIGH=1.0, K_LOW=0.2) → robust against
  jitter. Once active, stays active through small dips. Good for
  noisy content.
- **Narrow window** (e.g. K_HIGH=0.5, K_LOW=0.4) → responds quickly
  to small changes. Cleaner boundaries on clean content; flickery
  on noisy content.

If `K_HIGH < K_LOW`, the algorithm clamps to a 6 dB gap. Not harmful,
just not meaningful.

