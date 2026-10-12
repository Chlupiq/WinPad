#!/bin/sh
# Builds upstream FEX at a pinned commit (ARM64 Linux host only), runs a small
# x86-64 guest with code caching enabled so FEXServer records a code map and
# FEXOfflineCompiler turns it into a code cache, then counts what is in that
# cache with tools/fxcc-inspect.
#
# This is the baseline for the AOT mode (docs/M1-findings.md, section B): every
# relocation reported here is a write into code that iOS without JIT forbids.
#
# Needs: git, cmake, ninja, clang, lld, python3. Set FEX_BUILD to reuse a build.
set -eu

FEX_REPO=https://github.com/FEX-Emu/FEX.git
FEX_COMMIT=14c92681f4d62cf84d901460e0358de09c8847a7

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work=${WORK_DIR:-$(mktemp -d)}
mkdir -p "$work"

if [ "$(uname -m)" != aarch64 ]; then
    echo "FEX needs an ARM64 host" >&2
    exit 1
fi

src="$work/fex"
build=${FEX_BUILD:-$work/fex-build}
if [ ! -x "$build/Bin/FEX" ]; then
    if [ ! -d "$src/.git" ]; then
        git init -q "$src"
        git -C "$src" remote add origin "$FEX_REPO"
    fi
    git -C "$src" fetch -q --depth 1 origin "$FEX_COMMIT"
    git -C "$src" checkout -q FETCH_HEAD
    # Skip the large test-binary submodules.
    for m in $(git -C "$src" config -f .gitmodules --get-regexp 'submodule\..*\.path' | awk '{print $2}'); do
        case "$m" in External/fex-*-bins) continue ;; esac
        git -C "$src" submodule update -q --init --depth 1 "$m"
    done
    cmake -S "$src" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
        -DCMAKE_C_COMPILER=clang -DCMAKE_CXX_COMPILER=clang++ \
        -DENABLE_LTO=False -DENABLE_ASSERTIONS=True -DBUILD_TESTING=False \
        -DBUILD_THUNKS=False -DBUILD_FEX_LINUX_TESTS=False -DBUILD_FEXCONFIG=False
    cmake --build "$build" --target FEX FEXServer FEXOfflineCompiler
fi

guest="$work/guest"
clang --target=x86_64-linux-gnu -nostdlib -static -fuse-ld=lld -o "$guest" "$here/guest.S"

# Isolated FEX config and cache directories.
export HOME="$work/home"
export XDG_DATA_HOME="$HOME/.local/share" XDG_CACHE_HOME="$HOME/.cache" XDG_CONFIG_HOME="$HOME/.config"
mkdir -p "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"
export FEX_ENABLECODECACHINGWIP=1
export PATH="$build/Bin:$PATH"

# First runs record code maps; FEXServer merges them and runs FEXOfflineCompiler
# when the same executable starts again.
for i in 1 2 3; do
    out=$(FEX "$guest")
    [ "$out" = ok ] || { echo "guest printed '$out' on run $i" >&2; exit 1; }
    FEXServer -k >/dev/null 2>&1 || true
    sleep 2
done

echo "FEX cache directory:"
find "$HOME" -path '*fex-emu*' -type f | sed "s|$HOME/||"

caches=$(find "$HOME" -path '*fex-emu/cache/*' -type f ! -name '*.tmp' ! -name '*.lock')
if [ -z "$caches" ]; then
    echo "no code cache was generated" >&2
    exit 1
fi
# shellcheck disable=SC2086
python3 -I "$root/tools/fxcc-inspect/fxcc_inspect.py" --json "$work/census.json" $caches
