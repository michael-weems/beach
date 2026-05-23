# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Beach is a GUI tool for quickly ingesting and lightly processing raw `.wav` files from a field recorder. It uses [Sokol](https://github.com/floooh/sokol) for graphics/audio/windowing and is written in [Odin](https://odin-lang.org/).

## Build commands

All build scripts are Bash scripts intended to run in Git Bash on Windows.

**Build shaders** (run when `.glsl` files change):
```bash
source ./build_shaders
```
This finds all `*.glsl` files under `src/`, compiles each with `sokol-shdc` to a sibling `*_glsl.odin` file, using `-f sokol_odin -l hlsl5` (HLSL5 backend for Windows).

**Build and run** (builds shaders + Odin binary + launches with raddbg debugger):
```bash
source ./make
```

**Build Odin only**:
```bash
source ./build_odin
```
Produces `beach.exe` on Windows. The sokol collection is resolved from `$HOME/projects/sokol-odin/sokol`.

**Standardize audio files** (convert to PCM float32 via ffmpeg):
```bash
./standardize <input-dir> <output-dir>
```

**Run the app** (pass a directory of `.wav` files):
```bash
./beach.exe ./assets/audio
```

## Dependencies

- **Odin compiler** with sokol-odin bindings at `~/projects/sokol-odin/sokol` (aliased as `sokol:` collection)
- **sokol-shdc** — shader compiler, must be on PATH
- **raddbg** — debugger, launched by `make`
- **ffmpeg** — used by `standardize` script only

## Architecture

### Sokol app lifecycle

`src/main.odin` wires up four C-callable callbacks to `sapp.run`:
- `init` — allocates `Globals`, loads wav files, sets up sokol_gfx / sokol_debugtext / sokol_gl, builds pipeline and per-file text render descriptors
- `frame` — calls `process_user_input`, `update_gui`, `update_audio` each frame
- `event` — fills `key_down` sparse array (`#sparse[sapp.Keycode]bool`)
- `cleanup` — currently a no-op

### Global state

All mutable state lives in a single heap-allocated `Globals` struct accessed via the package-level pointer `g`. This includes the entity list, wav file contents, the camera entity, sokol pipeline/bindings, and per-entity text render descriptors.

### Entity / rendering model

- `Entity` has a `kind` (`FILE_ENTRY` or `CAMERA`), 3D position, model matrix, and an animation queue.
- Each loaded wav file gets an `Entity` and a `TextRenderDesc` (holds its own sokol offscreen render pass/context for text).
- Each frame, `update_gui` does an offscreen render pass per visible file entry (renders filename text into a texture), then a main pass that draws all entry quads with those textures applied.
- MVP computation is in `compute_mvp`: perspective × look-at × (translate × model_matrix).
- The color theme is Rose Pine-based, defined as `ColorTheme :: [ColorKey]sg.Color`.

### Shader pipeline

- GLSL source files live in `src/shaders/*.glsl`.
- `build_shaders` compiles them to `*_glsl.odin` files in the same directory.
- The generated files export shader descriptors, attribute/binding indices, and uniform structs used in `main.odin`.
- Currently only `triangle.glsl` / `debugtext.glsl` are used (the pipeline uses the `dbgtext` shader).

### Audio

- `src/audio/wav/wav.odin` parses WAV files (supports PCM and IEEE float formats) into `wav.Contents`, which holds raw `[]f32` samples.
- Playback uses sokol_audio: each frame `update_audio` calls `sa.expect()` and pushes frames into the ring buffer.
- The app expects 44100 Hz, stereo (2-channel) files. Files that fail `validate_contents` are skipped.

### Animation system

Entities have a `[dynamic][]Animation` queue and an arena allocator (`animation_arena`). Each `Animation` has a `kind` (currently only `Constant_Acceleration`), duration, progress, and target position. `process_animation_list` steps all queued animations per frame and writes the interpolated position to `entity.temp_position`. New animations cancel any in-progress ones.

### Key bindings (vim-style)

- `j` / `k` — navigate down/up the file list
- `g g` / `G` — jump to first/last file
- `Enter` — play selected file
- `Space` — pause/resume
- `h` / `l` — seek ±2 seconds
- `e` / `b` — trim end/beginning from current position
- `0` / `$` (shift+4) — seek to start/end
- `q` — toggle camera spin
- Arrow keys / Backspace / Delete — debug camera movement
