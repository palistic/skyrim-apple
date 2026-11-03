/* Native FFmpeg WMA source decoding for Apple targets. The existing Android
 * runtime is unchanged when SKYRIM_FFMPEG_AUDIO is absent. */
#include "audio_decode.h"
#ifdef SKYRIM_FFMPEG_AUDIO
#include <libavcodec/avcodec.h>
#include <libavutil/channel_layout.h>
#include <libavutil/error.h>
#include <libavutil/mem.h>
#include <libavutil/samplefmt.h>
#include <limits.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

/* Bound one queued decompressed buffer without depending on guest allocations. */
#define MAX_DECODED_BYTES (256u * 1024u * 1024u)
#define MAX_PACKET_COUNT (1024u * 1024u)

struct AudioDecoder {
    AVCodecContext *context;
    AVFrame *frame;
    unsigned channels, sample_rate;
    int ended;
};

static int error_text(char *text, size_t size, const char *message) {
    if (size) snprintf(text, size, "%s", message);
    return -1;
}

static int codec_error(char *text, size_t size, const char *message, int code) {
    char detail[AV_ERROR_MAX_STRING_SIZE];
    av_strerror(code, detail, sizeof detail);
    if (size) snprintf(text, size, "%s: %s", message, detail);
    return -1;
}

static int normalized_xwma_bitrate(const AudioDecodeFormat *f) {
    uint64_t bits = (uint64_t)f->avg_bytes * 8;
    if (bits > INT_MAX) return -1;
    int rate = (int)bits;
    /* xWMA encoder combinations whose header rate differs from codec data.
     * These compatibility values match FFmpeg's public xWMA demuxer. */
    if (f->tag == 0x161 && !f->extra_size) {
        if (f->channels == 1) {
            if ((f->sample_rate == 22050 || f->sample_rate == 32000) &&
                (rate == 48000 || rate == 192000)) rate = 20000;
            else if (f->sample_rate == 44100 && (rate == 96000 || rate == 192000)) rate = 48000;
        } else if (f->channels == 2) {
            if (f->sample_rate == 22050 && (rate == 48000 || rate == 192000)) rate = 32000;
            else if (f->sample_rate == 32000 && rate == 192000) rate = 48000;
        }
    }
    return rate;
}

AudioDecoder *audio_decode_open(const AudioDecodeFormat *f, char *error, size_t size) {
    if (!f || (f->tag != 0x161 && f->tag != 0x162) || !f->channels || f->channels > 8 ||
        f->sample_rate < 8000 || f->sample_rate > 192000 || !f->block_align ||
        !f->avg_bytes || !f->bits || f->bits > 32 || f->extra_size > 65535 ||
        (f->extra_size && !f->extra)) {
        error_text(error, size, "unsupported or invalid WMA source format");
        return NULL;
    }
    int bitrate = normalized_xwma_bitrate(f);
    if (bitrate < 0) { error_text(error, size, "WMA bitrate overflow"); return NULL; }
    enum AVCodecID id = f->tag == 0x161 ? AV_CODEC_ID_WMAV2 : AV_CODEC_ID_WMAPRO;
    const AVCodec *codec = avcodec_find_decoder(id);
    if (!codec) { error_text(error, size, "required native WMA decoder is not built"); return NULL; }
    AudioDecoder *d = calloc(1, sizeof *d);
    if (!d) { error_text(error, size, "cannot allocate WMA decoder"); return NULL; }
    d->context = avcodec_alloc_context3(codec);
    d->frame = av_frame_alloc();
    if (!d->context || !d->frame) { audio_decode_close(d); error_text(error, size, "cannot allocate WMA codec state"); return NULL; }
    d->channels = f->channels;
    d->sample_rate = f->sample_rate;
    AVCodecContext *c = d->context;
    c->sample_rate = (int)f->sample_rate;
    c->bit_rate = bitrate;
    c->block_align = f->block_align;
    c->bits_per_coded_sample = f->bits;
    c->thread_count = 1;
    av_channel_layout_default(&c->ch_layout, f->channels);
    c->extradata_size = (int)(f->extra_size ? f->extra_size : f->tag == 0x161 ? 6 : 18);
    c->extradata = av_mallocz((size_t)c->extradata_size + AV_INPUT_BUFFER_PADDING_SIZE);
    if (!c->extradata) { audio_decode_close(d); error_text(error, size, "cannot allocate WMA codec header"); return NULL; }
    if (f->extra_size) memcpy(c->extradata, f->extra, f->extra_size);
    else if (f->tag == 0x161) c->extradata[4] = 31;
    else { c->extradata[0] = (uint8_t)f->bits; c->extradata[14] = 224; }
    int result = avcodec_open2(c, codec, NULL);
    if (result < 0) { audio_decode_close(d); codec_error(error, size, "cannot open WMA decoder", result); return NULL; }
    return d;
}

