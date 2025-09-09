package beach

import "./assertprefix"
import "./audio/wav"
import "./shaders"
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
import sdebugtext "shared:sokol/debugtext"
import sg "shared:sokol/gfx"
import sgl "shared:sokol/gl"
import sglue "shared:sokol/glue"
import slog "shared:sokol/log"
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

Globals :: struct {
	waves:           [dynamic]wav.Contents,
	entities:        [dynamic]Entity,
	playing:         ^wav.Contents,
	playing_index:   int,
	index:           int,
	image:           sg.Image,
	vertices:        []Vertex,
	pipeline:        sg.Pipeline,
	bindings:        sg.Bindings,
	pass_action:     sg.Pass_Action,
	sampler:         sg.Sampler,
	debugtext_ctx:   sdebugtext.Context,
	debugtext_image: sg.Image,
	debugtext_pass:  sg.Pass,
}
g: ^Globals

convert_to_sokol_rgb :: proc(color: sg.Color) -> sg.Color {
	return sg.Color{r = color.r / 255, g = color.g / 255, b = color.b / 255, a = color.a / 255}
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

		append(&g.entities, make_file_entry(index))

		index += 1
	}
}

init :: proc "c" () {
	context = default_context

	g = new(Globals)
	load_dir(process_input.audio_dir)
	init_gui()
	g.image = load_image("./assets/senjou-starry.png")
	play_audio()
}

