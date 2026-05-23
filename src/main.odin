package beach

import "./assertprefix"
import "./audio/wav"
import "./pager"
import "./shaders"
import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/fixed"
import "core:math/linalg"
import "core:mem"
import "core:mem/virtual"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:thread"
import "core:time"
import sapp "sokol:app"
import sa "sokol:audio"
import sdtx "sokol:debugtext"
import sg "sokol:gfx"
import sgl "sokol:gl"
import sglue "sokol:glue"
import slog "sokol:log"
import fs "vendor:fontstash"
import stbi "vendor:stb/image"

default_context: runtime.Context

Vec2 :: [2]f32
Vec3 :: [3]f32
Vec4 :: [4]f32

Mat3 :: matrix[3, 3]f32
Mat4 :: matrix[4, 4]f32

Vertex :: struct {
  pos:   Vec3,
  uv:    Vec2,
  color: sg.Color,
}

Entity_Kind :: enum {
  FILE_ENTRY,
  CAMERA,
}

CARD_W :: 512
CARD_H :: 64
ATLAS_SIZE :: 512

TextVertex :: struct {
  pos:    Vec2,
  uv:     Vec2,
  color0: Vec4,
}

TextDesc :: struct {
  // gpu
  color_image:  sg.Image, // render target
  attach_view:  sg.View, // write target for offscreen pass
  texture_view: sg.View, // read source for main pass
  bindings:     sg.Bindings,
}

MAX_ANIMATIONS_PER_ENTITY :: 10
MAX_SECTIONS_PER_ANIMATION :: 10

Entity_Hot :: struct {
  position:      Vec3,
  temp_position: Vec3,
}

Entity_Cold :: struct {
  kind:         Entity_Kind,
  target:       Vec3,
  rotation:     f32,
  model_matrix: Mat4,
  animes:       [MAX_ANIMATIONS_PER_ENTITY]Animation,
}

Wave :: struct {
  index: int,
}

Entity :: struct {
  using hot:  Entity_Hot,
  using cold: Entity_Cold,
}

Wave_Entity :: struct {
  using entity: Entity,
  using text:   TextDesc,
  wave:         Wave,
}

Camera_Entity :: struct {
  using entity: Entity,
  debug_mode:   bool,
}

// shared state
FontState :: struct {
  fons:          fs.FontContext,
  font_id:       int,
  atlas_img:     sg.Image, // R8 stream-update image, the glyph atlas
  atlas_view:    sg.View, // texture view on atlas_img
  atlas_sampler: sg.Sampler, //
  pipeline:      sg.Pipeline, //
  vertex_buffer: sg.Buffer, // dynamic, holds text quads each frame
}

QuadState :: struct {
  pipeline:      sg.Pipeline,
  sampler:       sg.Sampler,
  vertex_buffer: sg.Buffer,
  index_buffer:  sg.Buffer,
}

MAX_FILES :: 1000
VERTICES_PER_ENTITY :: 4
MAX_VERTICES :: MAX_FILES * VERTICES_PER_ENTITY

Audio_State :: enum {
  OFFLINE,
  PLAYING,
  PAUSED,
  SWITCHING,
}

Frame :: struct {
  dt:            f32,
  screen_width:  f32,
  screen_height: f32,
  buffer:        [mem.Megabyte]u8,
  arena:         mem.Arena,
  allocator:     mem.Allocator,
}

MAX_WAV_FILE_MEMORY :: 4 * mem.Gigabyte

Alloc :: struct {
  // wave files
  wave_arena:       virtual.Arena,
  wave_allocator:   mem.Allocator,

  // entities
  entity_arena:     virtual.Arena,
  entity_allocator: mem.Allocator,
}
alloc: ^Alloc

Globals :: struct {
  frame:              Frame,
  pager:              pager.pager,
  fonts_state:        FontState,
  quads_state:        QuadState,
  camera:             Camera_Entity,
  num_waves:          int,
  waves:              []^wav.Wav,
  files:              #soa[]Wave_Entity,
  num_vertices:       int,
  vertices:           []Vertex,
  num_indices:        int,
  indices:            []u16,
  playing_state:      Audio_State,
  playing:            Wave,
  index:              int,
  bindings:           sg.Bindings,
  pass_action:        sg.Pass_Action,
  sampler:            sg.Sampler,
  disable_animations: bool,
}
g: ^Globals

SAMPLE_RATE :: 44100 // NOTE: 44100hz
DEPTH_UI :: f32(10.0) // NOTE: how far from the camera the base UI elements should be
DEPTH_UI_SURFACE :: f32(8.0) // NOTE: how far from the camera the surface UI elements should be
DEPTH_UI_OVERLAY :: f32(6.0) // NOTE: how far from the camera the overlay UI elements should be

convert_to_sokol_rgb :: proc(color: sg.Color) -> sg.Color {
  return sg.Color{r = color.r / 255, g = color.g / 255, b = color.b / 255, a = color.a / 255}
}

get_wave :: #force_inline proc(wave: Wave) -> ^wav.Wav {
  return g.waves[wave.index]
}

ColorKey :: enum {
  BASE,
  SURFACE,
  OVERLAY,
  MUTED,
  SUBTLE,
  TEXT,
  DEBUG_TEXT,
  HIGHLIGHT_LOW,
  HIGHLIGHT_MED,
  HIGHLIGHT_HIGH,
}

ColorTheme :: [ColorKey]sg.Color {
  // NOTE: for now based on rose-pine ish theme, make this adaptable via theme file
  .BASE           = {25, 23, 36, 242},
  .SURFACE        = {31, 29, 46, 255},
  .OVERLAY        = {38, 35, 58, 255},
  .MUTED          = {110, 106, 134, 255},
  .SUBTLE         = {144, 140, 170, 255},
  .TEXT           = {224, 222, 244, 255},
  .DEBUG_TEXT     = {156, 207, 217, 255},
  .HIGHLIGHT_LOW  = {33, 32, 46, 255},
  .HIGHLIGHT_MED  = {64, 61, 82, 255},
  .HIGHLIGHT_HIGH = {82, 79, 103, 242},
}

/*
	NOTE: rose-pine
    base: #191724F2; /* App Frames, sidebars, tabs */
    surface: #1f1d2e;/* cards, inputs, status lines */
    overlay: #26233a80;/* popovers, notifications, dialogs */
    muted: #6e6a86;/* diabled elements, unfocused text */
    subtle: #908caa;/* comments, punctuation, tab names */
    text: #e0def4;/* normal text, variables, active content */
    love: #eb6f92;/* diagnostic errors, deleted git files, terminal red, bright red */
    gold: #f6c177;/* diagnostic warnings, terminal yellow, bright yellow */
    rose: #ebbcba;/* matching search background paired with base foreground, modified git files, terminal cyan, bright cyan */
    pine: #31748f;/* renamed git files, terminal green, bright green */
    foam: #9ccfd8;/* diagnostic information, git additions, terminal blue, bright blue */
    iris: #c4a7e7;/* diagnostic hints, inline links, merged and staged git modifications, terminal magenta, bright magenta */
    highlight-low: #21202e;/* cursorline background */
    highlight-med: #403d52;/* selection background paired with text foreground */
    highlight-high: #524f67F2;/* borders / visual dividers, cursor background paired with text foreground */
