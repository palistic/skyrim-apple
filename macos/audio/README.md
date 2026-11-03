# Native WMA source audio

`runtime/audio_decode.c` is a platform-neutral native FFmpeg adapter enabled by
`SKYRIM_FFMPEG_AUDIO=1`. It decodes WMAv2 (`0x0161`) and WMAPro (`0x0162`) into
the existing source voice's interleaved S16 PCM buffer. The existing mixer handles
pitch, source-rate conversion, sends and output. There is no guest CPU JIT or
Windows decoder process. Without the macro, the existing Android build does not
link FFmpeg and keeps its original source-format behavior.

The adapter handles retained codec extradata and xWMA defaults, normalizes known
xWMA bitrate variants, preserves codec state across packet submissions, drains at
EOS/Discontinuity, bounds decoded allocation and rejects malformed metadata.
Native unsupported formats return an error instead of successful silent playback.
The XAudio2 shim copies guest `XAUDIO2_BUFFER_WMA` metadata before returning and
uses the existing buffer, loop and stream-end callback path.

## Private dependencies and public test media

No Homebrew libraries are shipped. Build minimal, pinned FFmpeg 7.1.2 static
`libavcodec` and `libavutil` in ignored project storage:

```sh
python3 macos/audio/build_ffmpeg.py macos --jobs 2
python3 macos/audio/build_ffmpeg.py simulator --jobs 2
python3 macos/audio/fetch_samples.py
```

Coordinate the two compiler jobs with other active builds. `--configure-only`
prepares configuration without the full compilation. An existing official source
tarball can be passed via `--source-archive`; its pinned SHA-256 is always checked.
The static archives target ARM64 macOS 13 and ARM64 iOS Simulator 16 respectively.
They are different platforms and must not be interchanged. Only WMAv2 and WMAPro
decoders are enabled; there are no network, autodetected host, GPL/nonfree, program,
encoder or other media dependencies. The LGPL license is retained with each build.

The sample helper pins two Microsoft DirectX SDK sample files and an FFmpeg FATE
file by source URL and SHA-256. Media stays in ignored `macos/build/audio-audit/`.
It is a private test corpus, not bundled game content or a redistribution grant.

If a local `ffmpeg` tool already exists, add an authored 440 Hz sine encoded as
ordinary WMAv2 with retained extradata:

```sh
python3 macos/audio/fetch_samples.py --authored
python3 macos/audio/reference_test.py --probe macos/build/native/audio_codec_probe
```

The normal CMake codec probe needs no Homebrew FFmpeg library. The optional
reference helper uses the local FFmpeg program only to produce independent PCM.

## Verified scope

- Real native decoder, four sample streams: Microsoft mono WMAv2, Microsoft
  six-channel WMAPro, FFmpeg stereo WMAv2, and an authored sine. Full-buffer,
  variable packet-streamed and reset decoding are byte-identical within the same
  adapter. Independent FFmpeg reference lengths match; observed S16 differences
  are at most one unit.
- Copied native codec executable ad-hoc signed with hardened runtime, **zero
  entitlements**, decodes all four streams successfully.
- `voice_probe.c` invokes the actual XAudio2 2.6 COM methods and existing mixer,
  using a dummy SDL device. It covers queue state, WMA metadata errors,
  decoded play region, two loops, source buffer/stream callbacks, decoder reuse,
  Discontinuity EOS, honest unsupported-format failure, and PCM16/MS ADPCM
  regressions. The flush extension verifies stopped/active queues, deferred
  processing-thread callbacks, reentrant submission, counter reset and 8,256
  accumulated notifications across the event-capacity boundary. See
  [FLUSH.md](FLUSH.md). No physical speaker playback is needed for this test.
- `macos/build/audio-audit/AUDIO-VALIDATION.json` binds the source hashes, private
  library manifests, decoder references, hardened copy and source-voice results.
  The later flush-specific source and binary hashes are recorded separately in
  `macos/build/audio-audit/flush-validation.json`.

Actual Skyrim assets and in-game music/voices remain untested. FFmpeg can output
fewer priming/tail samples than the file's final `dpds` count; the adapter retains
the actual decoded PCM without inventing padding. Exact Windows decoder timing,
long-buffer submission latency, device audio lifecycle, effects/reverb/filters and
speaker/headphone acceptance remain separate work. The current decoder runs
synchronously under the existing source-voice lock; game audio deadlines must be
measured once real content is available.

See [AUDIT.md](AUDIT.md) for the source-level cause and primary API references.
