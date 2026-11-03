> **Historical development reference.** The current public build targets iOS/iPadOS and has physical iPad Pro acceptance. See the [root README](../../README.md) and the [current build guide](../../docs/BUILDING.md). Status and launcher holds below describe the earlier prototype, not current iPad support.

# Skyrim launcher

Native SwiftUI macOS launcher adapted from Zach's Dark Eco library in GOALPad.
It keeps the centered 2:3 cover card, capsule menu, artwork choices, status
footer and flowing Metal background. The palette is smoke gray with gold or
white accents, selectable in Settings. There is one title.

Build on Apple Silicon with Xcode and its Metal toolchain:

```sh
sh macos/launcher/build.sh
open 'macos/build/launcher/Skyrim Launcher.app'
```

The launcher requests macOS 14 or newer for SwiftUI shader effects. The game
runtime remains a separate macOS 13 deployment target. This local launcher
points to the checkout through its bundled `checkout-path.txt`; it is not a
standalone distributed game package.

Choose the original Windows Skyrim installation folder to begin. Preparation
and native compilation run in the background through the existing private
input workflow. The original installation is preserved. Play is offered only
when the compiled game passes input/build receipt verification.

Launcher work is paused by the owner, with no launcher, phone or device
testing since 2026-11-01T10:48Z. The owned game has since been prepared and
exercised without this app (scripted keys and computer-use input; no person
has played it): `bridge.py status` and `bridge.py prepare` ran the
real preparation from the command line, and the game was run through
`macos/run.sh` and the development .app (see the [macOS notes](../README.md)).
Play from this launcher has not been tested.

Settings opens the game folder, save folder and diagnostic log. Artwork can be
chosen from the cover's ellipsis menu. Selected folders, artwork and accent
are local preferences; no account is required.

Design reference: [Dark Eco / GOALPad](https://github.com/zschwendi/dark-eco),
especially its library and `UI/DarkEcoLauncherBackground.metal`, reference checkout
`3be15de7e764553f70eb5f3f9f02dce695840586`. The smoke shader preserves its flow
and changes the purple color constants to neutral grays. The default cover is
an authored vector motif; custom owned artwork may replace it.