*/

play_audio :: proc(play: Wave) {
  g.playing = play
  w := get_wave(play)

  if !w.is_valid {
    log.infof("CANNOT PLAY INVALID WAV FILE: %s", w.file_path)
    g.playing_state = .OFFLINE
    return
  }

  wav.start_over(w)
  wav.play(w)

  g.playing_state = .PLAYING

  log.debugf(
    "%s %03d/%03d recordings  %dhz  %s  %10d samples  %d channels  %02dbit sample size  %s format  %s",
    assertprefix.PLAY,
    play.index,
    g.num_waves,
    w.frequency,
    wav.time_string(w.time),
    len(w.samples_raw),
    w.channels,
    w.format.bits_per_sample,
    wav.which_format(w.format.audio_format),
    w.file_path,
  )
}

make_file_entry :: proc(wav_index: int) -> Wave_Entity {
  log.assertf(
    len(g.waves) > wav_index,
    "wav_index %d is out of bounds: max %d",
    wav_index,
    len(g.waves),
  )

  model_matrix :=
    linalg.matrix4_rotate_f32(linalg.to_radians(f32(180)), {0, 1, 0}) *
    linalg.matrix4_rotate_f32(linalg.to_radians(f32(180)), {0, 0, 1}) *
    linalg.matrix4_scale_f32(Vec3{2, 2, 1})

  // TODO: consolidate
  entry := Wave_Entity {
    kind = .FILE_ENTRY,
    position = Vec3{0, 0, DEPTH_UI},
    wave = {index = wav_index},
    model_matrix = model_matrix,
  }

  return entry
}

EntityIndex :: struct {
  start: int,
  len:   int,
}

