#!/bin/sh
# Packs the iPad test app (tests/ios/app) as an Xcode project for a Mac with
# Xcode: open WinPadProbe.xcodeproj, pick a team, Run on the iPad or on an
# iPad simulator (Apple Silicon Macs). Xcode signs the app with the user's
# account and shows the probe's log in its console.
#
# Everything that needs FEX's sources is prebuilt, once for the device
# (iphoneos) and once for the simulator (iphonesimulator): the probe and
# FEXCore as static libraries in lib/<platform>/ and the AOT image in
# Frameworks/<platform>/probe-aot.dylib, with the test DLL wrapped by
# tools/pe2macho next to it (pe-testdll.dylib). Only main.mm is compiled. The device
# parts come from build-app.sh; this script builds the simulator ones.
# The project is generated with XcodeGen, built for both platforms with
# xcodebuild, and the simulator build is run on an iPad simulator.
#
# Usage: build-xcode.sh SRC_DIR APP_BUILD_DIR APP_OUT_DIR SIM_BUILD_DIR PROBE_WORK_DIR OUT_DIR
#   APP_BUILD_DIR, APP_OUT_DIR: build-app.sh's BUILD_DIR and OUT_DIR
#   PROBE_WORK_DIR: run-macos.sh's work directory (cache file, dispatcher.bin)
# Needs: Xcode, cmake, ninja, xcodegen, python3, lld-link. Writes OUT_DIR/WinPadProbe-xcode.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
src=$1
build=$2
app_out=$3
sim_build=$4
probe_work=$5
out=$6
min_ios=17.4
bundle=com.chlupiq.winpad.probe
proj="$out/WinPadProbe-xcode"
rm -rf "${proj:?}"
mkdir -p "$proj/Frameworks/iphoneos" "$proj/Frameworks/iphonesimulator"

# The simulator build: the same FEXCore and probe for arm64-apple-ios-simulator.
cmake -S "$src" -B "$sim_build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_SYSTEM_PROCESSOR=arm64 -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_SYSROOT=iphonesimulator \
    -DCMAKE_OSX_DEPLOYMENT_TARGET=$min_ios \
    -DENABLE_LTO=False -DENABLE_ASSERTIONS=True -DBUILD_TESTING=False \
    -DBUILD_THUNKS=False -DBUILD_FEX_LINUX_TESTS=False -DBUILD_FEXCONFIG=False \
    -DENABLE_FEX_ALLOCATOR=False -DTUNE_CPU=none -DWINPAD_PROBE_DIR="$root/tests/probe"
cmake --build "$sim_build" --target WinPadProbe

# The AOT image for the simulator; the device one is build-app.sh's.
cache=$(ls "$probe_work"/winpad-probe-guest-*)
c2m="$root/tools/cache2macho"
sim="$out/simulator"
mkdir -p "$sim"
python3 -I "$c2m/cache2macho.py" --ios-simulator $min_ios "$cache" "$sim/aot.o"
python3 -I "$c2m/cache2macho.py" --dispatcher "$probe_work/dispatcher.bin" "$sim/dispatcher.s"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios$min_ios-simulator -c -o "$sim/dispatcher.o" "$sim/dispatcher.s"
xcrun --sdk iphonesimulator clang -target arm64-apple-ios$min_ios-simulator -dynamiclib \
    -install_name @rpath/probe-aot.dylib -o "$sim/probe-aot.dylib" "$sim/aot.o" "$sim/dispatcher.o"
python3 -I "$c2m/check_linked.py" "$cache" "$sim/probe-aot.dylib"
cp "$app_out/probe-aot.dylib" "$proj/Frameworks/iphoneos/"
cp "$sim/probe-aot.dylib" "$proj/Frameworks/iphonesimulator/"
cp "$app_out/pe-testdll.dylib" "$proj/Frameworks/iphoneos/"
sh "$root/tests/pe2macho/build-dylib.sh" "$out/pe" iphonesimulator "arm64-apple-ios$min_ios-simulator" \
    "$proj/Frameworks/iphonesimulator/pe-testdll.dylib"

