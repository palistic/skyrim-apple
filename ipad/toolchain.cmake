# Physical iPhone/iPad (iphoneos SDK, arm64). The Simulator keeps simulator/toolchain.cmake.
set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_OSX_SYSROOT iphoneos CACHE STRING "iOS device SDK")
set(CMAKE_OSX_ARCHITECTURES arm64 CACHE STRING "Apple Silicon iPad")
set(CMAKE_OSX_DEPLOYMENT_TARGET 17.0 CACHE STRING "Minimum iPadOS, matching the launcher")
set(CMAKE_TRY_COMPILE_TARGET_TYPE STATIC_LIBRARY)
set(CMAKE_XCODE_ATTRIBUTE_CODE_SIGNING_ALLOWED NO)
