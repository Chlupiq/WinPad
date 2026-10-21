#!/bin/sh
# Packs the Wine app (tests/wine-app) as an Xcode project for a Mac with
# Xcode: open WinPadWine.xcodeproj, pick a team, Run on the iPad or on an
# iPad simulator (Apple Silicon Macs). It runs the 32-bit x86 hello.exe in
# Wine through WoW64 and FEX, with NoJIT, from the AOT image CI linked.
#
# Everything but main.m is prebuilt, once for the device (iphoneos) and once
# for the simulator (iphonesimulator): the host (tests/wine-loader/host,
# linked by link-host.sh, with its stubs) and Wine's unix side in
# lib/<platform>/, Wine's modules wrapped into dylibs in
# wine/<platform>/aarch64-windows, the AOT image in Frameworks/<platform>/.
# The x86 modules, the program, the NLS files and the fonts are the same for both.
# The project is generated with XcodeGen, built for both platforms with
# xcodebuild, and the simulator build is run on an iPad simulator.
#
# Usage: build-xcode.sh WORK_DIR SIM_AOT_DYLIB DEVICE_AOT_DYLIB OUT_DIR
# WORK_DIR: tests/wine-loader's work directory, with Wine's unix side and
# wrapped modules (xtajit.dll included) for both SDKs and the i386 modules.
# Needs: Xcode, xcodegen, python3. Writes OUT_DIR/WinPadWine-xcode.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work=$1
sim_aot=$2
dev_aot=$3
out=$4
min_ios=17.4
bundle=com.chlupiq.winpad.wine
proj="$out/WinPadWine-xcode"
rm -rf "${proj:?}"
mkdir -p "$proj"

for sdk in iphoneos iphonesimulator; do
    test -f "$work/modules-$sdk/aarch64-windows/xtajit.dll.dylib" ||
        { echo "no xtajit.dll.dylib for $sdk in $work/modules-$sdk" >&2; exit 1; }
    sh "$root/tests/wine-loader/link-host.sh" $sdk "$work" "$out/host-$sdk"
    mkdir -p "$proj/lib/$sdk" "$proj/wine/$sdk" "$proj/Frameworks/$sdk"
    cp "$out/host-$sdk/winehost-lib.o" "$proj/lib/$sdk/winehost.o"
    cp "$out/host-$sdk/stubs.o" "$work/ntdll-$sdk/libntdll_unix.a" "$work/win32u-$sdk/libwin32u_unix.a" \
        "$work/wineserver-$sdk/libwineserver.a" "$proj/lib/$sdk/"
    cp -R "$work/modules-$sdk/aarch64-windows" "$proj/wine/$sdk/"
done
# One list of flags serves both platforms through $(PLATFORM_NAME).
cmp "$out/host-iphoneos/weak-flags" "$out/host-iphonesimulator/weak-flags" ||
    { echo "the device and simulator builds leave different hooks undefined" >&2; exit 1; }
