#!/bin/sh
# Builds DXMT's unix side for SDK with Madeira's build/dxmt-ios/build.sh:
# winemetal's unix side (Metal, and the 32-bit table WoW64 programs reach
# it through), the airconv shader compiler with its DXBC parser, and the
# native D3D9 frontend, merged with LLVM (build-llvm.sh) into
# libdxmt_combined.a as Madeira's README says. Madeira's script builds for
# iphoneos; for another SDK it runs as a copy with the SDK and target
# replaced, and with sim-metalfx/MetalFX/MetalFX.h for the MetalFX the
# simulator SDK lacks (the host answers that it is not supported,
# tests/wine-loader/host/metal-display.m). DXMT gets patches/dxmt: 0001 for
# the simulator's Metal, 0002 for Xcode 27's Metal compiler, 0003 for the
# errors its Metal calls hand back. It does not generate airconv's shader headers
# (Madeira keeps them from an earlier meson build), so they are made here
# the way dxmt/src/airconv/meson.build makes them.
#
# Usage: build-dxmt-unix.sh WORK_DIR SDK   (SDK: iphoneos or iphonesimulator)
# WORK_DIR must hold the Madeira checkout tests/wine-loader/build.sh made.
# Needs cmake, ninja and Xcode's Metal toolchain.
# Output: WORK_DIR/dxmt-SDK/libdxmt_combined.a, which link-host.sh links, and
# WORK_DIR/dxmt-SDK/d3d12/libmetalirconverter.dylib, which the app carries.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
work=$1
sdk_name=$2
r="$work/dxmt-root"
out="$work/dxmt-$sdk_name"
case $sdk_name in
    iphoneos | iphonesimulator) ;;
    *) echo "unknown SDK $sdk_name" >&2; exit 2 ;;
esac

sh "$here/fetch-dxmt.sh" "$r"
sh "$here/build-llvm.sh" "$r" "$sdk_name"
# Madeira's script takes LLVM from toolchains/llvm-ios-build: this SDK's.
[ ! -L "$r/toolchains" ] || rm "$r/toolchains"
ln -s "toolchains-$sdk_name" "$r/toolchains"
# WinPad's changes to DXMT, see the patch headers. The tree may already
# have them from an earlier run.
for p in "$here"/../../patches/dxmt/*.patch; do
    git -C "$r/dxmt" apply -R --check "$p" 2>/dev/null || git -C "$r/dxmt" apply "$p"
done

b="$r/build/dxmt-ios"
rm -rf "$b"
mkdir -p "$b/shader-headers"
# winemetal_unix.c includes Madeira's build/madeira_cfg.h and the headers of
# research/remote-metal (its remote Metal wire format) by relative paths.
git -C "$work/madeira" sparse-checkout add /research/remote-metal/
cp "$work/madeira/build/madeira_cfg.h" "$r/build/madeira_cfg.h"
rm -rf "$r/research"
mkdir -p "$r/research"
cp -R "$work/madeira/research/remote-metal" "$r/research/remote-metal"
# Madeira's Direct3D 12 (madeira-d3d12): the script builds its shader conversion
# service (madeira_ir_unix.mm, winemetal's call 127) when build/madeira-d3d12/deps.sh
# finds Apple's Metal Shader Converter -- the headers in madeira-d3d12/third_party
# and the iOS library in app/Madeira/d3d12 -- both by paths from the tree's top.
git -C "$work/madeira" sparse-checkout add /madeira-d3d12/ /app/Madeira/d3d12/
rm -rf "$r/madeira-d3d12" "$r/app" "$r/build/madeira-d3d12"
mkdir -p "$r/build/madeira-d3d12" "$r/app/Madeira"
cp "$work/madeira/build/madeira-d3d12/deps.sh" "$r/build/madeira-d3d12/"
cp -R "$work/madeira/madeira-d3d12" "$r/madeira-d3d12"
cp -R "$work/madeira/app/Madeira/d3d12" "$r/app/Madeira/d3d12"
if [ "$sdk_name" = iphoneos ]; then
    cp "$work/madeira/build/dxmt-ios/build.sh" "$b/build.sh"
else
    sed -e "s/-sdk iphoneos /-sdk $sdk_name /g; s/--sdk iphoneos /--sdk $sdk_name /g" \
        -e "s|-arch arm64 -isysroot \$SDK -miphoneos-version-min=18.0|-target arm64-apple-ios18.0-simulator -isysroot \$SDK -I$here/sim-metalfx|" \
        "$work/madeira/build/dxmt-ios/build.sh" >"$b/build.sh"
    if grep -n 'iphoneos' "$b/build.sh" | grep -v '^ *[0-9]*: *#'; then
        echo "Madeira's build.sh still names iphoneos above" >&2
        exit 1
    fi
fi

for s in air_msad air_samplepos air_tessellation; do
    xcrun -sdk macosx metal -std=metal3.1 --target=air64-apple-macos14.0 \
        -o "$b/shader-headers/$s.air" -c "$r/dxmt/src/airconv/shaders/$s.metal"
    (cd "$b/shader-headers" && xxd -n "$s" -i "$s.air" "$s.h")
done

# With the converter in place the script builds the D3D12 service; it stops
# when it cannot (MADEIRA_ALLOW_NO_D3D12 is not set).
if ! bash "$b/build.sh"; then
    for e in "$b"/obj/*.err; do
        grep -q 'error:' "$e" || continue
        echo "--- $e ---"
        grep -B2 -A4 'error:' "$e" | head -40
    done
    exit 1
fi

[ -f "$b/obj/madeira_ir_unix.o" ] || { echo "the D3D12 conversion service was not built" >&2; exit 1; }

rm -rf "$out"
mkdir -p "$out/d3d12"
# The converter library the service dlopens from <main bundle>/d3d12/. Apple ships
# it for iOS devices only; the simulator gets the same arm64 code marked as a
# simulator library (vtool), ad-hoc signed again.
for f in libmetalirconverter.dylib LICENSE-metal-shader-converter-headers.txt \
         METAL-SHADER-CONVERTER-AGREEMENT.txt NOTICE.txt; do
    cp "$r/app/Madeira/d3d12/$f" "$out/d3d12/"
done
if [ "$sdk_name" = iphonesimulator ]; then
    xcrun vtool -set-build-version iossim 17.0 17.0 -replace \
        -output "$out/d3d12/sim.dylib" "$out/d3d12/libmetalirconverter.dylib"
    mv "$out/d3d12/sim.dylib" "$out/d3d12/libmetalirconverter.dylib"
    codesign -f -s - "$out/d3d12/libmetalirconverter.dylib"
fi
xcrun -sdk "$sdk_name" libtool -static -o "$out/libdxmt_combined.a" \
    "$b"/obj/*.o "$r"/toolchains/llvm-ios-build/lib/*.a
echo "DXMT unix side for $sdk_name: $out/libdxmt_combined.a ($(wc -c <"$out/libdxmt_combined.a" | tr -d ' ') bytes)"