create_wave_entities :: proc(allocator: runtime.Allocator) {
  context.allocator = allocator

  g.files = make(#soa[]Wave_Entity, size_of(Wave_Entity) * (g.num_waves + 1)) // TODO: verify this allocates the right amount of memory
  // TODO: necessary to memset to 0?

  for index in 1 ..= g.num_waves {
    g.files[index] = make_file_entry(index)
  }
}

load_dir :: proc(dir: string, allocator: runtime.Allocator) {
  context.allocator = allocator

  fd, err := os.open(dir)
  log.assertf(err == nil, "open dir: %s: %v", dir, err)

  entries, read_err := os.read_all_directory(fd, allocator)
  log.assertf(read_err == nil, "read dir: %s: %v", dir, read_err)
  log.assertf(len(entries) > 0, "no files found in dir: %s: %v", dir, read_err)

  // Get the total amount of space required to store the directory in-memory
  size: i64 = 0
  g.num_waves = 0
  for info in entries {
    if size > MAX_WAV_FILE_MEMORY {
      log.warnf("AT MEMORY CAPACITY: cannot load file %s", info.fullpath)
      continue
    }
    if os.is_directory(info.fullpath) do continue
    if !strings.contains(info.name, ".wav") do continue

    size += info.size
    g.num_waves += 1
  }

  g.waves = make([]^wav.Wav, g.num_waves + 1) // TODO: verify this allocates the right amount of memory

  pool: thread.Pool
  num_cpu_cores := 10 // TODO: system max threads?
  thread.pool_init(&pool, context.allocator, num_cpu_cores)
  defer thread.pool_destroy(&pool)

  thread.pool_start(&pool)

  // NOTE: process files
  for index in 1 ..= g.num_waves {
    e := &entries[index - 1] // os.entries is 0-based, we're one-based with 0 as empty stub

    is_dir := os.is_directory(e.fullpath)
    if is_dir do continue
    if !strings.contains(e.name, ".wav") do continue

    file_size := e.size

    g.waves[index] = new(wav.Wav)

    wave := g.waves[index]
    wave.file_path = e.fullpath
    wave.file_name = filepath.stem(e.fullpath)
    thread.pool_add_task(&pool, alloc.wave_allocator, load_wave_worker, wave, index)
  }

  thread.pool_finish(&pool)

  for index in 1 ..= g.num_waves {
    wave := get_wave({index})
    errs := wav.validate(wave)
    if !wave.is_valid {
      log.infof("invalid wav file: %s", wave.file_path)
    }
  }
}

load_wave_worker :: proc(t: thread.Task) {
  wave := cast(^wav.Wav)t.data
  wav.read_from_file(wave, context.allocator)
}

file_name_vertices :: proc() -> [4]Vertex {
  color_surface := convert_to_sokol_rgb(ColorTheme[.SURFACE])
  return [4]Vertex {
    // NOTE: file-name
    {pos = {1, 1, 1}, color = color_surface, uv = {1, 1}},
    {pos = {1, 0, 1}, color = color_surface, uv = {1, 0}},
    {pos = {0, 1, 1}, color = color_surface, uv = {0, 1}},
    {pos = {0, 0, 1}, color = color_surface, uv = {0, 0}},
    //{pos = {-1, 0, 0.0}, color = color_e, uv = {1, 0}},
    //{pos = {-1, 1, 0.0}, color = color_f, uv = {0, 0}},
  }
}

init_font_state :: proc(fonts: ^FontState) {
  // 1. Atlas image - R8, stream_update so we can push new glyph data each frame

  fonts.atlas_img = sg.make_image(
    {usage = {stream_update = true}, width = ATLAS_SIZE, height = ATLAS_SIZE, pixel_format = .R8},
  )

  // Texture view for binding the atlas in the text pipeline
  fonts.atlas_view = sg.make_view({texture = {image = fonts.atlas_img}})
  fonts.atlas_sampler = sg.make_sampler({min_filter = .LINEAR, mag_filter = .LINEAR})

  // 2. Dynamic vertex buffer: 6 verts per char * max chars * total entries
  MAX_TEXT_VERTS :: 256 * 64 * 6
  fonts.vertex_buffer = sg.make_buffer(
    {usage = {stream_update = true}, size = MAX_TEXT_VERTS * size_of(TextVertex)},
  )

  font_data := #load("../assets/fonts/Geometra.ttf")

  fs.Init(&fonts.fons, ATLAS_SIZE, ATLAS_SIZE, .TOPLEFT)
  fonts.font_id = fs.AddFontMem(&fonts.fons, "main", font_data, false, 0)

  // 4. Text pipeline — blend enabled so transparent parts show through
  fonts.pipeline = sg.make_pipeline(
  {
    shader = sg.make_shader(shaders.text_shader_desc(sg.query_backend())),
    index_type = .NONE,
    sample_count = 1, // matches CARD render target (init_file_card sets sample_count = 1)
    colors = {
      0 = {
        pixel_format = .RGBA8,
        blend = {
          enabled = true,
          src_factor_rgb = .SRC_ALPHA,
          dst_factor_rgb = .ONE_MINUS_SRC_ALPHA,
          src_factor_alpha = .ONE,
          dst_factor_alpha = .ONE_MINUS_SRC_ALPHA,
        },
      },
    },
    // No depth — purely 2D
    depth = {pixel_format = .NONE},
    layout = {
      attrs = {
        shaders.ATTR_text_pos0 = {format = .FLOAT2},
        shaders.ATTR_text_uv0 = {format = .FLOAT2},
        shaders.ATTR_text_color0 = {format = .FLOAT4},
      },
    },
  },
  )
}

init_file_card :: proc(e: Wave) {
  color_img := sg.make_image(
    {
      usage = {color_attachment = true},
      width = CARD_W,
      height = CARD_H,
      pixel_format = .RGBA8,
      sample_count = 1,
    },
  )
  e := &g.files[e.index] // TODO: will this work, since it's #soa
  e.text = {
    color_image  = color_img,
    // Separate views for the same image:
    attach_view  = sg.make_view({color_attachment = {image = color_img}}),
    texture_view = sg.make_view({texture = {image = color_img}}),
  }
}

init_quad_state :: proc(quads: ^QuadState) {
  // Six indices for two triangles forming a quad
  indices := [6]u16{0, 1, 2, 2, 1, 3}
  quads.vertex_buffer = sg.make_buffer(
    {usage = {stream_update = true}, size = uint(MAX_FILES * 4 * size_of(Vertex))},
  )
  quads.index_buffer = sg.make_buffer(
    {usage = {index_buffer = true}, data = {ptr = &indices, size = size_of(indices)}},
  )
  quads.sampler = sg.make_sampler({min_filter = .LINEAR, mag_filter = .LINEAR})
  quads.pipeline = sg.make_pipeline(
    {
      shader = sg.make_shader(shaders.quad_shader_desc(sg.query_backend())),
      index_type = .UINT16,
      depth = {compare = .LESS_EQUAL, write_enabled = true},
      sample_count = 4,
      layout = {
        attrs = {
          shaders.ATTR_quad_pos0 = {format = .FLOAT3},
          shaders.ATTR_quad_uv0 = {format = .FLOAT2},
          shaders.ATTR_quad_color0 = {format = .FLOAT4},
        },
      },
    },
  )
}

init_entity_allocator :: proc(alloc: ^Alloc, num_entities: int) {
  entity_arena_err := virtual.arena_init_growing(
    &alloc.entity_arena,
    uint(size_of(Entity) * num_entities),
  )
  log.assertf(entity_arena_err == .None, "could not create entity arena")
  alloc.entity_allocator = virtual.arena_allocator(&alloc.entity_arena)
}

init :: proc "c" () {
  context = default_context

  g = new(Globals)
  alloc = new(Alloc)
  g.disable_animations = true

  // wave file allocator
  wave_arena_err := virtual.arena_init_growing(&alloc.wave_arena, MAX_WAV_FILE_MEMORY)
  log.assertf(wave_arena_err == .None, "could not create wave file arena")
  alloc.wave_allocator = virtual.arena_allocator(&alloc.wave_arena)

  // frame allocator
  mem.arena_init(&g.frame.arena, g.frame.buffer[:])
  g.frame.allocator = mem.arena_allocator(&g.frame.arena)


  sa.setup(
    {
      sample_rate = wav.AUDIO_FREQ,
      num_channels = i32(wav.AUDIO_CHANNELS),
      logger = {func = slog.func},
    },
  )
  log.assertf(sa.isvalid(), "%s sokol audio setup is not valid", assertprefix.FAIL)

  load_dir(process_input.audio_dir, alloc.wave_allocator)
  log.assertf(g.num_waves > 0, "no wav files found in dir: %s", process_input.audio_dir)

  init_entity_allocator(alloc, g.num_waves)

  create_wave_entities(alloc.entity_allocator)

  g.pager.total_entries = g.num_waves

  // TODO: custom allocator?
  vertices := file_name_vertices()
  g.vertices = make([]Vertex, size_of(Vertex) * len(vertices))
  for v in 0 ..< len(vertices) {
    g.vertices[v] = vertices[v]
    g.num_vertices += 1
  }

  // odinfmt: disable
  g.indices = []u16{
    0, 1, 2,   2, 1, 3,  // NOTE: file-name
    //0, 1, 2,   2, 1, 3,   2, 3, 5,   5, 4, 3, // NOTE: file-name
  }
  g.num_indices = len(g.indices)
  // odinfmt: enable

  cam := &g.camera

  v := linalg.matrix4_look_at_f32(cam.position, cam.target, {0, 1, 1})
  cam.kind = .CAMERA
  set_position(cam, Vec3{0, 0, 0})
  set_target(cam, Vec3{0, 0, -DEPTH_UI})
  cam.rotation = linalg.to_radians(f32(180.0))

  sg.setup(
    {
      buffer_pool_size = 1000,
      view_pool_size = 1000,
      pipeline_pool_size = 1000,
      image_pool_size = 1000,
      shader_pool_size = 1000,
      environment = sglue.environment(),
      logger = {func = slog.func},
    },
  )
  log.assert(sg.isvalid(), "sokol graphics setup is not valid")

  sdtx.setup(
    {
      context_pool_size = 1000,
      fonts = {
        sdtx.font_kc853(),
        sdtx.font_kc854(),
        sdtx.font_z1013(),
        sdtx.font_cpc(),
        sdtx.font_c64(),
        sdtx.font_oric(),
        sdtx.font_oric(), // TODO: ???
        sdtx.font_oric(), // TODO: ???
      },
      logger = {func = slog.func},
    },
  )

  sgl.setup({pipeline_pool_size = 1000, logger = {func = slog.func}})

  init_font_state(&g.fonts_state)
  init_quad_state(&g.quads_state)

  sapp.show_mouse(false)
  sapp.lock_mouse(true)

  g.sampler = sg.make_sampler({min_filter = .NEAREST, mag_filter = .NEAREST})
  g.pass_action = {
    colors = {0 = {load_action = .CLEAR, clear_value = convert_to_sokol_rgb(ColorTheme[.BASE])}},
  }

  for w in 1 ..= g.num_waves {
    g.files[w].entity.position = Vec3{0, -1, 1}
    g.files[w].entity.model_matrix =
      linalg.matrix4_rotate_f32(linalg.to_radians(f32(180)), {0, 1, 0}) *
      linalg.matrix4_rotate_f32(linalg.to_radians(f32(180)), {0, 0, 1}) *
      linalg.matrix4_scale_f32(Vec3{2, 2, 1})

    id := Wave {
      index = w,
    }
    init_file_card(id)

    CARD_SPACING :: f32(2) // world-space vertical gap between cards
    g.files[w].entity.position.y = f32(w) * CARD_SPACING

    // NOTE: this *should* set the background color for the part the text will show up on
    // TODO: change this to .SURFACE or .OVERLAY
    log.assertf(len(g.vertices) > 0, "must load wav files and intialize vertices before init_gui")
    g.files[w].text.bindings.vertex_buffers[0] = sg.make_buffer({data = sg_range(g.vertices[:])})

    log.assertf(len(g.indices) > 0, "must load wav files and intialize vertices before init_gui")
    g.files[w].text.bindings.index_buffer = sg.make_buffer(
      {usage = {index_buffer = true}, data = sg_range(g.indices[:])},
    )

    log.assertf(len(g.waves) > 1, "len g.waves <= 1")

    g.files[w].text.bindings.views = {
      shaders.VIEW_text_tex = g.files[w].text.texture_view,
    }

    g.files[w].text.bindings.samplers = {
      shaders.SMP_text_smp = g.sampler,
    }
  }

  pager.first(&g.pager)
  pager.select(&g.pager)

  play_audio({index = g.pager.active_index})
}

frame :: proc "c" () {
  context = default_context

  g.frame.dt = f32(sapp.frame_duration())
  g.frame.screen_width = sapp.widthf()
  g.frame.screen_height = sapp.heightf()

  process_user_input(g.frame)
  update_gui(g.frame)
  update_audio(g.frame)
}

sg_range :: proc {
  sg_range_from_struct,
  sg_range_from_slice,
}

sg_range_from_struct :: proc(s: ^$T) -> sg.Range where intrinsics.type_is_struct(T) {
  return {ptr = s, size = size_of(T)}
}
sg_range_from_slice :: proc(s: []$T) -> sg.Range {
  return {ptr = raw_data(s), size = len(s) * size_of(s[0])}
}

/*
	// NOTE: example for how to draw a line using sokol_gl
	sx := 50 * g.font.dpi_scale
	sy := 50 * g.font.dpi_scale
	d := Vec2{sx, sy}
	line(
		start = Vec2{d.x - 10 * g.font.dpi_scale, d.y},
		end = Vec2{d.x + 100 * g.font.dpi_scale, d.y},
		color = {0, 0, 255, 128},
	)
	*/
/*
line :: proc(start: Vec2, end: Vec2, color: [4]u8) {
	sgl.begin_lines()
	sgl.c4b(color.r, color.g, color.b, color.a)
	sgl.v2f(start.x, start.y)
	sgl.v2f(end.x, end.y)
	sgl.end()
}
	*/

pow :: proc {
  pow_int,
  pow_f32,
}

pow_int :: proc(x, power: int) -> int {
  result := 1
  for _ in 0 ..< power do result *= x
  return result
}

pow_f32 :: proc(x: f32, power: int) -> f32 {
  result := f32(1.0)
  for _ in 0 ..< power do result *= x
  return result
}

move_by_delta :: proc {
  move_by_delta_soa,
  move_by_delta_aos,
}

move_by_delta_soa :: proc(entities: #soa[]Entity, wave: Wave, v: Vec3) {
  new_position := entities[wave.index].hot.position + v
  set_position(entities, wave, new_position)
  set_target(entities, wave, new_position)
}
move_by_delta_aos :: proc(e: ^Entity, v: Vec3) {
  new_position := e.position + v
  set_position(e, new_position)
  set_target(e, new_position)
}

set_position :: proc {
  set_position_soa,
  set_position_aos,
}
set_position_aos :: proc(e: ^Entity, v: Vec3) {
  e.position = v
  e.temp_position = v
}
set_position_soa :: proc(entities: #soa[]Entity, wave: Wave, v: Vec3) {
  entities[wave.index].hot.position = v
  entities[wave.index].hot.temp_position = v
}

set_target :: proc {
  set_target_soa,
  set_target_aos,
}
set_target_aos :: proc(e: ^Entity, v: Vec3) {
  e.target = v
}
set_target_soa :: proc(entities: #soa[]Entity, wave: Wave, v: Vec3) {
  entities[wave.index].cold.target = v
}
//e.target.z += DEPTH_UI // NOTE: camera: x: -left and +right, y: +up and -down, z: +forward/zoomin and -backward/zoomout

fovy := linalg.to_radians(f32(90.0))
fovy_half := fovy / 2
fovy_oppo := linalg.to_radians(f32(90.0)) - fovy_half

// NOTE: hacky but it gets the job done, close enough
BREADTH_UI := (DEPTH_UI * math.sin(fovy_half) / math.sin(fovy_oppo)) - 0.5 // NOTE: a = c * sin(A) / sin(C)
CAMERA_TRAVEL := 2 * BREADTH_UI

ROTATION_SPEED :: 30.0

// NOTE: COORDINATES
// NOTE: left <- -x, +x -> right
// NOTE: up   <- -y, +y -> down
// NOTE: out  <- -z, +z -> in

// TODO: super jank - sometimes does the y-movement and sometimes doesn't
camera_update :: proc(dt: f32) {
  log.debug("trace -> camera_update")
  // NOTE: start at base position, then rotate, then translate
  if g.camera.debug_mode {
    // NOTE: don't reset in debug mode
  } else {
    g.camera.position.x = 0.0
    g.camera.position.z = 0.0
    g.camera.target.x = 0.0
    g.camera.target.z = DEPTH_UI
  }

  // NOTE: compute new states for dependent values
  if spinning {
    g.camera.rotation += linalg.to_radians(ROTATION_SPEED * dt)
  }

  // NOTE: rotate camera around z=DEPTH_UI line
  if !g.camera.debug_mode {
    // TODO: enable this in debug mode, too, but right now it's getting in the way
    g.camera.position.x = linalg.sin(g.camera.rotation) * DEPTH_UI
    g.camera.position.z = (linalg.cos(g.camera.rotation) * DEPTH_UI) + DEPTH_UI
  }

  // NOTE: translate

  // TODO: bring this back once I've got animations again
  //process_animation_list(dt, &g.camera)
}

compute_mvp :: proc(dt: f32, position: Vec3, mm: Mat4, w: f32, h: f32) -> shaders.Quad_Vs_Params {

  p := linalg.matrix4_perspective_f32(fovy, w / h, 0.1, 2 * DEPTH_UI)
  v := linalg.matrix4_look_at_f32(g.camera.temp_position, g.camera.target, Vec3{0.0, 1.0, 0.0}) // NOTE: y == up

  // NOTE: transformations happen right-to-left
  // NOTE: T * R * S --> Scale, then rotate, then translate
  m := linalg.matrix4_translate_f32(position) * mm
  //     linalg.matrix4_rotate_f32(math.to_radians(f32(180)), position)

  vs_params := shaders.Quad_Vs_Params {
    mvp = p * v * m,
  }
  return vs_params
}

load_image :: proc(filename: cstring) -> sg.Image {
  w, h: i32
  pixels := stbi.load(filename, &w, &h, nil, 4)
  assert(pixels != nil)

  image := sg.make_image(
  {
    width        = w,
    height       = h,
    pixel_format = .RGBA8,
    // 4 bytes per pixel
    //data = {mips_levels = {0 = {ptr = pixels, size = uint(w * h * 4)}}},
  },
  )
  stbi.image_free(pixels)

  return image
}

card_quad_verts :: proc() -> [4]Vertex {
  half_h := f32(1.0)
  half_w := f32(8.0)
  return {
    {pos = {-1, 0.5, 0}, uv = {0, 0}, color = {1, 1, 1, 1}}, // TL screen ← TL tex
    {pos = {1, 0.5, 0}, uv = {1, 0}, color = {1, 1, 1, 1}}, // TR
    {pos = {-1, -0.5, 0}, uv = {0, 1}, color = {1, 1, 1, 1}}, // BL
    {pos = {1, -0.5, 0}, uv = {1, 1}, color = {1, 1, 1, 1}}, // BR
  }
}

bool_str :: proc(val: bool) -> string {
  if val do return "true"
  return "false"
}

CARD_SPACING :: 1.2
update_gui :: proc(frame: Frame) {
  dt := frame.dt
  w := frame.screen_width
  h := frame.screen_height

  // NOTE: camera should stay put while all other entities move
  // NOTE: coordinates should be
  // NOTE: - bottom: -1
  // NOTE: - top:     1
  // NOTE: - left:   -1
  // NOTE: - right:   1
  // so translate all entities to their correct spot first

  // translate y-positions to correct world-coordinates
  for index in 1 ..= g.num_waves {
    g.files[index].entity.position.x = 0
    g.files[index].entity.position.y = f32(g.pager.paging_index - index) * CARD_SPACING
    g.files[index].entity.position.z = -DEPTH_UI
    // TODO: any rotations?
    // TODO: any scaling?

    // TODO: actually apply these to the vertices?
  }

  sdtx.set_context(sdtx.default_context())
  sdtx.canvas(w * 0.5, h * 0.5)

  wave := Wave {
    index = g.pager.active_index,
  }

  playing := get_wave(wave)
  cam := &g.camera

  c := convert_to_sokol_rgb(ColorTheme[.DEBUG_TEXT])
  sdtx.font(5)
  sdtx.color4f(c.r, c.g, c.b, c.a)
  sdtx.origin(1, 1)
  sdtx.printf("File:     %s\n", playing.file_path)
  sdtx.printf("duration=%s: idx=%f\n", wav.time_string(playing.time), playing.frame_cursor)
  sdtx.printf("FPS: %f\n", 1 / sapp.frame_duration())
  sdtx.printf("breadth=%f\n", BREADTH_UI)
  sdtx.printf("cam: debug=%s\n", bool_str(g.camera.debug_mode))
  sdtx.printf("cam: position: x=%f y=%f z=%f\n", cam.position.x, cam.position.y, cam.position.z)
  sdtx.printf("cam: target: x=%f y=%f z=%f\n", cam.target.x, cam.target.y, cam.target.z)
  sdtx.printf("cam: rotation=%f spin=%v\n", linalg.to_degrees(g.camera.rotation), spinning)

  // TODO: translate camera_update functionality to apply to the world objects, not the camera
  //camera_update(dt)

  for i in 1 ..= g.num_waves {
    render_text_to_card({index = i}, &g.fonts_state, convert_to_sokol_rgb(ColorTheme[.TEXT]))
  }

  // now that we've rendered to the image on the GPU side, we can update the image
  sg.update_image(
    g.fonts_state.atlas_img,
    sg.Image_Data {
      mip_levels = {
        0 = {ptr = raw_data(g.fonts_state.fons.textureData), size = ATLAS_SIZE * ATLAS_SIZE},
      },
    },
  )
  log.assertf(
    sg.query_image_info(g.fonts_state.atlas_img).slot.state == .VALID,
    "font atlas img state is invalid",
  )

  // NOTE: MAIN PASS
  sg.begin_pass({action = g.pass_action, swapchain = sglue.swapchain()})
  //  sg.begin_pass({action = g.pass_action, swapchain = sglue.swapchain()})
  sg.apply_pipeline(g.quads_state.pipeline)


  for index in 1 ..= g.num_waves {

    verts := card_quad_verts()
    offset := sg.append_buffer(g.quads_state.vertex_buffer, {ptr = &verts, size = size_of(verts)})

    mvp := compute_mvp(dt, g.files[index].entity.position, linalg.MATRIX4F32_IDENTITY, w, h)

    bindings := sg.Bindings {
      vertex_buffers = {0 = g.quads_state.vertex_buffer},
      vertex_buffer_offsets = {0 = offset},
      index_buffer = g.quads_state.index_buffer,
      views = {shaders.VIEW_quad_tex = g.files[index].text.texture_view}, // texture view, not attachment view
      samplers = {shaders.SMP_quad_smp = g.quads_state.sampler},
    }
    sg.apply_bindings(bindings)
    sg.apply_uniforms(
      shaders.UB_Quad_Vs_Params,
      sg.Range{ptr = &mvp, size = size_of(shaders.Quad_Vs_Params)},
    )
    sg.draw(0, 6, 1)
  }

  // Draw debug overlay on top (sdtx uses its own internal pass resources)
  sdtx.draw()
  sg.end_pass()
  sg.commit()
}

render_text_to_card :: proc(wave: Wave, fonts: ^FontState, text_color: sg.Color) {
  // Build vertex buffer from fontstash quads
  verts: [dynamic]TextVertex // TODO: move this to frame allocator?
  defer delete(verts)

  fs.ClearState(&fonts.fons)
  fs.SetFont(&fonts.fons, fonts.font_id)
  fs.SetSize(&fonts.fons, 32.0)
  // color as packed u32 (r,g,b,a bytes) — convert from your f32 color
  packed := [4]u8{u8(text_color.r), u8(text_color.g), u8(text_color.b), u8(text_color.a)}
  fs.SetColor(&fonts.fons, packed)
  fs.SetAlignVertical(&fonts.fons, .MIDDLE)
  fs.SetAlignHorizontal(&fonts.fons, .LEFT)

  quad: fs.Quad
  w := get_wave(wave)
  iter := fs.TextIterInit(&fonts.fons, 8, f32(CARD_H) * 0.5, w.file_name)
  for fs.TextIterNext(&fonts.fons, &iter, &quad) {
    c := [4]f32{text_color.r, text_color.g, text_color.b, text_color.a}
    append(
      &verts,
      TextVertex{{quad.x0, quad.y0}, {quad.s0, quad.t0}, c},
      TextVertex{{quad.x1, quad.y0}, {quad.s1, quad.t0}, c},
      TextVertex{{quad.x0, quad.y1}, {quad.s0, quad.t1}, c},
      TextVertex{{quad.x0, quad.y1}, {quad.s0, quad.t1}, c},
      TextVertex{{quad.x1, quad.y0}, {quad.s1, quad.t0}, c},
      TextVertex{{quad.x1, quad.y1}, {quad.s1, quad.t1}, c},
    )
  }

  if len(verts) == 0 do return

  vbuf_offset := sg.append_buffer(
    fonts.vertex_buffer,
    {ptr = raw_data(verts), size = uint(len(verts) * size_of(TextVertex))},
  )

  // Maps pixel space (0,0)→(CARD_W, CARD_H) into NDC.
  // y is flipped (CARD_H is the second arg) so fontstash's top-left origin matches.
  ortho := linalg.matrix_ortho3d_f32(0, CARD_W, CARD_H, 0, -1, 1)
  vs_params := shaders.Text_Vs_Params {
    mvp = ortho,
  }

  clear_color := convert_to_sokol_rgb(ColorTheme[.SURFACE])

  // Offscreen pass: write into this card's render target
  sg.begin_pass(
    {
      action = {colors = {0 = {load_action = .CLEAR, clear_value = clear_color}}},
      attachments = {
        colors = {0 = g.files[wave.index].text.attach_view},
        // No depth attachment — we're doing 2D text only
      },
    },
  )
  sg.apply_pipeline(fonts.pipeline)

  bindings := sg.Bindings {
    vertex_buffers = {0 = fonts.vertex_buffer},
    vertex_buffer_offsets = {0 = vbuf_offset},
    views = {shaders.VIEW_text_tex = fonts.atlas_view},
    samplers = {shaders.SMP_text_smp = fonts.atlas_sampler},
  }
  sg.apply_bindings(bindings)
  sg.apply_uniforms(shaders.UB_Text_Vs_Params, {ptr = &vs_params, size = size_of(vs_params)})
  //sg.apply_uniforms(shaders.UB_Text_Vs_Params, {ptr = &mvp, size = size_of(mvp)})
  sg.draw(0, len(verts), 1)
  sg.end_pass()
}

g_intermediary := false

AnimationKind :: enum {
  None = 0,
  Constant_Acceleration,
  Non_Constant_Acceleration,
  Linear,
  // TODO: for now just lerp, no other animation kinds
}

Animation_Step :: struct {
  kind:         AnimationKind,
  cancelled:    bool,
  duration:     f32, // NOTE: seconds, eg. 1.5
  progress:     f32, // NOTE: 0.0 <= progress <= 1.0
  max_progress: f32, // NOTE: unset (eg. 0.0) maps to 1.0, but a way to do partial animations
  target:       Vec3, // NOTE: abs pos
  a:            Vec3,
  _v0:          Vec3,
}

Animation :: struct {
  progress: f32,
  steps:    #soa[MAX_SECTIONS_PER_ANIMATION]Animation_Step,
}

animation_update :: proc(dt: f32, anime: Animation_Step, pos0: Vec3) -> Vec3 {

  #partial switch anime.kind {
  case .Constant_Acceleration:
    // NOTE: enable passing in custom acceleration but manually set the initial velocity

    v0 := (anime.target - pos0 - (anime.a * pow(anime.duration, 2)) / 2.0) / anime.duration

    t := anime.progress * anime.duration
    return pos0 + v0 * t + (anime.a * pow(anime.duration, 2)) / 2.0
  /*
	case .Non_Constant_Acceleration:
		return linalg.lerp(pos0, anime.target, anime.progress)
	case .Linear:
		return linalg.lerp(pos0, anime.target, anime.progress)
	case:
		return linalg.lerp(pos0, anime.target, anime.progress)
		*/
  }
  return Vec3{}
}

