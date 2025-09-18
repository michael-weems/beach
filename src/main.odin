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
import "core:path/filepath"
import "core:strings"
import "core:time"
import sapp "shared:sokol/app"
import sa "shared:sokol/audio"
import sdtx "shared:sokol/debugtext"
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

EntityKind :: enum {
	FILE_ENTRY,
	CAMERA,
}

Entity :: struct {
	kind:         EntityKind,
	position:     Vec3,
	model_matrix: Mat4,
	target:       Vec3,
	rotation:     f32,
	velocity:     Vec3, // NOTE: ??
	acceleration: Vec3, // NOTE: ??

	// File Info
	file_name:    string,
	wav_index:    int,
}

TextRenderDesc :: struct {
	text:             string,
	position:         Vec3, // NOTE: definitely does not belong here
	model_matrix:     Mat4, // NOTE: definitely does not belong here
	ctx:              sdtx.Context,
	bindings:         sg.Bindings,
	image:            sg.Image,
	pass_action:      sg.Pass_Action,
	pass_attachments: sg.Attachments,
}

Globals :: struct {
	waves:         [dynamic]wav.Contents,
	entities:      [dynamic]Entity,
	vertices:      [dynamic]Vertex,
	indices:       []u16,
	playing:       ^wav.Contents,
	playing_index: int,
	index:         int,
	camera:        Entity,
	pipeline:      sg.Pipeline,
	pass_action:   sg.Pass_Action,
	sampler:       sg.Sampler,
	sdtx:          [EntityKind][dynamic]TextRenderDesc,
}
g: ^Globals

SAMPLE_RATE :: 44100 // NOTE: 44100hz
DEPTH_UI :: 10 // NOTE: how far from the camera the base UI elements should be
DEPTH_UI_SURFACE :: 8 // NOTE: how far from the camera the surface UI elements should be
DEPTH_UI_OVERLAY :: 6 // NOTE: how far from the camera the overlay UI elements should be

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

make_file_entry :: proc(wav_index: int) -> Entity {

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

	entry := Entity {
		kind         = .FILE_ENTRY,
		position     = Vec3{-BREADTH_UI, -BREADTH_UI, DEPTH_UI},
		wav_index    = wav_index,
		model_matrix = model_matrix,
		file_name    = filepath.short_stem(g.waves[wav_index].file_path),
	}

	return entry
}

EntityIndex :: struct {
	start: int,
	len:   int,
}

index_registry := [EntityKind]EntityIndex {
	.CAMERA = {},
	.FILE_ENTRY = {start = 0, len = 6},
}

load_dir :: proc(dir: string) {
	fd, err := os.open(dir)
	log.assertf(err == nil, "open dir: %s: %v", dir, err)

	entries, read_err := os.read_dir(fd, 1000)
	log.assertf(read_err == nil, "read dir: %s: %v", dir, read_err)
	log.assertf(len(entries) > 0, "no files found in dir: %s: %v", dir, read_err)

	num_entries := len(entries)

	if len(g.waves) != 0 do delete(g.waves)
	g.waves = {}

	// NOTE: process files
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

		entry := make_file_entry(wav_index = index)
		append(&g.entities, entry)

		index += 1
	}
}

file_name_vertices :: proc() -> [4]Vertex {
	color_surface := convert_to_sokol_rgb(ColorTheme[.SURFACE])
	color_a := sg.Color{1, 1, 1, 1}
	color_b := sg.Color{1, 1, 0, 1}
	color_c := sg.Color{0, 1, 1, 1}
	color_d := sg.Color{1, 0, 1, 1}
	color_e := sg.Color{1, 0, 0, 1}
	color_f := sg.Color{0, 1, 0, 1}
	return [4]Vertex {
		// NOTE: file-name
		{pos = {1, 1, 0.0}, color = color_a, uv = {1, 1}},
		{pos = {1, 0, 0.0}, color = color_b, uv = {1, 0}},
		{pos = {0, 1, 0.0}, color = color_c, uv = {0, 1}},
		{pos = {0, 0, 0.0}, color = color_d, uv = {0, 0}},
		//{pos = {-1, 0, 0.0}, color = color_e, uv = {1, 0}},
		//{pos = {-1, 1, 0.0}, color = color_f, uv = {0, 0}},
	}
}

