#!/bin/bash
# Fetches a prebuilt ANGLE (libEGL/libGLESv2) for iOS device (arm64) and lays it out
# where wscript's --ios --togles build expects it:
#   - headers: thirdparty/angle/include/{EGL,GLES2,GLES3,KHR}
#   - frameworks: Frameworks/libEGL.framework, Frameworks/libGLESv2.framework
#
# This engine has no committed source or prebuilt binary for ANGLE (verified: the
# thirdparty submodule has no "angle" dir at the pinned commit, and no fork ships one
# either), so this is fetched from kivy/angle-builder's GitHub releases, which is an
# actively CI-built, publicly verifiable source that produces exactly the two
# frameworks this codebase links against (see togl(es)/../wscript: FRAMEWORK_OPENGLES
# = "libEGL" when ANGLE is enabled).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
ANGLE_RELEASE_TAG="${ANGLE_RELEASE_TAG:-chromium-7151_rev1}"
ANGLE_ASSET="angle-iphoneos-arm64.tar.gz"
ANGLE_URL="https://github.com/kivy/angle-builder/releases/download/${ANGLE_RELEASE_TAG}/${ANGLE_ASSET}"

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

echo "Fetching ANGLE ($ANGLE_RELEASE_TAG) from kivy/angle-builder..."
curl -fL --retry 3 "$ANGLE_URL" -o "$WORK_DIR/angle.tar.gz"
tar xzf "$WORK_DIR/angle.tar.gz" -C "$WORK_DIR"

if [ ! -d "$WORK_DIR/libEGL.framework" ] || [ ! -d "$WORK_DIR/libGLESv2.framework" ]; then
	echo "error: expected libEGL.framework and libGLESv2.framework in the ANGLE release archive, got:" >&2
	find "$WORK_DIR" -maxdepth 1 >&2
	exit 1
fi

mkdir -p "$ROOT_DIR/thirdparty/angle/include"
rm -rf "$ROOT_DIR/thirdparty/angle/include"/*
cp -R "$WORK_DIR/include/." "$ROOT_DIR/thirdparty/angle/include/"

mkdir -p "$ROOT_DIR/Frameworks"
rm -rf "$ROOT_DIR/Frameworks/libEGL.framework" "$ROOT_DIR/Frameworks/libGLESv2.framework"
cp -R "$WORK_DIR/libEGL.framework" "$ROOT_DIR/Frameworks/"
cp -R "$WORK_DIR/libGLESv2.framework" "$ROOT_DIR/Frameworks/"

echo "ANGLE headers -> $ROOT_DIR/thirdparty/angle/include"
echo "ANGLE frameworks -> $ROOT_DIR/Frameworks/{libEGL,libGLESv2}.framework"
