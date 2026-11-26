#!/bin/sh
# Builds winpad-xinput.dll (xinput.c) with llvm-mingw: TC is its bin folder, ARCH i686 or
# x86_64, OUT the folder it goes into. Without a C runtime, kernel32 only.
# Usage: build.sh TC ARCH OUT [test]   ("test" also builds xinput-test.exe)
set -eu
here=$(cd "$(dirname "$0")" && pwd)
tc=${1:?usage: build.sh TC ARCH OUT}
arch=${2:?usage: build.sh TC ARCH OUT}
out=${3:?usage: build.sh TC ARCH OUT}
mkdir -p "$out"
def="$here/xinput.def"
if [ "$arch" != i686 ]; then
    # No stdcall decorations off i386.
    def="$out/xinput-$arch.def"
    sed 's/\([A-Za-z]\)@[0-9]*/\1/' "$here/xinput.def" >"$def"
fi
"$tc/$arch-w64-mingw32-clang" -O2 -Wall -Werror -shared -nostdlib -ffreestanding -fno-builtin \
    -Wl,--entry,"$([ "$arch" = i686 ] && echo _DllMain@12 || echo DllMain)" -Wl,--kill-at \
    -o "$out/winpad-xinput.dll" "$here/xinput.c" "$def" -lkernel32
if [ "${4:-}" = test ]; then
    "$tc/$arch-w64-mingw32-clang" -O2 -Wall -Werror -o "$out/xinput-test.exe" "$here/xinput-test.c"
fi
"$tc/llvm-objdump" -p "$out/winpad-xinput.dll" | sed -n '/Export Table/,/^$/p;/DLL Name/p'
