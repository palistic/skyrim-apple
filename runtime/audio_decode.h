/* Native compressed-source decoder. No guest machine code is generated here. */
#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

typedef struct AudioDecoder AudioDecoder;
typedef struct {
    uint16_t tag, channels, block_align, bits;
    uint32_t sample_rate, avg_bytes;
    const uint8_t *extra;
    size_t extra_size;
} AudioDecodeFormat;

#ifdef SKYRIM_FFMPEG_AUDIO
AudioDecoder *audio_decode_open(const AudioDecodeFormat *format, char *error, size_t error_size);
/* Packet metadata is relative to this submitted buffer, as in XAUDIO2_BUFFER_WMA.
 * Returned interleaved S16 frames are owned by the caller and freed with free().
 * Decoder state persists between submissions; EOS drains and the next stream resets.
 * No rate conversion is performed: the existing voice mixer resamples source PCM.
 */
int audio_decode_buffer(AudioDecoder *decoder, const uint8_t *encoded, uint32_t bytes,
    const uint32_t *decoded_cumulative_bytes, uint32_t packets, int end_of_stream,
    int16_t **pcm, uint32_t *frames, char *error, size_t error_size);
void audio_decode_reset(AudioDecoder *decoder);
void audio_decode_close(AudioDecoder *decoder);
#endif
#ifdef __cplusplus
}
#endif
