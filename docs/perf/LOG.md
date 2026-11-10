# Lifted-code performance log

One entry per change: hypothesis, diff summary, difftest result, before/after numbers, verdict. Work is on the
local branch `perf/lifted-arm64`. Numbers are from the M1 (MacBook Air, 8 cores) unless marked otherwise.
Private inputs (`gen/`, game files, logs, screenshots) stay in `~/SkyrimAVP/` and `bench-results/`, both outside
git.

## How things are measured

- **Static:** one generated file (`exe_14.c`, 978 functions) compiled with the build's flags, instructions
  counted from `llvm-objdump -d`. Cheap, and shows what the compiler did, but says nothing about which code is hot.
- **Runtime:** `tools/bench/bench.py run <scenario> --mac <build dir> --game <game dir>` on the macOS native
  build. The Mac build now logs `ft <frame> <frame ms> <Present ms> <work ms>`; *work* is the frame time without
  the 60 fps pacing sleep and without D3D9 `Present`, i.e. the game's own CPU time on the presenting thread. The
  60 fps cap stays on, so both sides of a comparison play the same scene.

## 2026-11-10 — setup

- `gen/` (manifest sha 5b68dc33…) and the game were already on the M1 in the planning session's scratch folder;
  cloned to `~/SkyrimAVP/` (APFS clones). Mint was not contacted.
