package main

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
import slog "shared:sokol/log"
import fontstash "vendor:fontstash"
import stbi "vendor:stb/image"

// ANSI escape codes for colors
FAIL :: "\x1b[31mfail >>\x1b[0m"
DONE :: "\x1b[32mdone >>\x1b[0m"
PLAY :: "\x1b[32mplay >>\x1b[0m"

// NOTE: ----------------------------------------------
// NOTE: move to it's own module / package

/*
[Master RIFF chunk]
   FileTypeBlocID  (4 bytes) : Identifier « RIFF »  (0x52, 0x49, 0x46, 0x46)
   FileSize        (4 bytes) : Overall file size minus 8 bytes
   FileFormatID    (4 bytes) : Format = « WAVE »  (0x57, 0x41, 0x56, 0x45)

[Chunk describing the data format]
   FormatBlocID    (4 bytes) : Identifier « fmt␣ »  (0x66, 0x6D, 0x74, 0x20)
   BlocSize        (4 bytes) : Chunk size minus 8 bytes, which is 16 bytes here  (0x10)
   AudioFormat     (2 bytes) : Audio format (1: PCM integer, 3: IEEE 754 float)
   NbrChannels     (2 bytes) : Number of channels
   Frequency       (4 bytes) : Sample rate (in hertz)
   BytePerSec      (4 bytes) : Number of bytes to read per second (Frequency * BytePerBloc).
   BytePerBloc     (2 bytes) : Number of bytes per block (NbrChannels * BitsPerSample / 8).
   BitsPerSample   (2 bytes) : Number of bits per sample

[Chunk containing the sampled data]
   DataBlocID      (4 bytes) : Identifier « data »  (0x64, 0x61, 0x74, 0x61)
   DataSize        (4 bytes) : SampledData size
   SampledData
*/

// https://www.mmsp.ece.mcgill.ca/Documents/AudioFormats/WAVE/WAVE.html
RiffHeader :: struct #packed {
	file_type_bloc_id: [4]u8, // (4 bytes) : Identifier « RIFF »  (0x52, 0x49, 0x46, 0x46)
	file_size:         i32, // (4 bytes) : Overall file size minus 8 bytes
	file_format_id:    [4]u8, // (4 bytes) : Format = « WAVE »  (0x57, 0x41, 0x56, 0x45)
}

PcmFormatHeader :: struct #packed {
	chunk_id:        [4]u8, // (4 bytes) : Identifier « fmt␣ »  (0x66, 0x6D, 0x74, 0x20)
	chunk_size:      i32, // (4 bytes) : Chunk size minus 8 bytes, which is 16 bytes here  (0x10) 
	audio_format:    i16, // (2 bytes) : Audio format (1: PCM integer, 3: IEEE 754 float)
	channels:        i16, // (2 bytes) : Number of channels
	frequency:       i32, // (4 bytes) : Sample rate (in hertz)
	byte_per_sec:    i32, // (4 bytes) : Number of bytes to read per second (Frequency * BytePerBloc).
	byte_per_bloc:   i16, // (2 bytes) : Number of bytes per block (NbrChannels * BitsPerSample / 8).
	bits_per_sample: i16, // (2 bytes) : Number of bits per sample
}

ExtFormatHeader :: struct #packed {
	chunk_id:              [4]u8, // (4 bytes) : Identifier « fmt␣ »  (0x66, 0x6D, 0x74, 0x20)
	chunk_size:            i32, // (4 bytes) : Chunk size minus 8 bytes, which is 16 bytes here  (0x10) 
	audio_format:          i16, // (2 bytes) : Audio format (1: PCM integer, 3: IEEE 754 float)
	channels:              i16, // (2 bytes) : Number of channels
	frequency:             i32, // (4 bytes) : Sample rate (in hertz)
	byte_per_sec:          i32, // (4 bytes) : Number of bytes to read per second (Frequency * BytePerBloc).
	byte_per_bloc:         i16, // (2 bytes) : Number of bytes per block (NbrChannels * BitsPerSample / 8).
	bits_per_sample:       i16, // (2 bytes) : Number of bits per sample
	ext_size:              i16,
	valid_bits_per_sample: i16, // 8 * M
	channel_mask:          i32, // speaker position mask
	sub_format:            [16]u8, // GUID
}

