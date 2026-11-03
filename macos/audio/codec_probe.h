/* Public-sample diagnostic, never part of the game's media loader. */
#pragma once
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct {
    unsigned checks, tag, channels, rate, packets, decoded_frames, metadata_frames;
    double rms;
    uint64_t pcm_hash;
} AudioCodecProbeResult;
int audio_codec_probe_file(const char *path, const char *pcm_output,
    AudioCodecProbeResult *result, char *error, size_t error_size);
#ifdef __cplusplus
}
#endif
