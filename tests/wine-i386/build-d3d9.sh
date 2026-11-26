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
# Direct3D 8, which games of the early 2000s use (Mafia...), is d3d8to9
# (crosire/d3d8to9, BSD-2-Clause, its licence beside it as
# d3d8to9-LICENSE.md): d3d8.dll turns each D3D8 call into D3D9 ones, which go
# to the shim above. It assembles and disassembles shaders with d3dx9_43,
# Wine's (with d3dcompiler_43 and d3dxof, which it imports). d3d8-cube.c is
# the D3D8 cube.
#
# Direct3D 10 and 11 come from the same DXMT build: its dxgi.dll, d3d11.dll
# and d3d10core.dll, which reach Metal through the same winemetal.dll. Wine's
# own d3d10.dll and d3d10_1.dll (D3D10CreateDevice*, effects, reflection)
# hand their devices to DXMT's d3d10core.dll; Wine's D3DX10, D3DX11, D2D1 and
# d3dcompiler_47 (D3DCompile, which games of that time also call) are built
# for them. Wine's own DXGI and D3D11 are not: they draw through wined3d's
# OpenGL or Vulkan, which iOS has not. d3d11-triangle.c is the D3D11 test
# (also built as d3d10-triangle.exe, through D3D10).
# gl-triangle.c is the OpenGL test (Wine's opengl32.dll from build.sh, its
# unix side from tests/opengl/build.sh).
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
D3D8TO9=255338f698c8270b537f0a91a13f795f4f988250

# build.sh starts i386-windows afresh with the modules it is given; what was
# there before (modules and programs other steps built) is put back. So is
# hello.exe as it was: FEX's code caches and the AOT image of the runs
# before are for that file, and a relinked one differs (its time stamp).
# Wine's Direct3D 10 modules and the D3DX/D2D1 ones that import them (build.sh
# leaves them out, as nothing it builds has DXGI or Direct3D 10/11).
d3d10_wine="d3d10 d3d10_1 d3dcompiler_47 d2d1 d3dx11_42 d3dx11_43 d3dx10_33 d3dx10_34 d3dx10_35 \
    d3dx10_36 d3dx10_37 d3dx10_38 d3dx10_39 d3dx10_40 d3dx10_41 d3dx10_42 d3dx10_43"
keep=$(mktemp -d)
[ ! -d "$out" ] || cp -R "$out/." "$keep/"
sh "$here/build.sh" "$work" ntdll kernelbase kernel32 user32 gdi32 win32u advapi32 sechost \
    msvcrt ucrtbase imm32 dbghelp d3dx9_43 d3dcompiler_43 d3dxof $d3d10_wine
for f in "$keep"/*; do
    [ -e "$f" ] || continue
    n=${f##*/}
    [ -e "$out/$n" ] && [ "$n" != hello.exe ] && continue
    cp -R "$f" "$out/$n"
done
rm -rf "$keep"
# Without their debug information, like build.sh's other extra modules.
for m in $d3d10_wine; do
    llvm-strip --strip-debug "$out/$m.dll"
done

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
# Direct3D 10/11 and DXGI.
"$tc/i686-w64-mingw32-strip" -o "$out/dxgi.dll" "$p/dxgi/dxgi.dll"
"$tc/i686-w64-mingw32-strip" -o "$out/d3d11.dll" "$p/d3d11/d3d11.dll"
"$tc/i686-w64-mingw32-strip" -o "$out/d3d10core.dll" "$p/d3d10/d3d10core.dll"

# d3d8to9, linked with its C++ runtime (no libc++.dll in the set); Release
# builds of it log nothing (D3D8TO9NOLOG).
d8="$r/d3d8to9-$D3D8TO9"
if [ ! -d "$d8" ]; then
    curl -fsSL "https://github.com/crosire/d3d8to9/archive/$D3D8TO9.tar.gz" | tar -xz -C "$r"
