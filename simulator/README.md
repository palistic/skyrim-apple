> **Historical development reference.** The current public build targets iOS/iPadOS and has physical iPad Pro acceptance. See the [root README](../README.md) and the [current build guide](../docs/BUILDING.md). Status and launcher holds below describe the earlier prototype, not current iPad support.

# iPad Simulator port

This target compiles the actual Windows Skyrim compatibility runtime, native
DXVK Direct3D 9, bundled SDL2 and MoltenVK for ARM64 iOS Simulator. The default
app is a game-free diagnostic. With `--game` it builds the actual Skyrim app
from the private code generated from the owner's original Windows executable,
matching DLLs and game assets; that app now boots and renders the game world in
the dedicated simulator ([game results](#game-results-2026-11-01)).

## Build and run

Use Apple Silicon macOS with Xcode, the iOS Simulator SDK/runtime, CMake, Ninja
and the Python environment prepared by the macOS setup. Commands run from the
repository root. Coordinate the maximum two compiler jobs with other work.

```sh
python3 simulator/bootstrap.py --jobs 2
python3 macos/audio/build_ffmpeg.py simulator --jobs 2
python3 macos/audio/fetch_samples.py
sh simulator/build.sh --audio --jobs 2
python3 simulator/run_probe.py
```

`bootstrap.py` pins MoltenVK v1.4.2 commit
`db66022459ffb663aa2b50f6b018bc2e124f5edf`, fetches its pinned dependencies and
builds a genuine `ios-arm64-simulator` slice. The device-only release library
cannot replace that slice. SDL2 builds from the existing pinned vendor source;
`prepare_sdl.py` applies the required UIKit scene lifecycle adaptation only to
an ignored build copy. macOS/vendor SDL files stay intact.

The audio build uses the private FFmpeg libraries and public sample corpus
described in [the audio notes](../macos/audio/README.md). Omit `--audio` for a
diagnostic without that backend. `--jobs 1` permits a concurrent single-job
build elsewhere. The app, dependencies, generated fixture and evidence remain
in ignored local directories.

`run_probe.py` creates or reuses only its recorded `Skyrim JITless iPad`
simulator, installs the signed diagnostic and launches it with ordinary
`simctl launch`. It preserves other simulators and game saves. It leaves its
dedicated simulator running, saves separate timestamped logs and refuses to
accept a failed CPU/GPU or enabled-audio result.

## Verified diagnostic scope

The 2026-10-26 ordinary launch on an iPad Pro 13-inch M5 simulator, iOS 27,
passed the following checks with an actual iOS Simulator SDK 27.1 build:

- Authored PE32 x86 code translated through the real lifter into native ARM64:
  19/19 assertions covering runtime threads, flags, calls, memory, SSE, x87,
  atomics, copies and Windows FS-relative access. A Mach VM walk covered all
  4 GiB of guest data across 32 regions; none was executable.
- Real Direct3D 9 import and guest COM texture methods: an authored DXT1 block
  passed compressed guest lock/unlock, the existing BC texture emulation,
  host texture upload, GPU sampling and readback. The Simulator reports no
  native BC texture support.
- DXVK → MoltenVK → Metal red clear and green triangle: GPU readback passed,
  with 2,920 red pixels, 1,176 green pixels and RGB FNV-1a64
  `e21c8a537cb574b5`.
- Native WMAv2 mono and WMAPro six-channel decode: 69 checks, 385,024 and
  418,378 decoded frames respectively, including packet-streamed and reset
  equivalence and invalid-input rejection. Speaker playback was not tested.

The visible app explicitly labels the authored diagnostic and the absence of
gameplay. `build/app-build-receipt.json` binds compiled source hashes and actual
Simulator binary hashes/platform metadata. `evidence/launch-receipt.json`
binds that build to the launched binary, process, results and dedicated device;
`evidence/probe.png` is the inspected screenshot. No debugger or CPU JIT is used.

The current SDL adaptation logs an unbalanced appearance transition on first
presentation. The diagnostic remains visible and usable. The game app has
since rendered for up to about 35 minutes in one session (PID 50939) and
paces presents at 60 fps;
lifecycle/background behavior, orientation and long sessions still need
validation. This is Simulator work, not physical iPad acceptance.

## Private game target

`game_app.cpp` and `game_inputs.mm` compile as an unlinked frontend during the
default build. Once the macOS input workflow has generated and verified the
original Windows game code (see the [macOS notes](../macos/README.md)), this
command builds the separate game app:

```sh
sh simulator/build.sh --game --audio --jobs 2
```

That target requires verified private `gen/`; it links the real generated
Windows code and calls the real runtime entrypoint. Its app resource binds
exact module and essential-data hashes to the generated manifest without
embedding host paths. Before execution it checks the matching complete game
under its own `Documents/Skyrim`; saves use separate `Documents/SkyrimSaves`.

After an Xcode/Simulator SDK update add `--fresh` to discard the stale CMake
cache. The simulator build gives guest-code threads the Mac's 8 MiB host
stacks (`GUEST_HOST_STACK`, otherwise 512 KiB on iOS). `run_game.py` checks
the game build receipt, gen/ binding and the private game view read-only, then
boots only the recorded simulator, installs the app, APFS-clones (never copies
or links) the view into `Documents/Skyrim` and launches with ordinary
`simctl launch`; `--preflight-only` stops before any simulator command.

### Build, preflight and launch

```sh
sh simulator/build.sh --game --audio --jobs 2
macos/.venv/bin/python simulator/run_game.py --preflight-only
macos/.venv/bin/python simulator/run_game.py --env LB_LOG=1 \
    --env LB_SHOT=1500,2300,4000,9000,12000 \
    --env LB_KEYS=2000:Return:10,2600:Space:10 --watch-seconds 300
```

The last command is sim boot 1's launch. The full game build is 490 steps; the
coordinator's fresh two-job build took about 10 minutes (12:41:17–12:51:15Z
on 2026-11-01), and an incremental relink takes seconds. `--game-dir` defaults
to the view `gen/` was generated from. Each launch writes
`simulator/evidence/game-launch-<UTC>.json` and `game-<UTC>.stdout.log` /
`.stderr.log`; `LB_SHOT` captures go to `Documents/SkyrimSaves` in the app
container. `--env` values reach the game through `SIMCTL_CHILD_`; the switches
are listed in the [macOS notes](../macos/README.md#verification-switches). The
game app defaults to discrete Metal bindings
(`MVK_CONFIG_USE_METAL_ARGUMENT_BUFFERS=0`), and an `--env` value overrides it.

### Game results (2026-11-01)

Dedicated `Skyrim JITless iPad` simulator (5D0E7675…, iPad Pro 13-inch M5,
iOS 27.0). Evidence is git-ignored in `macos/evidence/` and
`simulator/evidence/`; the timeline is `macos/evidence/native-game-handoff.md`,
N10–N21.

| Boot (UTC) | Configuration | Result |
|---|---|---|
| 1, 12:53:28Z | first build | Frame 1800, then MoltenVK rejected draws with a non-zero base vertex and the submissions failed |
| 2, 12:56:53Z | base-vertex fold | New Game confirmation menu; RGBA16F cube render targets failed to create, then the game read through a null texture |
| 3, 13:00:49Z | multi-layer attachment check | Opening cart scene in 3D at 1376×1032 (frame 4000); Skyrim's new-game autosave written in the container; 8–13 fps, bound in the Simulator's serialized argument encoder |
| 4, 13:07Z | discrete Metal bindings | Helgen character creation (frame 9000); about 145 fps uncapped; 0 errors |
| 5, 13:14Z | imported copy of the Mac console save | Riverwood through CONTINUE; F5 wrote `quicksave.ess`. The F9 result was inconclusive and is not claimed |
| 6, 13:20Z | DXVK `maxFrameRate` 60 | About 4 fps startup crawl from lock contention; design replaced |
| 7, 13:29Z | bridge pacing and reviewed fold (`66000c1`) | 60–65 fps; 0 pipeline, texture or base-vertex errors. Scripted D strafe, then F9 restored the quicksave viewpoint |
| 8, 13:47Z | iOS input parity before the DualSense filter, `LB_VPAD=0` with scripted keys | PC main menu, but the log showed `input: XInput pad 0 is Gamepad`, the Simulator's own controller, which led to the DualSense-only filter (`sim-boot8-kbmode-run.out`) |
| 9, 13:53Z | shared Apple input policy (`5c52657`), `LB_LOG=1` only | No virtual pad, generic controller ignored. Real OS keys through the Simulator viewer: menus, movement and console save/load ([Input](#input)) |
| 10, 14:39:57Z | cold relaunch of the `5c52657` build after an incremental rebuild (same executable, SHA-256 `0e3af478…`), `LB_LOG=1` and `LB_AUDIO_METER=1` | No virtual pad, generic controller ignored. Saves unchanged. The coordinator's CUA session then sent real OS keys: Return/Enter confirmation, CONTINUE loaded the saved `cuasimlive` view, 80 D taps moved to a bridge-centred view, and console `load cuasimlive` restored the saved view in this new process. Guest memory 4.00 GiB in 17 regions, `---` or `rw-`. Audio on an open SDL output device: 50 of 51 five-second windows non-zero (the first, during loading, was 0.000), peak up to 0.296, RMS up to 0.046; nobody listened |
| 11, 15:28:54Z | audio output-device recovery fix (`b44c19b`, executable `6b805108…`), `LB_LOG=1` and `LB_AUDIO_METER=1`, no scripted input | Through a 1 s `SIGSTOP`, a vmmap snapshot and a 3 s `SIGSTOP` of the game process, every 5 s meter window read `(device open)`, 24 of 25 non-zero, with no stall. Saves unchanged |
| 12, 15:41:02Z | final no-script session on the same build, `LB_LOG=1`, `LB_AUDIO_METER=1` and `LB_SHOT` frames | Root's computer-use keyboard: CONTINUE to Riverwood, console `save cuasimpostaudio`, D moved to a bridge-centred view, `load cuasimpostaudio` restored the saved view. Audio: 71 windows all `(device open)`, 70 non-zero, peak up to 0.374, still open after vmmap, no stall. Guest memory 4.00 GiB in 17 regions, `---` or `rw-` |

Boots 1–10 predate the audio output-device recovery fix in the shared
`runtime/xaudio2.c` (`b44c19b`, handoff N18). Before it, a process suspension of
more than 200 ms (vmmap, a debugger) could close the output device for the rest
of the session; no Simulator log above shows that. Boots 11 and 12 ran the fixed
build: the output stayed open and non-zero through `SIGSTOP` and vmmap, with no
stall. The development logs, status receipts and handoffs for these historical
checks remain private and are omitted from this source snapshot.

Sim boot 7's restore proof is `macos/evidence/sim-boot7-restore-proof-root.json`
(13:38:16Z): mean frame difference idle 2.30, after the strafe 35.28, restored
4.41 and 3.34 (of 255), with the frames also checked by eye. Runtime logs don't
print save reads, so the reload evidence is visual and numeric.

JITless proof from the live sim boot 3 process (13:07:12Z,
`macos/evidence/sim-boot3-guest-memory-proof-root.json` and
`sim-boot3-vmmap-root.txt`): the 4.00 GiB guest reservation spans 18 regions
with current protection `---` or `rw-` and no executable guest page. The
`5c52657` build (`0e3af478…`) showed the same in both CUA sessions, 17 regions
each (`macos/evidence/cua-simulator-20261101-vmmap.txt`,
`cua-simulator-cold-20261101-vmmap.txt`). Executable regions are only image
`__TEXT` segments and one 48 KiB `r-x` mapping of the Simulator runtime's
`libobjc-trampolines.dylib`; none is writable and executable.

### Input

Since commit `5c52657` the Simulator uses the shared Apple input policy
described in the [macOS notes](../macos/README.md#input-policy-all-apple-targets).
Sim boots 1–7 ran earlier builds with scripted `LB_KEYS`, which use the
virtual pad.

A no-script session (PID 50939, launched 13:53:19Z with `LB_LOG=1` only)
logged `input: virtual pad off; 1 controller(s) attached at launch` and
`input: ignoring controller Gamepad (type 0; DualSense only, LB_ANY_PAD=1
allows)`. The Simulator's own generic controller is ignored, so XInput reports
no pad (`simulator/evidence/game-launch-20261101T135319.680837Z.json`).

The coordinator agent's ("root") computer-use session, not a person, then sent
real OS key events through the Simulator viewer to that session (PID 50939, 13:53:19Z–14:28:34Z,
`macos/evidence/cua-simulator-20261101-proof.json`), and again in a cold
relaunch of that build (PID 70292, 14:39:57Z–14:44:38Z,
`macos/evidence/cua-simulator-cold-20261101-proof.json`; boot 10 above):

- Return/Enter drove CONTINUE and console commands; the confirmation legend
  read "Enter Yes / Tab No", so the game stayed in its keyboard interface.
- Repeated D presses visibly moved the player.
- Console `save cuasimlive` (3,107,290 bytes, SHA-256 `ffb08e39…`), D presses
  to a visibly different view, then `load cuasimlive` restored the saved view.
  In the cold relaunch, a new process, CONTINUE loaded that save and
  `load cuasimlive` restored its view again after 80 D taps; the save file was
  unchanged.
- Fast typing through the viewer can reorder characters: the cold relaunch's
  first `load` arrived as `cuasimilve`, which names no save. Typing at 150 ms
  per character, with Return sent separately, worked.
- The live process kept 4.00 GiB of guest memory in 17 regions with current
  protection `---` or `rw-` and no executable guest page.
- On the fixed build (boot 12, PID 94615, 15:41:02Z–15:47:00Z,
  `macos/evidence/cua-final-post-audio-20261101/sim-proof.json`): CONTINUE to
  Riverwood, console `save cuasimpostaudio` (3,122,746 bytes, SHA-256
  `86e28e6e…`), D moved to a bridge-centred view, and `load cuasimpostaudio`
  restored the saved view; the four earlier saves were unchanged.
- Not verified through the viewer: F5 did not write a quicksave, Escape did not
  open the pause menu and Tab moved focus to the viewer's controls. F9 and a
  continuous key hold were not checked. Why F5 and Escape did not act is not
  determined; scripted F5 wrote a quicksave in boot 5.

Real mouse input cannot be tested here. Clicks in the Simulator viewer arrive
as direct touches, which the game ignores by design, and the iPad pointer
(GCMouse) path has not been exercised.

### Not verified

The F5 and F9 hotkeys, Escape and held keys through the viewer (above), mouse
look, DualSense play (no physical controller tested; the PS5 path is covered
only by SDL virtual-device IDs), a human play session, game audio judged by ear
(the mix is measured non-silent, but nobody has listened), long sessions, lifecycle and backgrounding,
triangle-fan draws (none logged failing, but the Simulator's MoltenVK lacks the
indirect drawing it uses for fans) and physical iPad compatibility.
