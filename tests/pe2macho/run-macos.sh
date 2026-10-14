#!/bin/sh
# tools/pe2macho on an arm64 Mac: builds a small ARM64 Windows DLL
# (testdll.c), wraps it into a dylib, checks the layout and calls the DLL's
# exports from a Mac program. The same dylib layout is what an iPad loads.
#
# Usage: run-macos.sh WORK_DIR
# Needs: Xcode command line tools, lld-link (brew install lld), python3.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work=$1
mkdir -p "$work"
p2m="$root/tools/pe2macho/pe2macho.py"

python3 -I "$root/tools/pe2macho/test_pe2macho.py"

# Wine aligns PE sections to 64 KiB; 16 KiB (an iOS page) is the least
# pe2macho accepts.
clang --target=aarch64-pc-windows-msvc -O2 -fno-stack-protector -c -o "$work/testdll.obj" "$here/testdll.c"
lld-link /dll /noentry /nodefaultlib /machine:arm64 /align:65536 /out:"$work/testdll.dll" "$work/testdll.obj"

python3 -I "$p2m" "$work/testdll.dll" "$work/testdll.s"
clang -target arm64-apple-macos14 -c -o "$work/testdll.o" "$work/testdll.s"
# shellcheck disable=SC2046 # one flag per line
clang -target arm64-apple-macos14 -dynamiclib -nostdlib -install_name @rpath/testdll.dylib \
    -o "$work/testdll.dylib" "$work/testdll.o" $(cat "$work/testdll.ldflags")
python3 -I "$p2m" --check "$work/testdll.dll" "$work/testdll.dylib"

clang -target arm64-apple-macos14 -O2 -o "$work/pe2macho-test" "$here/main.c"
"$work/pe2macho-test" "$work/testdll.dylib"
