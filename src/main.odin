package beach

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/fixed"
import "core:math/linalg"
import "core:os"
import "core:strings"
import "core:time"
import sapp "shared:sokol/app"
import sa "shared:sokol/audio"
import sg "shared:sokol/gfx"
import sgl "shared:sokol/gl"
import sglue "shared:sokol/glue"
//import sgp "shared:sokol/gp"
import "./assertprefix"
import "./audio/wav"
import "./shaders"
import slog "shared:sokol/log"
import fontstash "vendor:fontstash"
import stbi "vendor:stb/image"

default_context: runtime.Context

Vec2 :: [2]f32
Vec3 :: [3]f32
Vec4 :: [4]f32

Mat3 :: matrix[3, 3]f32
Mat4 :: matrix[4, 4]f32

Vertex :: struct {
	pos:   Vec3,
	color: sg.Color,
	uv:    Vec2,
}

GuiElement :: enum {
	FILE_ENTRY,
}

Entity :: struct {
	kind:     GuiElement,
	pos:      Vec3,
	rot:      Vec3,
	target:   Vec3,
	look:     Vec2,
	geometry: []Vec3,
}

VertexMeta :: struct {
	vertex_buffer_offset: i32,
	index_buffer_offset:  i32,
	draw_vertices:        int,
}

Graphics :: struct {
	vertices:    []Vertex,
	pipeline:    sg.Pipeline,
	bindings:    sg.Bindings,
	pass_action: sg.Pass_Action,
	camera:      Entity,
	entities:    [dynamic]Entity,
	entity_meta: [GuiElement]VertexMeta,
	palette:     [NUM_FONTS]Color,
}

Font :: struct {
	id:        int,
	ctx:       fontstash.FontContext,
	dpi_scale: f32,
}

Globals :: struct {
	waves:         [dynamic]wav.Contents,
	playing:       ^wav.Contents,
	playing_index: int,
	index:         int,
	gui:           Graphics,
	font:          Font,
}
g: ^Globals

play_audio :: proc() {
	if g.playing != nil do sa.shutdown()

	sa.setup({logger = {func = slog.func}})
	log.assertf(sa.isvalid(), "%s sokol audio setup is not valid", assertprefix.FAIL)

	g.playing_index = g.index
	g.playing = &g.waves[g.playing_index]

	g.playing.sample_idx = 0
	g.playing.is_playing = true

	log.debugf(
		"%s %03d/%03d recordings  %dhz  %s  %10d samples  %d channels  %02dbit sample size  %s format  %s",
		assertprefix.PLAY,
		g.playing_index + 1,
		len(g.waves),
		g.playing.frequency,
		wav.time_string(g.playing.time),
		len(g.playing.samples_raw),
		g.playing.channels,
		g.playing.format.bits_per_sample,
		wav.which_format(g.playing.format.audio_format),
		g.playing.file_path,
	)
}


init :: proc "c" () {
	context = default_context

	g = new(Globals)
	load_dir(process_input.audio_dir)
	init_gui()
	play_audio()
}

FileEntry :: struct {
	label:        string,
	wav_index:    int,
	using entity: Entity,
}

make_file_entry :: proc(wav_index: int) -> FileEntry {
	return {
		kind = .FILE_ENTRY,
		label = g.waves[wav_index].file_path,
		wav_index = wav_index,
		pos = Vec3{0, f32(wav_index), 0},
		rot = Vec3{0, 0, 0},
	}
}