IeeeFormatHeader :: struct #packed {
	chunk_id:        [4]u8, // (4 bytes) : Identifier « fmt␣ »  (0x66, 0x6D, 0x74, 0x20)
	chunk_size:      i32, // (4 bytes) : Chunk size minus 8 bytes, which is 16 bytes here  (0x10) 
	audio_format:    i16, // (2 bytes) : Audio format (1: PCM integer, 3: IEEE 754 float)
	channels:        i16, // (2 bytes) : Number of channels
	frequency:       i32, // (4 bytes) : Sample rate (in hertz)
	byte_per_sec:    i32, // (4 bytes) : Number of bytes to read per second (Frequency * BytePerBloc).
	byte_per_bloc:   i16, // (2 bytes) : Number of bytes per block (NbrChannels * BitsPerSample / 8).
	bits_per_sample: i16, // (2 bytes) : Number of bits per sample
	ext_size:        i16, // 0
}

ChunkHeader :: struct #packed {
	chunk_id:   [4]u8, // (4 bytes) : Identifier « data »  (0x64, 0x61, 0x74, 0x61)
	chunk_size: i32, // (4 bytes) : SampledData size
}

FactHeader :: struct #packed {
	chunk_id:      [4]u8,
	chunk_size:    i32,
	sample_length: i32,
}

WAVE_FORMAT_PCM :: i16(1)
WAVE_FORMAT_IEEE_FLOAT :: i16(3)
WAVE_FORMAT_ALAW :: i16(6)
WAVE_FORMAT_MULAW :: i16(7)
//WAVE_FORMAT_EXTENSIBLE :: i16(0xFFFE)

WaveDataHeader :: struct #packed {
	chunk_id:   [4]u8, // (4 bytes) : Identifier « data »  (0x64, 0x61, 0x74, 0x61)
	chunk_size: i32, // (4 bytes) : SampledData size
}

WavContents :: struct {
	// config
	channels:    i16,
	frequency:   i32,
	// state
	sample_idx:  int,
	is_playing:  bool,
	// data
	samples_raw: []f32,
	samples:     ^f32,
	// metadata
	file_path:   string,
	format:      PcmFormatHeader,
	time:        Time,
}

AUDIO_FREQ := i32(44100)
AUDIO_CHANNELS := i16(2)

// NOTE: ----------------------------------------------

default_context: runtime.Context

ROTATION_SPEED :: 10

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
	waves:         [dynamic]WavContents,
	playing:       ^WavContents,
	playing_index: int,
	index:         int,
	gui:           Graphics,
	font:          Font,
}
g: ^Globals

WavErrors :: struct {
	frequency: string,
	channels:  string,
	sokol:     string,
}

@(require_results)
validate_wav :: proc(wav: WavContents) -> (WavErrors, bool) {
	errs: WavErrors
	valid := true

	switch wav.frequency {
	case 0:
		valid = false
		errs.frequency = fmt.aprintf("error: file %s: missing frequency", wav.file_path)
	case AUDIO_FREQ:
		errs.frequency = fmt.aprintf(
			"warn : file %s: possible frequency mismatch: expected %f: received %f",
			wav.file_path,
			AUDIO_FREQ,
			wav.frequency,
		)
	}

	switch wav.channels {
	case 0:
		valid = false
		errs.channels = fmt.aprintf("error: file %s: missing channels", wav.file_path)
	case AUDIO_CHANNELS:
		errs.channels = fmt.aprintf(
			"warn : file %s: possible frequency mismatch: expected %f: received %f",
			wav.file_path,
			AUDIO_CHANNELS,
			wav.channels,
		)
	}

	return errs, valid
}

