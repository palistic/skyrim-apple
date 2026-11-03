# Native xWMA audit

This records the baseline audit before the native decoder implementation. See
[README.md](README.md) for the implemented feature and verified scope.

The original silence is a missing codec path in `runtime/xaudio2.c`, not an SDL
device or JIT issue. `set_format` recognizes PCM, IEEE float and MS ADPCM only.
WMA tags `0x0161` and `0x0162` become `FMT_NONE`; submission accepts the buffer,
sets its decoded frame count to zero and returns success. The second argument to
`SubmitSourceBuffer`, `XAUDIO2_BUFFER_WMA`, is ignored. The mixer then completes
the empty buffer without any audio.

## Small implementation seam

Keep the existing source-voice queue, mixer, resampling, sends and callbacks.
Add a native FFmpeg decoder per WMA voice, guarded by `SKYRIM_FFMPEG_AUDIO`, and
fill the existing interleaved `XBuf.decoded` signed-16 PCM path. Preserve the PCM
and MS ADPCM branches. Keep Android builds unchanged when the macro is absent.

The backend should accept a normalized format (tag, channels, rate, byte rate,
block alignment, bits, codec extradata), encoded packet buffer, packet count,
decoded-packet cumulative byte table and end-of-stream flag. It must copy input
into padded FFmpeg packets, preserve decoder state across submissions, drain at
EOS, validate bounds and reject unsupported/corrupt input rather than report
successful silent completion. WMA buffers cannot be treated as fixed PCM frames.

Microsoft defines the cumulative table in decoded bytes relative to each submitted
buffer. Packet count is nonzero and divides `AudioBytes`. Caller structures can
be released after submission; actual referenced data remains valid until buffer
completion. Play/loop positions refer to decoded samples.

For ordinary WMA, retain codec extradata. For xWMA with no codec extradata, use
the documented FFmpeg xWMA initialization: WMAv2 gets six zeroed bytes with byte
4 set to 31; WMAPro gets 18 zeroed bytes with bits-per-sample at byte 0 and byte
14 set to 224. Normalize known fake xWMA bitrates as FFmpeg does. Extracting a
WAVEFORMATEXTENSIBLE subtype must not mistake the subtype GUID for codec extradata.

## Available native decoder and test corpus

- Local Homebrew FFmpeg 8.0.1 provides WMAv2 encoding, WMAv2/WMAPro decoding and
  an xWMA demuxer. Its `libavcodec` has minimum macOS **26.0**, so it is a probe
  tool, not the macOS-13/Simulator shipping dependency.
- A previously cached official FFmpeg **7.1.2** source tarball can be reused after
  SHA-256 verification (`089bc60fb59d6aecc5d994ff530fd0dcb3ee39aa55867849a2bbc4e555f9c304`).
  Existing iPhoneOS archives are device-only and have the wrong codec set; they
  must not be relabeled or reused as Simulator libraries.
- Pin minimal private `libavcodec`/`libavutil` builds for ARM64 macOS 13 and ARM64
  iOS Simulator, with WMAv2/WMAPro decoders, no autodetected host dependencies,
  no network, no GPL/nonfree components, no runtime CPU translation.
- Microsoft DirectX SDK samples at commit
  `07e3eaa10e7dd026ec9d95fe326db2d5c4227e1b` provide genuine public xWMA test media:
  `musicmono_xwma.wav` (WMAv2, mono 44.1kHz), SHA-256
  `2baaaf89c6a949f9eec61a167fe953097e09dbffd7c5685d0162fa2a9eafa0a1`;
  `musicsurround_xwma.wav` (WMAPro, 6ch 48kHz), SHA-256
  `12ea6a97c00ca43c54aaa0c7d804bed635df4d0c36f2a99a74d1effc7c3258c3`.
  Keep downloaded media in ignored private build output; do not redistribute it.
- FFmpeg's official FATE xWMA test uses `ergon.xwma`, SHA-256
  `3e25391489c17b134f4cf908def2a6b8932d973137aaf7a56445d57d89798237`.

## Meaningful test plan

1. Encode an authored sine with local FFmpeg and verify ordinary WMAv2 decoding,
   amplitude, frame count and channel layout using the actual codec adapter.
2. Exercise the Microsoft WMAv2 and WMAPro xWMA corpus with omitted codec
   extradata; compare full-buffer versus packet-streamed decoding and a native
   FFmpeg PCM reference. Record decoder priming/tail behavior: the current FFmpeg
   command output is 770048/5020536 bytes, while the two files' final `dpds`
   values are 771072/5045112 bytes. Those differences must not be hidden by a
   falsely exact duration claim.
3. Invoke the real XAudio2 COM shims against guest-memory buffers: queue, start,
   decoded play region, loops, flush, `GetState`, buffer-end and stream-end
   callbacks. Verify PCM/ADPCM regressions and honest unsupported-format errors.
4. Reject missing/nonmonotonic packet metadata, bad packet count, malformed
   extradata, truncation, oversized decoded duration and unsupported codec tags.
5. Build and execute the same native adapter in the iPad Simulator. This remains
   codec/runtime proof, not evidence of Skyrim's actual asset coverage or audio.

## Primary references

- [Microsoft XAUDIO2_BUFFER_WMA](https://learn.microsoft.com/en-us/windows/win32/api/xaudio2/ns-xaudio2-xaudio2_buffer_wma)
- [Microsoft SubmitSourceBuffer](https://learn.microsoft.com/en-us/windows/win32/api/xaudio2/nf-xaudio2-ixaudio2sourcevoice-submitsourcebuffer)
- [FFmpeg 7.1.2 xWMA demuxer](https://github.com/FFmpeg/FFmpeg/blob/n7.1.2/libavformat/xwma.c)
- [FFmpeg 7.1.2 WMA decoder](https://github.com/FFmpeg/FFmpeg/blob/n7.1.2/libavcodec/wmadec.c)
- [FFmpeg 7.1.2 WMAPro decoder](https://github.com/FFmpeg/FFmpeg/blob/n7.1.2/libavcodec/wmaprodec.c)
- [Microsoft sample media](https://github.com/microsoft/DirectX-SDK-Samples/tree/07e3eaa10e7dd026ec9d95fe326db2d5c4227e1b/Media/Wavs)
- [FFmpeg FATE xWMA test](https://github.com/FFmpeg/FFmpeg/blob/n7.1.2/tests/fate/demux.mak#L154-L155)
