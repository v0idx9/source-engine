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

# IMPORTANT: every caller does `OUT="$(cmake_build_static ...)"`, which captures this
# entire function's STDOUT, not just the final `echo "$found"` -- so every other line
# in here must be redirected to stderr (>&2), or cmake's own multi-hundred-line
# configure/build/install output ends up concatenated into $OUT, and the caller's
# `cp "$OUT" ...` then fails trying to use that whole blob as a single filename.
cmake_build_static() {
	local src_dir="$1" build_subdir="$2" out_lib_name="$3"; shift 3
	local build_dir="$BUILD_ROOT/$build_subdir"
	echo "=== Building $build_subdir ===" >&2
	rm -rf "$build_dir"
	cmake -S "$src_dir" -B "$build_dir" -G "Unix Makefiles" \
		-DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_INSTALL_PREFIX="$build_dir/install" \
		-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
		"$@" >&2
	if [ -n "${CMAKE_BUILD_TARGET:-}" ]; then
		cmake --build "$build_dir" --parallel "$JOBS" --target "$CMAKE_BUILD_TARGET" >&2
	else
		cmake --build "$build_dir" --parallel "$JOBS" >&2
	fi
	cmake --install "$build_dir" >&2
	local found
	# Search the install prefix first, then fall back to the raw build dir. Some of
	# these libraries install both a versioned and unversioned name for the same lib
	# (e.g. libpng16.a and libpng.a) which can match a glob like "libpng*.a" more than
	# once; take just the first hit via `head -1` rather than relying on `find -quit`
	# to stop at exactly one result across multiple search roots.
	found="$(find "$build_dir/install" -maxdepth 4 -name "$out_lib_name" 2>/dev/null | head -1)"
	if [ -z "$found" ]; then
		found="$(find "$build_dir" -maxdepth 3 -name "$out_lib_name" 2>/dev/null | head -1)"
	fi
	if [ -z "$found" ]; then
		echo "error: expected to produce $out_lib_name in $build_dir, but didn't find it" >&2
		exit 1
	fi
	echo "$found"
}

# zutil.c includes "zutil.h" (which #define local static) before "gzguts.h" (which
# does a fresh #include <stdio.h>). Under recent iOS SDKs that second, differently-
# configured re-entry into <stdio.h> happens while "local" is already macro'd to
# "static", corrupting an unrelated identifier in Apple's header and producing a
# baffling "_stdio.h:322:7: error: expected identifier or '('". Only zutil.c is
# affected -- the other gz*.c files include gzguts.h first, before any zlib macros
# are defined. Force <stdio.h> to be fully (and cleanly) parsed before zutil.h ever
# runs, so gzguts.h's later #include <stdio.h> is just a no-op via the include guard.
ZUTIL_C="$ROOT_DIR/thirdparty/zlib/zutil.c"
if [ -f "$ZUTIL_C" ] && ! head -1 "$ZUTIL_C" | grep -q '#include <stdio.h>'; then
	echo "=== Patching zutil.c: hoist <stdio.h> before zutil.h's 'local' macro ==="
	TMP_ZUTIL="$(mktemp)"
	{ echo '#include <stdio.h> /* patched by scripts/ios/build-deps.sh, see comment there */'; cat "$ZUTIL_C"; } > "$TMP_ZUTIL"
	mv "$TMP_ZUTIL" "$ZUTIL_C"
fi

# --- zlib ---
# Classic zlib's CMakeLists always defines both "zlib" (shared) and "zlibstatic"
# targets regardless of BUILD_SHARED_LIBS, and its install() rule references both --
# so building only "zlibstatic" (to dodge an iOS shared-lib cross-compile) and then
# running `cmake --install` would fail looking for the shared lib we never built.
# Just grab the static lib straight out of the build dir instead of installing.
if [ ! -f "$LIBDIR/libz.a" ]; then
	ZLIB_BUILD_DIR="$BUILD_ROOT/zlib"
	rm -rf "$ZLIB_BUILD_DIR"
	cmake -S "$ROOT_DIR/thirdparty/zlib" -B "$ZLIB_BUILD_DIR" -G "Unix Makefiles" \
		-DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_POLICY_VERSION_MINIMUM=3.5
	cmake --build "$ZLIB_BUILD_DIR" --parallel "$JOBS" --target zlibstatic
	OUT="$(find "$ZLIB_BUILD_DIR" -maxdepth 2 -name 'libz.a' -print -quit)"
	if [ -z "$OUT" ]; then
		echo "error: expected to produce libz.a in $ZLIB_BUILD_DIR, but didn't find it" >&2
		exit 1
	fi
	cp "$OUT" "$LIBDIR/libz.a"
fi

