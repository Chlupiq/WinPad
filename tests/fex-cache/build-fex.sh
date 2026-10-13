#!/bin/sh
# Builds upstream FEX (FEX, FEXServer, FEXOfflineCompiler) at the commit pinned
# in fex-commit, with patches/fex applied by fetch-fex.sh. CI caches the build
# keyed on these files, so any change to how FEX is built belongs in them.
#
# Usage: build-fex.sh SRC_DIR BUILD_DIR
set -eu

here=$(cd "$(dirname "$0")" && pwd)
src=$1
build=$2
sh "$here/fetch-fex.sh" "$src"

cmake -S "$src" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
    -DENABLE_LTO=False -DENABLE_ASSERTIONS=True -DBUILD_TESTING=False \
    -DBUILD_THUNKS=False -DBUILD_FEX_LINUX_TESTS=False -DBUILD_FEXCONFIG=False
cmake --build "$build" --target FEX FEXServer FEXOfflineCompiler
