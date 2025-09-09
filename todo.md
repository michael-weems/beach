# TODO

- [ ] learn linear algebra
- [ ] learn glsl shaders
- [ ] render 3d geometry
- [ ] collision detection
- [ ] grapple hook affected by gravity
- [ ] grapple only to collideable entities
- [ ] import more sounds from field recorder
- [ ] improve `standardize` to include converting other formats to wav: `mp4`, `mp3`, `flac`, etc...
- [ ] 

## Book takeaways

- odin automatically converts inputs of > 16bytes to immutable references
    - no need to pass pointers instead of original struct for performance
    - pass a pointer when you want to mutate, pass the struct when you just want to use the data
- no closures in odin
- `proc`s always support positional and named arguments
- parameters are always immutable

### Examples

`struct using`

```odin
Info :: struct {
    name: string,
    age: int,
}

Person :: struct {
    using info: Info, // like go struct embedding?
    height: int,
}
```

## devlog

- Took all the lessons from building a very, very, very rough and small sandbox and translated them to this project.
    - how to read wav files
    - sample rates and channels and building the float buffer to shove into sokol audio
    - rendering shapes (squares, pretty much)
- Learning how to take the vertex buffers and transform the vertices into the shapes I needed was an important hurdle. This [link](https://jsantell.com/model-view-projection/) immediately clarified for me the mental model to have with model-space, world-space, and camera-space, followed by the clipping planes.
- Got text rendering working (kinda)! It's not exactly what I was hoping for since I'm using debugtext locked to 8x8 pixel sizes, but it's a start! I'll figure out custom font rendering later. Maybe. Now, to get more than 4 characters rendering at a time...

