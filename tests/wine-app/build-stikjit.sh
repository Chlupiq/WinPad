#!/bin/sh
# SPDX-License-Identifier: MIT
# Fetches StikJIT (github.com/StikDebug/StikJIT, MPL-2.0) as source for WinPad Wine's built-in
# JIT helper (JITHelper/): its Swift files are compiled into the helper by whichever Xcode
# builds the project. A prebuilt StikJIT.framework only loads in the Xcode that built it (its
# .swiftinterface cannot be rebuilt by another: the module and its enum are both "StikJIT").
#
# usage: build-stikjit.sh OUT_DIR
#   -> OUT_DIR/Sources/*.swift, OUT_DIR/Scripts/*.js (the helper's resources),
#      OUT_DIR/idevice (module map, header, libidevice_ffi.a for iphoneos),
#      OUT_DIR/iokit (module map, header), OUT_DIR/LICENSE
# Needs: git.
set -eu
tag=2.0.1
[ $# -eq 1 ] || { echo "usage: $0 OUT_DIR" >&2; exit 2; }
out=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
git clone -q --depth 1 --branch "$tag" https://github.com/StikDebug/StikJIT.git "$work/src"
rm -rf "$out"
mkdir -p "$out/idevice" "$out/iokit"
cp -R "$work/src/Sources" "$work/src/Scripts" "$out/"
cp "$work/src/idevice/module.modulemap" "$work/src/idevice/idevice.h" "$work/src/idevice/libidevice_ffi.a" "$out/idevice/"
cp "$work/src/iokit/module.modulemap" "$work/src/iokit/StikJITIOKit.h" "$out/iokit/"
cp "$work/src/LICENSE" "$out/LICENSE"
test -f "$out/Sources/StikJIT.swift" && test -f "$out/Scripts/universal.js" ||
    { echo "StikJIT $tag: unexpected layout" >&2; exit 1; }
echo "StikJIT $tag source: $out ($(ls "$out/Sources" | wc -l | tr -d ' ') Swift files)"
