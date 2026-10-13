#!/bin/sh
# Builds the iPad test app (tests/ios/app) as an unsigned IPA for sideloading
# (Sideloadly signs it with the user's Apple ID). The app runs the probe's
# x86-64 guest from an AOT image in Frameworks/probe-aot.dylib with NoJIT.
#
# The image is made from a cache and dispatcher generated on a Mac by
# tests/probe/run-macos.sh: macOS and iOS share FEXCore's Darwin code and data
# layout, and FEX checks at run time that the dispatcher bytes match its own.
#
# Usage: build-app.sh SRC_DIR BUILD_DIR OUT_DIR PROBE_WORK_DIR
#   PROBE_WORK_DIR: run-macos.sh's work directory (cache file, dispatcher.bin)
# Needs: Xcode, cmake, ninja, python3. Writes OUT_DIR/WinPadProbe.ipa.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
src=$1
build=$2
out=$3
probe_work=$4
min_ios=17.4
mkdir -p "$out"

sh "$root/tests/fex-cache/fetch-fex.sh" "$src"
cmake -S "$src" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64 -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=iphoneos \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=$min_ios \
    -DENABLE_LTO=False -DENABLE_ASSERTIONS=True -DBUILD_TESTING=False \
    -DBUILD_THUNKS=False -DBUILD_FEX_LINUX_TESTS=False -DBUILD_FEXCONFIG=False \
    -DENABLE_FEX_ALLOCATOR=False -DTUNE_CPU=none -DWINPAD_PROBE_DIR="$root/tests/probe"
cmake --build "$build" --target WinPadProbe

# The AOT image as an iOS dylib.
cache=$(ls "$probe_work"/winpad-probe-guest-*)
sdk=$(xcrun --sdk iphoneos --show-sdk-path)
c2m="$root/tools/cache2macho"
python3 -I "$c2m/cache2macho.py" --min-ios $min_ios "$cache" "$out/aot.o"
python3 -I "$c2m/cache2macho.py" --dispatcher "$probe_work/dispatcher.bin" "$out/dispatcher.s"
xcrun --sdk iphoneos clang -target arm64-apple-ios$min_ios -c -o "$out/dispatcher.o" "$out/dispatcher.s"
xcrun --sdk iphoneos clang -target arm64-apple-ios$min_ios -isysroot "$sdk" -dynamiclib \
    -install_name @rpath/probe-aot.dylib -o "$out/probe-aot.dylib" "$out/aot.o" "$out/dispatcher.o"
python3 -I "$c2m/check_linked.py" "$cache" "$out/probe-aot.dylib"

# Payload/WinPadProbe.app, zipped: an unsigned IPA.
app="$out/Payload/WinPadProbe.app"
rm -rf "${out:?}/Payload"
mkdir -p "$app/Frameworks"
cp "$build/Bin/WinPadProbe" "$app/WinPadProbe" 2>/dev/null || cp "$(find "$build" -type f -name WinPadProbe -perm -u+x | head -n 1)" "$app/WinPadProbe"
cp "$out/probe-aot.dylib" "$app/Frameworks/"
sed "s/\${WINPAD_IOS_MIN}/$min_ios/" "$here/app/Info.plist.in" >"$app/Info.plist"
plutil -lint "$app/Info.plist"
printf 'APPL????' >"$app/PkgInfo"
(cd "$out" && rm -f WinPadProbe.ipa && zip -qr WinPadProbe.ipa Payload)
ls -l "$out/WinPadProbe.ipa"
otool -l "$app/WinPadProbe" | grep -A4 LC_BUILD_VERSION | head -n 5