load_dir :: proc(dir: string) {
	fd, err := os.open(dir)
	log.assertf(err == nil, "open dir: %s: %v", dir, err)

	entries, read_err := os.read_dir(fd, 1000)
	log.assertf(read_err == nil, "read dir: %s: %v", dir, read_err)

	num_entries := len(entries)

	if len(g.waves) != 0 do delete(g.waves)
	g.waves = {}

	index := 0
	for e in entries {
		if e.is_dir do continue
		if !strings.contains(e.name, ".wav") do continue

		append(&g.waves, wav.Contents{file_path = e.fullpath})
		wav.read_from_file(e.fullpath, &g.waves[index])
		errs, valid := wav.validate_contents(g.waves[index])
		if !valid {
			delete(g.waves[index].samples_raw)
			log.infof("invalid wav file: %s", e.fullpath)
			continue // NOTE: continue so the next entry can stay at this index

			// TODO: gracefully handle errors in the wav file, but keep the program running
			// NOTE: for now, assert and crash
			//log.assertf(errs.sokol == "", errs.sokol)
			//log.assertf(errs.frequency == "", errs.frequency)
			//log.assertf(errs.channels == "", errs.channels)
		}

		append(&g.gui.entities, make_file_entry(index))

		index += 1
	}
}

frame :: proc "c" () {
	context = default_context

	dt := f32(sapp.frame_duration())

	process_user_input(dt)
	update_gui(dt)
	update_audio(dt)
}