process_animation_list :: proc(dt: f32, wave: Wave) {

  still_processing := false
  pos := g.files[wave.index].entity.position

  // TODO: use range iteration when the animation queue memory issues are figured out
  for queue_index in 0 ..< MAX_ANIMATIONS_PER_ENTITY {
    for index in 0 ..< MAX_SECTIONS_PER_ANIMATION {
      log.assertf(
        g.files[wave.index].entity.animes[queue_index].steps[index].kind == .Constant_Acceleration,
        "g.files[wave.index] animation has invalid memory %v",
        g.files[wave.index].entity.animes[queue_index].steps[index].kind,
      )
      log.debugf("using %v", g.files[wave.index].entity.animes[queue_index].steps[index].kind)

      if g.files[wave.index].entity.animes[queue_index].steps[index].cancelled do continue

      if g.files[wave.index].entity.animes[queue_index].steps[index].progress <
         g.files[wave.index].entity.animes[queue_index].steps[index].max_progress {
        percent_complete :=
          dt / g.files[wave.index].entity.animes[queue_index].steps[index].duration
        g.files[wave.index].entity.animes[queue_index].steps[index].progress += percent_complete
        // NOTE: still report out the final calculated position even when the animation is complete
      }

      pos = animation_update(dt, g.files[wave.index].entity.animes[queue_index].steps[index], pos)

      if g.files[wave.index].entity.animes[queue_index].steps[index].progress >= g.files[wave.index].entity.animes[queue_index].steps[index].max_progress do continue

      still_processing = true
      break
    }
  }

  if still_processing {
    g.files[wave.index].entity.temp_position = pos
    g.files[wave.index].entity.target = pos
    g.files[wave.index].entity.target = Vec3{0.0, pos.y, DEPTH_UI}
    return
  }

  log.assert(false, "not processing for some reason")
  g.files[wave.index].entity.position = pos // NOTE: finalize the changes
  g.files[wave.index].entity.temp_position = g.files[wave.index].entity.position
  g.files[wave.index].entity.target = g.files[wave.index].entity.position
  g.files[wave.index].entity.target = Vec3{0.0, g.files[wave.index].entity.position.y, DEPTH_UI}
  reset_animations(wave)
  return
}