static int append_frame(AudioDecoder *d, int16_t **pcm, size_t *samples, size_t *capacity,
                        char *error, size_t size) {
    AVFrame *f = d->frame;
    if (f->ch_layout.nb_channels != (int)d->channels || f->sample_rate != (int)d->sample_rate || f->nb_samples < 0)
        return error_text(error, size, "WMA decoded format changed unexpectedly");
    size_t count = (size_t)f->nb_samples * d->channels;
    if (count > MAX_DECODED_BYTES / sizeof(int16_t) || *samples > MAX_DECODED_BYTES / sizeof(int16_t) - count)
        return error_text(error, size, "WMA decoded buffer exceeds memory bound");
    size_t needed = *samples + count;
    if (needed > *capacity) {
        size_t grown = *capacity ? *capacity : 8192;
        while (grown < needed) grown = grown > MAX_DECODED_BYTES / sizeof(int16_t) / 2 ? MAX_DECODED_BYTES / sizeof(int16_t) : grown * 2;
        int16_t *next = realloc(*pcm, grown * sizeof(int16_t));
        if (!next) return error_text(error, size, "cannot allocate decoded WMA samples");
        *pcm = next; *capacity = grown;
    }
    enum AVSampleFormat format = (enum AVSampleFormat)f->format;
    for (int n = 0; n < f->nb_samples; ++n) {
        for (unsigned ch = 0; ch < d->channels; ++ch) {
            int16_t value;
            size_t offset = (size_t)n * d->channels + ch;
            if (format == AV_SAMPLE_FMT_S16) value = ((const int16_t *)f->data[0])[offset];
            else if (format == AV_SAMPLE_FMT_S16P) value = ((const int16_t *)f->extended_data[ch])[n];
            else {
                float sample;
                if (format == AV_SAMPLE_FMT_FLTP) sample = ((const float *)f->extended_data[ch])[n];
                else if (format == AV_SAMPLE_FMT_FLT) sample = ((const float *)f->data[0])[offset];
                else return error_text(error, size, "unsupported WMA decoder sample format");
                long rounded = !isfinite(sample) ? 0 : sample >= 1 ? 32767 : sample <= -1 ? -32768 : lrintf(sample * 32768.0f);
                value = (int16_t)(rounded > 32767 ? 32767 : rounded < -32768 ? -32768 : rounded);
            }
            (*pcm)[*samples + offset] = value;
        }
    }
    *samples = needed;
    return 0;
}

static int receive_frames(AudioDecoder *d, int16_t **pcm, size_t *samples, size_t *capacity,
                          char *error, size_t size) {
    for (;;) {
        int result = avcodec_receive_frame(d->context, d->frame);
        if (result == AVERROR(EAGAIN) || result == AVERROR_EOF) return 0;
        if (result < 0) return codec_error(error, size, "WMA decode failed", result);
        int appended = append_frame(d, pcm, samples, capacity, error, size);
        av_frame_unref(d->frame);
        if (appended < 0) return -1;
    }
}

int audio_decode_buffer(AudioDecoder *d, const uint8_t *encoded, uint32_t bytes,
    const uint32_t *cumulative, uint32_t packets, int eos,
    int16_t **pcm, uint32_t *frames, char *error, size_t size) {
    if (!pcm || !frames) return error_text(error, size, "missing WMA output pointers");
    *pcm = NULL; *frames = 0;
    if (!d || (!packets && (bytes || !eos)) || packets > MAX_PACKET_COUNT ||
        (packets && (!encoded || !cumulative || !bytes || bytes % packets)))
        return error_text(error, size, "invalid WMA packet buffer");
    uint32_t previous = 0;
    for (uint32_t n = 0; n < packets; ++n) {
        if (cumulative[n] < previous || cumulative[n] % (2 * d->channels) || cumulative[n] > MAX_DECODED_BYTES)
            return error_text(error, size, "invalid WMA decoded-packet cumulative bytes");
        previous = cumulative[n];
    }
    uint32_t packet_bytes = packets ? bytes / packets : 0;
    if (packet_bytes > INT_MAX || (packets && packet_bytes != (uint32_t)d->context->block_align))
        return error_text(error, size, "WMA packet size does not match source block alignment");
    if (d->ended && packets) audio_decode_reset(d);
    size_t samples = 0, capacity = 0;
    AVPacket *packet = av_packet_alloc();
    if (!packet) return error_text(error, size, "cannot allocate WMA packet");
    for (uint32_t n = 0; n < packets; ++n) {
        int result = av_new_packet(packet, (int)packet_bytes);
        if (result < 0) { codec_error(error, size, "cannot allocate padded WMA packet", result); goto failed; }
        memcpy(packet->data, encoded + (size_t)n * packet_bytes, packet_bytes);
        result = avcodec_send_packet(d->context, packet);
        av_packet_unref(packet);
        if (result < 0) { codec_error(error, size, "cannot submit WMA packet", result); goto failed; }
        if (receive_frames(d, pcm, &samples, &capacity, error, size) < 0) goto failed;
    }
    if (eos && !d->ended) {
        int result = avcodec_send_packet(d->context, NULL);
        if (result < 0 && result != AVERROR_EOF) { codec_error(error, size, "cannot drain WMA decoder", result); goto failed; }
        if (receive_frames(d, pcm, &samples, &capacity, error, size) < 0) goto failed;
        d->ended = 1;
    }
    av_packet_free(&packet);
    *frames = (uint32_t)(samples / d->channels);
    return 0;
failed:
    av_packet_free(&packet);
    free(*pcm); *pcm = NULL; *frames = 0;
    audio_decode_reset(d);
    return -1;
}

void audio_decode_reset(AudioDecoder *d) {
    if (!d) return;
    avcodec_flush_buffers(d->context);
    av_frame_unref(d->frame);
    d->ended = 0;
}

void audio_decode_close(AudioDecoder *d) {
    if (!d) return;
    av_frame_free(&d->frame);
    avcodec_free_context(&d->context);
    free(d);
}
#endif
