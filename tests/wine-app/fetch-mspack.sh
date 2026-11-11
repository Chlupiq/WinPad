#!/bin/sh
# Fetches the part of libmspack (kyz/libmspack, LGPL-2.1) the app needs to read Microsoft's
# cabinet files (Redist.c): the cabinet decompressor with its MSZIP, Quantum and LZX
# decoders. Into OUT: mspack/*.c, *.h and the licence, COPYING.LIB.
# Usage: fetch-mspack.sh OUT
set -eu
out=${1:?usage: fetch-mspack.sh OUT}
MSPACK_COMMIT=55d501976171397ccd5d5a7a1ca7da065b1d9a06
src=$(mktemp -d)
git -C "$src" init -q
git -C "$src" remote add origin https://github.com/kyz/libmspack.git
git -C "$src" fetch -q --depth 1 origin "$MSPACK_COMMIT"
git -C "$src" checkout -q FETCH_HEAD
mkdir -p "$out"
m="$src/libmspack/mspack"
for f in system.c cabd.c mszipd.c lzxd.c qtmd.c \
    system.h mspack.h macros.h cab.h mszip.h lzx.h qtm.h readbits.h readhuff.h; do
    cp "$m/$f" "$out/"
done
cp "$src/libmspack/COPYING.LIB" "$out/"
rm -rf "$src"
