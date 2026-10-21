#!/bin/sh
# Builds Wine's 32-bit x86 (i386) PE modules, the ones a WoW64 process loads
# from i386-windows, the way Madeira's build/wine-i386/build.sh does: a separate
# build-i386 tree of Madeira's Wine, configured with --enable-archs=i386, and
# make of each module's i386-windows target. The PE side needs no MinGW: Wine
# compiles it with LLVM clang for i686-windows and links it with lld.
# Also builds tests/wine-i386/hello.c, a 32-bit console program that only
# imports kernel32, tests/wine-i386/window.c, one with a window (user32,
# gdi32), tests/wine-i386/imports.c, which imports what a game imports, and
# tests/wine-i386/guard.c, stack growth and guard pages.
#
# Usage: build.sh WORK_DIR [MODULE...]
# (default: ntdll kernelbase kernel32, what a program with a window needs and
# the import closure of tests/wine-i386/imports.c)
# WORK_DIR must hold the Wine tree tests/wine-loader/build.sh fetched.
# Needs LLVM clang, llvm-dlltool and lld (Homebrew llvm, lld), bison and flex.
# Output: WORK_DIR/i386-windows/*.dll, hello.exe, guard.exe, window.exe, imports.exe and
# casetest.dll (imports.exe's own DLL).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
work=$1
shift
# The default set is what a program with a window needs, then what the DLLs a
# game imports (DirectInput, DirectSound, DirectDraw, winmm, Winsock, TAPI,
# netapi32, shell32 and shfolder) import in turn: their whole import closure,
# or the loader stops at the first missing one (c0000135). d3d9 is not here.
# mmdevapi is no import but the COM class dsound creates for its device;
# cryptbase and cryptsp are where advapi32 forwards its SystemFunction* exports
# (RtlGenRandom, which mmdevapi reaches; an unresolved forward aborts the call).
[ $# -gt 0 ] || set -- ntdll kernelbase kernel32 win32u gdi32 user32 advapi32 sechost msvcrt ucrtbase imm32 \
    dinput8 dinput dsound ddraw winmm ws2_32 tapi32 netapi32 shfolder shell32 \
    comctl32 ole32 combase coml2 oleaut32 rpcrt4 hid setupapi cfgmgr32 wined3d opengl32 \
    msacm32 iphlpapi dnsapi nsi netutils shlwapi shcore version mmdevapi \
    cryptbase cryptsp
wine="$work/madeira/wine"
b="$wine/build-i386"
out="$work/i386-windows"
jobs=$(sysctl -n hw.ncpu 2>/dev/null || nproc)

if [ ! -f "$b/config.status" ]; then
    mkdir -p "$b"
    (cd "$b" && ../configure -q --enable-archs=i386 --without-x --without-freetype \
        --without-gnutls --without-vulkan --without-opencl --without-gstreamer --without-sdl \
        --without-cups --without-sane --without-krb5 --without-netapi --without-pcap \
        --without-usb --without-v4l2 --without-pulse --without-alsa --without-oss \
        --without-coreaudio --without-capi --without-gphoto --without-inotify \
        --without-dbus --without-udev --without-unwind --disable-tests \
        >"$work/configure-i386.log" 2>&1) || {
        tail -40 "$work/configure-i386.log" >&2
        exit 1
    }
fi

# WinPad's change to the i386 ntdll, see the patch header. The tree may come
# from a cache with the patch already applied.
p="$here/../../patches/wine/0003-i386-ntdll-wow64-bop.patch"
git -C "$wine" apply -R --check "$p" 2>/dev/null || git -C "$wine" apply "$p"

targets=
for m in "$@"; do
    t=$(grep -oE "^dlls/$m/i386-windows/[^/ :]+\.dll" "$b/Makefile" | sort -u | head -1)
    [ -n "$t" ] || { echo "no i386 target for $m in $b/Makefile" >&2; exit 2; }
    targets="$targets $t"
done
echo "i386 modules:$targets"
# shellcheck disable=SC2086 # a list of make targets
if ! make -C "$b" -j"$jobs" $targets >"$work/make-i386.log" 2>&1; then
    grep -E 'error|Error' "$work/make-i386.log" | head -40 >&2
    exit 1
fi

rm -rf "$out"
mkdir -p "$out"
for t in $targets; do
    cp "$b/$t" "$out/"
done

# The test program: i686 PE, entry point of its own, kernel32 import library
# from this tree.
implib() {
    l=$(grep -oE "^dlls/$1/[^ :]*lib$1\\.a" "$b/Makefile" | sort -u | head -1)
    [ -n "$l" ] || { echo "no $1 import library target in $b/Makefile" >&2; exit 2; }
    make -C "$b" "$l" >>"$work/make-i386.log" 2>&1 || { tail -20 "$work/make-i386.log" >&2; exit 1; }
    echo "$b/$l"
}
kernel32=$(implib kernel32)
clang -target i686-windows -O2 -nostdlib -fno-builtin -ffreestanding \
    -Wl,-entry:start -Wl,-subsystem:console \
    "$here/hello.c" "$kernel32" -o "$out/hello.exe" -fuse-ld=lld
# Stack growth and guard pages (kernel32 only); the image asks for an 8 MB
# stack, as a game's does.
clang -target i686-windows -O2 -nostdlib -fno-builtin -ffreestanding \
    -Wl,-entry:start -Wl,-subsystem:console -Wl,-stack:8388608 \
    "$here/guard.c" "$kernel32" -o "$out/guard.exe" -fuse-ld=lld
# The program with a window, if this build has its modules.
if [ -f "$out/user32.dll" ] && [ -f "$out/gdi32.dll" ]; then
    user32=$(implib user32)
    gdi32=$(implib gdi32)
    clang -target i686-windows -O2 -nostdlib -fno-builtin -ffreestanding \
        -Wl,-entry:start -Wl,-subsystem:windows \
        "$here/window.c" "$kernel32" "$user32" "$gdi32" -o "$out/window.exe" -fuse-ld=lld
fi
# The program with a game's imports, if this build has their DLLs.
game_dlls="user32 advapi32 gdi32 winmm dinput8 ddraw ws2_32 shfolder shell32 tapi32 netapi32"
have=1
for m in $game_dlls dsound; do [ -f "$out/$m.dll" ] || have=; done
if [ -n "$have" ]; then
    libs=
    for m in $game_dlls; do libs="$libs $(implib "$m")"; done
    # Games import DirectSoundCreate by its ordinal, 1, not by name; Wine's
    # import library has it by name, so this one is made here.
    printf 'LIBRARY DSOUND.dll\nEXPORTS\nDirectSoundCreate@12 @1 NONAME\n' >"$work/dsound-ordinal.def"
    llvm-dlltool -m i386 -d "$work/dsound-ordinal.def" -l "$work/libdsound-ordinal.a"
    libs="$libs $work/libdsound-ordinal.a"
    # The program's own DLL, next to it (no entry point, no imports).
    clang -target i686-windows -O2 -nostdlib -fno-builtin -ffreestanding -shared \
        -Wl,-noentry -Wl,-implib:"$work/libcasetest.a" \
        "$here/casetest.c" -o "$out/casetest.dll" -fuse-ld=lld
    libs="$libs $work/libcasetest.a"
    # kernel32 last: its import library has winmm's time* functions too,
    # and they have to come from winmm, as in the game.
    # shellcheck disable=SC2086 # a list of import libraries
    clang -target i686-windows -O2 -nostdlib -fno-builtin -ffreestanding \
        -Wl,-entry:start -Wl,-subsystem:console \
        "$here/imports.c" $libs "$kernel32" -o "$out/imports.exe" -fuse-ld=lld
    # A game names some DLLs in capitals (USER32.dll, DINPUT8.dll) and the files
    # are lowercase, so the loader has to find them without regard to case. The
    # import table names are rewritten in place, same length.
    python3 -I - "$out/imports.exe" <<'PY'
import sys
path = sys.argv[1]
data = open(path, "rb").read()
for name in (b"user32.dll", b"advapi32.dll", b"gdi32.dll", b"dinput8.dll", b"casetest.dll"):
    old, new = b"\0" + name + b"\0", b"\0" + name[:-4].upper() + b".dll\0"
    if data.count(old) != 1:
        sys.exit(f"imports.exe: {name.decode()} is in it {data.count(old)} times, not once")
    data = data.replace(old, new)
open(path, "wb").write(data)
PY
fi
ls -l "$out"
for exe in "$out"/*.exe; do
    llvm-objdump -p "$exe" | grep -E 'Magic|DLL Name|Machine' || true
done