reset_animations :: proc(wave: Wave) {
  // zero-is-initialization
  for anime in 0 ..< MAX_ANIMATIONS_PER_ENTITY {
    for step in 0 ..< MAX_SECTIONS_PER_ANIMATION {
      g.files[wave.index].entity.animes[anime].steps[step].kind = .None
      g.files[wave.index].entity.animes[anime].steps[step].duration = 0
      g.files[wave.index].entity.animes[anime].steps[step].max_progress = 0
      g.files[wave.index].entity.animes[anime].steps[step].progress = 0
      g.files[wave.index].entity.animes[anime].steps[step].target = 0
      g.files[wave.index].entity.animes[anime].steps[step]._v0 = 0
      g.files[wave.index].entity.animes[anime].steps[step].a = 0
      g.files[wave.index].entity.animes[anime].steps[step].cancelled = false
    }
  }
}

Animation_Lookup :: struct {
  entity: int,
  anime:  int,
}

push_animation_step :: proc(lookup: Animation_Lookup, step: Animation_Step) {
  if lookup.anime > MAX_ANIMATIONS_PER_ENTITY - 1 {
    return // NOTE: too many animations, ignore
  }

  for s in 0 ..< MAX_SECTIONS_PER_ANIMATION {
    if g.files[lookup.entity].entity.animes[lookup.anime].steps[s].kind == .None {
      g.files[lookup.entity].entity.animes[lookup.anime].steps[s] = step
      return
    }
  }

  // if we didn't find an open slot, ignore
}