# This vendored libpng predates iOS: pngpriv.h treats any TARGET_OS_MAC build (true
# on modern iOS too, via TargetConditionals.h -- not just classic Mac OS) as wanting
# the decades-extinct classic-MacOS <fp.h> header instead of <math.h>, which no
# longer exists on any current Apple SDK ("fatal error: 'fp.h' file not found").
# Drop TARGET_OS_MAC from that check so only genuinely archaic compilers
# (__MWERKS__/applec/THINK_C/__SC__, none of which are ever true here) can still hit
# the <fp.h> branch, and modern Apple builds always take the <math.h> path.
PNGPRIV_H="$ROOT_DIR/thirdparty/libpng/pngpriv.h"
if [ -f "$PNGPRIV_H" ] && grep -q 'defined(TARGET_OS_MAC)' "$PNGPRIV_H"; then
	echo "=== Patching pngpriv.h: don't route modern Apple builds through <fp.h> ==="
	sed -i '' 's/defined(THINK_C) || defined(__SC__) || defined(TARGET_OS_MAC)/defined(THINK_C) || defined(__SC__)/' "$PNGPRIV_H"
fi

# --- libpng (needs zlib) ---
if [ ! -f "$LIBDIR/libpng.a" ]; then
	ZLIB_H_DIR="$ROOT_DIR/thirdparty/zlib"
	# PNG_ARM_NEON defaults to "check", which needs a PNG_ARM_NEON_FILE providing a
	# runtime CPU-feature probe that isn't set up for iOS cross-compiles here
	# ("PNG_ARM_NEON_FILE undefined: no support for run-time ARM NEON checks").
	# Cross-compiling straight to arm64 makes the whole runtime-check moot anyway;
	# just disable the NEON fast path (minor PNG-decode perf cost, not correctness).
	OUT="$(cmake_build_static "$ROOT_DIR/thirdparty/libpng" libpng "libpng*.a" \
		-DPNG_SHARED=OFF -DPNG_STATIC=ON -DPNG_TESTS=OFF -DPNG_TOOLS=OFF \
		-DPNG_ARM_NEON=off \
		-DZLIB_INCLUDE_DIR="$ZLIB_H_DIR" -DZLIB_LIBRARY="$LIBDIR/libz.a")"
	cp "$OUT" "$LIBDIR/libpng.a"
fi

# --- libjpeg ---
# This is not libjpeg-turbo -- it's classic IJG libjpeg wrapped in a LuaDist
# CMakeLists.txt (only cjpeg/djpeg/jconfig.h.cmake etc, no SIMD/turbojpeg files), so
# it uses that wrapper's own option names (BUILD_STATIC/BUILD_EXECUTABLES/BUILD_TESTS),
# not libjpeg-turbo's (ENABLE_STATIC/WITH_SIMD/...), which would have silently no-op'd.
if [ ! -f "$LIBDIR/libjpeg.a" ]; then
	OUT="$(cmake_build_static "$ROOT_DIR/thirdparty/libjpeg" libjpeg libjpeg.a \
		-DBUILD_STATIC=ON -DBUILD_EXECUTABLES=OFF -DBUILD_TESTS=OFF)"
	cp "$OUT" "$LIBDIR/libjpeg.a"
fi

# --- freetype (png/harfbuzz/bzip2/brotli disabled; zlib pointed at our real libz.a) ---
# FT_DISABLE_ZLIB=ON does NOT drop the gzip-compressed-font source file (ftgzip.c)
# from the build -- it just makes that file fall back to freetype's own old bundled
# zlib copy instead of a real one, and that fallback fails to build here ("error:
# incompatible pointer types ... Bytef*"). Point it at our already-working real zlib
# instead of disabling zlib entirely.
if [ ! -f "$LIBDIR/libfreetype2.a" ]; then
	OUT="$(cmake_build_static "$ROOT_DIR/thirdparty/freetype" freetype "libfreetype*.a" \
		-DFT_DISABLE_ZLIB=OFF -DFT_REQUIRE_ZLIB=ON \
		-DZLIB_INCLUDE_DIR="$ROOT_DIR/thirdparty/zlib" -DZLIB_LIBRARY="$LIBDIR/libz.a" \
		-DFT_DISABLE_PNG=ON -DFT_DISABLE_HARFBUZZ=ON \
		-DFT_DISABLE_BZIP2=ON -DFT_DISABLE_BROTLI=ON -DBUILD_SHARED_LIBS=OFF)"
	cp "$OUT" "$LIBDIR/libfreetype2.a"
fi

