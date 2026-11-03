# Source-buffer flushing

The earlier shim marked removed buffers exhausted but left them queued until
the source ran again. A stopped voice could retain its queue indefinitely, and
removed buffers could subsequently receive `OnBufferStart` incorrectly.

`FlushSourceBuffers` now detaches removed buffers under the queue lock. It keeps
the current buffer only when the source is running and that buffer has actually
started. Removed contexts enter a separate pending-end list; the engine delivers
only `OnBufferEnd` for them during its processing pass, outside the queue lock.
It does this for stopped sources too. A stopped engine preserves these pending
notifications until processing resumes. Repeated flushes append to the list.

Flushed ends are recorded before normal mixing, so they precede the retained
active buffer's eventual end. If the per-pass event array fills, remaining
notifications wait for the next pass. A voice with undelivered flushed ends is
held from mixing, and a full event array does not advance sources. Submission
after a stopped-source flush resets the played counter and resampling state;
failed submission does not reset the counter. Source Start/Stop uses the same
queue lock as flush and mixing.

Native unsupported formats now log `rejected`, matching their failure HRESULT.
The macro-off legacy format log keeps its existing wording.

## Contract sources

- [Microsoft FlushSourceBuffers](https://learn.microsoft.com/en-us/windows/win32/api/xaudio2/nf-xaudio2-ixaudio2sourcevoice-flushsourcebuffers):
  stopped/started use, active-buffer retention, removed-buffer callback types,
  callback ordering, running-state preservation and stopped-source counter reset.
- [Microsoft XAudio2 callbacks](https://learn.microsoft.com/en-us/windows/win32/xaudio2/xaudio2-callbacks):
  callbacks execute on the audio processing thread. Consequently flush does not
  invoke guest callbacks synchronously on an arbitrary calling thread.
- [Microsoft StopEngine](https://learn.microsoft.com/en-us/windows/win32/api/xaudio2/nf-xaudio2-ixaudio2-stopengine):
  processing stops while voice state and pending buffers are preserved. The test
  does not call StopEngine from a callback, which the contract forbids.

## Reproduce

From the repository root, with the existing private dependencies and public
Microsoft sample prepared:

```sh
cmake --build macos/build/native --target audio_voice_probe --parallel 1
ctest --test-dir macos/build/native -R '^audio_voice_queue$' --output-on-failure
```

The probe uses the real XAudio2 2.6 COM shim, guest memory, mixer and engine
thread. Authored callback shims record context, order and native thread identity.
It verifies stopped sources, stopped formerly-active buffers, active retention,
source running-state preservation, EOS/loop suppression for removed buffers,
counter reset on reuse, engine-stop deferral and engine-thread reentry through
GetState/Submit/Flush/Submit. Another case starts a source while the engine is
paused, proving that an unplayed first buffer is removed. The stress case
accumulates 8,256 distinct end contexts while processing is paused, crossing both
the source queue's 64 entries and the event array's 8,192 entries, then verifies
each end exactly once and in order, with no start or loop callback for any.

`macos/build/audio-audit/flush-validation.json` records the passing invocation,
source/object/binary/fixture hashes, thread IDs and the JSON result. The baseline
WMA play-region/loop/reuse, PCM16 and MS ADPCM checks run in the same process.
The SDL output is a dummy device; this proves queue/mixer/callback behavior and
does not prove audible playback, actual game behavior or audio deadlines. The
StopEngine case allows an already-entered pass to settle and does not assert a
synchronous stop fence. General simultaneous normal-buffer event overflow is a
pre-existing limitation outside this change.
