# TODO

- [ ] render all wav files as their own regions
    - [ ] figure out why file "cards" are not showing up
    - [ ] translate all regions from model view to camera view, stacked vertically on top of each other
    - [ ] moving up and down the list should move the regions up and down
- [ ] rounded corners on cards
- [ ] implement custom color themes
- [ ] add animations for camera movement
    - [ ] "composable" so it's not like "one animation at a time" but I can stack them (eg. "spin camera around list" can be done independently + summed with "move camera up and down")
- [ ] import more sounds from field recorder
- [ ] improve performance for large files / large directories
- [ ] improve `standardize` to include converting other formats to wav: `mp4`, `mp3`, `flac`, etc...
- [ ] 

## devlog

My terminology is probably incorrect in certain areas, as I'm discovering what I need to know as I run into problems.

- Took all the lessons from building a very, very, very rough and small sandbox and translated them to this project.
    - how to read wav files
    - sample rates and channels and building the float buffer to shove into sokol audio
    - rendering shapes (squares pretty much)
- Learning how to take the vertex buffers and transform the vertices into the shapes I needed was an important hurdle. This [link](https://jsantell.com/model-view-projection/) immediately clarified for me the mental model to have with model-space, world-space, and camera-space, followed by the clipping planes.
- Got text rendering working (kinda)! It's not exactly what I was hoping for since I'm using debugtext locked to 8x8 pixel sizes, but it's a start! I'll figure out custom font rendering later. Maybe. Now, to get more than 4 characters rendering at a time...
- If you update your camera's position, also remember to update the camera's target! Otherwise your world matrix will swing and rotate around in unexpected ways.

### Rendering

#### Copied Geometry

Gonna go with this for now until it's shown to be a problem.

#### Instance Rendering
Since I'm mostly going to be rendering the same mesh, I am exploring instance rendering to save on vertex buffer space. For the purposes of rendering many rectangles with different textures (text), I'm not sure if this will actually be an improvement over having just a big old vertex buffer with geometry copied over and over again. Worth exploring to understand what's possible, definitely useful to know for future projects. 

Links
[OpenGL instance texture rendering discussion](https://community.khronos.org/t/different-textures-in-instanced-rendering/71414/2)


