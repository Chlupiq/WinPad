#!/bin/sh
# Builds FEXCore (upstream FEX at tests/fex-cache/fex-commit with
# patches/fex) as static libraries for iOS (arm64, device). macOS host with
# Xcode only. This is the core the iPad test app links; Madeira's fork builds
# the same targets the same way (build/fex-ios/build.sh there).
#
# Usage: build-fexcore.sh SRC_DIR BUILD_DIR
set -eu

here=$(cd "$(dirname "$0")" && pwd)
src=$1
build=$2
sh "$here/../fex-cache/fetch-fex.sh" "$src"

# TUNE_CPU=none: the build host is not the iPad, and FEX would read /proc/cpuinfo
cmake -S "$src" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64 -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 \
    -DENABLE_LTO=False -DENABLE_ASSERTIONS=True -DBUILD_TESTING=False \
    -DBUILD_THUNKS=False -DBUILD_FEX_LINUX_TESTS=False -DBUILD_FEXCONFIG=False \
    -DENABLE_FEX_ALLOCATOR=False -DTUNE_CPU=none
# -k 0: report every file that does not compile yet, not just the first
cmake --build "$build" --target FEXCore FEXCore_Base -- -k 0
find "$build" -name '*.a' | sort
