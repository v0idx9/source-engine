# Minimal CMake toolchain for cross-compiling to iOS device (arm64) with clang,
# used only to build the static thirdparty libs (zlib/libpng/libjpeg-turbo/freetype/curl)
# that wscript's --ios --togles configure step expects to already exist under
# lib/darwin/aarch64/. Deliberately small and self-contained rather than pulling in
# an external toolchain project, since we only ever target one platform/arch here.

set(CMAKE_SYSTEM_NAME iOS)
set(CMAKE_SYSTEM_PROCESSOR aarch64)
set(CMAKE_OSX_ARCHITECTURES arm64)
set(CMAKE_OSX_SYSROOT iphoneos)
set(CMAKE_OSX_DEPLOYMENT_TARGET "12.0" CACHE STRING "")

set(CMAKE_C_COMPILER clang)
set(CMAKE_CXX_COMPILER clang++)

set(CMAKE_FIND_ROOT_PATH_MODE_PROGRAM NEVER)
set(CMAKE_FIND_ROOT_PATH_MODE_LIBRARY ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_INCLUDE ONLY)
set(CMAKE_FIND_ROOT_PATH_MODE_PACKAGE ONLY)

set(CMAKE_C_FLAGS_INIT "--target=aarch64-apple-ios -mios-version-min=12.0")
set(CMAKE_CXX_FLAGS_INIT "--target=aarch64-apple-ios -mios-version-min=12.0")

set(IOS TRUE)
set(BUILD_SHARED_LIBS OFF CACHE BOOL "")
