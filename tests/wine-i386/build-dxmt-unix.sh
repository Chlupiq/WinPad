#!/bin/sh
# Builds DXMT's unix side for SDK with Madeira's build/dxmt-ios/build.sh:
# winemetal's unix side (Metal, and the 32-bit table WoW64 programs reach
# it through), the airconv shader compiler with its DXBC parser, and the
# native D3D9 frontend, merged with LLVM (build-llvm.sh) into
# libdxmt_combined.a as Madeira's README says. Madeira's script builds for
# iphoneos; for another SDK it runs as a copy with the SDK and target
# replaced. It does not generate airconv's shader headers (Madeira keeps
# them from an earlier meson build), so they are made here the way
# dxmt/src/airconv/meson.build makes them.
#
# Usage: build-dxmt-unix.sh WORK_DIR SDK   (SDK: iphoneos or iphonesimulator)
# WORK_DIR must hold the Madeira checkout tests/wine-loader/build.sh made.
# Needs cmake, ninja and Xcode's Metal toolchain.
# Output: WORK_DIR/dxmt-SDK/libdxmt_combined.a, which link-host.sh links.
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
if [ "$sdk_name" = iphoneos ]; then
    cp "$work/madeira/build/dxmt-ios/build.sh" "$b/build.sh"
else
    sed -e "s/-sdk iphoneos /-sdk $sdk_name /g; s/--sdk iphoneos /--sdk $sdk_name /g" \
        -e 's/-arch arm64 -isysroot $SDK -miphoneos-version-min=18.0/-target arm64-apple-ios18.0-simulator -isysroot $SDK/' \
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

# Without Madeira's D3D12 shader converter (a separate package) the script
# stops unless told that D3D12 is not needed.
if ! MADEIRA_ALLOW_NO_D3D12=1 bash "$b/build.sh"; then
    for e in "$b"/obj/*.err; do
        grep -q 'error' "$e" || continue
        echo "--- $e ---"
        head -30 "$e"
    done
    exit 1
fi

rm -rf "$out"
mkdir -p "$out"
xcrun -sdk "$sdk_name" libtool -static -o "$out/libdxmt_combined.a" \
    "$b"/obj/*.o "$r"/toolchains/llvm-ios-build/lib/*.a
echo "DXMT unix side for $sdk_name: $out/libdxmt_combined.a ($(wc -c <"$out/libdxmt_combined.a" | tr -d ' ') bytes)"
