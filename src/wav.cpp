#include "wav.hpp"
#include "ctx.hpp"

#include "ansi_colors.hpp"
#include "log.hpp"

#include <string>
#include <format>
#include <ifstream>
#include <assert.h>

namespace wav
{
   bool is_valid(wav& wav)
   {
      switch (wav.frequency) 
      {
         case 0:
         {
            wav.has_errors = true;
            wav.errors.push_back(std::format("error: file {}: missing frequency", wav.file_path));
            break;
         }
         case AUDIO_FREQ:
         {
            wav.has_errors = true;
            wav.errors.push_back(std::format(
                 "warn : file {}: possible frequency mismatch: expected {}: received {}",
                 wav.file_path,
                 AUDIO_FREQ,
                 wav.frequency,
            ));
            break;
         }
      }

      switch (wav.channels) 
      {
         case 0:
         {
            wav.has_errors = false;
            wav.errors.push_back(std::format("error: file {}: missing channels", wav.file_path));
            break;
         }
         case AUDIO_CHANNELS:
         {
            wav.has_errors = false;
            wav.errors.push_back(std::format(
                    "warn : file {}: possible frequency mismatch: expected {}: received {}",
                    wav.file_path,
                    AUDIO_CHANNELS,
                    wav.channels,
            ));
            break;
         }
       }

      return wav.has_errors;;
   }

   error load_from_file(ctx::ctx *ctx, std::string file_path, wav *contents) 
   {
      error e{};

      std::ifstream input_file_stream(file_path, std::ios::in | std::ios::binary);
      if (!input_file_stream) {
         e.has_error = true;
         e.msg = "open file: " + file_path;
         return e;
      }
/* TODO: close file and all that
    // Check if the loop terminated due to end-of-file (EOF) or another error
    if (!input_file_stream.eof()) 
   {
        std::cerr << "An error occurred while reading the file before the end was reached." << std::endl;
        // Optionally clear the stream state to continue processing if needed
        // inputFileStream.clear();
    }
    
    inputFileStream.close();
*/

      contents->file_path = file_path;
      //contents->file_name = filepath.short_stem(file_path); // TODO: cpp version of getting just file name

      log.debug("debug: wav file: " + contents.file_path);

      int offset = 0;

      riff_header riff{};
      pcm_format_header format{};
      ieee_format_header ieee_format{};
      fact_header fact{};
      wave_data_header data{};

      intrinsics.mem_copy(&riff, &file_data[offset], size_of(RiffHeader))
      offset += size_of(RiffHeader)

      log.assert(
         // TODO: string compare
         strings.clone_from_bytes(riff.file_type_bloc_id[:]) == "RIFF", // RIFF header
         "invalid .wav file, bytes 0-3 should spell 'RIFF'"
      );
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
             chunk_header chunk;
             intrinsics.mem_copy(&chunk, &file_data[offset], size_of(chunk_header))

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
                     intrinsics.mem_copy(&format, &file_data[offset], size_of(pcm_format_header))

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

                       offset += size_of(chunk_header)
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
                       intrinsics.mem_copy(&fact, &file_data[offset], size_of(fact_header))
                       offset += size_of(chunk_header)
                       offset += int(chunk.chunk_size)

               // TODO: should I do anything with this?
               // TODO: any calculations / extra fields on 'contents' ?

               case "data":
                       intrinsics.mem_copy(&data, &file_data[offset], size_of(wave_data_header))
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
                       offset += size_of(chunk_header)
                       offset += int(chunk.chunk_size)
               case "bext":
                       offset += size_of(chunk_header)
                       offset += int(chunk.chunk_size)
               case "junk":
                       offset += size_of(chunk_header)
                       offset += int(chunk.chunk_size)
               case "JUNK":
                       offset += size_of(chunk_header)
                       offset += int(chunk.chunk_size)
               case:
                       offset += size_of(chunk_header)
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

   struct Time 
   {
      float duration_seconds;
      float ms;
      fload seconds;
      int minutes;
      int hours;
   }


   Time time_make(float duration) 
   {
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

   music_bounce := Contents {
           file_path = "assets/audio/bounce.wav",
   }

   // TODO: cache recently played up to certain amount to save on load time for switching back and forth?


   which_format :: proc(f: i16) -> string {
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
   low_pass_filter :: proc(wav: ^Contents) {

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

   int32_t count_samples(PCM_Format_Header* format)
   {
      return format->chunk_size / i32((format->bits_per_sample / 8))
   }

   count_samples :: proc(format: PcmFormatHeader) -> i32 {
           return format.chunk_size / i32((format.bits_per_sample / 8))
   }

   seconds :: proc(wav: Contents) -> f32 {
           return f32(len(wav.samples_raw)) / f32((wav.frequency * i32(wav.channels)))
   }
}