set_animation_step_at_index :: proc(
  entity_index: int,
  animation_index: int,
  step: Animation_Step,
  step_index: int,
) -> (
  next_step_index: int,
  success: bool,
) {
  if animation_index > MAX_ANIMATIONS_PER_ENTITY - 1 do return MAX_SECTIONS_PER_ANIMATION, false // NOTE: too many animations, ignore
  if step_index > MAX_SECTIONS_PER_ANIMATION - 1 do return MAX_SECTIONS_PER_ANIMATION, false // NOTE: too many animations, ignore

  for s in 0 ..< MAX_SECTIONS_PER_ANIMATION {
    if g.files[entity_index].entity.animes[animation_index].steps[s].kind == .None {
      return s, true
    }
  }
  return step_index, false
}

animate_move :: proc(
  wave: Wave,
  e_index: int,
  prev_index: int = 0,
  new_index: int = 1,
  y_travel: f32 = CAMERA_TRAVEL,
) {

  if g.disable_animations {
    delta := Vec3{0.0, -(y_travel * f32(new_index - prev_index)), 0.0}
    move_by_delta(&g.camera, delta)
  } else {
    target := Vec3{0.0, -(CAMERA_TRAVEL * f32(new_index)), 0.0}
    // x = vt + ((at^2) / 2)
    // a = ((x - vt) * 2) / t^2

    // s=x0+v0t+12at2, v=v0+at

    // TODO: not animating camera (yet), so mostly pass an index to an entity
    reset_animations(wave)
    push_animation_step(
      {entity = wave.index, anime = 0},
      {
        // NOTE: jump in the air and end at high-point
        kind         = .Constant_Acceleration,
        target       = target,
        a            = Vec3{0.0, 0.0, -GRAVITY},
        duration     = 0.4,
        max_progress = 0.5,
      },
    )
    push_animation_step(
      {entity = wave.index, anime = 0},
      {
        // NOTE: fall from high-point at higher initial-velocity
        kind     = .Constant_Acceleration,
        target   = target,
        a        = Vec3{0.0, 0.0, -GRAVITY},
        duration = 0.1,
      },
    )

  }


  // TODO: ideas for animating index movement
  // - animations disabled: important!
  // - zoom out and zoom back in on the index you're trying to look at
  // - accelerate then deccelerate
  // - swirl around the list, camera kept pointing at the list as it rotates around it and moves up / down
  // - think of more!

  // NOTE: for now, we just move up and down
  //_add_camera_position(Vec3{0, CAMERA_TRAVEL * f32(g.index - prev_index), 0})
}