load_wav :: proc(contents: ^WavContents) {
	file_data, ok := os.read_entire_file(contents.file_path)
	if !ok {
		log.fatal("could not read: ", contents.file_path)
		return
	}

	log.debugf("wav file: %s", contents.file_path)

	offset := 0

	riff: RiffHeader
	format: PcmFormatHeader
	ieee_format: IeeeFormatHeader
	fact: FactHeader
	data: WaveDataHeader

	intrinsics.mem_copy(&riff, &file_data[offset], size_of(RiffHeader))
	offset += size_of(RiffHeader)

	log.assert(
		strings.clone_from_bytes(riff.file_type_bloc_id[:]) == "RIFF", // RIFF header
		"Invalid .wav file, bytes 0-3 should spell 'RIFF'",
	)
	log.assert(
		strings.clone_from_bytes(riff.file_format_id[:]) == "WAVE",
		"Invalid .wav file, bytes 8-11 should spell 'WAVE'",
	)
	log.assert(
		offset < len(file_data),
		fmt.aprint("offset %d >= len(file_data) %d", offset, len(file_data)),
	)

	for offset < len(file_data) {
		// TODO: get this to read the file properly
		chunk: ChunkHeader
		intrinsics.mem_copy(&chunk, &file_data[offset], size_of(ChunkHeader))

		log.debugf(
			"%c%c%c%c header",
			cast(rune)chunk.chunk_id[0],
			cast(rune)chunk.chunk_id[1],
			cast(rune)chunk.chunk_id[2],
			cast(rune)chunk.chunk_id[3],
		)
		log.debugf("- chunk size: %d", chunk.chunk_size)

		switch chunk.chunk_id {
		case "fmt ":
			// Format section
			intrinsics.mem_copy(&format, &file_data[offset], size_of(PcmFormatHeader))

			log.debugf("- audio_format: %d", format.audio_format)
			log.debugf("- channels: %d", format.channels)
			log.debugf("- frequency: %d", format.frequency)
			log.debugf("- byte per sec: %d", format.byte_per_sec)
			log.debugf("- byte per bloc: %d", format.byte_per_bloc)
			log.debugf("- bits per sample: %d", format.bits_per_sample)

			switch format.audio_format {
			case WAVE_FORMAT_IEEE_FLOAT:
				log.debug("IEEE FLOAT format detected")
				intrinsics.mem_copy(&ieee_format, &file_data[offset], size_of(IeeeFormatHeader))

				log.assert(
					ieee_format.audio_format == WAVE_FORMAT_IEEE_FLOAT,
					"ieee format audio format != 3",
				)

				/*
				log.assertf(
					ieee_format.chunk_size == 18,
					"ieee format size %d != 18",
					ieee_format.chunk_size,
				)
				*/

				contents.frequency = ieee_format.frequency
				contents.channels = ieee_format.channels

				log.debugf("- ext size: %d", ieee_format.ext_size)

			case WAVE_FORMAT_PCM:
				log.debug("PCM format detected")
				log.assert(format.audio_format == WAVE_FORMAT_PCM, "pcm format audio format != 1")

				contents.frequency = format.frequency
				contents.channels = format.channels
			case:
				log.panicf("uknown format: %d", format.audio_format)
			}

			offset += size_of(ChunkHeader)
			offset += int(chunk.chunk_size)


		/*log.assert(
				format.frequency == AUDIO_FREQ,
				fmt.aprintf("sample_rate, got %d - expected %d", format.sample_rate, AUDIO_FREQ),
			)*/
		/*log.assert(
				format.channel_count == AUDIO_CHANNELS,
				fmt.aprintf(
					"channel_count, got %d - expected %d",
					format.channel_count,
					AUDIO_CHANNELS,
				),
			)*/
		/*log.assert(
				format.bits_per_sample == i16(32),
				fmt.aprintf("bits per sample, got %d - expected %d", format.bits_per_sample, 32),
			)*/

		case "fact":
			intrinsics.mem_copy(&fact, &file_data[offset], size_of(FactHeader))
			offset += size_of(ChunkHeader)
			offset += int(chunk.chunk_size)

		// TODO: should I do anything with this?
		// TODO: any calculations / extra fields on 'contents' ?

		case "data":
			intrinsics.mem_copy(&data, &file_data[offset], size_of(WaveDataHeader))
			offset += size_of(ChunkHeader)

			// Data section
			log.assertf(data.chunk_size != 0, "data size: %d", data.chunk_size)
			log.assertf(
				int(chunk.chunk_size) + offset <= len(file_data),
				"data size (%d) + offset (%d) goes beyond length of file (%d)",
				int(chunk.chunk_size),
				offset,
				len(file_data),
			)

			samples := data.chunk_size / i32((format.bits_per_sample / 8))
			log.debugf("- total samples: %d", samples)

			contents.samples_raw = make([]f32, samples)
			intrinsics.mem_copy(&contents.samples_raw[0], &file_data[offset], data.chunk_size)
			offset += int(chunk.chunk_size)
			if offset % 2 == 1 {
				offset += 1 // NOTE: account for pad-byte
			}

			contents.samples = &contents.samples_raw[0]

		case "cue ":
			// TODO: cue chunk and handling sample offsets
			offset += size_of(ChunkHeader)
			offset += int(chunk.chunk_size)
		case "bext":
			offset += size_of(ChunkHeader)
			offset += int(chunk.chunk_size)
		case "junk":
			offset += size_of(ChunkHeader)
			offset += int(chunk.chunk_size)
		case "JUNK":
			offset += size_of(ChunkHeader)
			offset += int(chunk.chunk_size)
		case:
			offset += size_of(ChunkHeader)
			offset += int(chunk.chunk_size)
		}
	}

	contents.format = format
	contents.time = time_make(seconds(contents^))
	log.debug("contents")
	log.debugf("- audio duration: %s", time_string(contents.time))

	log.assert(contents.frequency != 0, "contents.freqency is 0")
	log.assert(contents.channels != 0, "contents.channels is 0")
	log.assert(len(contents.samples_raw) != 0, "contents.samples_raw length is 0")
}

