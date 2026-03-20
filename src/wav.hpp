#ifndef BEACH_WAV_HPP
#define BEACH_WAV_HPP

#include <string>

namespace wav
{
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
   struct riff_header 
   {
           char file_type_bloc_id[4]; // (4 bytes) : Identifier « RIFF »  (0x52, 0x49, 0x46, 0x46)
           int32_t file_size;         // (4 bytes) : Overall file size minus 8 bytes
           char file_format_id[4];    // (4 bytes) : Format = « WAVE »  (0x57, 0x41, 0x56, 0x45)
   }

   struct pcm_format_header 
   {
           char chunk_id[4];        // (4 bytes) : Identifier « fmt␣ »  (0x66, 0x6D, 0x74, 0x20)
           int32_t chunk_size;      // (4 bytes) : Chunk size minus 8 bytes, which is 16 bytes here  (0x10)
           int16_t audio_format;    // (2 bytes) : Audio format (1: PCM integer, 3: IEEE 754 float)
           int16_t channels;        // (2 bytes) : Number of channels
           int32_t frequency;       // (4 bytes) : Sample rate (in hertz)
           int32_t byte_per_sec;    // (4 bytes) : Number of bytes to read per second (Frequency * BytePerBloc).
           int16_t byte_per_bloc;   // (2 bytes) : Number of bytes per block (NbrChannels * BitsPerSample / 8).
           int16_t bits_per_sample; // (2 bytes) : Number of bits per sample
   }

   struct ext_format_header 
   {
           char chunk_id[4];              // (4 bytes) : Identifier « fmt␣ »  (0x66, 0x6D, 0x74, 0x20)
           int32_t chunk_size;            // (4 bytes) : Chunk size minus 8 bytes, which is 16 bytes here  (0x10)
           int16_t audio_format;          // (2 bytes) : Audio format (1: PCM integer, 3: IEEE 754 float)
           int16_t channels;              // (2 bytes) : Number of channels
           int32_t frequency;             // (4 bytes) : Sample rate (in hertz)
           int32_t byte_per_sec;          // (4 bytes) : Number of bytes to read per second (Frequency * BytePerBloc).
           int16_t byte_per_bloc;         // (2 bytes) : Number of bytes per block (NbrChannels * BitsPerSample / 8).
           int16_t bits_per_sample;       // (2 bytes) : Number of bits per sample
           int16_t ext_size;
           int16_t valid_bits_per_sample; // 8 * M
           int32_t channel_mask;          // speaker position mask
           char sub_format[16];           // GUID
   }

   struct ieee_format_header
   {
           char chunk_id[4];        // (4 bytes) : Identifier « fmt␣ »  (0x66, 0x6D, 0x74, 0x20)
           int32_t chunk_size;      // (4 bytes) : Chunk size minus 8 bytes, which is 16 bytes here  (0x10)
           int16_t audio_format;    // (2 bytes) : Audio format (1: PCM integer, 3: IEEE 754 float)
           int16_t channels;        // (2 bytes) : Number of channels
           int32_t frequency;       // (4 bytes) : Sample rate (in hertz)
           int32_t byte_per_sec;    // (4 bytes) : Number of bytes to read per second (Frequency * BytePerBloc).
           int16_t byte_per_bloc;   // (2 bytes) : Number of bytes per block (NbrChannels * BitsPerSample / 8).
           int16_t bits_per_sample; // (2 bytes) : Number of bits per sample
           int16_t ext_size;        // 0
   }

   struct chunk_header 
   {
           char chunk_id[4];          // (4 bytes) : Identifier « data »  (0x64, 0x61, 0x74, 0x61)
           int32_t chunk_size;   // (4 bytes) : SampledData size
   }

   struct fact_header 
   {
           char chunk_id[4];
           int32_t chunk_size;
           int32_t sample_length;
   }

   const int32_t AUDIO_FREQ = 44100;
   const int16_t AUDIO_CHANNELS = 2;

   const std::string ID_RIFF = "RIFF";
   const std::string ID_WAVE = "WAVE";

   const int16_t WAVE_FORMAT_PCM        = 1;
   const int16_t WAVE_FORMAT_IEEE_FLOAT = 3;
   const int16_t WAVE_FORMAT_ALAW       = 6;
   const int16_t WAVE_FORMAT_MULAW      = 7;
   //const int16_t WAVE_FORMAT_EXTENSIBLE = 0xFFFE;

   struct wave_data_header 
   {
        char chunk_id[4];         // (4 bytes) : Identifier « data »  (0x64, 0x61, 0x74, 0x61)
        int32_ti chunk_size: i32; // (4 bytes) : SampledData size
   }

   struct wav 
   {
	// config
	int16_t channels;
	int32_t frequency;

	// state
	int sample_idx;
	bool is_playing;

	// data
	float samples_raw[];
	float *samples;

	// metadata
	std::string file_path;
	std::string file_name;
	pcm_format_header format;

	std::chrono time;

        bool has_errors;
        std::vector<std::string> errors;
   }

}
#endif