spinning := false

spin_reset :: proc() {
  g.camera.rotation = linalg.to_radians(f32(180.0))
}

GRAVITY: f32 = 9.8
JUMP_VELOCITY: f32 = 40.0
JUMP_ACCELERATION: f32 = 45.0

in_air := false

process_user_input :: proc(frame: Frame) {
  dt := frame.dt
  playing := get_wave(g.playing)

  // NOTE: generally, the goal is to make this intuitive to use for someone familiar with VIM motions

  // TODO: switch statement instead ??

  if key_down[.PERIOD] {
    set_position(&g.camera, Vec3{0, 0, 0})
    spinning = false
    spin_reset()
    //reset_animations(&g.camera)
  }

  // TODO: rework paging
  // TODO: vim motions for yanking / pasting / deleting / etc...
  // TODO: buffers for storing audio and pasting later
  // TODO: macros to store motions and replay them (won't work exactly the same as vim macros since the buffers fundementally will store different info: audio vs key-strokes)
  // TODO:  - different buffer sets? audio buffers range and text buffer range?

  if key_down[.BACKSPACE] {
    // TODO: here for debugging, can remove later
    move_by_delta(&g.camera, Vec3{0, 0, -1})
  }
  if key_down[.DELETE] {
    // TODO: here for debugging, can remove later
    move_by_delta(&g.camera, Vec3{0, 0, 1})
  }
  if key_down[.DOWN] {
    // TODO: here for debugging, can remove later
    move_by_delta(&g.camera, Vec3{0, -.1, 0})
  }
  if key_down[.UP] {
    // TODO: here for debugging, can remove later
    move_by_delta(&g.camera, Vec3{0, .1, 0})
  }
  if key_down[.LEFT] {
    // TODO: here for debugging, can remove later
    move_by_delta(&g.camera, Vec3{-.1, 0, 0})
  }
  if key_down[.RIGHT] {
    // TODO: here for debugging, can remove later
    move_by_delta(&g.camera, Vec3{.1, 0, 0})
  }
  if key_down[.Z] {
    // TODO: here for debugging, can remove later
    g.camera.debug_mode = !g.camera.debug_mode
    key_down[.Z] = false // NOTE: manually disable it so it doesn't keep cutting
  }
  if key_down[.Q] {
    spinning = !spinning
    key_down[.Q] = false // NOTE: manually disable it so it doesn't keep cutting
  }

  if key_down[._0] {
    wav.start_over(playing)
    key_down[._0] = false // NOTE: manually disable it so it doesn't keep cutting
  }

  if key_down[.U] {
    // TODO: undo 😱
    key_down[.U] = false // NOTE: manually disable it so it doesn't keep cutting
  }
  if (key_down[.LEFT_CONTROL] || key_down[.RIGHT_CONTROL]) && key_down[.R] {
    // TODO: redo 😱
    key_down[.LEFT_CONTROL] = false // NOTE: manually disable it so it doesn't keep cutting
    key_down[.RIGHT_CONTROL] = false // NOTE: manually disable it so it doesn't keep cutting
    key_down[.R] = false // NOTE: manually disable it so it doesn't keep cutting
  }

  // NOTE: $ vim motion
  if (key_down[.LEFT_SHIFT] || key_down[.RIGHT_SHIFT]) && key_down[._4] {
    // NOTE: glfw doesn't support the literal '$' key code apparently. I have my $ on shift+0 with firmware remapping, but glfw doesn't care about that
    wav.go_to_end(playing)

    key_down[.LEFT_SHIFT] = false // NOTE: manually disable it so it doesn't keep cutting
    key_down[.RIGHT_SHIFT] = false // NOTE: manually disable it so it doesn't keep cutting
    key_down[._4] = false // NOTE: manually disable it so it doesn't keep cutting
  }

  // TODO: Ctrl + d and Ctrl + u for jumping multiple up and down: hard-code / calculate correct number to jump

  if (key_down[.LEFT_SHIFT] || key_down[.RIGHT_SHIFT]) && key_down[.G] {
    prev_index, new_index := pager.last(&g.pager)
    key_down[.LEFT_SHIFT] = false // NOTE: manually disable it so it doesn't keep cutting
    key_down[.RIGHT_SHIFT] = false // NOTE: manually disable it so it doesn't keep cutting
    key_down[.G] = false // NOTE: manually disable it so it doesn't keep cutting
  }

  if key_down[.G] {
    if g_intermediary {
      prev_index, new_index := pager.first(&g.pager)
      g_intermediary = false
    } else {
      g_intermediary = true
    }

    key_down[.G] = false // NOTE: manually disable it so it doesn't keep cutting
  }

  // NOTE: directional menu navigation
  if key_down[.K] {
    pager.prev(&g.pager)
    key_down[.K] = false // NOTE: manually disable it so it doesn't keep cutting
  }
  if key_down[.J] {
    pager.next(&g.pager)
    key_down[.J] = false // NOTE: manually disable it so it doesn't keep cutting
  }

  // NOTE: pause or re-start playing
  if key_down[.SPACE] {
    wav.toggle_playing(playing)
    if playing.is_playing {
      g.playing_state = .PLAYING
    } else {
      g.playing_state = .PAUSED
    }
    key_down[.SPACE] = false // NOTE: manually disable it so it doesn't keep cutting
  }

  // NOTE: select track
  if key_down[.ENTER] || key_down[.LEFT_ALT] {
    // TODO: LEFT_ALT because my keyboard is sending LEFT_ALT for enter... ?
    if g.playing_state == .OFFLINE || g.pager.paging_index != g.pager.active_index {
      // NOTE: switching song, unload all other wav files
      // TODO: sa.shutdown on all?

      prev, play_index := pager.select(&g.pager)
      play_audio({index = play_index})
    }
    key_down[.ENTER] = false // NOTE: manually disable it so it doesn't keep cutting
    key_down[.LEFT_ALT] = false // NOTE: manually disable it so it doesn't keep cutting
  }

  // TODO: change 'e' to go to end of next 'word' or section of higher gain
  if key_down[.E] {
    if playing.num_samples >= playing.frequency {
      //playing.samples_raw = playing.samples_raw[:playing.sample_index] // TODO: is this right??
      wav.scan_forward(playing)
      log.debugf("E: samples: %d", playing.num_samples)
      key_down[.E] = false // NOTE: manually disable it so it doesn't keep cutting
    }
  }
  // TODO: change 'b' to go to beginning of prev 'word' or section of higher gain
  if key_down[.B] {
    wav.scan_backward(playing)
    log.debugf("B: samples: %d", playing.num_samples)
    key_down[.B] = false // NOTE: manually disable it so it doesn't keep cutting
  }
  // TODO: change 'w' to go to beginning of next 'word' or section of higher gain

  // NOTE: scan through song
  if key_down[.H] {
    wav.scan_backward(playing)
    key_down[.H] = false // NOTE: manually disable it so it doesn't keep cutting
  }
  if key_down[.L] {
    wav.scan_forward(playing)
    key_down[.L] = false // NOTE: manually disable it so it doesn't keep cutting
  }
}

