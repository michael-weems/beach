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

---

## Verification recipe (run for each of the 3 test files)

For each of `./claude_make test/2sec`, `test/30sec`, `test/5min`:

### [ ] 1. Visual edge placement

Look at the waveform. For each visibly-louder section:

- [ ] A **green tick at its left edge** (start of the burst).
- [ ] A **red tick at its right edge** (end of the burst).
- [ ] No ticks in stretches that *look* silent (would be false
      positives → K_HIGH too low).
- [ ] No visible bursts without ticks (would be missed events →
      K_HIGH too high).

### [ ] 2. Audible `w` / `e` / `b` navigation

- [ ] Press `w` → playback audibly skips to the start of the next
      event.
- [ ] Press `e` → skips to the end of the current event.
- [ ] Press `b` → walks backwards through onset starts.

If `w` lands in silence, or `e` lands mid-event → tuning issue.

### [ ] 3. Count plausibility

The overlay shows `L/T=<leading>/<trailing>`. They should always be
**equal** (or `trailing = leading − 1` if mid-event at EOF — in the
test files they ought to match exactly).

If counts are wildly off:

- Way too many → K_HIGH too low.
- Way too few → K_HIGH too high.

### [ ] 4. Tuning loop

| Symptom                                        | Action               |
|------------------------------------------------|----------------------|
| Too many ticks (events in silence)             | press `]` (raise K_HIGH) |
| Real events have no ticks                      | press `[` (lower K_HIGH) |
| Red ticks fire while sound is still playing    | press `-` (lower K_LOW)  |
| Red ticks fire long after sound stopped        | press `=` (raise K_LOW)  |
| Ticks flicker on/off as audio plays through    | widen window: `]` then `-` |
| Single events split into multiple short ones   | widen window: `]` then `-` |

Aim for **edge placement that matches what you'd manually mark with a
mouse if you were segmenting the file by hand**. When you find a
setting that works, **write down the K values shown in the overlay**.

---

## "No crashes at K extremes" — concrete test

Do this once per session (doesn't matter which file).

### [ ] Step A — Push `K_HIGH` to the bottom

Press `[` ~20 times. The overlay should show K_HIGH approaching or
going **negative** (e.g., `K_HIGH=-0.30`).

Look for:

- [ ] App still running, framerate roughly the same.
- [ ] Overlay updates each press.
- [ ] Edge counts behave (may rise then clamp).
- [ ] No crash / freeze / unresponsive input.
- [ ] No visual artifacts (waveform garbled, random ticks).

### [ ] Step B — Push `K_HIGH` to the top

Press `]` ~30 times. K_HIGH should climb past 1.5–2.0.

Look for:

- [ ] Edge counts shrink toward zero.
- [ ] `L/T=0/0` is fine — algorithm just declares no events. State
      stays SILENT.
- [ ] Ticks disappear; the waveform line itself still renders.
- [ ] No crash / freeze.

### [ ] Step C — Push `K_LOW` to extremes

Same pattern with `-` and `=`. Key edge cases:

- [ ] `K_LOW` very high (`=` ~20 times) → `K_LOW > K_HIGH` → the
      6 dB clamp kicks in. Overlay shows `t_high ≥ t_low + ~6`.
- [ ] `K_LOW` very low (`-` ~20 times) → `T_low` near silence.
      Trailing edges may take longer to fire, but EOF-close branch
      always pairs the last leading with a trailing. `L == T` holds.

### [ ] Step D — Recover

After pushing K_HIGH to the top (no edges):

- [ ] Press `[` ~30 times to bring it back down.
- [ ] Edges re-appear at roughly the same K values they had
      originally.
- [ ] App responsive, no leftover garbage state.

That recovery cycle is the strongest "no crashes" signal: pushing to
an extreme and coming back should leave you in a state
indistinguishable from a fresh launch.

---

## What "well tuned" looks like

At the right K, you'll see:

- Tick clusters lined up with the visibly louder waveform regions.
- Pressing `w` audibly cues each successive event with no false
  stops on noise.
- `L/T` counts roughly match what you'd estimate by ear (within a
  couple).
- Same K works for a *family* of similar files (silent vs. noisy may
  want different settings; that's normal).

---

## Report back

Three things I need to know to decide whether Step 5 is done or we
dig deeper before Step 6:

1. **Does a single `(K_HIGH, K_LOW)` work across all 3 test files**,
   or do different files want different settings? Drives whether we
   hardcode a default or invest in per-file adaptation.
2. **At your preferred K, are ticks where they should be by
   eye/ear?**
3. **K-extreme test results** — anything crash, freeze, or render
   weirdly?