fi
"$tc/i686-w64-mingw32-clang++" -std=c++17 -O2 -DD3D8TO9NOLOG -Wno-delete-non-virtual-dtor -Wno-unknown-pragmas \
    -shared -static -o "$r/d3d8.dll" "$d8"/source/*.cpp "$d8/res/d3d8.def" -Wl,--enable-stdcall-fixup -ld3d9 -lgdi32
"$tc/i686-w64-mingw32-strip" -o "$out/d3d8.dll" "$r/d3d8.dll"
cp "$d8/LICENSE.md" "$out/d3d8to9-LICENSE.md"

# The test program, with the flags of Madeira's build-d3d9-cube.sh. It runs
# for D3D9_CUBE_SECONDS of wall-clock time and exits with 43.
"$tc/i686-w64-mingw32-clang" -O2 -g -nostdlib -ffreestanding \
    -static-libgcc -Wno-unused-command-line-argument \
    -Wl,--entry=_start -Wl,--large-address-aware \
    -DMADEIRA_D3D9_SECONDS="${D3D9_CUBE_SECONDS:-8}" \
    -o "$out/d3d9-cube.exe" "$here/d3d9-cube.c" -lkernel32 -luser32 -ld3d9
"$tc/i686-w64-mingw32-clang" -O2 -g -nostdlib -ffreestanding \
    -static-libgcc -Wno-unused-command-line-argument \
    -Wl,--entry=_start -Wl,--large-address-aware \
    -DWINPAD_D3D8_SECONDS="${D3D9_CUBE_SECONDS:-8}" \
    -o "$out/d3d8-cube.exe" "$here/d3d8-cube.c" -lkernel32 -luser32 -ld3d8
# The D3D11 triangle and its D3D10 twin, the same way; D3D11_TRIANGLE_SECONDS
# of wall-clock time, then exit 43.
for v in 11 10; do
    "$tc/i686-w64-mingw32-clang" -O2 -g -nostdlib -ffreestanding \
        -static-libgcc -Wno-unused-command-line-argument \
        -Wl,--entry=_start -Wl,--large-address-aware \
        -DWINPAD_D3D11_SECONDS="${D3D11_TRIANGLE_SECONDS:-8}" -DWINPAD_D3D10=$((v == 10)) \
        -o "$out/d3d$v-triangle.exe" "$here/d3d11-triangle.c" -lkernel32 -luser32 -ld3d$v -ldxguid
done
# The OpenGL test (tests/opengl), the same way; GL_TRIANGLE_SECONDS, then exit 43.
"$tc/i686-w64-mingw32-clang" -O2 -g -nostdlib -ffreestanding \
    -static-libgcc -Wno-unused-command-line-argument \
    -Wl,--entry=_start -Wl,--large-address-aware \
    -DWINPAD_GL_SECONDS="${GL_TRIANGLE_SECONDS:-8}" \
    -o "$out/gl-triangle.exe" "$here/gl-triangle.c" -lkernel32 -luser32 -lgdi32 -lopengl32
# MinGW's import libraries name USER32.dll and GDI32.dll, which Wine does not
# find in these runs; see lowercase-imports.py.
python3 -I "$here/lowercase-imports.py" "$out/winemetal.dll" "$out/d3d9.dll" "$out/d3d9shim.dll" \
    "$out/d3d9-emulated.dll" "$out/d3d9-cube.exe" "$out/d3d8.dll" "$out/d3d8-cube.exe" \
    "$out/dxgi.dll" "$out/d3d11.dll" "$out/d3d10core.dll" "$out/d3d11-triangle.exe" "$out/d3d10-triangle.exe" \
    "$out/gl-triangle.exe"

# Every DLL a module imports has to be there (api-ms-win-* resolve through
# the API set schema, to ucrtbase).
missing=0
present=$(ls "$out" | tr 'A-Z' 'a-z')
for f in "$out"/*.dll "$out"/d3d9-cube.exe "$out"/d3d8-cube.exe "$out"/d3d1?-triangle.exe "$out"/gl-triangle.exe; do
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
