# Physical Apple Vision Pro (xros SDK, arm64): the iPad engine's sources, for visionOS.
# Needs CMake 3.28+ (CMAKE_SYSTEM_NAME visionOS).
set(CMAKE_SYSTEM_NAME visionOS)
set(CMAKE_OSX_SYSROOT xros CACHE STRING "visionOS device SDK")
set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "Apple Vision Pro")
# 26.5: MoltenVK v1.4.2's xros slices are built for it, so the whole engine and app match.
set(CMAKE_OSX_DEPLOYMENT_TARGET 26.5 CACHE STRING "Minimum visionOS")
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
set(CMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO)
# Pinned SDL 2.30's CMake only knows iOS and tvOS as UIKit platforms; its UIKit backend builds for
# visionOS through the ipad/visionos/sdl overlay, so take its iOS path (the SDK stays xros).
set(IOS ON CACHE BOOL "SDL: use the UIKit backend" FORCE)
