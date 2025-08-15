# TODO

- [ ] learn linear algebra
- [ ] learn glsl shaders
- [ ] render 3d geometry
- [ ] collision detection
- [ ] grapple hook affected by gravity
- [ ] grapple only to collideable entities
- [ ] import more sounds from field recorder
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
