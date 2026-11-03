# Native JITless boundary checks

These checks use authored synthetic instructions and data with the actual lifter,
dispatcher, heap and complete macOS runtime. They do not load Skyrim or establish
that its real functions, imports, rendering or gameplay work.

After building the native runtime and running its CTest suite (which refreshes
the strict-order AOT fixture under `macos/build/native/aot-fixtures-strict/`):

```sh
macos/.venv/bin/python tests/jitless/run.py
```

The script copies existing executables into ignored `macos/build/jitless-proof/`.
It ad-hoc signs and verifies those copies with the hardened runtime. The real AOT
fixture executes with **zero entitlements**, including its fail-closed negative
tests. The full-runtime copy enables only
`com.apple.security.cs.disable-library-validation` so locally built third-party
graphics libraries can load; it does **not** enable JIT, unsigned executable memory,
executable-page-protection exceptions or debugger access. Original binaries and
dependencies are not signed or changed.

For a complete 4 GiB guest-reservation check before and after real allocator
release/remapping, coordinate the shared compiler slot and run:

```sh
macos/.venv/bin/python tests/jitless/run.py --build-mapping-probe
```

The additional small native probe scans every VM region spanning the entire guest
reservation, verifies the null guard and data-only permissions, writes the first,
middle and last usable pages, then repeats scans around allocation/free/reuse.
This checks current VM protections, not a claim about every possible future API
call. Source review and fail-closed dispatch tests are complementary evidence.

The graphics driver's compilation of GPU shaders is separate from runtime guest
CPU code translation. No global signing policy or developer setting is changed.
