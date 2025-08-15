package main

import "base:intrinsics"
import "base:runtime"
import "core:fmt"
import "core:log"
import "core:math"
import "core:math/linalg"
import "core:os"
import "core:strings"
import "core:time"
import sapp "shared:sokol/app"
import sa "shared:sokol/audio"
import sg "shared:sokol/gfx"
import sglue "shared:sokol/glue"
import slog "shared:sokol/log"
import stbi "vendor:stb/image"

// ANSI escape codes for colors
FAIL :: "\x1b[31mfail >>\x1b[0m"
DONE :: "\x1b[32mdone >>\x1b[0m"

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
	channels:      i16,
	frequency:     i32,
	// data
	samples_raw:   []f32,
	samples:       ^f32,
	// metadata
	file_path:     string,
	sample_idx:    int,
	is_playing:    bool,
	is_music:      bool,
	time_duration: int, // ms
}

AUDIO_FREQ := i32(44100)
AUDIO_CHANNELS := i16(2)

// NOTE: ----------------------------------------------

default_context: runtime.Context

ROTATION_SPEED :: 10

Vec2 :: [2]f32
Vec3 :: [3]f32
Vec4 :: [4]f32

Mat4 :: matrix[4, 4]f32

Vertex :: struct {
	pos:   Vec3,
	color: sg.Color,
	uv:    Vec2,
}

WavErrors :: struct {
	frequency: string,
	channels:  string,
	sokol:     string,
}

@(require_results)
validate_audio :: proc(wav: WavContents) -> (WavErrors, bool) {
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
	if !sa.isvalid() {
		valid = false
		errs.sokol = fmt.aprintf("%s sokol audio setup is not valid", FAIL)
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

	per_sample := ((int(contents.channels) * int(format.bits_per_sample) / 8))

	contents.time_duration = len(contents.samples_raw) / per_sample
	log.debug("contents")
	log.debugf("- audio duration: %s", time_string(contents.time_duration))

	log.assert(contents.frequency != 0, "contents.freqency is 0")
	log.assert(contents.channels != 0, "contents.channels is 0")
	log.assert(len(contents.samples_raw) != 0, "contents.samples_raw length is 0")
}

time_string :: proc(ms: int) -> string {

	total_seconds := ms / 1000
	seconds := total_seconds % 60
	minutes := (total_seconds / 60) % 60
	hours := total_seconds / 3600

	time_string := fmt.aprintf("%02d:%02d:%02d (note: verify this)", hours, minutes, seconds)
	return time_string // Output: 10:35:14
}

music_bounce := WavContents {
	file_path = "assets/audio/bounce.wav",
}

wav: WavContents

init :: proc "c" () {
	context = default_context

	//wav.file_path = "audio/loon.wav"
	wav.file_path = "../game/assets/audio/bounce.wav"
	wav.is_playing = true
	wav.is_music = true
	load_wav(&wav)

	sa.setup({logger = {func = slog.func}})
	log.debugf("%s setup audio", DONE)

	errs, valid := validate_audio(wav)
	if !valid {
		// TODO: gracefully handle errors in the wav file, but keep the program running
		// NOTE: for now, assert and crash
		log.assertf(errs.sokol == "", errs.sokol)
		log.assertf(errs.frequency == "", errs.frequency)
		log.assertf(errs.channels == "", errs.channels)
	}
	log.debugf("%s validate audio", DONE)
}

frame :: proc "c" (dt: f64) {
	context = default_context

	update_audio(dt)
}

update_audio :: proc(dt: f64) {

	num_frames := int(sa.expect())
	if num_frames > 0 {

		buf := make([]f32, num_frames)
		frame_loop: for frame in 0 ..< num_frames {
			log.assertf(wav.channels != 0, "wav pointers are invalid: channels %d", wav.channels)
			if !wav.is_playing do continue

			for channel in 0 ..< wav.channels {
				if wav.sample_idx >= len(wav.samples_raw) {
					wav.sample_idx = 0
					wav.is_playing = false
					continue frame_loop
				}

				buf[frame] += wav.samples_raw[wav.sample_idx]
				wav.sample_idx += 1
			}
		}

		sa.push(&buf[0], num_frames)
	}
}

mouse_down: bool = false
mouse_move: Vec2
mouse_pos: Vec2
key_down: #sparse[sapp.Keycode]bool

event :: proc "c" (ev: ^sapp.Event) {
	context = default_context

	#partial switch ev.type {
	case .MOUSE_DOWN:
		mouse_down = true
	case .MOUSE_UP:
		mouse_down = false
	case .MOUSE_MOVE:
		mouse_move += {ev.mouse_dx, ev.mouse_dy}
		mouse_pos = {ev.mouse_x, ev.mouse_y}
	case .KEY_DOWN:
		key_down[ev.key_code] = true
	case .KEY_UP:
		key_down[ev.key_code] = false
	}

}


cleanup :: proc "c" () {
	context = default_context
	sa.shutdown()
}

FRAMERATE :: 60.0
TIMESTEP :: 1.0 / FRAMERATE
accumulator := 0.0
start_time := time.now()

main :: proc() {
	context.logger = log.create_console_logger()
	default_context = context

	init()

	for {
		current_time := time.now()

		diff := time.diff(start_time, current_time)
		dt := time.duration_seconds(diff)
		start_time = current_time

		accumulator += dt

		for accumulator >= TIMESTEP {
			frame(accumulator)
			accumulator -= TIMESTEP
		}
	}
}
