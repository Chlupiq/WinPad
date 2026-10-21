#!/bin/sh
# Builds FEX's aarch64 WoW64 module (libwow64fex.dll, which Madeira ships as
# aarch64-windows/xtajit.dll) from Madeira's FEX fork, with the options of
# Madeira's build/fex-wow64/build.sh, so its code can be changed and its logs
# read. Uses the llvm-mingw toolchain Madeira names (docs/BUILDING.md there).
#
# Also builds FEX's offline compiler from the same tree and options: a code
# cache only fits the FEX build that made it.
#
# Usage: build.sh WORK_DIR
# Leaves WORK_DIR/xtajit.dll and WORK_DIR/FEXOfflineCompiler.exe.
set -eu

work=$1
FEX_REPO=https://github.com/willfaust/FEX.git
FEX_COMMIT=3bec2ac498bf78156ab47c0c194b0e8cb2849756  # Madeira's FEX submodule
TOOLCHAIN=llvm-mingw-20260421-ucrt-ubuntu-22.04-aarch64
mkdir -p "$work"

if [ ! -x "$work/$TOOLCHAIN/bin/clang" ]; then
    curl -fsSL "https://github.com/mstorsjo/llvm-mingw/releases/download/20260421/$TOOLCHAIN.tar.xz" |
        tar -xJ -C "$work"
fi
export PATH="$work/$TOOLCHAIN/bin:$PATH"

src="$work/FEX"
if [ ! -d "$src/.git" ]; then
    git init -q "$src"
    git -C "$src" remote add origin "$FEX_REPO"
fi
git -C "$src" fetch -q --depth 1 origin "$FEX_COMMIT"
git -C "$src" checkout -q -f FETCH_HEAD
# Files a patch added in an earlier (cached) build would make it fail to apply again.
git -C "$src" clean -q -fd
# Skip the large test-binary submodules.
for m in $(git -C "$src" config -f .gitmodules --get-regexp 'submodule\..*\.path' | awk '{print $2}'); do
    case "$m" in External/fex-*-bins) continue ;; esac
    git -C "$src" submodule update -q --init --depth 1 "$m"
    # A patch may change a submodule (patches/fex-wow64/0021: rpmalloc), and
    # submodule update leaves the changes in a restored tree in place.
    git -C "$src/$m" checkout -q -f HEAD -- .
    git -C "$src/$m" clean -q -fd
done
# WinPad changes to the WoW64 module, see the header of each patch.
for p in "$(cd "$(dirname "$0")" && pwd)"/../../patches/fex-wow64/*.patch; do
    git -C "$src" apply "$p"
done

b="$work/build-wow64"
# Configured every time, so that a build restored from an older cache gets
# today's options. 16 KiB sections let tools/pe2macho wrap xtajit.dll into a
# dylib (iOS pages are 16 KiB).
cmake -S "$src" -B "$b" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_TOOLCHAIN_FILE="$src/Data/CMake/toolchain_mingw.cmake" \
    -DMINGW_TRIPLE=aarch64-w64-mingw32 \
    -DFEX_IOS_HOST_BUILD=ON -DCMAKE_C_FLAGS=-DFEX_IOS_HOST \
    -DCMAKE_CXX_FLAGS=-DFEX_IOS_HOST -DCMAKE_ASM_FLAGS=-DFEX_IOS_HOST \
    -DENABLE_LTO=OFF -DENABLE_ASSERTIONS=OFF -DENABLE_JEMALLOC_GLIBC_ALLOC=OFF \
    -DBUILD_TESTING=OFF -DBUILD_FEXCONFIG=OFF -DTUNE_ARCH=generic -DTUNE_CPU=none \
    -DCMAKE_SHARED_LINKER_FLAGS=-Wl,--section-alignment,16384 \
    -DCMAKE_POLICY_VERSION_MINIMUM=3.5
cmake --build "$b" --target wow64fex FEXOfflineCompiler
cp "$b/Bin/libwow64fex.dll" "$work/xtajit.dll"
cp "$b/Bin/FEXOfflineCompiler.exe" "$work/FEXOfflineCompiler.exe"
for f in xtajit.dll FEXOfflineCompiler.exe; do
    echo "Built $work/$f: $(wc -c <"$work/$f" | tr -d ' ') bytes"
done