- macOS build bootstrapped (`macos/bootstrap.sh`; the DirectX fetch step needs `cabextract`, which isn't
  installed and isn't needed because the game folder already has both DLLs).
- `macos/CMakeLists.txt`: `SKYRIM_GAME_DIR` (the manifest records a path on another volume), `LB_CONST_MEM`,
  `SKYRIM_GEN_FLAGS`. `macos/build_receipt.py`: `begin`/`seal` take `--game-dir`.
- `runtime/platform_sdl.c`: frame pacing log, `LB_FRAMETIMES` and `LB_EXIT_FRAME` on the Mac build too.
  `runtime/d3d9_bridge.cpp` reports the pacing sleep so the work time can be logged.
- `tools/bench/bench.py`: `--mac BUILD_DIR --game DIR` target; summaries and comparisons include work time.

## Static findings (exe_14.c, `-O2 -fno-strict-aliasing -fwrapv`, arm64)

| Variant | Instructions | Loads | Guest-base reloads | Acquire/release |
|---|---|---|---|---|
| baseline (`LB_STRICT_ORDER`) | 569,717 | 177,401 | 64,181 | 18,005 |
| + `LB_CONST_MEM` | 507,596 (−10.9%) | 118,454 | 4,460 | 18,051 |
| + `CPU *restrict c` | 506,565 (−0.2% more) | 117,944 | 4,460 | 18,051 |
| `LB_CONST_MEM`, `LB_STRICT_ORDER` off | 419,422 (−26.4%) | 106,312 | 4,437 | 0 |

- **Guest base reloads confirmed** (brief candidate 1): `MEM` is reached through the GOT and reloaded after
  almost every guest store, 11.3% of all instructions.
- **`restrict` on the CPU pointer doesn't help** (0.2%): the remaining CPU-struct traffic is spills and reloads
  around calls, which `restrict` can't remove. Dropped.
- **Strict ordering is expensive statically** (another 17%): each `TL32`/`TS32` carries an alignment test, a
  branch and a fenced slow path. Tried removing the test: unaligned `ldapr`/`stlr` raise SIGBUS on the M1
  (even inside one cache line), so the test has to stay while strict ordering is on.

## 2026-11-10 — where the time goes (M1, Riverwood, 1280×720 low preset)

Scenario `riverwood-walk-mac`: `coc riverwood` from the main menu, stand 10 s (*idle*, frames 2400–3000), run
forward 20 s (*run*, 3000–4200). The idle phase repeats within about 1%; the run phase varies by about 5%, so
verdicts use idle and report run alongside.

- **The built-in profiler misleads on macOS.** Its SIGPROF samples land mostly on threads in system calls: it
  reported 53% `__psynch_cvsignal` in the world, where a call-stack sample (`sample <pid> 10 1`) shows 31 of
  ~3,000 main-thread samples there. Turning it off (`noprof.txt`) changed nothing measurable (idle work
  10.95 / 11.68 / 11.39 ms against 11.36 / 11.39 / 11.49).
- **Main thread, on-CPU time by where it is spent** (one 10 s sample while standing in Riverwood):
  lifted code 79%, profiler signal handler 7%, locks 4%, indirect-call dispatch 2%, DXVK's D3D9 front end about
  3%. Two worker threads run lifted code about a third of the time; `dxvk-submit` and `dxvk-cs` use 14% and 9%
  of a core. On the M1 the frame is limited by the main thread's lifted code, not by graphics.
- **x87 is the hot part.** 48% of the main thread's lifted-code samples are in functions that use x87, and one
  function, `0x472580` (a plane/sphere test, called from culling), has 23% by itself. SSE register access is
  0.3% of sample-weighted lines, so SSE registers as locals (brief candidate 3) is not worth doing.
- During loading the first 30 s of CPU go mostly to `swtch_pri` (`Sleep(0)`/`sched_yield` spinning), not seen
  once in the world.

## 2026-11-10 — constant guest base (`LB_CONST_MEM`)

- **Hypothesis:** every guest store may alias the global `MEM`, so it is reloaded all the time.
- **Change:** `runtime/x86.h` declares `extern uint8_t *const MEM` when `LB_CONST_MEM` is defined; the generated
  code's target defines it, the runtime (which assigns `MEM` once in `main`) does not. No regen.
- **Static:** −10.9% instructions in `exe_14.c`, guest-base reloads 64,181 → 4,460.
- **Difftest:** not affected (header-only; the harness doesn't define it).
- **Runtime, idle work ms/frame:** baseline 11.36, 11.39, 11.49, 11.65 (mean 11.47); const 11.16, 10.84, 11.16
  (mean 11.05). **−3.7%**; every const run is below every baseline run, but the gap is only about three times
  the run-to-run spread. Run phase: 10.88 / 12.05 / 11.03 / 10.92 against 10.47 / 10.11 / 10.51.
- **Verdict:** keep. Small, free, no behaviour change.

## 2026-11-10 — x87 register cache in the lifter (`X87CACHE`, `LIFT_X87CACHE=0` turns it off)

- **Hypothesis:** the x87 stack lives in `c->st[]` at a runtime index, so each operation is a load and a store
  that can't be forwarded past guest stores, and `fnstsw`/`test` after a compare goes through memory too.
- **Change (`tools/lift.py`):** a function that uses x87 keeps the top index in a local `ft` and, within a
  basic block, the registers it touches in locals `fr0..fr7`, loaded on first use and written back at the end of
  the block and before any call, return or helper that takes the CPU. A compare also leaves C3/C2/C0 in a local,
  which `fnstsw` in the same block reads. `c->st[]`, `c->top` and the condition codes hold the same values as
  before at every point where other code can see them. Runtime: `SPILLF`/`RELOADF` (`lift_prelude.h`),
  `fcompare_sw`/`fstatus_sw`/`fstatus_top` (`x86.h`).
- **Checks:**
  - `tools/difftest.py`: report identical to the unmodified lifter's (1,462 instruction tests). On this Mac the
    unmodified lifter already shows 44 mnemonics with differences, most of them the test reading an empty x87
    register after a pop; the harness also died on SIGBUS from an unaligned atomic until it was taught to
    record a fault as that test's result.
  - New `tools/x87cache_test.py`: 400 real multi-block functions (359 with calls) lifted both ways and run on
    the same random states, callees replaced by a stub that hashes the CPU state it receives and sometimes
    returns a float: 2,133 runs compared, 0 different. Deliberately broken caches (no write-back, no top
    update) give 422 and 271 differences, so the test does see the failure modes.
  - Regenerated code has the same 96,653 functions; 15,235 use the cache.
- **Static:** `0x472580` 130 → 98 instructions, `0x474CD0` 185 → 117. Whole-file totals rise about 1% (the
  top index is stored and reloaded around calls in x87 functions).
- **Runtime, interleaved with the const build (idle / run work ms per frame):**
  const 10.99, 11.30, 11.01 / 10.15, 10.59, 10.12; x87 cache 9.37, 9.45, 9.44 / 8.95, 8.65, 8.72.
  **−15.1% idle, −14.8% run**, far outside the spread. An earlier pair (9.39, 9.31 against 11.29, 11.10) agrees.
  Screenshots at frames 2990 and 4190 show the same spot and view as the const build (the weather differs from
  run to run in either build).
- **Verdict:** keep. Needs a regen (the manifest check enforces that, since `tools/lift.py` changed).
- Three runs taken while the Mac was busy after a login (load average over 100) were discarded.

## 2026-11-10 — native replacement for `0x472580` (plane/sphere side test)

- **Hypothesis:** the function had 23% of the main thread's lifted-code samples, so a native version should
  save several percent of the frame.
- **Change:** `runtime/skyrim_native.c` (new), listed in `HOST_OVERRIDES_SKYRIM` in `tools/lift.py`, so the
  lifter emits the guest body as `f_472580_guest`. It reproduces the lifted body's results exactly, including
  the float temporaries in the argument slot, the stale x87 registers and the condition codes.
- **Check:** new `tools/native_test.py` runs the lifted guest body and the native function on 20,000 random
  states: 0 different. Four deliberate errors, one per result path (behind, between, in front, NaN), give
  2,619 / 14,362 / 1,881 / 1,138 differences.
- **Runtime (idle / run):** x87 cache alone 9.37, 9.45, 9.44 / 8.95, 8.65, 8.72; with the native function
  9.20, 9.31, 9.33 / 8.78, 8.64, 8.63. **−1.5% idle, −1.0% run.** Every native run is below every x87 run in
  idle, but the gain is a tenth of what the sample share suggested.
- **Verdict:** keep, as the worked example of the override mechanism, but it shows the limit of this approach:
  the function's time is not its instructions (98 → about 35) but, most likely, cache misses on the object data
  it reads while culling walks the scene. Hot-function replacement is not the next lever; candidate 8 is closed
  unless a profile shows a function whose cost is computation.

## Running total (M1, Riverwood idle, work ms per frame)

| Build | Mean of 3 | Against baseline |
|---|---|---|
| baseline (`perf-base`) | 11.47 (4 runs) | |
| + `LB_CONST_MEM` | 11.10 | −3% |
| + x87 register cache | 9.42 | −18% |
| + native `0x472580` | 9.28 | −19% |

## 2026-11-10 — lock-free COM object lookup in the D3D9 bridge

- **Hypothesis:** a second profile (after the x87 cache) showed 113 of 2,040 main-thread on-CPU samples in
  pthread mutex slow paths, 109 of them under `com_host`, which takes a recursive mutex on every D3D9 call only
  to index a vector that another thread might grow.
- **Change (`runtime/d3d9_bridge.cpp`):** the id → object table grows in chunks that never move, entries and
  the count are atomics, and `com_host` reads without the lock. Writers (`com_wrap`, `com_forget`) still hold it.
- **Runtime, six interleaved pairs (idle work ms):** before 9.26, 8.93, 9.22, 9.16, 9.38, 9.26 (mean 9.20);
  after 8.72, 8.77, 9.17, 8.77, 9.20, 9.03 (mean 8.94). **−2.8% idle**, lower in all six pairs; run phase
  8.68 → 8.32 (**−4.1%**).
- **Verdict:** keep. Not committed: the file also carries the planning session's uncommitted changes.
- **Same profile, other notes:** `0x472580` is still 8% of the main thread as a native function (so its cost
  is the memory it reads), the six-plane loop that calls it (`0xB1B6C0`) another 8%, indirect-call dispatch
  (`rt_call`) 3%.

Running total: baseline 11.47 → 8.94 ms idle (**−22%**).

## 2026-11-10 — `LB_STRICT_ORDER` off (measurement only; the decision is the maintainer's)

- **Build:** same code as the current best (x87 cache, const base, native function, lock-free COM lookup), with
  `-DLB_STRICT_ORDER=OFF`. The executable shrinks from 110 MB to 90 MB.
- **Runtime:** macOS was indexing in the background during every run (Spotlight and media analysis, load
  average 8–12), so the spread is about three times the usual and these are indicative only. Idle work ms,
  interleaved: strict 8.60, 8.84, 9.75, 9.29 (mean 9.12); off 8.17, 8.71, 7.91, 7.82 (mean 8.15).
  **About −11%**, off lower in all four pairs.
- **Failures:** none in five full runs (4,300 frames each, clean exits, no fatal or unimplemented-instruction
  lines). That is far too little to say it is safe: the ordering exists for races between threads, and this
  scenario exercises loading once and then a quiet scene.
- **Verdict:** worth the maintainer's attention as roughly a tenth of the main thread, but needs a quiet-machine
  rerun and long play sessions on several cores before anyone turns it off.
