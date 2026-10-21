#!/bin/sh
# Runs check-wow-window.py: Madeira's guest-window code, with patches/madeira,
# compiled against the fake address map of an iPad whose map ends at
# 0x7180000000. Needs git, python3 and cc; runs on Linux too.
#
# Usage: check-wow-window.sh WORK_DIR
set -eu

MADEIRA_REPO=https://github.com/willfaust/Madeira.git
MADEIRA_COMMIT=48f976429c189f8396e23d251d8a82f43c705922  # as in build.sh

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work=$1
madeira="$work/madeira-wow"
if [ ! -d "$madeira/.git" ]; then
    git init -q "$madeira"
    git -C "$madeira" sparse-checkout set --no-cone /build/ntdll-unix/ /tests/host/
    git -C "$madeira" fetch -q --depth 1 --filter=blob:none "$MADEIRA_REPO" "$MADEIRA_COMMIT"
fi
git -C "$madeira" checkout -q -f "$MADEIRA_COMMIT"
# Only Madeira's own sources are checked out, not its Wine tree
# (patches/madeira/0005 changes wine/dlls/ntdll/unix/file.c).
git -C "$madeira" apply --exclude='wine/*' "$root"/patches/madeira/*.patch
python3 -I "$madeira/tests/host/check-lazy-windows.py"
python3 -I "$here/check-wow-window.py" "$madeira"
