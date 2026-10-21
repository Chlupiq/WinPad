#!/bin/sh
# Fetches DXMT at the commit Madeira's dxmt submodule pins (willfaust/dxmt,
# ios-port: Metal on iOS, the D3D9 frontend and the i386 d3d9shim), with the
# one nested submodule the build needs (include/native/directx), into
# ROOT/dxmt, where Madeira's build/dxmt-ios/build.sh looks for it.
#
# Usage: fetch-dxmt.sh ROOT
set -eu

DXMT_REPO=https://github.com/willfaust/dxmt.git
DXMT_COMMIT=db546ee466ad50ec6463edb5fa183de11db43761  # Madeira 48f9764's dxmt submodule
HEADERS_REPO=https://github.com/misyltoad/mingw-directx-headers
HEADERS_COMMIT=9df86f2341616ef1888ae59919feaa6d4fad693d  # dxmt's include/native/directx

d="$1/dxmt"
if [ ! -d "$d/.git" ]; then
    git init -q "$d"
    git -C "$d" fetch -q --depth 1 "$DXMT_REPO" "$DXMT_COMMIT"
    git -C "$d" checkout -q FETCH_HEAD
fi
h="$d/include/native/directx"
if [ ! -f "$h/d3d11.h" ]; then
    rm -rf "$h"
    git init -q "$h"
    git -C "$h" fetch -q --depth 1 "$HEADERS_REPO" "$HEADERS_COMMIT"
    git -C "$h" checkout -q FETCH_HEAD
fi
echo "DXMT $(git -C "$d" rev-parse --short HEAD) in $d"