frame :: proc "c" () {
	context = default_context

	dt := f32(sapp.frame_duration())

	process_user_input(dt)
	update_gui(dt)
	update_audio(dt)
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


pow :: proc(x, power: int) -> int {
	result := 1
	for _ in 0 ..< power do result *= x
	return result
}

init_gui :: proc() {


	sg.setup({environment = sglue.environment(), logger = {func = slog.func}})
	log.assert(sg.isvalid(), "sokol graphics setup is not valid")

	sdebugtext.setup(
		{
			fonts = {
				sdebugtext.font_kc853(),
				sdebugtext.font_kc854(),
				sdebugtext.font_z1013(),
				sdebugtext.font_cpc(),
				sdebugtext.font_c64(),
				sdebugtext.font_oric(),
				sdebugtext.font_oric(), // TODO: ???
				sdebugtext.font_oric(), // TODO: ???
			},
			logger = {func = slog.func},
		},
	)

	sgl.setup({logger = {func = slog.func}})

	sapp.show_mouse(false)
	sapp.lock_mouse(true)

	_color := convert_to_sokol_rgb(ColorTheme[.OVERLAY])

	// a vertex buffer with 3 vertices
	g.vertices = []Vertex {
		{pos = {-6.0, -1.0, 0.0}, color = _color, uv = {0, 0}},
		{pos = {6.0, -1.0, 0.0}, color = _color, uv = {1, 0}},
		{pos = {-6.0, 1.0, 0.0}, color = _color, uv = {0, 1}},
		{pos = {6.0, 1.0, 0.0}, color = _color, uv = {1, 1}},
	}

	g.bindings.vertex_buffers[0] = sg.make_buffer({data = sg_range(g.vertices)})
	
	// odinfmt: disable
	indices := []u16 {
		0, 1, 2,
		2, 1, 3,
	}
	// odinfmt: enable
	g.bindings.index_buffer = sg.make_buffer(
		{usage = {index_buffer = true}, data = sg_range(indices)},
	)

	g.bindings.images = {
		shaders.IMG_tex = g.image, // TODO: make this a texture option somehow?
	}

	g.sampler = sg.make_sampler({})
	g.bindings.samplers = {
		shaders.SMP_smp = g.sampler,
	}

	// create a shader and pipeline object (default render states are fine for triangle)
	g.pipeline = sg.make_pipeline(
		{
			shader = sg.make_shader(shaders.triangle_shader_desc(sg.query_backend())),
			index_type = .UINT16,
			depth = {
				write_enabled = true, // always write to depth buffer
				compare       = .LESS_EQUAL, // don't render objects behind objects in view
			},
			layout = {
				attrs = {
					shaders.ATTR_triangle_position = {format = .FLOAT3},
					shaders.ATTR_triangle_color0 = {format = .FLOAT4},
					shaders.ATTR_triangle_uv = {format = .FLOAT2},
				},
			},
		},
	)

	// a pass action to clear framebuffer to black
	g.pass_action = {
		colors = {
			0 = {load_action = .CLEAR, clear_value = convert_to_sokol_rgb(ColorTheme[.BASE])},
		},
	}

	g.debugtext_ctx = sdebugtext.make_context(
		{
			char_buf_size = 64,
			canvas_width = 32,
			canvas_height = 16,
			color_format = .RGBA8,
			depth_format = .NONE,
			sample_count = 1,
		},
	)

	g.debugtext_image = sg.make_image(
		{
			usage = {render_attachment = true},
			width = 32,
			height = 32,
			pixel_format = .RGBA8,
			sample_count = 1,
		},
	)

	g.debugtext_pass = sg.Pass {
		attachments = sg.make_attachments({colors = {0 = {image = g.debugtext_image}}}),
		// NOTE: this *should* set the background color for the part the text will show up on
		// TODO: change this to .SURFACE or .OVERLAY
		action = {colors = {0 = {load_action = .CLEAR, clear_value = ColorTheme[.DEBUG_TEXT]}}},
	}

	g.sampler = sg.make_sampler({min_filter = .NEAREST, mag_filter = .NEAREST})
}

//v := linalg.matrix4_look_at_f32(g.camera.pos, g.camera.target, {0, 1, 0})
view_matrix := linalg.matrix4_look_at_f32(
	Vec3{0.0, 0.0, 0.0},
	Vec3{1.0, 0.0, 0.0},
	Vec3{0.0, 1.0, 0.0},
)

model_matrix :=
	linalg.matrix4_translate_f32(Vec3{10, 0, 0}) *
	linalg.matrix4_scale_f32(Vec3{0.1, 1, 1}) *
	linalg.matrix4_from_yaw_pitch_roll_f32(
		linalg.to_radians(f32(270.0)),
		linalg.to_radians(f32(0.0)),
		linalg.to_radians(f32(0.0)),
	)

compute_mvp :: proc(w: i32, h: i32) -> shaders.Vs_Params {
	p := linalg.matrix4_perspective_f32(70, sapp.widthf() / sapp.heightf(), 0.0001, 1000)

	vs_params := shaders.Vs_Params {
		mvp = p * view_matrix * model_matrix,
	}
	return vs_params
}

load_image :: proc(filename: cstring) -> sg.Image {
	w, h: i32
	pixels := stbi.load(filename, &w, &h, nil, 4)
	assert(pixels != nil)

	image := sg.make_image(
	{
		width = w,
		height = h,
		pixel_format = .RGBA8,
		data = {
			subimage = {
				0 = {
					0 = {
						ptr  = pixels,
						size = uint(w * h * 4), // 4 bytes per pixel
					},
				},
			},
		},
	},
	)
	stbi.image_free(pixels)

	return image
}

update_gui :: proc(dt: f32) {

	disp_width := sapp.width()
	disp_height := sapp.height()

	mvp := compute_mvp(disp_width, disp_height)

	sdebugtext.set_context(sdebugtext.default_context())
	sdebugtext.canvas(f32(disp_width) * 0.5, f32(disp_height) * 0.5)

	c := convert_to_sokol_rgb(ColorTheme[.DEBUG_TEXT])
	sdebugtext.font(5)
	sdebugtext.color4f(c.r, c.g, c.b, c.a)
	sdebugtext.origin(1, 1)
	sdebugtext.printf("File:     %s\n", g.playing.file_path)
	sdebugtext.printf("Duration: %s\n", wav.time_string(g.playing.time))
	sdebugtext.printf("FPS: %f\n", 1 / sapp.frame_duration())

	// NOTE: render file font
	sg.begin_pass(g.debugtext_pass)
	sdebugtext.set_context(g.debugtext_ctx)

	sdebugtext.origin(0, 0.5)
	sdebugtext.font(5)
	c = convert_to_sokol_rgb(ColorTheme[.DEBUG_TEXT])
	sdebugtext.color4f(c.r, c.g, c.b, c.a)
	//sdebugtext.printf("%s\n", g.waves[0].file_path)
	sdebugtext.printf("hi")

	sdebugtext.draw()
	sg.end_pass()
	// NOTE: END render file font

	// NOTE: render geometry
	sg.begin_pass({action = g.pass_action, swapchain = sglue.swapchain()})
	sg.apply_pipeline(g.pipeline)

	sg.apply_bindings(
		{
			images = {shaders.IMG_tex = g.debugtext_image},
			vertex_buffers = g.bindings.vertex_buffers,
			index_buffer = g.bindings.index_buffer,
			samplers = {shaders.SMP_smp = g.sampler},
		},
	)
	sg.apply_uniforms(shaders.UB_Vs_Params, sg_range(&mvp))
	sg.draw(0, 6, 1)

	sdebugtext.set_context(sdebugtext.default_context())
	sdebugtext.draw()
	sg.end_pass()
	sg.commit()
	// NOTE: END render geometry

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
	sdebugtext.shutdown()
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
			window_title = "triangle",
			icon = {sokol_default = true},
			logger = {func = slog.func},
		},
	)
}
