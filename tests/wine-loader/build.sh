#!/bin/sh
# Compiles Madeira's iOS ntdll loader (build/ntdll-unix/loader_ios.c and
# virtual_ios.c) for iOS with the flags of Madeira's compile_patched.sh: first
# as Madeira ships it, then with patches/madeira/0001-adopt-pe-dylib.patch.
# The Wine tree is configured on the Mac only to get config.h.
#
# Usage: build.sh WORK_DIR
# Needs: an arm64 Mac with Xcode (iphoneos SDK), git, bison, flex, and LLVM
# clang, llvm-dlltool and lld for the PE side (configure insists on them).
set -eu

MADEIRA_REPO=https://github.com/willfaust/Madeira.git
MADEIRA_COMMIT=48f976429c189f8396e23d251d8a82f43c705922
WINE_REPO=https://github.com/willfaust/wine.git
WINE_COMMIT=257f271cfffed9f22f7987cac53bc00095d092fe  # Madeira's wine submodule

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work=$1
mkdir -p "$work"

# madeira/wine may already be there (restored from a cache), so no git clone.
if [ ! -d "$work/madeira/.git" ]; then
    git init -q "$work/madeira"
    git -C "$work/madeira" sparse-checkout set --no-cone /build/ /app/Madeira/Winios/ /app/Madeira/aarch64-windows/
    git -C "$work/madeira" fetch -q --depth 1 --filter=blob:none "$MADEIRA_REPO" "$MADEIRA_COMMIT"
fi
git -C "$work/madeira" checkout -q -f "$MADEIRA_COMMIT"

wine="$work/madeira/wine"
if [ ! -f "$wine/build-macos/include/config.h" ]; then
    rm -rf "$wine"
    git init -q "$wine"
    git -C "$wine" fetch -q --depth 1 "$WINE_REPO" "$WINE_COMMIT"
    git -C "$wine" checkout -q FETCH_HEAD
    mkdir -p "$wine/build-macos"
    (cd "$wine/build-macos" && ../configure -q --without-x --without-freetype \
        --without-gnutls --without-vulkan --without-opencl --without-gstreamer --without-sdl \
        --without-cups --without-sane --without-krb5 --without-netapi --without-pcap \
        --without-usb --without-v4l2 --without-pulse --without-alsa --without-oss \
        --without-coreaudio --without-capi --without-gphoto --without-inotify \
        --without-dbus --without-udev --without-unwind >"$work/configure.log" 2>&1) || {
        tail -40 "$work/configure.log" >&2
        exit 1
    }
fi

sdk=$(xcrun --sdk iphoneos --show-sdk-path)
src="$work/madeira/build/ntdll-unix"
compile() {  # FILE OUT [extra flags]
    file=$1 out=$2
    shift 2
    xcrun -sdk iphoneos clang -arch arm64 -isysroot "$sdk" -miphoneos-version-min=17.0 \
        -O2 -fPIC -fvisibility=hidden -fno-stack-protector -fno-strict-aliasing \
        -Wno-implicit-function-declaration -Wno-int-conversion \
        -include "$wine/build-macos/include/config.h" \
        -include "$src/shims/wine_ios_exit.h" \
        -I"$src/shims" \
        -I"$wine/build-macos/dlls/ntdll" -I"$wine/dlls/ntdll" -I"$wine/dlls/ntdll/unix" \
        -I"$wine/build-macos/include" -I"$wine/include" \
        -D__WINESRC__ -DLTC_NO_PROTOTYPES -DLTC_SOURCE -D_NTSYSTEM_ \
        -D_ACRTIMP= -DWINBASEAPI= \
        -DBINDIR=\"/usr/local/bin\" -DLIBDIR=\"/usr/local/lib\" \
        -DDATADIR=\"/usr/local/share\" -DSYSTEMDLLPATH=\"\" \
        -DWINE_UNIX_LIB -DWINE_IOS=1 \
        -Dget_thread_context=ntdll_get_thread_context \
        -Dset_thread_context=ntdll_set_thread_context \
        "$@" -c "$src/$file" -o "$work/$out"
}

for f in loader_ios virtual_ios; do
    compile "$f.c" "$f-madeira.o"
done
echo "Madeira's loader_ios.c and virtual_ios.c build for iOS as shipped"

git -C "$work/madeira" apply "$root/patches/madeira/0001-adopt-pe-dylib.patch"
for f in loader_ios virtual_ios; do
    compile "$f.c" "$f-adopt.o" -I"$root/tools/pe2macho"
done
git -C "$work/madeira" checkout -q -- build
# The patched objects may only need what the shipped ones need, plus dlopen
# and friends (already used by Madeira's loader) and nothing new from WinPad.
for f in loader_ios virtual_ios; do
    xcrun nm -u "$work/$f-madeira.o" | sort -u >"$work/$f-madeira.undef"
    xcrun nm -u "$work/$f-adopt.o" | sort -u >"$work/$f-adopt.undef"
    extra=$(comm -13 "$work/$f-madeira.undef" "$work/$f-adopt.undef" | tr '\n' ' ')
    echo "$f.c with the adopt patch: new undefined symbols: ${extra:-none}"
done
echo "Both build for iOS with patches/madeira/0001-adopt-pe-dylib.patch"
