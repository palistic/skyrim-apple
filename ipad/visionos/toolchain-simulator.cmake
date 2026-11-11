# visionOS Simulator (xrsimulator SDK, arm64): the Vision Pro engine for pre-headset checks of the
# window, SDL scene and MoltenVK surface. The Simulator runs on the Mac, so memory results don't carry over.
include("${CMAKE_CURRENT_LIST_DIR}/toolchain.cmake")
set(CMAKE_OSX_SYSROOT xrsimulator CACHE STRING "visionOS Simulator SDK" FORCE)