# libs BUILD PLATFORM: copies the libraries of CMake's link of the app to
# lib/PLATFORM and writes the link flags, in link order, to PLATFORM.flags.
libs() {
    mkdir -p "$proj/lib/$2"
    ninja -C "$1" -t commands WinPadProbe | tail -n 1 >"$out/link-command-$2.txt"
    python3 -I "$here/xcode/link-libs.py" "$1" "$out/link-command-$2.txt" "$proj/lib/$2" "$out/$2.flags"
}
libs "$build" iphoneos
libs "$sim_build" iphonesimulator
# One list of flags serves both platforms through $(PLATFORM_NAME).
cmp "$out/iphoneos.flags" "$out/iphonesimulator.flags" ||
    { echo "the device and simulator builds link different libraries" >&2; exit 1; }

cp "$here/app/main.mm" "$root/tests/pe2macho/teb-test.h" "$proj/"
# Xcode fills in the bundle id and executable name from the build settings.
sed -e "s/\${WINPAD_IOS_MIN}/$min_ios/" \
    -e 's/<string>com.chlupiq.winpad.probe</<string>$(PRODUCT_BUNDLE_IDENTIFIER)</' \
    -e 's/<string>WinPadProbe<\/string>/<string>$(EXECUTABLE_NAME)<\/string>/' \
    "$here/app/Info.plist.in" >"$proj/Info.plist"
# Xcode sets UIDeviceFamily from TARGETED_DEVICE_FAMILY and the platform itself.
plutil -remove UIDeviceFamily "$proj/Info.plist"
plutil -remove CFBundleSupportedPlatforms "$proj/Info.plist"
plutil -lint "$proj/Info.plist"

{
    sed "s/@MIN_IOS@/$min_ios/; s/@BUNDLE@/$bundle/" "$here/xcode/project.yml.in"
    sed 's/^/          - "/; s/$/"/' "$out/iphoneos.flags"
} >"$proj/project.yml"
cp "$here/xcode/README.md" "$proj/"
(cd "$proj" && xcodegen generate --spec project.yml)

# build SDK: builds the project with xcodebuild and checks the product;
# prints the app's path. Signing for the device is the user's part.
build() {
    sign=
    [ "$1" = iphoneos ] && sign=CODE_SIGNING_ALLOWED=NO
    xcodebuild -project "$proj/WinPadProbe.xcodeproj" -scheme WinPadProbe -configuration Debug \
        -sdk "$1" -derivedDataPath "$out/xcode-derived" $sign build >&2
    product="$out/xcode-derived/Build/Products/Debug-$1/WinPadProbe.app"
    for dylib in probe-aot.dylib pe-testdll.dylib; do
        test -f "$product/Frameworks/$dylib" ||
            { echo "the $1 build did not embed $dylib" >&2; exit 1; }
    done
    # Debug builds keep the app's code in WinPadProbe.debug.dylib (Xcode 16).
    code="$product/WinPadProbe.debug.dylib"
    [ -f "$code" ] || code="$product/WinPadProbe"
    nm "$code" | grep -q WinPadProbeMain ||
        { echo "the $1 build did not link the probe" >&2; exit 1; }
    echo "$product"
}
build iphoneos >/dev/null
sim_app=$(build iphonesimulator)

# Run the simulator build on an iPad simulator and read the app's log.
udid=$(xcrun simctl list devices available -j | python3 -I "$here/xcode/pick-ipad.py" $min_ios)
[ -n "$udid" ] || { echo "no iPad simulator with iOS $min_ios or later" >&2; exit 1; }
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b
xcrun simctl install "$udid" "$sim_app"
xcrun simctl launch "$udid" "$bundle"
log="$(xcrun simctl get_app_container "$udid" "$bundle" data)/Documents/probe.log"
for _ in $(seq 120); do
    grep -q '== finished' "$log" 2>/dev/null && break
    sleep 1
done
cat "$log" || true
xcrun simctl shutdown "$udid" || true
grep -q '== finished, exit 0' "$log" ||
    { echo "the app did not run the guest on the simulator" >&2; exit 1; }
grep -q 'Dispatcher: static code from AOT image' "$log" ||
    { echo "FEX did not run the dispatcher from the AOT image on the simulator" >&2; exit 1; }
grep -q 'PE code ran from the dylib' "$log" ||
    { echo "the Windows DLL did not run from its dylib on the simulator" >&2; exit 1; }
grep -q 'TEB reads through x18 found the TEB on both threads' "$log" ||
    { echo "the Windows DLL's TEB reads failed on the simulator" >&2; exit 1; }