Time :: struct {
	duration_seconds: f32,
	ms:               f32,
	seconds:          f32,
	minutes:          int,
	hours:            int,
}


time_make :: proc(duration: f32) -> Time {
	milliseconds := duration - math.floor(duration)
	seconds := f32(int(duration) % 60) + milliseconds
	minutes := (int(duration) / 60) % 60
	hours := int(duration) / 3600

	return Time {
		duration_seconds = duration,
		ms = milliseconds,
		seconds = seconds,
		minutes = minutes,
		hours = hours,
	}
}

// format: 10:35:14.34
time_string :: proc(t: Time) -> string {
	return fmt.aprintf("%02d:%02d:%05.2f", t.hours, t.minutes, t.seconds)
}

music_bounce := WavContents {
	file_path = "assets/audio/bounce.wav",
}

// TODO: cache recently played up to certain amount to save on load time for switching back and forth?

play_audio :: proc() {
	if g.playing != nil do sa.shutdown()

	sa.setup({logger = {func = slog.func}})
	log.assertf(sa.isvalid(), "%s sokol audio setup is not valid", FAIL)

	g.playing_index = g.index
	g.playing = &g.waves[g.playing_index]

	g.playing.sample_idx = 0
	g.playing.is_playing = true

	log.debugf(
		"%s %03d/%03d recordings  %dhz  %s  %10d samples  %d channels  %02dbit sample size  %s format  %s",
		PLAY,
		g.playing_index + 1,
		len(g.waves),
		g.playing.frequency,
		time_string(g.playing.time),
		len(g.playing.samples_raw),
		g.playing.channels,
		g.playing.format.bits_per_sample,
		wav_format(g.playing.format.audio_format),
		g.playing.file_path,
	)
}

wav_format :: proc(f: i16) -> string {
	switch f {
	case WAVE_FORMAT_PCM:
		return "PCM"
	case WAVE_FORMAT_IEEE_FLOAT:
		return "IEEE Float"
	case WAVE_FORMAT_ALAW:
		return "ALAW"
	case WAVE_FORMAT_MULAW:
		return "MULAW"
	case:
		return "UNKNOWN"
	}
}

