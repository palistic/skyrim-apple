# Original Windows executable preparation on an ARM64 Mac

This is a private **build-time conversion tool**. It is never linked into or bundled with the JITless game runtime. On 2026-11-01 it unpacked the owner's original Steam `TESV.exe` (depot 72852); the result and the accepted unpacked identity are [below](#unpacking-the-owned-original-tesvexe).

## Verified route

The existing native `/opt/homebrew/bin/dotnet` host is ARM64, SDK `10.0.402`, runtime `10.0.13`. The official [Steamless v3.1.0.5 source](https://github.com/atom0s/Steamless/tree/cd770bf9749d3e4f438d23ac643917ad1a804257), commit `cd770bf9749d3e4f438d23ac643917ad1a804257`, builds locally using generated `net10.0`/`AnyCPU` projects. Original C# parsing, crypto, CLI and the five x86 SteamStub variant implementations are compiled unchanged. Only the unused WPF API types `Model/ViewModelBase.cs` and `Model/NavigatedEventArgs.cs` are excluded. The generated projects and all compiled outputs stay in ignored `macos/build/steamless/`.

The upstream projects target Windows .NET Framework 4.5.2/x86. The official release CLI has CLR flags `0x3` (`ILONLY | 32BITREQUIRED`); we have **not executed that Windows binary** or changed its platform metadata. No Mono, Wine, Rosetta, Windows SDK or .NET global installation was needed. NuGet package sources are cleared for the host build; it uses the already installed SDK reference packs and the pinned source's bundled managed dependency.

The original optional `imagehlp.dll` checksum P/Invoke remains in source but is never requested: `RecalculateFileChecksum` defaults to false and the wrapper accepts no upstream flags. Raw CLI help still lists the upstream Windows checksum switch; use the wrapper below for owned inputs.

The included `SharpDisasm.dll` is a managed C# disassembler, not a native BeaEngine dependency. Both source copies and the official release copy are identical: 220672 bytes, SHA256 `6d3ce990cdf58da228697d25416d16d15994135c5f66571fe1e00e9c975bc2cf`, CLR flags `0x1` (`ILONLY`, no `32BITREQUIRED`). Its [upstream project](https://github.com/justinstenning/SharpDisasm) identifies BSD 2-Clause licensing for SharpDisasm and its Udis86 port. The ARM64 helper probe successfully decodes authored x86 bytes through that actual DLL.

## Rebuild and check without game files

From the repository root, obtain the source if it is absent:

```sh
git clone --depth 1 --branch v3.1.0.5 https://github.com/atom0s/Steamless.git macos/deps/steamless/source
```

The builder requires the exact pinned revision and a clean source checkout; it preserves unexpected local edits by refusing to build. The existing native SDK is required. Build serially, then run the game-free checks:

```sh
python3 -m unittest discover -s macos/executable -p 'test_*.py' -v
python3 macos/executable/build.py
python3 macos/executable/readiness.py
```

`build.py` creates a fresh private directory and publishes `macos/build/steamless/CURRENT.json` only after success. The receipt binds all tracked source hashes, authored build/wrapper/probe source, generated project configuration, the actual dotnet host, and output hashes. Readiness checks validate this receipt before and after testing.

The verified ARM64 host checks are:

- Original CLI `--help` prints usage (upstream's exit code is 1).
- All five x86 variant plugins load; an authored valid PE32 with no `.bind` section is rejected, unchanged, with no unpacked output.
- The unmodified upstream PE parser reads that fixture.
- The unmodified upstream AES helper decrypts the NIST AES-128 ECB known-answer vector.
- The actual managed SharpDisasm decodes two authored x86 instructions.
- Wrapper tests exercise a test double with authored PE data for original preservation, private copy/output receipts, refusing existing output directories, rejecting unknown inputs, rejecting incorrect unpacked hashes, converter failure and stale source/binary/host bindings. Production hash prefixes are patched only inside those tests.

These establish native host readiness. The owned-game result follows.

## Unpacking the owned original TESV.exe

```sh
python3 macos/executable/unpack.py '/absolute/path/to/owned/TESV.exe'
```

The wrapper reads PE headers, requires x86 PE32 and the port's supported original SHA1 prefix `f39aeceb`, then creates a unique private directory under `macos/build/steamless/unpacked/`. It runs the verified managed converter on a **copy**, preserves and checks the source SHA256, and only accepts an x86 PE32 output with an accepted unpacked identity: upstream's SHA1 prefix `fed96638`, or the exact SHA1 `17ec1ef6d72781359860f103f600711dfc219182` of this pinned Steamless v3.1.0.5 output. It writes an audit receipt and converter log. A successful command prints the private `TESV_unpacked.exe` path for the staging helper. `--output-directory /new/path` is optional and refuses every existing path; `--tool-receipt` can select a particular pinned build receipt. The existing installation is never modified or executed.

An unsupported input or unexpected output fails closed. If actual Steamless default output differs from the expected executable, inspect its private receipt and log before changing the conversion configuration; no matching output is assumed or fabricated.

### Result with the owned input (2026-11-01)

- Input: `TESV.exe` from Steam depot 72852, 18,024,240 bytes, SHA1 `f39aecebf6e332616c4c518617073f6e8250e0f8`, SHA256 `69362f77bc56bf17570a33106d020b6c67fd8f32a294b82f8b687b9cf71efc72`. It passes the unchanged packed-original gate.
- The first preparation failed closed: the Steamless v3.1.0.5 output has SHA1 `17ec1ef6d72781359860f103f600711dfc219182`, not upstream's `fed96638`.
- Scratch trials: the default, `--keepbind` and `--keepstub` outputs have identical mapped `.text`, `.rdata`, `.data`, `.tls`, `.rsrc` and `.reloc` SHA256 and the same entry point `0xb568a1`; only headers and stub/`.bind` remnants differ. `--realign` pads sections and `--exp` changes `.text`; neither is used. Recomputing the PE checksum does not produce `fed96638` either.
- `fed96638` is upstream's own unpacked copy. Upstream's launcher notes that Steamless output differs between Steamless versions.
- Commit `cb9227f` accepts the exact full v3.1.0.5 SHA1 as a second identity in `common.py` and `macos/inputs.py`; the packed gate is unchanged.
- The accepted output is 17,462,064 bytes, SHA256 `d97eb0cc0ceef0923d2234d42b382c0d033853356528b271bc043542b1f5e605`. Its receipt, `macos/build/steamless/unpacked/<id>/receipt.json`, records `status: verified` and `original_preserved: true`.

The launcher bridge runs this step as part of `bridge.py prepare`; see the [macOS notes](../README.md#reproducible-preparation-from-steam-depots).

## Provenance and private-use boundary

The [official release](https://github.com/atom0s/Steamless/releases/tag/v3.1.0.5), published 2024-03-30, was downloaded for metadata inspection only. Archive `Steamless.v3.1.0.5.-.by.atom0s.zip`: 610646 bytes, locally computed SHA256 `e3e2d22e098ff3fb359b2876aa2bed9596f0501e6ff588cbffae90a76d2dc4f5`. This is our recorded download hash, not a publisher signature. Per-file CLR flags/hashes are retained privately in `macos/deps/steamless/release-inspection.json`.

Steamless's [license](https://github.com/atom0s/Steamless/blob/cd770bf9749d3e4f438d23ac643917ad1a804257/LICENSE) is CC BY-NC-ND 4.0; its source headers also prohibit distribution of modified works. Keep this adapted converter, upstream source, release archive and compiled assemblies private. Do not commit or distribute them with this project. The license file SHA256 is `2cc025882addeebbc6c8e86e55f2652ba4353aa17fa04c34b9e5c9be50cfc03f`; the pinned Git tree is `6b66ee2feac909921c9bff5004c62557be2cffee`.

The tracked files in this directory are authored orchestration, configuration generation, tests and documentation. Game executables, dependencies and compiled conversion outputs remain ignored. Bink and the Skyrim data files still come from the user's installation.
