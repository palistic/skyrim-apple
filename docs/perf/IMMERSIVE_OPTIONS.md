# Options for immersive performance beyond the lifted code

Written 2026-11-10 alongside `docs/perf/LOG.md`. Nothing here is implemented. Items marked *read* come from
reading the code, *measured* from the M1 benchmark, *idea* is untested.

## What the measurements say first

On the M1 at 1280×720 the frame is limited by the game's main thread running lifted code (79% of its on-CPU
time); DXVK's front end is about 3% of it, and DXVK's own threads use under a quarter of a core (*measured*).
The M2 headset adds a compositor and a weaker GPU than the iPad, so the GPU may matter more there, but any
stereo design that makes the game simulate or submit the scene twice per displayed frame pays on the thread that
is already the limit.

## 1. Stereo without a second game pass: per-eye draws inside DXVK

The plan's M3 renders alternate eyes through a camera hook, which halves each eye's frame rate. The alternative
is what NVIDIA 3D Vision Automatic did for D3D9 games: the game renders one mono frame, and the graphics layer
issues each scene draw once per eye with the vertex shader shifting clip-space x by
`eye * separation * (w - convergence)`. The game thread's cost doesn't change; the replay runs on DXVK's
command thread and the GPU.

What the vendored DXVK 1.9.2 offers (*read*, by a read-only study of `android/app/jni/dxvk`):

- **Where the shift goes:** `src/dxso/dxso_compiler.cpp` `emitVsFinalize()` (line 3914), between
  `emitLinkerOutputSetup()` and `emitVsClipping()`; the fixed-function vertex shader
  (`src/d3d9/d3d9_fixed_function.cpp`) needs the same patch.
- **How the eye reaches the shader:** the push-constant block `D3D9RenderStateInfo` (`src/d3d9/d3d9_state.h:33`)
  has room for eye sign, separation and convergence, and can change per draw inside a command-stream lambda.
  Spec constants would recompile pipelines per eye.
- **Mechanism:** duplicate each scene draw in the five Draw lambdas of `d3d9_device.cpp`, the second time bound
  to a twin of each back-buffer-sized render target and depth buffer. Twins rather than a double-wide target,
  because post passes compute UVs over the whole texture. Vulkan multiview isn't used anywhere in this DXVK and
  would need layered targets that the translated `sampler2D` shaders can't read.
- **Present:** `skyrim_present_tap_frame` carries one image; it would carry two.

Risks: effects that rebuild position from depth with the mono projection (water, fog, imagespace) will be
slightly off; the HUD and full-screen passes must be recognised and left unshifted; the game culls for one
camera, so the field of view has to be widened and cropped; GPU scene cost roughly doubles. Not verified:
Skyrim's real render-target sizes and pass order, and MoltenVK's feature set on visionOS.

This keeps the plan's head-rotation camera hook and pose-tagged reprojection, and replaces only the per-eye
frustum hooks. It is a large change to vendored DXVK (seven areas), so it wants its own milestone and a
prototype on the Mac first: a side-by-side window is enough to judge the artefacts.

## 2. Thread scheduling on the headset (*idea*, cheap to try)

Guest threads are plain pthreads with no QoS class, and `SetThreadPriority` is a no-op
(`runtime/kernel32.c:455`). The M2 has four performance cores; the game's main thread, two busy workers and
DXVK's two threads already fill them, and nothing tells the scheduler which matter. Give the presenting thread
and DXVK's threads `QOS_CLASS_USER_INTERACTIVE` and map the game's own `SetThreadPriority` calls onto QoS
classes. Measure on the headset; the M1 result won't transfer.

## 3. Loading-time spin (*measured*, not yet addressed)

For the first 30 s of a run most CPU time is `swtch_pri`, i.e. `Sleep(0)`/`sched_yield` loops (the brief's
spin-wait). It doesn't appear once in the world on the M1, so it costs loading time, heat and battery rather
than frame rate. A short real sleep after a few consecutive yields is the usual fix.

## 4. Render scale and upscaling (*idea*)

If the headset turns out GPU-bound in immersive mode: render below the panel's angular resolution and upscale
in the compositor pass (MetalFX spatial needs no motion vectors), and use the compositor's foveation with a
rasterization rate map, as the plan already notes for M2.

## 5. Compiler-level work still open (*idea*)

ThinLTO (inlining across the 140 generated files removes spill/reload pairs at direct calls), profile-guided
optimisation, and a linker order file built from a profile to keep the hot few megabytes of the 110 MB of code
together. Each needs a 20-minute build per try on the M1.
