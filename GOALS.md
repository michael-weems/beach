# Edge Detection Feature — Goals

## Application context

Beach is a GUI tool for quickly ingesting and lightly processing raw `.wav`
files from a field recorder (see [CLAUDE.md](./CLAUDE.md)). The typical
workflow is to load a directory of recordings, skim them to find the
interesting moments, and isolate those moments as standalone clips. Field
recordings are heterogeneous — some are nearly silent with a couple of brief
events, others have continuous background noise (wind, water, room tone) with
events of varying prominence on top. Additionally, some of the file-formats are
heterogeneous, with some being IEEE 32-bit float and some 24-bit PCM and some
are something else entirely. The application should be able to support any
and all of these file-formats from .wav files.

Beach optimizes for **keyboard-driven, vim-style navigation** because the user
flips through many files (tens to hundreds) per session and screen real estate
is dominated by the audio content. Speed of "skim and locate" is the primary
UX axis.

### Hard rules that shape every feature

- **Source files are sacrosanct.** Edits to audio .wav files must produce 
  new files; originals are never modified or overwritten.
- **Lazy/cached state must stay coherent with edits.** Cached derived data
  (like edges) must invalidate when source changes. Stale state is a bug.
- **Frames-per-seconds minimum is 60 FPS** with 120+ being preferred. 
  Currently we're not meeting this rule, we need to drastically improve
  performance while maintaining feature-complexity

## This feature in that context

Edge detection makes "skim and locate" *fast*. Without it, the user scrubs
with `h`/`l` (±2s) and listens for events. With it, the user jumps
event-to-event with `w`/`e`/`b` — exactly like jumping word-to-word in vim.
The same edges will become the natural cut boundaries when the editing layer
lands later: a future `dw` deletes one complete audio "word."

So this feature is both:

1. A standalone skim-acceleration tool (usable immediately after this work).
2. The foundation for keyboard-driven editing (when that arrives).

## Goals (acceptance signals)

### Detection

- Each loaded WAV produces two sorted arrays of frame indices:
  `leading[]` (where audio activity begins) and `trailing[]` (where it ends).
- Algorithm: RMS envelope → dB → Q25-anchored thresholds with IQR spread →
  hysteretic state machine → debounce.
- Robust across content regimes: silent-with-sparse-events,
  noisy-with-frequent-events, and decent-floor-with-clear-events files must
  all yield reasonable edge sets *without* per-file changes to constants in
  source.
- Rare loud transients (outliers) must be **captured as edges** but must not
  shift thresholds enough to suppress everyday-level events. Robust
  statistics (median, percentiles) achieve this; mean/stddev would not.

### Navigation

- `w` — jump `frame_cursor` to the next leading edge strictly after it.
- `e` — jump `frame_cursor` to the next trailing edge strictly after it.
- `b` — jump `frame_cursor` to the previous leading edge strictly before it.
- All three are O(log N) via binary search on the sorted edge arrays.
- At the boundaries (no further/prior edge), the cursor stays put — no crash,
  no wrap-around.

### Visualization

- Leading edges drawn as green vertical ticks on the live sgl waveform.
- Trailing edges as red ticks.
- Ticks are positioned at the same x-coordinate as the corresponding sample,
  so visual alignment with the rendered waveform is exact.

### Live tuning

- `K_HIGH` and `K_LOW` (threshold sensitivity multipliers) are runtime-mutable
  globals in the `wav` package, not compile-time constants.
- `[` / `]` keys nudge `K_HIGH` by ±0.05 and mark the currently-playing wav's
  edges dirty (forces recompute on next access).
- Debug overlay displays `K_HIGH`, `K_LOW`, `t_high_db`, `t_low_db`, and edge
  counts so the user can tune confidently.

### Performance

- Edges are cached on the `Wav` struct with a `dirty` flag.
- Recompute fires only on first access per file, after edits, or after a K
  change. **Not per-frame.**
- Steady-state per-frame overhead is one dirty-flag check.

## Out of scope (deferred to a future feature)

- **Audio buffer editing.** No `wav.delete_range`, no `d`-prefix verb, no
  `dw`/`de`/`db`. Editing requires architecture work (immutable sources,
  undo/redo semantics, save-as-new-file behavior) that hasn't happened yet.
  Edges are read-only in this feature.
- **Alternative detection algorithms.** Otsu's method, spectral flux, and
  sliding-window adaptive thresholding are documented as future options but
  not implemented. The IQR+K approach is the chosen primary; alternatives are
  added only if real files prove it insufficient.
- **Modifying source files.** Hard rule; reiterated here because it affects
  every editing-adjacent decision downstream of this feature.

## Done definition

This feature is complete when:

1. A loaded WAV produces a non-empty, sorted `leading[]` and `trailing[]` on
   first access (assuming the file actually contains events).
2. `w` / `e` / `b` audibly and visibly move the playback cursor between event
   boundaries on real recordings from `assets/audio/`.
3. Green and red ticks appear on the live waveform at every detected edge.
4. `[` and `]` tune sensitivity live; the debug overlay reflects the changes;
   edge counts update accordingly.
5. Per-frame overhead is unchanged in steady state (no per-frame recompute).
6. The algorithm produces sensible results across the variety of files in
   `assets/audio/` without source changes — only runtime K tuning.
7. Unit tests are written and passing for the `compute_edges` implementation.
   It is acceptable to use the .wav files found under ./assets/audio/*.wav
   to perform testing, but if you have better ideas, like stubbing out 
   data and having the tests verify against that data or something that's fine.
8. Frames-per-second is not impacted
