#!/bin/sh
# tools/pe2macho on an arm64 Mac: builds a small ARM64 Windows DLL
# (testdll.c), wraps it into a dylib, checks the layout and calls the DLL's
# exports from a Mac program. The iPad test app (tests/ios) does the same
# with an iOS build of the dylib.
#
# Usage: run-macos.sh WORK_DIR
# Needs: Xcode command line tools, lld-link (brew install lld), python3.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work=$1
mkdir -p "$work"

python3 -I "$root/tools/pe2macho/test_pe2macho.py"
python3 -I "$root/tools/pe2macho/test_fix_syscall_stubs.py"
python3 -I "$root/tools/pe2macho/test_x18.py"
sh "$here/build-dylib.sh" "$work" macosx arm64-apple-macos14 "$work/pe-testdll.dylib"
clang -target arm64-apple-macos14 -O2 -o "$work/pe2macho-test" "$here/main.c"
"$work/pe2macho-test" "$work/pe-testdll.dylib"
