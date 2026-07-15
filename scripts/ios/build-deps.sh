#!/bin/bash
# Cross-compiles this repo's own vendored thirdparty sources (thirdparty/zlib,
# libpng, libjpeg, freetype, curl, SDL-src) for iOS device (arm64) and installs the
# static libs where wscript's --ios --togles configure hardcodes its -L search path:
# lib/<DEST_OS>/<DEST_CPU>/ == lib/darwin/aarch64/ (see wscript line ~550).
#
# waf's conf.check(lib=X) looks for a file literally named libX.*, so the installed
# filenames below are NOT arbitrary -- they must match what wscript asks for:
#   conf.check(lib='freetype2', ...) -> libfreetype2.a
#   conf.check(lib='jpeg', ...)      -> libjpeg.a
#   conf.check(lib='png', ...)       -> libpng.a
#   conf.check(lib='curl', ...)      -> libcurl.a
#   conf.check(lib='z', ...)         -> libz.a
#
# SDL2 is linked as a framework (conf.env.FRAMEWORK_SDL2 = "SDL2"), not a static lib,
# so it's built separately into Frameworks/SDL2.framework.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
TOOLCHAIN="$ROOT_DIR/scripts/ios/ios.toolchain.cmake"
LIBDIR="$ROOT_DIR/lib/darwin/aarch64"
BUILD_ROOT="$ROOT_DIR/build-ios-deps"
JOBS="$(sysctl -n hw.ncpu 2>/dev/null || echo 4)"

mkdir -p "$LIBDIR" "$BUILD_ROOT"

cmake_build_static() {
	local src_dir="$1" build_subdir="$2" out_lib_name="$3"; shift 3
	local build_dir="$BUILD_ROOT/$build_subdir"
	echo "=== Building $build_subdir ==="
	rm -rf "$build_dir"
	cmake -S "$src_dir" -B "$build_dir" -G "Unix Makefiles" \
		-DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX="$build_dir/install" \
		"$@"
	cmake --build "$build_dir" --parallel "$JOBS"
	cmake --install "$build_dir"
	local found
	found="$(find "$build_dir/install" "$build_dir" -maxdepth 3 -name "$out_lib_name" -print -quit)"
	if [ -z "$found" ]; then
		echo "error: expected to produce $out_lib_name in $build_dir, but didn't find it" >&2
		exit 1
	fi
	echo "$found"
}

# --- zlib ---
if [ ! -f "$LIBDIR/libz.a" ]; then
	OUT="$(cmake_build_static "$ROOT_DIR/thirdparty/zlib" zlib libz.a)"
	cp "$OUT" "$LIBDIR/libz.a"
fi

# --- libpng (needs zlib) ---
if [ ! -f "$LIBDIR/libpng.a" ]; then
	ZLIB_H_DIR="$ROOT_DIR/thirdparty/zlib"
	OUT="$(cmake_build_static "$ROOT_DIR/thirdparty/libpng" libpng "libpng*.a" \
		-DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF -DPNG_TOOLS=OFF \
		-DZLIB_INCLUDE_DIR="$ZLIB_H_DIR" -DZLIB_LIBRARY="$LIBDIR/libz.a")"
	cp "$OUT" "$LIBDIR/libpng.a"
fi

# --- libjpeg-turbo ---
if [ ! -f "$LIBDIR/libjpeg.a" ]; then
	OUT="$(cmake_build_static "$ROOT_DIR/thirdparty/libjpeg" libjpeg libjpeg.a \
		-DENABLE_SHARED=OFF -DENABLE_STATIC=ON -DWITH_SIMD=OFF -DWITH_TURBOJPEG=OFF)"
	cp "$OUT" "$LIBDIR/libjpeg.a"
fi

# --- freetype (kept dependency-free: no zlib/png/harfbuzz/bzip2/brotli) ---
if [ ! -f "$LIBDIR/libfreetype2.a" ]; then
	OUT="$(cmake_build_static "$ROOT_DIR/thirdparty/freetype" freetype "libfreetype*.a" \
		-DFT_DISABLE_ZLIB=ON -DFT_DISABLE_PNG=ON -DFT_DISABLE_HARFBUZZ=ON \
		-DFT_DISABLE_BZIP2=ON -DFT_DISABLE_BROTLI=ON -DBUILD_SHARED_LIBS=OFF)"
	cp "$OUT" "$LIBDIR/libfreetype2.a"
fi