// TODO: this slow. we don't need it to be fast (yet). but we're getting < 60fps and this is most likely the cause. For this app, we don't need more than 30fps (probably). But I'd like to get it >60fps, >120fps if possible
update_audio :: proc(frame: Frame) {
  dt := frame.dt
  playing := get_wave(g.playing)

  if g.playing_state != .PLAYING do return
  log.assertf(
    playing.is_playing,
    "did not update playing wave file state to match g.playing_state mode",
  )

  num_frames := int(sa.expect())
  if num_frames == 0 do return

  out_rate := f64(sa.sample_rate())
  out_channels := int(sa.channels())
  in_rate := f64(playing.frequency)
  in_channels := int(playing.channels)

  // How many input frames we consume per output frame
  step := in_rate / out_rate

  // Total *frames* (not samples) in the source
  total_in_frames := wav.total_frames(playing)
  if total_in_frames < 2 do return // need at least 2 frames to interpolate

  samples_needed := num_frames * out_channels

  @(static) scratch: [dynamic]f32
  resize(&scratch, samples_needed)

  for out_frame in 0 ..< num_frames {
    // Loop back to start if we ran off the end
    if playing.frame_cursor >= f64(total_in_frames) {
      playing.frame_cursor -= f64(total_in_frames)
    }

    src := playing.frame_cursor
    base := int(src)
    next := base + 1
    if next >= int(total_in_frames) do next = base // clamp at EOF, avoid OOB
    frac := f32(src - f64(base))

    base_off := base * in_channels
    next_off := next * in_channels

    for out_ch in 0 ..< out_channels {
      // mono → duplicate to all output channels; stereo → pass through;
      // surround → take the first 2 (since out_channels is usually 2)
      in_ch := out_ch
      if in_ch >= in_channels do in_ch = in_channels - 1

      a := playing.samples_raw[base_off + in_ch]
      b := playing.samples_raw[next_off + in_ch]
      scratch[out_frame * out_channels + out_ch] = a + (b - a) * frac
    }

    playing.frame_cursor += step
  }

  sa.push(raw_data(scratch), num_frames)
}

key_down: #sparse[sapp.Keycode]bool

event :: proc "c" (ev: ^sapp.Event) {
  context = default_context

  #partial switch ev.type {
  case .KEY_DOWN: key_down[ev.key_code] = true
  case .KEY_UP: key_down[ev.key_code] = false
  case .MOUSE_DOWN:
  case .MOUSE_UP:
  case .MOUSE_ENTER:
  case .MOUSE_SCROLL:
  case .MOUSE_LEAVE:
  case .MOUSE_MOVE:
  }

}

cleanup :: proc "c" () {
  context = default_context
  // TODO: cleanup or no? it's already cleaned up by the OS on process close, right?
  /*
	sdtx.shutdown()
	sa.shutdown()
	sg.shutdown()
	*/
}

ProcessInput :: struct {
  audio_dir: string,
}

process_input: ^ProcessInput

main :: proc() {
  context.logger = log.create_console_logger()
  default_context = context

  // TODO: setup tracking allocator in debug mode

  process_input = new(ProcessInput)

  // NOTE: default to current working directory
  if len(os.args) == 1 do process_input.audio_dir = "."
  else {
    process_input.audio_dir = os.args[1]
    log.assertf(process_input.audio_dir != "", "bad input: must provide <wav-file-directory> as first positional argument")
  }

  sapp.run(
    {
      init_cb = init,
      frame_cb = frame,
      event_cb = event,
      cleanup_cb = cleanup,
      sample_count = 4,
      width = 1920,
      height = 1080,
      window_title = "beach",
      icon = {sokol_default = true},
      logger = {func = slog.func},
    },
  )
}

