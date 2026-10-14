#!/bin/sh
# Builds the test DLL (testdll.c, ARM64 Windows) and wraps it with
# tools/pe2macho into a dylib for one Apple platform, checked with --check.
#
# Usage: build-dylib.sh WORK_DIR SDK TARGET OUT_DYLIB
#   SDK: macosx, iphoneos or iphonesimulator; TARGET: a clang target such as
#   arm64-apple-ios17.4. The dylib's install name is @rpath/<its file name>.
# Needs: Xcode, lld-link (brew install lld), python3.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work=$1
sdk=$2
target=$3
out=$4
mkdir -p "$work"
p2m="$root/tools/pe2macho/pe2macho.py"

# Wine aligns PE sections to 64 KiB; 16 KiB (an iOS page) is the least
# pe2macho accepts.
if [ ! -f "$work/testdll.dll" ]; then
    clang --target=aarch64-pc-windows-msvc -O2 -fno-stack-protector -c -o "$work/testdll.obj" "$here/testdll.c"
    lld-link /dll /noentry /nodefaultlib /machine:arm64 /align:65536 /out:"$work/testdll.dll" "$work/testdll.obj"
    python3 -I "$p2m" "$work/testdll.dll" "$work/testdll.s"
fi
obj="$work/testdll-$sdk.o"
xcrun --sdk "$sdk" clang -target "$target" -c -o "$obj" "$work/testdll.s"
# shellcheck disable=SC2046 # one flag per line
xcrun --sdk "$sdk" clang -target "$target" -dynamiclib -install_name "@rpath/$(basename "$out")" \
    -o "$out" "$obj" $(cat "$work/testdll.ldflags")
python3 -I "$p2m" --check "$work/testdll.dll" "$out"
