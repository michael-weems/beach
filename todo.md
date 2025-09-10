# TODO

- [ ] render all wav files as their own regions
    - [ ] figure out why file "cards" are not showing up
    - [ ] translate all regions from model view to camera view, stacked vertically on top of each other
    - [ ] moving up and down the list should move the regions up and down
- [ ] import more sounds from field recorder
- [ ] improve `standardize` to include converting other formats to wav: `mp4`, `mp3`, `flac`, etc...
- [ ] 

## devlog

- Took all the lessons from building a very, very, very rough and small sandbox and translated them to this project.
    - how to read wav files
    - sample rates and channels and building the float buffer to shove into sokol audio
    - rendering shapes (squares, pretty much)
- Learning how to take the vertex buffers and transform the vertices into the shapes I needed was an important hurdle. This [link](https://jsantell.com/model-view-projection/) immediately clarified for me the mental model to have with model-space, world-space, and camera-space, followed by the clipping planes.
- Got text rendering working (kinda)! It's not exactly what I was hoping for since I'm using debugtext locked to 8x8 pixel sizes, but it's a start! I'll figure out custom font rendering later. Maybe. Now, to get more than 4 characters rendering at a time...

