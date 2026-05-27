# Edges Feature Plan Tweaks and Suggestions

## Important

### Otsu's method

You mentioned Otsu's method as "the next rung" but didn't really explain it or it's trade-offs. Why would we or would we not want to use this algorithm over what we're currently cooking up?

### editing wave files

Something very important I haven't explained yet. When we edit the wave files, we're going to always, always, always keep the originals as-is. Any edits we make will be to trim out sections and save them off as new files, never overwriting the originals. As we proceed, we're going to need to figure out what we're going to want to do - the requirements here aren't set yet. Either we edit the in-memory version of the file directly, OR we copy the original in-memory and make any edits to the new copy. Essentially, we're going to need to enable undoing and re-doing edits. We're not at that stage yet, so please hold off on ANY changes that do any actual editing of the audio / samples. Undoing and redoing is going to take some real design and architecture thought before we proceed. 

## Your questions and my responses

You asked:
```Module placement — putting the algorithm in the wav package (src/audio/wav/edges.odin) so Edges can live as a field on Wav. Alternative: top-level src/edges.odin and pass ^wav.Wav. I prefer the former (better encapsulation, lazy recompute is natural); flag if you'd rather keep wav package pure.```

My Answer:
```
src/audio/wav/edges.odin is the right place, good call.
```

You asked:
```2. Allocator — compute_edges will accept an mem.Allocator parameter. I'll wire update_gui to pass alloc.wave_allocator (your existing persistent wav allocator). The edges arrays will live on that arena until the wav is unloaded. OK as a first pass, or do you want a dedicated edges_arena from the start?```

My Answer:
```
Using the wav allocator is good here. 
```


You asked:
```
3. Constants vs. globals for K — Step 1 will define K as compile-time constants (EDGE_K_HIGH :: 0.7). Step 6 promotes them to globals for live tuning. Acceptable order, or would you rather have them as globals from the start so Step 6 is purely "wire up keys"?
```


My Answer:
```
Use globals from the start
```

You asked: 
```
4. Whether to do Steps 6 and 7 — both are quality-of-life. They make tuning and verification dramatically easier but aren't required for the feature. Tell me if you want them in scope.
```

My Answer:
```
Yes, steps 6 and 7 are both good ideas.
```

