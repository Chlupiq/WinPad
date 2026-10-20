#!/bin/sh
# Builds Wine's 32-bit x86 (i386) PE modules, the ones a WoW64 process loads
# from i386-windows, the way Madeira's build/wine-i386/build.sh does: a separate
# build-i386 tree of Madeira's Wine, configured with --enable-archs=i386, and
# make of each module's i386-windows target. The PE side needs no MinGW: Wine
# compiles it with LLVM clang for i686-windows and links it with lld.
# Also builds tests/wine-i386/hello.c, a 32-bit console program that only
# imports kernel32, and tests/wine-i386/window.c, one with a window (user32,
# gdi32).
#
# Usage: build.sh WORK_DIR [MODULE...]
# (default: ntdll kernelbase kernel32 and what a program with a window needs)
# WORK_DIR must hold the Wine tree tests/wine-loader/build.sh fetched.
# Needs LLVM clang, llvm-dlltool and lld (Homebrew llvm, lld), bison and flex.
# Output: WORK_DIR/i386-windows/*.dll, hello.exe and window.exe.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
work=$1
shift
[ $# -gt 0 ] || set -- ntdll kernelbase kernel32 win32u gdi32 user32 advapi32 sechost msvcrt ucrtbase imm32
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
# The program with a window, if this build has its modules.
if [ -f "$out/user32.dll" ] && [ -f "$out/gdi32.dll" ]; then
    user32=$(implib user32)
    gdi32=$(implib gdi32)
    clang -target i686-windows -O2 -nostdlib -fno-builtin -ffreestanding \
        -Wl,-entry:start -Wl,-subsystem:windows \
        "$here/window.c" "$kernel32" "$user32" "$gdi32" -o "$out/window.exe" -fuse-ld=lld
fi
ls -l "$out"
for exe in "$out"/*.exe; do
    llvm-objdump -p "$exe" | grep -E 'Magic|DLL Name|Machine' || true
done
