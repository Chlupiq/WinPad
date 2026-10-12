#!/bin/sh
# Builds upstream FEX (FEX, FEXServer, FEXOfflineCompiler) at the commit pinned
# in fex-commit. CI caches the build keyed on this file, so any change to how
# FEX is built belongs here.
#
# Usage: build-fex.sh SRC_DIR BUILD_DIR
set -eu

here=$(cd "$(dirname "$0")" && pwd)
src=$1
build=$2
FEX_REPO=https://github.com/FEX-Emu/FEX.git
FEX_COMMIT=$(cat "$here/fex-commit")

if [ ! -d "$src/.git" ]; then
    git init -q "$src"
    git -C "$src" remote add origin "$FEX_REPO"
fi
git -C "$src" fetch -q --depth 1 origin "$FEX_COMMIT"
git -C "$src" checkout -q -f FETCH_HEAD
# Skip the large test-binary submodules.
for m in $(git -C "$src" config -f .gitmodules --get-regexp 'submodule\..*\.path' | awk '{print $2}'); do
    case "$m" in External/fex-*-bins) continue ;; esac
    git -C "$src" submodule update -q --init --depth 1 "$m"
done

# On Linux, FEX at this commit never writes the main-executable marker into
# code maps (only the Windows ImageTracker does). FEXServer asserts on its
# absence when FEX asks it to populate the cache at startup, which kills the
# server before it can hand out a code map file. Drop that one assertion and
# keep the rest of the assertion build.
pipe="$src/Source/Tools/FEXServer/ProcessPipe.cpp"
grep -q 'New code maps did not contain executable marker' "$pipe"
sed -i '/New code maps did not contain executable marker/d' "$pipe"

# WinPad fixes to FEX, see the header of each patch.
for p in "$here"/../../patches/fex/*.patch; do
    git -C "$src" apply "$p"
done

cmake -S "$src" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
    -DENABLE_LTO=False -DENABLE_ASSERTIONS=True -DBUILD_TESTING=False \
    -DBUILD_THUNKS=False -DBUILD_FEX_LINUX_TESTS=False -DBUILD_FEXCONFIG=False
cmake --build "$build" --target FEX FEXServer FEXOfflineCompiler
