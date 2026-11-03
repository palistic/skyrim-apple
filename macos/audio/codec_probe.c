#include "codec_probe.h"
#include "audio_decode.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint16_t u16(const uint8_t *p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t u32(const uint8_t *p) { return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24; }
#define REQUIRE(test, message) do { ++r->checks; if (!(test)) { snprintf(error, error_size, "%s", message); goto failed; } } while (0)

int audio_codec_probe_file(const char *path, const char *pcm_output,
    AudioCodecProbeResult *r, char *error, size_t error_size) {
    uint8_t *bytes = NULL;
    uint32_t *cumulative = NULL;
    int16_t *whole = NULL, *streamed = NULL, *again = NULL;
    AudioDecoder *decoder = NULL;
    FILE *file = fopen(path, "rb");
    memset(r, 0, sizeof *r);
    REQUIRE(file != NULL, "cannot open official audio fixture");
    REQUIRE(fseek(file, 0, SEEK_END) == 0, "cannot seek audio fixture");
    long length = ftell(file);
    REQUIRE(length >= 12 && length <= 64 * 1024 * 1024, "audio fixture size is invalid");
    rewind(file);
    bytes = malloc((size_t)length);
    REQUIRE(bytes != NULL, "cannot allocate audio fixture");
    REQUIRE(fread(bytes, 1, (size_t)length, file) == (size_t)length, "audio fixture short read");
    fclose(file); file = NULL;
    REQUIRE(!memcmp(bytes, "RIFF", 4) && !memcmp(bytes + 8, "XWMA", 4), "fixture is not RIFF xWMA");
    const uint8_t *fmt = NULL, *dpds = NULL, *data = NULL;
    uint32_t fmt_size = 0, dpds_size = 0, data_size = 0;
    for (size_t offset = 12; offset + 8 <= (size_t)length;) {
        uint32_t size = u32(bytes + offset + 4);
        REQUIRE((uint64_t)offset + 8 + size <= (size_t)length, "audio fixture chunk exceeds file");
        if (!memcmp(bytes + offset, "fmt ", 4)) { fmt = bytes + offset + 8; fmt_size = size; }
        if (!memcmp(bytes + offset, "dpds", 4)) { dpds = bytes + offset + 8; dpds_size = size; }
        if (!memcmp(bytes + offset, "data", 4)) { data = bytes + offset + 8; data_size = size; }
        offset += 8 + (uint64_t)size + (size & 1);
    }
    REQUIRE(fmt && fmt_size >= 18 && dpds && dpds_size >= 4 && !(dpds_size & 3) && data, "audio fixture missing required chunks");
    AudioDecodeFormat format = {u16(fmt), u16(fmt + 2), u16(fmt + 12), u16(fmt + 14),
        u32(fmt + 4), u32(fmt + 8), fmt + 18, u16(fmt + 16)};
    REQUIRE(18 + format.extra_size <= fmt_size, "format extra data exceeds fixture chunk");
    if (format.tag == 0xfffe) {
        REQUIRE(format.extra_size >= 22, "invalid extensible fixture format");
        format.tag = u16(fmt + 24);
        format.extra += 22;
        format.extra_size -= 22;
    }
    r->tag = format.tag; r->channels = format.channels; r->rate = format.sample_rate;
    r->packets = dpds_size / 4;
    REQUIRE(format.block_align && data_size % format.block_align == 0 &&
        data_size / format.block_align == r->packets, "packet count and block alignment differ");
    cumulative = malloc(dpds_size);
    REQUIRE(cumulative != NULL, "cannot allocate fixture packet metadata");
    for (unsigned n = 0; n < r->packets; ++n) cumulative[n] = u32(dpds + 4 * n);
    r->metadata_frames = cumulative[r->packets - 1] / (2 * r->channels);
    decoder = audio_decode_open(&format, error, error_size);
    REQUIRE(decoder != NULL, "native decoder failed to open official xWMA format");
    uint32_t whole_frames = 0;
    REQUIRE(audio_decode_buffer(decoder, data, data_size, cumulative, r->packets, 1,
        &whole, &whole_frames, error, error_size) == 0, "native official xWMA decode failed");
    REQUIRE(whole && whole_frames > 0 && whole_frames <= r->metadata_frames,
        "native xWMA decode has invalid frame count");
    r->decoded_frames = whole_frames;
    double energy = 0;
    r->pcm_hash = 1469598103934665603ull;
    for (size_t n = 0; n < (size_t)whole_frames * r->channels; ++n) {
        double sample = whole[n] / 32768.0;
        energy += sample * sample;
        r->pcm_hash ^= (uint8_t)whole[n]; r->pcm_hash *= 1099511628211ull;
        r->pcm_hash ^= (uint8_t)((uint16_t)whole[n] >> 8); r->pcm_hash *= 1099511628211ull;
    }
    r->rms = sqrt(energy / ((size_t)whole_frames * r->channels));
    REQUIRE(r->rms > 0.0001 && r->rms < 1, "official xWMA decoded to silence or invalid amplitude");

    /* One codec instance, variable-size submissions, buffer-relative dpds data. */
    size_t streamed_frames = 0;
    for (unsigned n = 0; n < r->packets;) {
        unsigned count = 1 + n % 5;
        if (count > r->packets - n) count = r->packets - n;
        uint32_t relative[5], previous = n ? cumulative[n - 1] : 0;
        for (unsigned k = 0; k < count; ++k) relative[k] = cumulative[n + k] - previous;
        uint32_t count_frames = 0;
        int16_t *part = NULL;
        REQUIRE(audio_decode_buffer(decoder, data + (size_t)n * format.block_align,
            count * format.block_align, relative, count, n + count == r->packets,
            &part, &count_frames, error, error_size) == 0, "streamed native xWMA submission failed");
        size_t joined_frames = streamed_frames + count_frames;
        int16_t *joined = realloc(streamed, (joined_frames ? joined_frames : 1) * r->channels * sizeof(int16_t));
        if (!joined) { free(part); REQUIRE(0, "cannot allocate streamed fixture result"); }
        streamed = joined;
        if (count_frames) memcpy(streamed + streamed_frames * r->channels, part,
            (size_t)count_frames * r->channels * sizeof(int16_t));
        free(part);
        streamed_frames = joined_frames;
        n += count;
    }
    REQUIRE(streamed_frames == whole_frames && !memcmp(streamed, whole,
        (size_t)whole_frames * r->channels * sizeof(int16_t)), "packet-streamed PCM differs from full-buffer decode");

    audio_decode_reset(decoder);
    uint32_t again_frames = 0;
    REQUIRE(audio_decode_buffer(decoder, data, data_size, cumulative, r->packets, 1,
        &again, &again_frames, error, error_size) == 0, "native xWMA reset decode failed");
    REQUIRE(again_frames == whole_frames && !memcmp(again, whole,
        (size_t)whole_frames * r->channels * sizeof(int16_t)), "reset decoder changed PCM output");
    free(again); again = NULL;
    uint32_t negative_frames = 0;
    uint32_t invalid[2] = {4u * r->channels, 0};
    REQUIRE(audio_decode_buffer(decoder, data, 2 * format.block_align, invalid, 2, 0,
        &again, &negative_frames, error, error_size) < 0 && again == NULL && negative_frames == 0,
        "descending packet metadata was accepted");
    REQUIRE(audio_decode_buffer(decoder, data, data_size - 1, cumulative, r->packets, 0,
        &again, &negative_frames, error, error_size) < 0,
        "misaligned compressed packet buffer was accepted");
    format.tag = 0x9999;
    AudioDecoder *unsupported = audio_decode_open(&format, error, error_size);
    REQUIRE(unsupported == NULL, "unsupported source codec was accepted");
    if (pcm_output) {
        file = fopen(pcm_output, "wb");
        REQUIRE(file != NULL, "cannot write private diagnostic PCM result");
        size_t samples = (size_t)whole_frames * r->channels;
        REQUIRE(fwrite(whole, sizeof(int16_t), samples, file) == samples, "short diagnostic PCM write");
        fclose(file); file = NULL;
    }
    audio_decode_close(decoder);
    free(bytes); free(cumulative); free(whole); free(streamed);
    if (error_size) error[0] = 0;
    return 0;
failed:
    if (file) fclose(file);
    audio_decode_close(decoder);
    free(bytes); free(cumulative); free(whole); free(streamed); free(again);
    return -1;
}

#ifdef AUDIO_CODEC_PROBE_MAIN
int main(int argc, char **argv) {
    if (argc < 2 || argc > 3) { fprintf(stderr, "usage: audio_codec_probe SAMPLE [PRIVATE_PCM_OUTPUT]\n"); return 2; }
    AudioCodecProbeResult r;
    char error[256];
    if (audio_codec_probe_file(argv[1], argc == 3 ? argv[2] : NULL, &r, error, sizeof error)) {
        fprintf(stderr, "native audio probe failed: %s\n", error); return 1;
    }
    printf("{\"pass\":true,\"checks\":%u,\"tag\":%u,\"channels\":%u,\"rate\":%u,"
        "\"packets\":%u,\"decoded_frames\":%u,\"metadata_frames\":%u,\"rms\":%.9f,\"pcm_fnv1a64\":\"%016llx\",\"gameplay_tested\":false}\n",
        r.checks,r.tag,r.channels,r.rate,r.packets,r.decoded_frames,r.metadata_frames,r.rms,(unsigned long long)r.pcm_hash);
    return 0;
}
#endif
