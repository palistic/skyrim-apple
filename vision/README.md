# Vision Pro launcher scaffold

This directory contains the earlier standalone Vision Pro SwiftUI launcher and original artwork. The shared launcher is now under `apple/` with the `SkyrimVision` target. Neither launcher-only target includes a native Skyrim engine by itself.

The accepted physical-device runtime in this publication is the iOS/iPadOS build, tested on iPad Pro M5. Native Vision Pro windowed and immersive runtime integration is in development separately. No working Vision Pro gameplay or immersive release is claimed here.

The original smoke-gray, white and gold icon and cover are packaged from `Artwork/` by `prepare_assets.swift`. They contain no Skyrim logo or extracted assets. The earlier scaffold can be built with `sh vision/build.sh` on a suitably configured Mac, but this creates a launcher, not a playable game.

For current platform status and installation, start with the [root README](../README.md).