cp "$dev_aot" "$proj/Frameworks/iphoneos/fexaot.dylib"
cp "$sim_aot" "$proj/Frameworks/iphonesimulator/fexaot.dylib"
cp -R "$work/i386-windows" "$proj/wine/"
mkdir -p "$proj/wine/nls" "$proj/wine/fonts"
cp "$work"/madeira/wine/nls/*.nls "$proj/wine/nls/"
find "$work/madeira/wine/fonts" -maxdepth 1 -type f \( -name '*.ttf' -o -name '*.ttc' -o -name '*.fon' \) \
    -exec cp {} "$proj/wine/fonts/" \;
echo "Wine files in the project:"
du -sh "$proj"/wine/* "$proj"/wine/*/aarch64-windows "$proj"/lib/* | sed 's/^/  /'

cp "$here/main.m" "$here/Info.plist" "$here/README.md" "$proj/"
{
    sed "s/@MIN_IOS@/$min_ios/; s/@BUNDLE@/$bundle/" "$here/project.yml.in"
    for f in winehost.o stubs.o libntdll_unix.a libwin32u_unix.a libwineserver.a; do
        echo "          - \"\$(PROJECT_DIR)/lib/\$(PLATFORM_NAME)/$f\""
    done
    for f in $(cat "$out/host-iphoneos/weak-flags"); do echo "          - \"$f\""; done
    for f in Foundation CoreFoundation CoreText CoreGraphics AudioToolbox; do
        echo "          - \"-framework\""
        echo "          - \"$f\""
    done
    echo '          - "-lc++"'
    echo '          - "-lz"'
} >"$proj/project.yml"
(cd "$proj" && xcodegen generate --spec project.yml)

# build SDK: builds the project with xcodebuild and checks the product;
# prints the app's path. Signing for the device is the user's part.
build() {
    sign=
    [ "$1" = iphoneos ] && sign=CODE_SIGNING_ALLOWED=NO
    # shellcheck disable=SC2086 # $sign is empty or one setting
    xcodebuild -project "$proj/WinPadWine.xcodeproj" -scheme WinPadWine -configuration Debug \
        -sdk "$1" -derivedDataPath "$out/xcode-derived" $sign build >"$out/xcodebuild-$1.log" 2>&1 ||
        { tail -60 "$out/xcodebuild-$1.log" >&2; exit 1; }
    product="$out/xcode-derived/Build/Products/Debug-$1/WinPadWine.app"
    for f in Frameworks/fexaot.dylib aarch64-windows/ntdll.dll.dylib aarch64-windows/xtajit.dll.dylib \
        i386-windows/ntdll.dll i386-windows/hello.exe nls/locale.nls; do
        test -f "$product/$f" || { echo "the $1 build lacks $f" >&2; exit 1; }
    done
    nm "$product/WinPadWine" | grep -q ' T _winehost_main$' ||
        { echo "the $1 build did not link the Wine host" >&2; exit 1; }
    echo "$product"
}
build iphoneos >/dev/null
sim_app=$(build iphonesimulator)

# Run the simulator build on an iPad simulator and read the app's log.
udid=$(xcrun simctl list devices available -j | python3 -I "$root/tests/ios/xcode/pick-ipad.py" $min_ios)
[ -n "$udid" ] || { echo "no iPad simulator with iOS $min_ios or later" >&2; exit 1; }
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl install "$udid" "$sim_app"
# The map of an iPad without the extended virtual addressing entitlement ends at
# 0x7180000000 (TASK_VM_INFO.max_address); ntdll places the 32-bit guest window
# as if the simulator's did too (patches/madeira/0003). An iPad maps nothing at
# address 0, so ntdll maps no copy of the TEB there either (patches/madeira/0004).
# Its kernel refuses mappings at 32-63 GB and past the end of the map, so the
# host holds those ranges (WINEHOST_VA_HOLES), and FEX's host band is the rest
# of the map above the guest window (patches/fex-wow64/0019).
SIMCTL_CHILD_MADEIRA_WOW_MAP_END=0x7180000000 SIMCTL_CHILD_MADEIRA_PAGE0=0 \
    SIMCTL_CHILD_WINEHOST_VA_HOLES=0x800000000-0x1000000000,0x7180000000-0x8000000000 \
    xcrun simctl launch "$udid" "$bundle"
log="$(xcrun simctl get_app_container "$udid" "$bundle" data)/Documents/wine.log"
for _ in $(seq 150); do
    grep -q '== finished' "$log" 2>/dev/null && break
    sleep 1
done
xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
# The same kind of excerpt as run-host.sh: a fault storm repeats one line.
awk '{ k = $0; gsub(/[0-9]+/, "#", k); k = substr(k, 1, 30); if (++same[k] > 40) next } { print }' "$log" || true
grep -q '== finished, exit 0' "$log" ||
    { echo "the app did not run the x86 program in Wine on the simulator" >&2; exit 1; }
for expect in 'Hello from x86' 'winehost: NoJIT, so no JIT pool' \
    '[nojit] no JIT pool: nothing is written to executable memory' \
    '[aot-dispatcher] static code from the AOT image' 'xtajit.dll.dylib" at' \
    '[wow-window] MADEIRA_WOW_MAP_END: the map is taken to end at 0x7180000000' \
    '[wow-window] short address map: it ends at 0x7180000000' \
    'page0: MADEIRA_PAGE0=0: page 0 taken to be unavailable' \
    "winehost: address range [0x7180000000, 0x8000000000) held" \
    '[va-profile] ml787 FEX host arena = [0x7100100000, 0x717fffffff]'; do
    grep -qF "$expect" "$log" || { echo "missing in the app's log: $expect" >&2; exit 1; }
done
# Under Xcode's debugger on an iPad the debugger BRK of the page-0 chain stopped
# the app; ntdll executes it only with MADEIRA_PAGE0=debugger.
if grep -qF 'page0: trying debugger' "$log"; then
    echo "ntdll asked a debugger to map page 0 (BRK #0xf00d)" >&2; exit 1
fi
echo "The x86 program ran in Wine in the app on the iPad simulator, from the AOT image with NoJIT"
