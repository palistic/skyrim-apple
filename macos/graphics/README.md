# macOS D3D9 graphics groundwork

This target builds the actual upstream patched dxvk-native D3D9 library for
ARM64 macOS. It links SDL2 and MoltenVK; no Windows VM, Wine, Rosetta or CPU JIT
is used by the probe. GPU shader translation/compilation still happens normally.
This target contains no Skyrim executable, generated Skyrim code or game assets.

## Build

Prerequisites: Apple Silicon Mac with a logged-in graphical session, Xcode Command
Line Tools, CMake, Python 3, and SDL2 with its CMake package (tested with Homebrew
SDL2 2.32.10). The dependency fetcher writes only into ignored `macos/deps`.

From the repository root:

```sh
python3 macos/graphics/fetch_dependencies.py
cmake -S macos/graphics -B macos/graphics/build \
  -DCMAKE_BUILD_TYPE=Release -DCMAKE_OSX_ARCHITECTURES=arm64 \
  -DCMAKE_PREFIX_PATH=/opt/homebrew
cmake --build macos/graphics/build -j2
cd macos/graphics/build
./graphics_smoke
```

The same directory can be included with `add_subdirectory(graphics)` by the
parent macOS project. Targets are `dxvk_d3d9` and `graphics_smoke`.
`SKYRIM_MOLTENVK_ROOT` can select an already extracted package; its expected
layout contains `include/` and `dynamic/dylib/macOS/libMoltenVK.dylib`.

The public dependency is MoltenVK **1.4.2**,
[`MoltenVK-macos.tar`](https://github.com/KhronosGroup/MoltenVK/releases/download/v1.4.2/MoltenVK-macos.tar),
59,563,008 bytes. SHA256, also published by the GitHub release asset API:
`f95765a6229cb7b915990a2890ce12ebe36a730b021545d3d52ae69ce4c4024e`.
The script verifies that digest before extracting headers, dylib and license.

## What the smoke proves

The executable creates a hidden 64x64 SDL Vulkan window and a real D3D9 device,
clears its render target red, draws a green transformed triangle through D3D9's
fixed-function pipeline, copies the rendered surface to system memory, and checks
the pixels. It fails on API errors, wrong sample colors, or missing red/green
coverage. A JSON result reports the adapter, samples, pixel counts and an RGB
readback hash. DXVK's shader compiler pool is capped at two workers by `probe.conf`.

On the local Apple M4, the expected successful result has red corner `ff0000`,
green center `00ff00`, 2920 red pixels, 1176 green pixels, and RGB FNV-1a64
`e21c8a537cb574b5`. The executable and library are Mach-O ARM64.

This establishes native graphics-library build, device/swapchain creation,
draw execution and readback. It does not establish Skyrim shader coverage,
Skyrim gameplay, performance, a visible presentation test, or iOS compatibility.
The host runtime's texture/COM bridge remains actual upstream code; all five
`runtime/*.cpp` files also passed an ARM64 Clang syntax check with the native
D3D9 headers. No replacement renderer or success stubs were introduced.

## Apple adaptations

* Resolve executable paths with `_NSGetExecutablePath` and thread names with
  `pthread_setname_np` under an Apple guard.
* Use the installed SDL headers on Apple, retaining vendored Android headers
  on other platforms.
* Enable Vulkan portability enumeration when advertised and portability subset
  on an advertising device. Unsupported Vulkan features remain unsupported.
* Link directly to the pinned MoltenVK dylib. The smoke calls
  `SDL_Vulkan_LoadLibrary` with its exact path; a future game launcher must also
  select that library, for example with `SDL_VULKAN_LIBRARY`.

Linux/Android branches retain their existing Vulkan linking and platform flag.
This private prototype has not been published; upstream source reuse licensing
still needs resolution before distribution.
