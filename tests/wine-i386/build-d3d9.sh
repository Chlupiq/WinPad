#!/bin/sh
# Builds the 32-bit side of Direct3D 9 the way Madeira's
# build/wine-i386/build.sh does (its DXMT part, docs/WOW64.md "Direct3D 9"):
# DXMT for i386 with meson and Madeira's i686 cross file, linked against the
# import libraries of the i386 Wine tree. Installed into WORK_DIR/i386-windows
# like Madeira's farm: the shim as d3d9.dll and d3d9shim.dll, DXMT's D3D9
# frontend as d3d9-emulated.dll (the shim forwards to it), and winemetal.dll,
# which the frontend reaches Metal through (its 32-bit unix-call table).
# Also builds d3d9-cube.c, Madeira's tests/x86/d3d9-cube-x86.c, the way
# Madeira's tests/x86/build-d3d9-cube.sh does.
#
# The Wine modules a 32-bit program with a window needs come first, built
# with build.sh: user32 and what it imports, and ucrtbase, which DXMT's DLLs
# import through api-ms-win-crt-*.
#
# Usage: build-d3d9.sh WORK_DIR
# WORK_DIR must hold the Wine tree tests/wine-loader/build.sh fetched.
# Needs LLVM clang, llvm-dlltool and lld, bison, flex, meson and ninja; DXMT
# is built with llvm-mingw (fetched here) as in Madeira, its shaders with
# Xcode's Metal toolchain.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
work=$1
b="$work/madeira/wine/build-i386"
out="$work/i386-windows"
r="$work/dxmt-root"
jobs=$(sysctl -n hw.ncpu 2>/dev/null || nproc)
TOOLCHAIN=llvm-mingw-20260421-ucrt-macos-universal

sh "$here/build.sh" "$work" ntdll kernelbase kernel32 user32 gdi32 win32u advapi32 sechost \
    msvcrt ucrtbase imm32 dbghelp

# What DXMT's meson build takes from the Wine tree (src/winemetal/meson.build).
targets=
for lib in winecrt0 ntdll dbghelp; do
    t=$(grep -oE "^(dlls|libs)/$lib/i386-windows/lib$lib\.a" "$b/Makefile" | sort -u | head -1)
    [ -n "$t" ] || { echo "no i386 lib$lib.a target in $b/Makefile" >&2; exit 2; }
    targets="$targets $t"
done
# shellcheck disable=SC2086 # a list of make targets
make -C "$b" -j"$jobs" $targets tools/winebuild/winebuild >>"$work/make-i386.log" 2>&1 ||
    { tail -20 "$work/make-i386.log" >&2; exit 1; }

tc="$work/$TOOLCHAIN/bin"
if [ ! -x "$tc/i686-w64-mingw32-clang" ]; then
    curl -fsSL "https://github.com/mstorsjo/llvm-mingw/releases/download/20260421/$TOOLCHAIN.tar.xz" |
        tar -xJ -C "$work"
fi

sh "$here/fetch-dxmt.sh" "$r"
d="$r/dxmt"
x="$r/dxmt-cross-i386.txt"
# Madeira's build/wine-i386/build.sh, the cross file as it writes it.
cat >"$x" <<EOF
[binaries]
c = '$tc/i686-w64-mingw32-clang'
cpp = '$tc/i686-w64-mingw32-clang++'
ar = '$tc/i686-w64-mingw32-ar'
strip = '$tc/i686-w64-mingw32-strip'
windres = '$tc/i686-w64-mingw32-windres'
dlltool = '$tc/i686-w64-mingw32-dlltool'

[properties]
needs_exe_wrapper = true

[host_machine]
system = 'windows'
cpu_family = 'x86'
cpu = 'i686'
endian = 'little'
EOF
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"
PATH="$tc:$PATH"
if [ ! -f "$d/build-pe-i386/build.ninja" ]; then
    (cd "$d" && meson setup --cross-file "$x" --native-file build-osx.txt --buildtype release \
        -Dwine_build_path="$b" -Dwine_builtin_dll=true build-pe-i386 >"$r/meson-i386.log" 2>&1) ||
        { tail -40 "$r/meson-i386.log" >&2; exit 1; }
fi
meson compile -C "$d/build-pe-i386" >"$r/meson-compile-i386.log" 2>&1 ||
    { grep -E 'error|FAILED' "$r/meson-compile-i386.log" | head -40 >&2; exit 1; }

p="$d/build-pe-i386/src"
"$tc/i686-w64-mingw32-strip" -o "$out/winemetal.dll" "$p/winemetal/winemetal.dll"
# The shim is what programs load as d3d9.dll; the emulated frontend (the
# meson target also called d3d9.dll) ships beside it as d3d9-emulated.dll.
"$tc/i686-w64-mingw32-strip" -o "$out/d3d9.dll" "$p/d3d9shim/d3d9shim.dll"
"$tc/i686-w64-mingw32-strip" -o "$out/d3d9shim.dll" "$p/d3d9shim/d3d9shim.dll"
"$tc/i686-w64-mingw32-strip" -o "$out/d3d9-emulated.dll" "$p/d3d9/d3d9.dll"

# The test program, with the flags of Madeira's build-d3d9-cube.sh. It runs
# for D3D9_CUBE_SECONDS of wall-clock time and exits with 43.
"$tc/i686-w64-mingw32-clang" -O2 -g -nostdlib -ffreestanding \
    -static-libgcc -Wno-unused-command-line-argument \
    -Wl,--entry=_start -Wl,--large-address-aware \
    -DMADEIRA_D3D9_SECONDS="${D3D9_CUBE_SECONDS:-8}" \
    -o "$out/d3d9-cube.exe" "$here/d3d9-cube.c" -lkernel32 -luser32 -ld3d9

# Every DLL a module imports has to be there (api-ms-win-* resolve through
# the API set schema, to ucrtbase).
missing=0
present=$(ls "$out" | tr 'A-Z' 'a-z')
for f in "$out"/*.dll "$out"/d3d9-cube.exe; do
    imports=$("$tc/llvm-objdump" -p "$f" | sed -n 's/^ *DLL Name: //p' | tr 'A-Z' 'a-z' | sort -u)
    echo "${f##*/}:" $imports
    for i in $imports; do
        case $i in api-ms-win-* | ext-ms-win-*) continue ;; esac
        echo "$present" | grep -qx "$i" && continue
        echo "missing import: ${f##*/} -> $i"
        missing=$((missing + 1))
    done
done
[ "$missing" = 0 ]
ls -l "$out"