# --- curl (Apple Secure Transport for TLS, no OpenSSL needed) ---
if [ ! -f "$LIBDIR/libcurl.a" ]; then
	OUT="$(cmake_build_static "$ROOT_DIR/thirdparty/curl" curl libcurl.a \
		-DBUILD_SHARED_LIBS=OFF -DBUILD_CURL_EXE=OFF -DBUILD_TESTING=OFF \
		-DCURL_USE_SECTRANSP=ON -DCURL_USE_OPENSSL=OFF -DCURL_DISABLE_LDAP=ON \
		-DCURL_DISABLE_TELNET=ON -DCURL_ZLIB=ON -DZLIB_INCLUDE_DIR="$ROOT_DIR/thirdparty/zlib" \
		-DZLIB_LIBRARY="$LIBDIR/libz.a" -DHTTP_ONLY=OFF)"
	cp "$OUT" "$LIBDIR/libcurl.a"
fi

echo "=== Static libs installed to $LIBDIR ==="
ls -la "$LIBDIR"

# --- SDL2.framework (built from this repo's patched thirdparty/SDL-src) ---
FRAMEWORKS_DIR="$ROOT_DIR/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"
if [ ! -d "$FRAMEWORKS_DIR/SDL2.framework" ]; then
	echo "=== Building SDL2 (static lib, then wrapped into a framework) ==="
	SDL_BUILD_DIR="$BUILD_ROOT/sdl2"
	rm -rf "$SDL_BUILD_DIR"
	cmake -S "$ROOT_DIR/thirdparty/SDL-src" -B "$SDL_BUILD_DIR" -G "Unix Makefiles" \
		-DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
		-DCMAKE_BUILD_TYPE=Release \
		-DSDL_STATIC=ON -DSDL_SHARED=OFF \
		-DSDL_AUDIO=ON -DSDL_VIDEO=ON -DSDL_RENDER=ON -DSDL_JOYSTICK=ON \
		-DSDL_HAPTIC=ON -DSDL_ATOMIC=ON -DSDL_THREADS=ON -DSDL_FILE=ON \
		-DSDL_LOADSO=ON -DSDL_CPUINFO=ON -DSDL_FILESYSTEM=ON -DSDL_SENSOR=ON \
		-DSDL_LIBSAMPLERATE=OFF
	cmake --build "$SDL_BUILD_DIR" --parallel "$JOBS"
	SDL_STATIC_LIB="$(find "$SDL_BUILD_DIR" -maxdepth 2 -name 'libSDL2.a' -print -quit)"
	if [ -z "$SDL_STATIC_LIB" ]; then
		echo "error: SDL2 build did not produce libSDL2.a" >&2
		exit 1
	fi

	# Wrap the static lib into a flat iOS-style dynamic framework so it links the
	# same way this codebase's FRAMEWORK_SDL2 = "SDL2" expects (-framework SDL2).
	FW="$FRAMEWORKS_DIR/SDL2.framework"
	rm -rf "$FW"
	mkdir -p "$FW"
	SDKROOT="$(xcrun --sdk iphoneos --show-sdk-path)"
	clang -dynamiclib \
		--target=aarch64-apple-ios -mios-version-min=12.0 -isysroot "$SDKROOT" \
		-Wl,-force_load,"$SDL_STATIC_LIB" \
		-framework Foundation -framework UIKit -framework CoreGraphics \
		-framework QuartzCore -framework CoreAudio -framework AudioToolbox \
		-framework AVFoundation -framework CoreMotion -framework GameController \
		-framework CoreHaptics \
		-install_name "@rpath/SDL2.framework/SDL2" \
		-o "$FW/SDL2"
	cat > "$FW/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>CFBundleExecutable</key><string>SDL2</string>
	<key>CFBundleIdentifier</key><string>org.libsdl.SDL2</string>
	<key>CFBundlePackageType</key><string>FMWK</string>
	<key>CFBundleShortVersionString</key><string>2.0.17</string>
	<key>CFBundleVersion</key><string>2.0.17</string>
	<key>MinimumOSVersion</key><string>12.0</string>
	<key>CFBundleSupportedPlatforms</key><array><string>iPhoneOS</string></array>
</dict>
</plist>
PLIST

	# waf's scripts/waifulib/sdl2.py --sdl2=<path> option (used by package-ipa.sh)
	# requires a real "<path>/Headers" directory with SDL's public headers, and adds
	# it directly as an include dir (code does #include "SDL.h", not <SDL2/SDL.h>).
	mkdir -p "$FW/Headers"
	cp "$ROOT_DIR"/thirdparty/SDL-src/include/*.h "$FW/Headers/"
fi

echo "=== SDL2.framework installed to $FRAMEWORKS_DIR/SDL2.framework ==="