// TODO: change Globals structure to enable dynamic adding / removing of filters / transforms on wav contents
// TODO: make this transform the "dynamic" buffer of samples -> when time to save off the values, transfer to the "static" buffer and write to disk?
low_pass_filter :: proc(wav: ^WavContents) {

	num_samples := count_samples(wav.format)
	lpf_samples := make([]f32, num_samples)
	intrinsics.mem_copy(&lpf_samples[0], &wav.samples_raw[0], wav.format.chunk_size)

	// LPF: Y(n) = (1-ß)*Y(n-1) + (ß*X(n))) = Y(n-1) - (ß*(Y(n-1)-X(n)));

	raw: f32
	smooth: f32
	beta: f32 = 0.025 // 0<ß<1

	channels := i32(wav.channels)

	// LPF: Y(n) = (1-ß)*Y(n-1) + (ß*X(n))) = Y(n-1) - (ß*(Y(n-1)-X(n)));
	for i in channels ..< num_samples {
		lpf_samples[i] =
			lpf_samples[i - channels] - (beta * (lpf_samples[i - channels] - lpf_samples[i]))
	}

	delete(wav.samples_raw)
	wav.samples = nil
	intrinsics.mem_copy(&wav.samples_raw[0], &lpf_samples[0], wav.format.chunk_size)
	wav.samples = &lpf_samples[0]
}

FREQ :: 44100

count_samples :: proc(format: PcmFormatHeader) -> i32 {
	return format.chunk_size / i32((format.bits_per_sample / 8))
}

seconds :: proc(wav: WavContents) -> f32 {
	return f32(len(wav.samples_raw)) / f32((wav.frequency * i32(wav.channels)))
}

init :: proc "c" () {
	context = default_context

	g = new(Globals)

	load_dir(audio_dir)

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

		append(&g.waves, WavContents{file_path = e.fullpath})
		load_wav(&g.waves[index])
		errs, valid := validate_wav(g.waves[index])
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

	update_state(dt)
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

line :: proc(sx, sy, ex, ey: f32) {
	sgl.begin_lines()
	sgl.c4b(255, 255, 0, 128)
	sgl.v2f(sx, sy)
	sgl.v2f(ex, ey)
	sgl.end()
}

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
	g.font.id = fontstash.AddFont(&g.font.ctx, "calligraphic", "assets/DuctusCalligraphic.ttf")

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
			shader = sg.make_shader(triangle_shader_desc(sg.query_backend())),
			index_type = .UINT16,
			layout = {
				attrs = {
					ATTR_triangle_position = {format = .FLOAT2},
					ATTR_triangle_color0 = {format = .FLOAT3},
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

	fontstash.ClearState(&g.font.ctx)

	sgl.defaults()
	sgl.matrix_mode_projection()
	sgl.ortho(0.0, sapp.widthf(), sapp.heightf(), 0.0, -1.0, 1.0)

	sx := 50 * g.font.dpi_scale
	sy := 50 * g.font.dpi_scale
	dx := sx
	dy := sy

	fontstash.BeginState(&g.font.ctx)
	fontstash.SetFont(&g.font.ctx, g.font.id)
	fontstash.SetSize(&g.font.ctx, 16.0 * g.font.dpi_scale)
	_, _, lh := fontstash.VerticalMetrics(&g.font.ctx)
	dx = sx
	dy += lh
	fontstash.SetColor(&g.font.ctx, [4]u8{255, 255, 255, 255})
	fontstash.TextIterInit(&g.font.ctx, 50, 50, "yee")

	// NOTE: font alignment

	dx = 100 * g.font.dpi_scale
	dy = 50 * g.font.dpi_scale
	line(dx - 10 * g.font.dpi_scale, dy, dx + 100 * g.font.dpi_scale, dy)
	fontstash.SetAV(&g.font.ctx, .MIDDLE)
	fontstash.SetAH(&g.font.ctx, .CENTER)
	fontstash.TextIterInit(&g.font.ctx, 50, 50, "whaaahoooo")

	fontstash.EndState(&g.font.ctx)

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

update_state :: proc(dt: f32) {
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

FRAMERATE :: 60.0
TIMESTEP :: 1.0 / FRAMERATE
accumulator := 0.0
start_time := time.now()

audio_dir: string

main :: proc() {
	context.logger = log.create_console_logger()
	default_context = context

	audio_dir = os.args[1]
	log.assertf(
		audio_dir != "",
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
