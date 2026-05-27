# Current Step — Steps 11a + 9a

Status: complete.

## Step 11a: Bulk K Adjustment

Added Shift+`[`/`]` (K_HIGH) and Shift+`-`/`=` (K_LOW) to shift all sections'
K values uniformly. Each section is reclassified and edges re-merged on the
same frame.

## Step 9a: Smooth Tick Transition

`mark_edges_dirty` no longer deletes old edge arrays. Old ticks stay visible
until the scheduler installs fresh edges, eliminating the flicker gap.

## Verification

- 17 tests passed (mark_edges_dirty test updated to expect retained edges).
- Build clean.
- ~120 FPS confirmed after Nvidia control panel fix.

## All Planned Steps Complete

| # | Step | Status |
|---|---|---|
| 1–8 | Core algorithm through background scheduler | ✅ |
| 9 | Per-file params + analysis cache | ✅ |
| 9a | Smooth tick transition | ✅ |
| 10 | Section discovery | ✅ |
| 11 | Per-section K fitting + classification | ✅ |
| 11a | Bulk K adjustment | ✅ |
| 12 | Min/max envelope downsampler | ✅ |
