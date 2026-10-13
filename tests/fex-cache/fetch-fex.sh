#!/bin/sh
# Checks out upstream FEX at the commit pinned in fex-commit, with the
# submodules a build needs, and applies WinPad's changes (patches/fex). Shared
# by the Linux build (build-fex.sh) and the iOS build (tests/ios).
#
# Usage: fetch-fex.sh SRC_DIR
set -eu

here=$(cd "$(dirname "$0")" && pwd)
src=$1
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
sed -i.orig '/New code maps did not contain executable marker/d' "$pipe"
rm "$pipe.orig"

# WinPad fixes to FEX, see the header of each patch.
for p in "$here"/../../patches/fex/*.patch; do
    git -C "$src" apply "$p"
done