init :: proc "c" () {
	context = default_context

	g = new(Globals)
	load_dir(process_input.audio_dir)
	log.assertf(len(&g.waves) > 0, "no wav files found in dir: %s", process_input.audio_dir)

	vertices := file_name_vertices()
	for v in 0 ..< len(vertices) do append(&g.vertices, vertices[v])
	
	// odinfmt: disable
	g.indices = []u16{
		0, 1, 2,   2, 1, 3,  // NOTE: file-name
		//0, 1, 2,   2, 1, 3,   2, 3, 5,   5, 4, 3, // NOTE: file-name
	}
	// odinfmt: enable

	// v := linalg.matrix4_look_at_f32(g.camera.pos, g.camera.target, {0, 1, 0})
	g.camera.kind = .CAMERA
	_set_camera_position(Vec3{0, 0, 0})

	sg.setup(
		{
			max_dispatch_calls_per_pass = 1000,
			buffer_pool_size = 1000,
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

	sapp.show_mouse(false)
	sapp.lock_mouse(true)

	g.sampler = sg.make_sampler({min_filter = .NEAREST, mag_filter = .NEAREST})
	g.pass_action = {
		colors = {
			0 = {load_action = .CLEAR, clear_value = convert_to_sokol_rgb(ColorTheme[.BASE])},
		},
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

	for w in 0 ..< len(g.waves) {

		append(&g.sdtx[.FILE_ENTRY], TextRenderDesc{})

		e := &g.sdtx[.FILE_ENTRY][len(g.sdtx[.FILE_ENTRY]) - 1]

		e.text = g.waves[w].file_name
		e.position = Vec3{-BREADTH_UI, (f32(w) * CAMERA_TRAVEL) - BREADTH_UI, DEPTH_UI}
		e.model_matrix =
			linalg.matrix4_rotate_f32(linalg.to_radians(f32(180)), {0, 1, 0}) *
			linalg.matrix4_rotate_f32(linalg.to_radians(f32(180)), {0, 0, 1}) *
			linalg.matrix4_scale_f32(Vec3{2, 2, 1})

		e.ctx = sdtx.make_context(
			{
				char_buf_size = 64,
				canvas_width = 64,
				canvas_height = 16,
				color_format = .RGBA8,
				depth_format = .NONE,
				sample_count = 1,
			},
		)

		e.image = sg.make_image(
			{
				usage = {render_attachment = true},
				width = 32,
				height = 32,
				pixel_format = .RGBA8,
				sample_count = 1,
			},
		)

		e.pass_attachments = sg.make_attachments({colors = {0 = {image = e.image}}})

		// NOTE: this *should* set the background color for the part the text will show up on
		// TODO: change this to .SURFACE or .OVERLAY
		e.pass_action = {
			colors = {
				0 = {
					load_action = .CLEAR,
					clear_value = convert_to_sokol_rgb(ColorTheme[.SURFACE]),
				},
			},
		}

		log.assertf(
			len(g.vertices) > 0,
			"must load wav files and intialize vertices before init_gui",
		)
		e.bindings.vertex_buffers[0] = sg.make_buffer({data = sg_range(g.vertices[:])})

		log.assertf(
			len(g.indices) > 0,
			"must load wav files and intialize vertices before init_gui",
		)
		e.bindings.index_buffer = sg.make_buffer(
			{usage = {index_buffer = true}, data = sg_range(g.indices[:])},
		)

		log.assertf(len(g.waves) > 1, "len g.waves <= 1")

		e.bindings.images = {
			shaders.IMG_tex = e.image,
		}

		e.bindings.samplers = {
			shaders.SMP_smp = g.sampler,
		}

	}

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

_add_camera_position :: proc(position: Vec3) {
	_set_camera_position(g.camera.position + position)
}

_set_camera_position :: proc(position: Vec3) {
	g.camera.position = position
	g.camera.target = position
	g.camera.target.z += DEPTH_UI // NOTE: camera: x: -left and +right, y: -up and +down, z: +forward/zoomin and -backward/zoomout
}

fovy := linalg.to_radians(f32(90.0))
fovy_half := fovy / 2
fovy_oppo := linalg.to_radians(f32(90.0)) - fovy_half

// NOTE: hacky but it gets the job done, close enough
BREADTH_UI := (DEPTH_UI * math.sin(fovy_half) / math.sin(fovy_oppo)) - 0.5 // NOTE: a = c * sin(A) / sin(C)
CAMERA_TRAVEL := 2 * BREADTH_UI

ROTATION_SPEED :: 10.0

compute_mvp :: proc(dt: f32, position: Vec3, mm: Mat4, w: f32, h: f32) -> shaders.Vs_Params {

	p := linalg.matrix4_perspective_f32(fovy, w / h, 0.1, 100.0)

	if spinning {
		g.camera.rotation += linalg.to_radians(ROTATION_SPEED * dt)

		g.camera.position.x = linalg.sin(g.camera.rotation) * DEPTH_UI // TODO: want to handle offset? or lock them into the spin coordinates?
		g.camera.position.z = (linalg.cos(g.camera.rotation) * DEPTH_UI) + DEPTH_UI // TODO: want to handle offset? or lock them into the spin coordinates?
		g.camera.target.x = 0
		g.camera.target.z = DEPTH_UI
	}
	v := linalg.matrix4_look_at_f32(g.camera.position, g.camera.target, Vec3{0.0, -1.0, 0.0}) // NOTE: -y == up


	// NOTE: T * R * S --> Scale, then rotate, then translate
	m := linalg.matrix4_translate_f32(position) * mm

	vs_params := shaders.Vs_Params {
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

	w := sapp.widthf()
	h := sapp.heightf()

	sdtx.set_context(sdtx.default_context())
	sdtx.canvas(w * 0.5, h * 0.5)

	c := convert_to_sokol_rgb(ColorTheme[.DEBUG_TEXT])
	sdtx.font(5)
	sdtx.color4f(c.r, c.g, c.b, c.a)
	sdtx.origin(1, 1)
	sdtx.printf("File:     %s\n", g.playing.file_path)
	sdtx.printf("duration=%s: idx=%d\n", wav.time_string(g.playing.time), g.playing.sample_idx)
	sdtx.printf("FPS: %f\n", 1 / sapp.frame_duration())
	sdtx.printf("breadth=%f\n", BREADTH_UI)
	sdtx.printf(
		"camera: position: x=%f y=%f z=%f\n",
		g.camera.position.x,
		g.camera.position.y,
		g.camera.position.z,
	)
	sdtx.printf(
		"camera: target: x=%f y=%f z=%f\n",
		g.camera.target.x,
		g.camera.target.y,
		g.camera.target.z,
	)
	sdtx.printf("camera: rotation: r=%f\n", g.camera.rotation)
	sdtx.printf("camera: spinning=%v\n", spinning)

	used := 0

	MAX_PASSES := 5

	for i in 0 ..< MAX_PASSES {
		e := &g.sdtx[.FILE_ENTRY][i]
		// NOTE: render file font
		sg.begin_pass({action = e.pass_action, attachments = e.pass_attachments})
		sdtx.set_context(e.ctx)

		sdtx.origin(0, 0.5)
		sdtx.font(5)
		c = convert_to_sokol_rgb(ColorTheme[.BASE]) // TODO: get this color looking better somehow
		sdtx.color4f(c.r, c.g, c.b, c.a)
		sdtx.printf("%s\n", e.text)

		sdtx.draw()
		sg.end_pass() // NOTE: END render file font
	}


	sg.begin_pass({action = g.pass_action, swapchain = sglue.swapchain()})
	sg.apply_pipeline(g.pipeline)

	/*
	for entity in g.entities {
		switch entity.kind {
		case .CAMERA:
		case .FILE_ENTRY:
			// NOTE: render geometry
			sg.apply_bindings(g.sdtx_bindings)

			// TODO: doing the really dumb thing for now to get this working


			mvp := compute_mvp(entity, w, h)
			sg.apply_uniforms(shaders.UB_Vs_Params, sg_range(&mvp))

			sg.draw(0, 6, 1)
			used += 1

		}
	}
	*/

	// TODO: doing the really dumb thing for now to get this working
	for i in 0 ..< MAX_PASSES {
		e := &g.sdtx[.FILE_ENTRY][i]

		// NOTE: render geometry
		sg.apply_bindings(e.bindings)

		mvp := compute_mvp(dt, e.position, e.model_matrix, w, h)
		sg.apply_uniforms(shaders.UB_Vs_Params, sg_range(&mvp))

		sg.draw(0, 6, 1)
	}


	sdtx.set_context(sdtx.default_context())
	sdtx.draw()
	sg.end_pass() // NOTE: END render geometry

	sg.commit()
}

_in_bounds :: proc() {
	if g.playing_index < 0 do g.playing_index = 0
	if g.playing_index >= len(g.waves) do g.playing_index = len(g.waves) - 1

	if g.index < 0 do g.index = 0
	if g.index >= len(g.waves) do g.index = len(g.waves) - 1
}

g_intermediary := false

_move_index :: proc(n: int) {
	prev_index := g.index
	g.index += n
	_in_bounds()

	// TODO: ideas for animating index movement
	// - animations disabled: important!
	// - zoom out and zoom back in on the index you're trying to look at
	// - accelerate then deccelerate
	// - swirl around the list, camera kept pointing at the list as it rotates around it and moves up / down
	// - think of more!

	// NOTE: for now, we just move up and down
	_add_camera_position(Vec3{0, CAMERA_TRAVEL * f32(g.index - prev_index), 0})
}

spinning := false

process_user_input :: proc(dt: f32) {
	// NOTE: generally, the goal is to make this intuitive to use for someone familiar with VIM motions

	// TODO: switch statement instead ??

	if key_down[.PERIOD] {
		_set_camera_position(Vec3{0, 0, 0})
	}

	if key_down[.BACKSPACE] {
		// TODO: here for debugging, can remove later
		_add_camera_position(Vec3{0, 0, -.1})
	}
	if key_down[.DELETE] {
		// TODO: here for debugging, can remove later
		_add_camera_position(Vec3{0, 0, .1})
	}
	if key_down[.DOWN] {
		// TODO: here for debugging, can remove later
		_add_camera_position(Vec3{0, .1, 0})
	}
	if key_down[.UP] {
		// TODO: here for debugging, can remove later
		_add_camera_position(Vec3{0, -.1, 0})
	}
	if key_down[.LEFT] {
		// TODO: here for debugging, can remove later
		_add_camera_position(Vec3{-.1, 0, 0})
	}
	if key_down[.RIGHT] {
		// TODO: here for debugging, can remove later
		_add_camera_position(Vec3{.1, 0, 0})
	}
	if key_down[.Q] {
		if spinning {
			spinning = false
		} else {
			spinning = true
		}
		key_down[.Q] = false // NOTE: manually disable it so it doesn't keep cutting
	}

	if key_down[._0] {
		g.playing.sample_idx = 0
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
		g.playing.sample_idx = len(g.playing.samples_raw) - 1
		key_down[.LEFT_SHIFT] = false // NOTE: manually disable it so it doesn't keep cutting
		key_down[.RIGHT_SHIFT] = false // NOTE: manually disable it so it doesn't keep cutting
		key_down[._4] = false // NOTE: manually disable it so it doesn't keep cutting
	}

	// TODO: Ctrl + d and Ctrl + u for jumping multiple up and down: hard-code / calculate correct number to jump

	if (key_down[.LEFT_SHIFT] || key_down[.RIGHT_SHIFT]) && key_down[.G] {
		_move_index(len(g.waves))
		key_down[.LEFT_SHIFT] = false // NOTE: manually disable it so it doesn't keep cutting
		key_down[.RIGHT_SHIFT] = false // NOTE: manually disable it so it doesn't keep cutting
		key_down[.G] = false // NOTE: manually disable it so it doesn't keep cutting
	}

	if key_down[.G] {
		if g_intermediary {
			// TODO: _move_index(first)
			g_intermediary = false
			_move_index(-len(g.waves))
		} else {
			g_intermediary = true
		}

		key_down[.G] = false // NOTE: manually disable it so it doesn't keep cutting
	}

	// NOTE: directional menu navigation
	if key_down[.K] {
		_move_index(-1)
		key_down[.K] = false // NOTE: manually disable it so it doesn't keep cutting
	}
	if key_down[.J] {
		_move_index(1)
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

	// TODO: change 'e' to go to end of next 'word' or section of higher gain
	if key_down[.E] {
		if len(g.playing.samples_raw) >= 44100 {
			g.playing.samples_raw = g.playing.samples_raw[:g.playing.sample_idx]
			g.playing.sample_idx -= 44100
			if g.playing.sample_idx < 0 do g.playing.sample_idx = 0
			log.debugf("E: samples: %d", len(g.playing.samples_raw))
			key_down[.E] = false // NOTE: manually disable it so it doesn't keep cutting
		}
	}
	// TODO: change 'b' to go to beginning of prev 'word' or section of higher gain
	if key_down[.B] {
		if len(g.playing.samples_raw) >= 44100 {
			g.playing.samples_raw = g.playing.samples_raw[g.playing.sample_idx:]
			g.playing.sample_idx = 0
			log.debugf("B: samples: %d", len(g.playing.samples_raw))
			key_down[.B] = false // NOTE: manually disable it so it doesn't keep cutting
		}
	}
	// TODO: change 'w' to go to beginning of next 'word' or section of higher gain

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

// TODO: this slow. we don't need it to be fast (yet). but we're getting < 60fps and this is most likely the cause. For this app, we don't need more than 30fps (probably). But I'd like to get it >60fps, >120fps if possible
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
	sdtx.shutdown()
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