Bindable :: struct {
	vertices:    []Vertex,
	bind:        sg.Bindings,
	pipeline:    sg.Pipeline,
	pass_action: sg.Pass_Action,
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

FONT_KC854 :: 0
FONT_C64 :: 1
FONT_ORIC :: 2
NUM_FONTS :: 3

Color :: struct {
	r, g, b: u8,
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


pow :: proc(x, power: int) -> int {
	result := 1
	for _ in 0 ..< power do result *= x
	return result
}

init_gui :: proc() {
	g.font.dpi_scale = sapp.dpi_scale()

	sg.setup({environment = sglue.environment(), logger = {func = slog.func}})
	log.assert(sg.isvalid(), "sokol graphics setup is not valid")

	sgl.setup({logger = {func = slog.func}})

	atlas_dim := pow(100 * int(g.font.dpi_scale), 2)
	log.assertf(atlas_dim > 0, "atlas_dim <= 0: %d", atlas_dim)
	//log.assertf(atlas_dim == 262144, "unexpected atlas_dim: %d", atlas_dim)
	log.assertf(atlas_dim == 10000, "unexpected atlas_dim: %d", atlas_dim)
	fontstash.Init(&g.font.ctx, atlas_dim, atlas_dim, .TOPLEFT)
	g.font.id = fontstash.AddFont(
		&g.font.ctx,
		"calligraphic",
		"assets/fonts/DuctusCalligraphic.ttf",
	)

	sapp.show_mouse(false)
	sapp.lock_mouse(true)

	g.gui.camera = {
		pos    = {0, 0, 2},
		target = {0, 0, 1},
	}

	WHITE :: sg.Color{1, 1, 1, 1}
	RED :: sg.Color{1, 0, 0, 1}
	BLUE :: sg.Color{0, 0, 1, 1}
	PURP :: sg.Color{1, 0, 1, 1}
	
	// odinfmt: disable
	indices := []u16 {
		// file entry
		0, 1, 2, 2, 1, 3,
	}
	g.gui.vertices = []Vertex {
		// file entry
		{pos = {-0.5, -0.5, 0.0}, color = WHITE, uv = {0, 0}},
		{pos = {0.5, -0.5, 0.0}, color = RED, uv = {1, 0}},
		{pos = {-0.5, 0.5, 0.0}, color = BLUE, uv = {0, 1}},
		{pos = {0.5, 0.5, 0.0}, color = PURP, uv = {1, 1}},
	}
	// odinfmt: enable
	g.gui.entity_meta[.FILE_ENTRY] = VertexMeta {
		vertex_buffer_offset = 0 * size_of(Vertex),
		index_buffer_offset  = 0 * size_of(u16),
		draw_vertices        = 6,
	}

	g.gui.bindings.vertex_buffers[0] = sg.make_buffer({data = sg_range(g.gui.vertices)})

	g.gui.bindings.index_buffer = sg.make_buffer(
		{usage = {index_buffer = true}, data = sg_range(indices)},
	)

	// create a shader and pipeline object (default render states are fine for triangle)
	g.gui.pipeline = sg.make_pipeline(
		{
			shader = sg.make_shader(shaders.triangle_shader_desc(sg.query_backend())),
			index_type = .UINT16,
			layout = {
				attrs = {
					shaders.ATTR_triangle_position = {format = .FLOAT2},
					shaders.ATTR_triangle_color0 = {format = .FLOAT3},
				},
			},
		},
	)

	// a pass action to clear framebuffer to black
	g.gui.pass_action = {
		colors = {0 = {load_action = .CLEAR, clear_value = {r = 0.4, g = 0.2, b = 0.7, a = 1}}},
	}
	
	//odinfmt: disable
	g.gui.palette = {
			{ 0xf4, 0x43, 0x36 },
			{ 0x21, 0x96, 0xf3 },
			{ 0x4c, 0xaf, 0x50 },
	}
	//odinfmt: enable

}

update_gui :: proc(dt: f32) {

	sg.begin_pass({action = g.gui.pass_action, swapchain = sglue.swapchain()})
	sg.apply_pipeline(g.gui.pipeline)
	binding := g.gui.bindings


	// NOTE: loop through entities
	for entity in g.gui.entities {
		switch entity.kind {
		case .FILE_ENTRY:
			m :=
				linalg.matrix4_translate_f32(entity.pos) *
				linalg.matrix4_from_yaw_pitch_roll_f32(
					linalg.to_radians(entity.rot.y),
					linalg.to_radians(entity.rot.x),
					linalg.to_radians(entity.rot.z),
				) *
				linalg.matrix4_rotate_f32(linalg.to_radians(f32(180)), {1, 0, 0})

			meta := g.gui.entity_meta[.FILE_ENTRY]
			log.assertf(meta.draw_vertices > 0, "g.gui.entity_meta[.FILE_ENTRY] does not exist")

			binding.vertex_buffer_offsets[0] = meta.vertex_buffer_offset
			binding.index_buffer_offset = meta.index_buffer_offset
			sg.apply_bindings(binding)
			sg.draw(0, meta.draw_vertices, 1)
		}
	}

	sgl.draw()
	sg.end_pass()
	sg.commit()
}

_in_bounds :: proc() {
	if g.playing_index < 0 do g.playing_index = 0
	if g.playing_index >= len(g.waves) do g.playing_index = len(g.waves) - 1

	if g.index < 0 do g.index = 0
	if g.index >= len(g.waves) do g.index = len(g.waves) - 1
}

g_intermediary := false

process_user_input :: proc(dt: f32) {
	if (key_down[.LEFT_SHIFT] || key_down[.RIGHT_SHIFT]) && key_down[.G] {
		g.index = len(g.waves)
		_in_bounds()
		key_down[.LEFT_SHIFT] = false // NOTE: manually disable it so it doesn't keep cutting
		key_down[.RIGHT_SHIFT] = false // NOTE: manually disable it so it doesn't keep cutting
		key_down[.G] = false // NOTE: manually disable it so it doesn't keep cutting
	}

	if key_down[.G] {
		if g_intermediary {
			g_intermediary = false
			g.index = 0
			_in_bounds()
		} else {
			g_intermediary = true
		}

		key_down[.G] = false // NOTE: manually disable it so it doesn't keep cutting
	}

	// NOTE: directional menu navigation
	if key_down[.K] {
		g.index -= 1
		_in_bounds()
		key_down[.K] = false // NOTE: manually disable it so it doesn't keep cutting
	}
	if key_down[.J] {
		g.index += 1
		_in_bounds()
		key_down[.J] = false // NOTE: manually disable it so it doesn't keep cutting
	}

	// NOTE: pause or re-start playing
	if key_down[.SPACE] {
		g.waves[g.index].is_playing = !g.waves[g.index].is_playing
		key_down[.SPACE] = false // NOTE: manually disable it so it doesn't keep cutting
	}

	// NOTE: select track
	if key_down[.ENTER] {
		if g.playing == nil || g.index != g.playing_index {
			// NOTE: switching song, unload all other wav files
			// TODO: sa.shutdown on all?
			play_audio()
		}
		key_down[.ENTER] = false // NOTE: manually disable it so it doesn't keep cutting
	}

	if key_down[.E] {
		if len(g.playing.samples_raw) >= 44100 {
			g.playing.samples_raw = g.playing.samples_raw[:g.playing.sample_idx]
			g.playing.sample_idx -= 44100
			if g.playing.sample_idx < 0 do g.playing.sample_idx = 0
			log.debugf("E: samples: %d", len(g.playing.samples_raw))
			key_down[.E] = false // NOTE: manually disable it so it doesn't keep cutting
		}
	}
	if key_down[.B] {
		if len(g.playing.samples_raw) >= 44100 {
			g.playing.samples_raw = g.playing.samples_raw[g.playing.sample_idx:]
			g.playing.sample_idx = 0
			log.debugf("B: samples: %d", len(g.playing.samples_raw))
			key_down[.B] = false // NOTE: manually disable it so it doesn't keep cutting
		}
	}

	// NOTE: scan through song
	if key_down[.H] {
		g.playing.sample_idx -= (44100 * 2)
		if g.playing.sample_idx < 0 do g.playing.sample_idx = 0
		key_down[.H] = false // NOTE: manually disable it so it doesn't keep cutting
	}
	if key_down[.L] {
		g.playing.sample_idx += (44100 * 2)
		if g.playing.sample_idx > len(g.playing.samples_raw) do g.playing.sample_idx = len(g.playing.samples_raw) - 40000
		key_down[.L] = false // NOTE: manually disable it so it doesn't keep cutting
	}

}

update_audio :: proc(dt: f32) {
	if g.playing == nil do return
	if !g.playing.is_playing do return

	num_frames := int(sa.expect())
	if num_frames > 0 {
		buf := make([]f32, num_frames)
		frame_loop: for frame in 0 ..< num_frames {
			log.assertf(
				g.playing.channels != 0,
				"wav pointers are invalid: channels %d",
				g.playing.channels,
			)

			for channel in 0 ..< g.playing.channels {
				if g.playing.sample_idx >= len(g.playing.samples_raw) {
					g.playing.sample_idx = 0 // NOTE: loop back to beginning
				}

				buf[frame] += g.playing.samples_raw[g.playing.sample_idx]
				g.playing.sample_idx += 1
			}
		}

		sa.push(&buf[0], num_frames)
		// TODO: delete the buffer?
	}
}

key_down: #sparse[sapp.Keycode]bool

event :: proc "c" (ev: ^sapp.Event) {
	context = default_context

	#partial switch ev.type {
	case .KEY_DOWN:
		key_down[ev.key_code] = true
	case .KEY_UP:
		key_down[ev.key_code] = false
	}

}

cleanup :: proc "c" () {
	context = default_context
	fontstash.Destroy(&g.font.ctx)
	sa.shutdown()
	sg.shutdown()
}

ProcessInput :: struct {
	audio_dir: string,
}

process_input: ^ProcessInput

main :: proc() {
	context.logger = log.create_console_logger()
	default_context = context

	process_input = new(ProcessInput)

	process_input.audio_dir = os.args[1]
	log.assertf(
		process_input.audio_dir != "",
		"bad input: must provide <wav-file-directory> as first positional argument",
	)

	sapp.run(
		{
			init_cb = init,
			frame_cb = frame,
			event_cb = event,
			cleanup_cb = cleanup,
			width = 1920,
			height = 1080,
			window_title = "triangle",
			icon = {sokol_default = true},
			logger = {func = slog.func},
		},
	)
}