# --- curl (Apple Secure Transport for TLS, no OpenSSL needed) ---
# This vendored curl is 7.79.0: the SSL-backend option is CMAKE_USE_SECTRANSP /
# CMAKE_USE_OPENSSL (renamed to CURL_USE_* only in much later curl releases).
# CMake silently ignores unrecognized -D cache vars instead of erroring, so getting
# these names wrong wouldn't fail the build -- it'd just silently produce a curl
# with no working TLS backend.
if [ ! -f "$LIBDIR/libcurl.a" ]; then
	OUT="$(cmake_build_static "$ROOT_DIR/thirdparty/curl" curl libcurl.a \
		-DBUILD_SHARED_LIBS=OFF -DBUILD_CURL_EXE=OFF -DBUILD_TESTING=OFF \
		-DCMAKE_USE_SECTRANSP=ON -DCMAKE_USE_OPENSSL=OFF -DCURL_DISABLE_LDAP=ON \
		-DCURL_DISABLE_TELNET=ON -DZLIB_INCLUDE_DIR="$ROOT_DIR/thirdparty/zlib" \
		-DZLIB_LIBRARY="$LIBDIR/libz.a" -DHTTP_ONLY=OFF)"
	cp "$OUT" "$LIBDIR/libcurl.a"
fi

echo "=== Static libs installed to $LIBDIR ==="
ls -la "$LIBDIR"

# --- SDL2.framework (built from this repo's patched thirdparty/SDL-src) ---
FRAMEWORKS_DIR="$ROOT_DIR/Frameworks"
mkdir -p "$FRAMEWORKS_DIR"
if [ ! -d "$FRAMEWORKS_DIR/SDL2.framework" ]; then
	# SDL's CMakeLists.txt unconditionally probes for -Wdeclaration-after-statement
	# support and, if found, escalates it to -Werror=declaration-after-statement for
	# the whole build (no CMake option to opt out). At least one bundled source file
	# (SDL_rwopsbundlesupport.m) violates that under this SDK/toolchain. SDL2 is a
	# large codebase, so rather than fixing files one at a time as each surfaces from
	# a slow CI iteration, just stop the flag from ever being added -- fully
	# neutralizes the whole warning-as-error class regardless of later compiler flag
	# precedence, which patching CFLAGS to override it wouldn't reliably guarantee.
	SDL_CMAKELISTS="$ROOT_DIR/thirdparty/SDL-src/CMakeLists.txt"
	if grep -q 'declaration-after-statement' "$SDL_CMAKELISTS"; then
		echo "=== Patching SDL CMakeLists.txt: don't escalate -Wdeclaration-after-statement to -Werror ===" >&2
		sed -i '' '/declaration-after-statement/d' "$SDL_CMAKELISTS"
	fi

	echo "=== Building SDL2 (static lib, then wrapped into a framework) ==="
	SDL_BUILD_DIR="$BUILD_ROOT/sdl2"
	rm -rf "$SDL_BUILD_DIR"
	cmake -S "$ROOT_DIR/thirdparty/SDL-src" -B "$SDL_BUILD_DIR" -G "Unix Makefiles" \
		-DCMAKE_TOOLCHAIN_FILE="$TOOLCHAIN" \
		-DCMAKE_BUILD_TYPE=Release \
		-DCMAKE_POLICY_VERSION_MINIMUM=3.5 \
		-DSDL_STATIC=ON -DSDL_SHARED=OFF \
		-DSDL_AUDIO=ON -DSDL_VIDEO=ON -DSDL_RENDER=ON -DSDL_JOYSTICK=ON \
		-DSDL_HAPTIC=ON -DSDL_ATOMIC=ON -DSDL_THREADS=ON -DSDL_FILE=ON \
		-DSDL_LOADSO=ON -DSDL_CPUINFO=ON -DSDL_FILESYSTEM=ON -DSDL_SENSOR=ON \
		-DSDL_LIBSAMPLERATE=OFF
	cmake --build "$SDL_BUILD_DIR" --parallel "$JOBS"
	SDL_STATIC_LIB="$(find "$SDL_BUILD_DIR" -maxdepth 3 -name 'libSDL2.a' 2>/dev/null | head -1)"
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
	# -force_load pulls in every object from libSDL2.a, including subsystems this
	# engine doesn't use through this framework directly but which still need their
	# symbols resolved at link time: SDL's built-in GLES1/GLES2 SDL_Renderer backends
	# and EAGL-based SDL_uikitopenglview (OpenGLES.framework), SDL_iconv
	# (iconv/iconv_open/iconv_close -> libiconv), Metal-based joystick/render hints
	# (MTLCreateSystemDefaultDevice -> Metal.framework), and Bluetooth game controller
	# support (CBAdvertisementDataLocalNameKey -> CoreBluetooth.framework). Full list
	# cross-checked against every "referenced from" in a real failed link.
	clang -dynamiclib \
		--target=aarch64-apple-ios -mios-version-min=12.0 -isysroot "$SDKROOT" \
		-Wl,-force_load,"$SDL_STATIC_LIB" \
		-framework Foundation -framework UIKit -framework CoreGraphics \
		-framework QuartzCore -framework CoreAudio -framework AudioToolbox \
		-framework AVFoundation -framework CoreMotion -framework GameController \
		-framework CoreHaptics -framework OpenGLES -framework Metal \
		-framework CoreBluetooth -liconv \
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
