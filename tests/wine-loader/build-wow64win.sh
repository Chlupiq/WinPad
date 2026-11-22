#!/bin/sh
# Builds wow64win.dll (the ARM64 side of WoW64 for win32u: user32/gdi32 calls
# of a 32-bit program) from Madeira's Wine with WinPad's patches, in place of
# the prebuilt one in Madeira's app/Madeira/aarch64-windows.
# Built from that same source without the patches and stripped the same way,
# it differs from Madeira's file only in its time stamp and checksum (8 bytes).
#
# Usage: build-wow64win.sh WORK_DIR
# WORK_DIR must hold the Wine tree tests/wine-loader/build.sh fetched. Fetches
# the llvm-mingw toolchain Madeira names into WORK_DIR (as build-d3d9.sh does)
# and configures WORK_DIR/madeira/wine/build-aarch64 once (PE side only).
# Needs bison and flex (Homebrew's on a Mac).
# Output: WORK_DIR/wow64win/wow64win.dll
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work=$1
wine="$work/madeira/wine"
b="$wine/build-aarch64"
out="$work/wow64win"
jobs=$(sysctl -n hw.ncpu 2>/dev/null || nproc)
case $(uname -s) in
    Darwin) TOOLCHAIN=llvm-mingw-20260421-ucrt-macos-universal ;;
    *) TOOLCHAIN=llvm-mingw-20260421-ucrt-ubuntu-22.04-$(uname -m) ;;
esac
patches="$root/patches/wine/0005-wow64win-atoms-stay-atoms.patch"

tc="$work/$TOOLCHAIN/bin"
if [ ! -x "$tc/aarch64-w64-mingw32-clang" ]; then
    curl -fsSL "https://github.com/mstorsjo/llvm-mingw/releases/download/20260421/$TOOLCHAIN.tar.xz" |
        tar -xJ -C "$work"
fi
PATH="$tc:$PATH"
if command -v brew >/dev/null 2>&1; then
    PATH="$(brew --prefix bison)/bin:$(brew --prefix flex)/bin:$PATH"
fi
export PATH

# The tree may come from a cache with a patch already applied.
for p in $patches; do
    git -C "$wine" apply -R --check "$p" 2>/dev/null || git -C "$wine" apply "$p"
done

if [ ! -f "$b/config.status" ]; then
    mkdir -p "$b"
    (cd "$b" && ../configure -q --enable-archs=aarch64 --without-x --without-freetype \
        --without-gnutls --without-vulkan --without-opencl --without-gstreamer --without-sdl \
        --without-cups --without-sane --without-krb5 --without-netapi --without-pcap \
        --without-usb --without-v4l2 --without-pulse --without-alsa --without-oss \
        --without-coreaudio --without-capi --without-gphoto --without-inotify \
        --without-dbus --without-udev --without-unwind --without-wayland --without-fontconfig \
        --disable-tests >"$work/configure-aarch64.log" 2>&1) || {
        tail -40 "$work/configure-aarch64.log" >&2
        exit 1
    }
fi
t=dlls/wow64win/aarch64-windows/wow64win.dll
make -C "$b" -j"$jobs" "$t" >"$work/make-aarch64.log" 2>&1 || {
    grep -E 'error|Error' "$work/make-aarch64.log" | head -40 >&2
    exit 1
}
mkdir -p "$out"
cp "$b/$t" "$out/wow64win.dll"
# As Madeira's: no symbols, no debug information (same size, same sections).
aarch64-w64-mingw32-strip --strip-all "$out/wow64win.dll"
echo "Built $out/wow64win.dll: $(wc -c <"$out/wow64win.dll" | tr -d ' ') bytes, with$(for p in $patches; do printf ' %s' "${p##*/}"; done)"
