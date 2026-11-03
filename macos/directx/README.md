# Private Microsoft DirectX dependency preparation

These helpers prepare **x86 `d3dx9_42.dll` and `X3DAudio1_7.dll`** from the
[official Microsoft DirectX End-User Runtimes (June 2010) package](https://www.microsoft.com/en-us/download/details.aspx?id=8109).
They do not download Skyrim or Bink, run a Windows installer, or install anything
globally. All Microsoft binaries and generated C remain under ignored
`macos/build/directx/`.

Run from the repository root, after the normal macOS bootstrap:

```sh
macos/.venv/bin/python macos/directx/fetch.py
macos/.venv/bin/python macos/directx/generate.py
```

`fetch.py` uses only Microsoft's HTTPS download host and checks the entire
100,275,120-byte archive against SHA-256
`053f76dcbb28802e23341b6a787e3b0791c0fa5c8d4d011b1044172dbf89c73b`.
That pin was measured from the official download; it is not represented as a
Microsoft-published checksum. It extracts only the selected x86 CABs and DLLs
with `cabextract`, verifies both DLL hashes and PE32/i386 headers, and writes
`fetch-receipt.json` privately. Existing unexpected output files are preserved
and rejected.

The stable DLL directory for the private game staging helper is:

```text
macos/build/directx/inputs/d3dx9_42.dll
macos/build/directx/inputs/X3DAudio1_7.dll
```

The pinned DLL hashes are:

| DLL | SHA-256 |
| --- | --- |
| d3dx9_42.dll | `f8b9cfab7fffbc8f98e41aa439d72921dc180634a1febca2a9d41a0df35d3472` |
| X3DAudio1_7.dll | `288c701bdedf1d45c63dd0b7d424a752f8819f90feb5088c582f76bc98970ba3` |

`cabextract` reports possible extra trailing bytes in these two pinned CABs;
extraction returns success and the extracted DLLs match the pinned hashes.

`generate.py` runs the actual repository scanner and lifter at guest bases
`0x08000000` and `0x0A000000`, respectively. Each invocation creates a new private
`aot-*` directory, binds the input and tool hashes before/after generation, and
records the generated-source closure. It reports rejected discovery roots and
unresolved indirect jumps explicitly: successful generation does not establish
complete functional coverage.

## Native ARM64 call probes

After building the genuine macOS runtime, pass the private `aot-*` directory
reported by `generate.py`:

```sh
macos/.venv/bin/python macos/directx/smoke.py macos/build/directx/aot-EXAMPLE --module x3da
macos/.venv/bin/python macos/directx/smoke.py macos/build/directx/aot-EXAMPLE --module d3dx9
```

These probes compile one generated C object at a time, link the actual runtime
objects and locally built SDL/DXVK libraries, map the real DLL image as
non-executable guest data, bind imports through the real runtime, and call its
compiled functions. No x86 interpreter or CPU JIT is used.

The X3DAudio probe calls the real DLL entry, `X3DAudioInitialize`, and
`X3DAudioCalculate`. It checks stack balance, output-buffer guards, deterministic
initialization, stationary Doppler and distance, symmetric center panning, and
left/right spatial panning. This is a numeric DLL-call test, not audible output
or Skyrim gameplay.

The D3DX probe calls the real DLL entry and checks version selection, matrix
translation/scaling/multiplication/inversion, determinant, vector normalization,
and stack balance. Its receipt records the actual result; a failure is not
silently replaced with native math helpers.

Keep the compiler-slot coordination used by the parent build. These commands
do not spawn parallel compiler jobs, but another concurrent build may already
occupy the agreed host job limit. Receipts, command logs, input images, compiled
objects and native probes remain private in the selected generation directory.

No DLL, installer, generated Microsoft C, or resulting private probe is intended
for committing or public distribution by this workflow. Game boot, game import
coverage, audio playback, textures and shader behavior still need the actual
owned Skyrim installation.

## Observed validation, October 26, 2026

- **Official DLL extraction:** the pinned archive and both PE32/i386 DLL hashes
  matched. Six local path/origin/preservation tests pass with
  `macos/.venv/bin/python macos/directx/test_fetch.py`.
- **X3DAudio:** 86 discovered roots, 79 lifted functions, seven rejected roots;
  both exported entries are present in the generated table. The native call
  probe passed **20 checks**, including real DLL initialization and panning
  results center `[0.5, 0.5]`, right `[0, 1]`, left `[1, 0]`.
- **D3DX9:** 5,913 discovered roots, 5,682 lifted functions, 231 rejected roots;
  all 329 exported entries are present in the generated table. All emitted
  function translation units compiled for ARM64. The native call probe passed
  **72 checks**, including real DLL initialization, determinant `24`, and
  normalized vector approximately `[0.6, 0.8, 0]`.

Private receipts from those runs are:

```text
macos/build/directx/fetch-receipt.json
macos/build/directx/aot-cpi0ipli/generation-receipt.json
macos/build/directx/aot-cpi0ipli/native-smoke-d3dx9/receipt.json
macos/build/directx/aot-zb0v7_ky/native-smoke/receipt.json
```

The last path is the original successful X3DAudio probe, retained before the
probe runner was generalized to `smoke.py --module ...`. New probe runs use
`native-smoke-x3da` and `native-smoke-d3dx9` subdirectories. Discovery rejections
include data-like roots and legacy instruction paths; none is silently counted
as supported. These numeric call probes establish only the exercised DLL paths,
not all exports, shader compilation, audio playback or Skyrim boot.
