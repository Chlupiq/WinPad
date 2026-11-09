#!/bin/sh
# SPDX-License-Identifier: MIT
# Builds StikJIT (github.com/StikDebug/StikJIT, MPL-2.0) for the iPad with this Mac's Xcode,
# for WinPad Wine's built-in JIT helper (JITHelper/): the helper imports its Swift module,
# which only the compiler that built it is sure to read.
#
# usage: build-stikjit.sh OUT_DIR   -> OUT_DIR/StikJIT.framework (iphoneos, unsigned)
# Needs: Xcode, xcodegen, git.
set -eu

tag=2.0.1
[ $# -eq 1 ] || { echo "usage: $0 OUT_DIR" >&2; exit 2; }
out=$1
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

git clone -q --depth 1 --branch "$tag" https://github.com/StikDebug/StikJIT.git "$work/src"
(cd "$work/src" && xcodegen generate >/dev/null)
xcodebuild archive -project "$work/src/StikJIT.xcodeproj" -scheme StikJIT \
    -destination 'generic/platform=iOS' -archivePath "$work/StikJIT" \
    SKIP_INSTALL=NO BUILD_LIBRARY_FOR_DISTRIBUTION=YES CODE_SIGNING_ALLOWED=NO \
    >"$work/xcodebuild.log" 2>&1 || { tail -60 "$work/xcodebuild.log" >&2; exit 1; }
framework="$work/StikJIT.xcarchive/Products/Library/Frameworks/StikJIT.framework"
test -f "$framework/StikJIT" || { echo "no StikJIT.framework in the archive" >&2; exit 1; }
mkdir -p "$out"
rm -rf "$out/StikJIT.framework"
cp -R "$framework" "$out/"
cp "$work/src/LICENSE" "$out/StikJIT-LICENSE.txt"
echo "StikJIT $tag: $out/StikJIT.framework ($(du -sh "$out/StikJIT.framework" | cut -f1))"
