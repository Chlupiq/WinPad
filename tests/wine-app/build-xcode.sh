#!/bin/sh
# Packs the Wine app (tests/wine-app) as an Xcode project for a Mac with
# Xcode: open WinPadWine.xcodeproj, pick a team, Run on the iPad or on an
# iPad simulator (Apple Silicon Macs). It runs the 32-bit x86 hello.exe in
# Wine through WoW64 and FEX, with NoJIT, from the AOT image CI linked
# (with the blocks FEX's interpreter ran compiled in, converge-nojit.sh); a
# block still missing from it runs in that interpreter.
#
# Everything but main.m is prebuilt, once for the device (iphoneos) and once
# for the simulator (iphonesimulator): the host (tests/wine-loader/host,
# linked by link-host.sh, with its stubs) and Wine's unix side in
# lib/<platform>/, Wine's modules wrapped into dylibs in
# wine/<platform>/aarch64-windows, the AOT image in Frameworks/<platform>/.
# The x86 modules, the program, the NLS files and the fonts are the same for both.
# The project is generated with XcodeGen, built for both platforms with
# xcodebuild, and the simulator build is run on an iPad simulator.
# With the AOT images of the x86 program with a window (window.exe) too, the
# app can run that one instead (the "program" setting, main.m): the simulator
# build then runs once with each, and the window has to show and take the tap.
# When DXMT's unix side was built for both (WORK_DIR/dxmt-SDK) and the i386
# set has the D3D9 cube (tests/wine-i386/build-d3d9.sh), the app links DXMT
# and host/metal-display.m too, with a scheme "WinPadWine D3D9" for the cube
# and one, "WinPadWine Game", for a game copied into the app's Documents
# (main.m). Neither runs here.
#
# Usage: build-xcode.sh WORK_DIR SIM_AOT_DYLIB DEVICE_AOT_DYLIB OUT_DIR [SIM_WINDOW_AOT DEVICE_WINDOW_AOT]
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
sim_window_aot=${5:-}
dev_window_aot=${6:-}
min_ios=17.4
bundle=com.chlupiq.winpad.wine
proj="$out/WinPadWine-xcode"
rm -rf "${proj:?}"
mkdir -p "$proj"
d3d9=
[ -f "$work/dxmt-iphoneos/libdxmt_combined.a" ] && [ -f "$work/dxmt-iphonesimulator/libdxmt_combined.a" ] &&
    [ -f "$work/i386-windows/d3d9-cube.exe" ] && d3d9=1

for sdk in iphoneos iphonesimulator; do
    test -f "$work/modules-$sdk/aarch64-windows/xtajit.dll.dylib" ||
        { echo "no xtajit.dll.dylib for $sdk in $work/modules-$sdk" >&2; exit 1; }
    sh "$root/tests/wine-loader/link-host.sh" $sdk "$work" "$out/host-$sdk"
    mkdir -p "$proj/lib/$sdk" "$proj/wine/$sdk" "$proj/Frameworks/$sdk"
    cp "$out/host-$sdk/winehost-lib.o" "$proj/lib/$sdk/winehost.o"
    cp "$out/host-$sdk/stubs.o" "$work/ntdll-$sdk/libntdll_unix.a" "$work/win32u-$sdk/libwin32u_unix.a" \
        "$work/wineserver-$sdk/libwineserver.a" "$proj/lib/$sdk/"
    [ -z "$d3d9" ] || cp "$out/host-$sdk/metal-display.o" "$work/dxmt-$sdk/libdxmt_combined.a" "$proj/lib/$sdk/"
    cp -R "$work/modules-$sdk/aarch64-windows" "$proj/wine/$sdk/"
done
# One list of flags serves both platforms through $(PLATFORM_NAME).
cmp "$out/host-iphoneos/weak-flags" "$out/host-iphonesimulator/weak-flags" ||
    { echo "the device and simulator builds leave different hooks undefined" >&2; exit 1; }
cp "$dev_aot" "$proj/Frameworks/iphoneos/fexaot.dylib"
cp "$sim_aot" "$proj/Frameworks/iphonesimulator/fexaot.dylib"
if [ -n "$sim_window_aot" ]; then
    test -f "$work/i386-windows/window.exe" || { echo "no window.exe in $work/i386-windows" >&2; exit 1; }
    cp "$dev_window_aot" "$proj/Frameworks/iphoneos/fexaot-window.dylib"
    cp "$sim_window_aot" "$proj/Frameworks/iphonesimulator/fexaot-window.dylib"
fi
cp -R "$work/i386-windows" "$proj/wine/"
mkdir -p "$proj/wine/nls" "$proj/wine/fonts"
cp "$work"/madeira/wine/nls/*.nls "$proj/wine/nls/"
find "$work/madeira/wine/fonts" -maxdepth 1 -type f \( -name '*.ttf' -o -name '*.ttc' -o -name '*.fon' \) \
    -exec cp {} "$proj/wine/fonts/" \;
echo "Wine files in the project:"
du -sh "$proj"/wine/* "$proj"/wine/*/aarch64-windows "$proj"/lib/* | sed 's/^/  /'

cp "$here/main.m" "$here/Library.h" "$here/Library.m" "$here/Info.plist" "$here/README.md" "$here/make-ipa.sh" "$proj/"
cp -R "$here/Settings.bundle" "$proj/"
{
    sed "s/@MIN_IOS@/$min_ios/; s/@BUNDLE@/$bundle/" "$here/project.yml.in"
    libs="winehost.o stubs.o libntdll_unix.a libwin32u_unix.a libwineserver.a"
    frameworks="Foundation CoreFoundation CoreText CoreGraphics AudioToolbox GameController"
    if [ -n "$d3d9" ]; then
        libs="$libs metal-display.o libdxmt_combined.a"
        frameworks="$frameworks Metal QuartzCore IOSurface"
    fi
    for f in $libs; do
        echo "          - \"\$(PROJECT_DIR)/lib/\$(PLATFORM_NAME)/$f\""
    done
    for f in $(cat "$out/host-iphoneos/weak-flags"); do echo "          - \"$f\""; done
    for f in $frameworks; do
        echo "          - \"-framework\""
        echo "          - \"$f\""
    done
    echo '          - "-lc++"'
    echo '          - "-lz"'
    # Every scheme runs the same app; all but the first pick a program.
    schemes="WinPadWine:"
    [ -z "$sim_window_aot" ] || schemes="$schemes WinPadWine_Window:window"
    [ -z "$d3d9" ] || schemes="$schemes WinPadWine_D3D9:d3d9-cube WinPadWine_Game:game"
    if [ "$schemes" != "WinPadWine:" ]; then
        echo 'schemes:'
        for s in $schemes; do
            echo "  $(echo "${s%%:*}" | tr _ ' '):"
            echo '    build:'
            echo '      targets:'
            echo '        WinPadWine: all'
            echo '    run:'
            echo '      config: Debug'
            # The JIT programs run under Xcode's debugger, which would stop on
            # every signal Wine uses (thread suspend, faults it handles).
            case ${s#*:} in d3d9-cube|game)
                echo '      customLLDBInit: $(SRCROOT)/lldbinit' ;;
            esac
            [ -z "${s#*:}" ] || {
                echo '      environmentVariables:'
                echo "        WINPAD_PROGRAM: ${s#*:}"
            }
        done
    fi
} >"$proj/project.yml"
echo 'process handle SIGUSR1 SIGUSR2 SIGSEGV SIGBUS SIGILL -n false -p true -s false' >"$proj/lldbinit"
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
    test -f "$product/Settings.bundle/Root.plist" || { echo "the $1 build lacks its Settings.bundle" >&2; exit 1; }
    if [ -n "$sim_window_aot" ]; then
        for f in Frameworks/fexaot-window.dylib i386-windows/window.exe; do
            test -f "$product/$f" || { echo "the $1 build lacks $f" >&2; exit 1; }
        done
    fi
    nm "$product/WinPadWine" | grep -q ' T _winehost_main$' ||
        { echo "the $1 build did not link the Wine host" >&2; exit 1; }
    if [ -n "$d3d9" ]; then
        test -f "$product/i386-windows/d3d9-cube.exe" || { echo "the $1 build lacks the D3D9 cube" >&2; exit 1; }
        for sym in _macdrv_functions _winehost_show_metal_layer _dxmt_winemetal_unix_call_wow64_funcs; do
            nm "$product/WinPadWine" | grep -q " [TDS] $sym\$" ||
                { echo "the $1 build lacks $sym" >&2; exit 1; }
        done
    fi
    echo "$product"
}
ipad_app=$(build iphoneos)
# The same build as an unsigned IPA, for AltStore, SideStore or Sideloadly.
sh "$here/make-ipa.sh" "$ipad_app" "$out/WinPadWine.ipa"
for f in WinPadWine Frameworks/fexaot.dylib aarch64-windows/ntdll.dll.dylib Settings.bundle/Root.plist; do
    unzip -l "$out/WinPadWine.ipa" "Payload/WinPadWine.app/$f" >/dev/null ||
        { echo "the IPA lacks $f" >&2; exit 1; }
done
sim_app=$(build iphonesimulator)

# Run the simulator build on an iPad simulator and read the app's log.
udid=$(xcrun simctl list devices available -j | python3 -I "$root/tests/ios/xcode/pick-ipad.py" $min_ios)
[ -n "$udid" ] || { echo "no iPad simulator with iOS $min_ios or later" >&2; exit 1; }
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null
xcrun simctl install "$udid" "$sim_app"
data=$(xcrun simctl get_app_container "$udid" "$bundle" data)
log="$data/Documents/wine.log"
# run_app NAME [ARGS...]: launches the app with ARGS and waits for the end
# of its run; the log is kept as $out/wine-NAME.log.
run_app() {
    name=$1
    shift
    rm -f "$log"
    # The map of an iPad without the extended virtual addressing entitlement ends at
    # 0x7180000000 (TASK_VM_INFO.max_address); ntdll places the 32-bit guest window
    # as if the simulator's did too (patches/madeira/0003). An iPad maps nothing at
    # address 0, so ntdll maps no copy of the TEB there either (patches/madeira/0004).
    # Its kernel refuses mappings at 32-63 GB and past the end of the map, so the
    # host holds those ranges (WINEHOST_VA_HOLES), and FEX's host band is the rest
    # of the map above the guest window (patches/fex-wow64/0024).
    SIMCTL_CHILD_MADEIRA_WOW_MAP_END=0x7180000000 SIMCTL_CHILD_MADEIRA_PAGE0=0 \
        SIMCTL_CHILD_WINEHOST_VA_HOLES=0x800000000-0x1000000000,0x7180000000-0x8000000000 \
        xcrun simctl launch "$udid" "$bundle" "$@"
    for _ in $(seq 150); do
        grep -q '== finished' "$log" 2>/dev/null && break
        sleep 1
    done
    xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
    cp "$log" "$out/wine-$name.log" 2>/dev/null || true
    echo "--- the app's log, $name ---"
    # The same kind of excerpt as run-host.sh: a fault storm repeats one line.
    awk '{ k = $0; gsub(/[0-9]+/, "#", k); k = substr(k, 1, 30); if (++same[k] > 40) next } { print }' "$log" || true
    grep -q '== finished, exit 0' "$log" ||
        { echo "the app did not run the x86 program ($name) in Wine on the simulator" >&2; exit 1; }
    for expect in 'winehost: NoJIT, so no JIT pool' \
        '[nojit] no JIT pool: nothing is written to executable memory' \
        '[aot-dispatcher] static code from the AOT image' 'xtajit.dll.dylib" at' \
        '[wow-window] MADEIRA_WOW_MAP_END: the map is taken to end at 0x7180000000' \
        '[wow-window] short address map: it ends at 0x7180000000' \
        'page0: MADEIRA_PAGE0=0: page 0 taken to be unavailable' \
        "winehost: address range [0x7180000000, 0x8000000000) held" \
        '[va-profile] ml787 FEX host arena = [0x7100100000, 0x717fffffff]'; do
        grep -qF "$expect" "$log" || { echo "missing in the app's log ($name): $expect" >&2; exit 1; }
    done
    # Under Xcode's debugger on an iPad the debugger BRK of the page-0 chain stopped
    # the app; ntdll executes it only with MADEIRA_PAGE0=debugger.
    if grep -qF 'page0: trying debugger' "$log"; then
        echo "ntdll asked a debugger to map page 0 (BRK #0xf00d)" >&2; exit 1
    fi
}
# hello.exe, picked by the "program" setting as a launch argument: without
# one the app opens on its game library.
run_app hello -program hello
for expect in 'Hello from x86' 'WinPad Wine: program hello, AOT image fexaot.dylib'; do
    grep -qF "$expect" "$log" || { echo "missing in the app's log (hello): $expect" >&2; exit 1; }
done
echo "The x86 program ran in Wine in the app on the iPad simulator, from the AOT image with NoJIT"

# The game library the app opens on (Library.m) finds the games copied into
# Documents, one per folder. Fake ones here, copies of hello.exe: one named by
# its winpad.json next to a larger installer, one with only its program, and a
# folder without one. With libraryTest the app writes what it found to
# Documents/library.txt, presses right and A, and writes what it would start.
docs="$data/Documents"
rm -rf "$docs/Test Game" "$docs/Plain" "$docs/Empty" "$docs/library.txt"
mkdir -p "$docs/Test Game" "$docs/Plain" "$docs/Empty"
cp "$sim_app/i386-windows/hello.exe" "$docs/Test Game/TEST.EXE"
cat "$sim_app/i386-windows/hello.exe" "$sim_app/i386-windows/hello.exe" >"$docs/Test Game/SETUP.EXE"
printf '{"title": "WinPad Test"}\n' >"$docs/Test Game/winpad.json"
cp "$sim_app/i386-windows/hello.exe" "$docs/Plain/GAME.EXE"
echo notes >"$docs/Empty/readme.txt"
xcrun simctl launch "$udid" "$bundle" -libraryTest YES
for _ in $(seq 60); do
    grep -q '== finished' "$docs/library.txt" 2>/dev/null && break
    sleep 1
done
xcrun simctl terminate "$udid" "$bundle" 2>/dev/null || true
echo "--- the library's report ---"
cat "$docs/library.txt" || true
for expect in 'library: 2 games' 'library: Plain | Plain/GAME.EXE | 32bit | image none' \
    'library: WinPad Test | Test Game/TEST.EXE | 32bit | image none' 'start: game Test Game/TEST.EXE, image none'; do
    grep -qF "$expect" "$docs/library.txt" 2>/dev/null || { echo "missing in the library's report: $expect" >&2; exit 1; }
done
rm -rf "$docs/Test Game" "$docs/Plain" "$docs/Empty"
echo "The game library found the games in Documents and started the one picked with the controller's buttons"
[ -n "$sim_window_aot" ] || exit 0

# window.exe, picked by the "program" setting, given here as a launch argument
# (the argument domain of NSUserDefaults). The window shows in the app, which
# taps it as CI's runs do; it changes colour and the program exits with 0.
run_app window -program window
for expect in 'WinPad Wine: program window, AOT image fexaot-window.dylib' 'fexaot-window.dylib, ' \
    'winehost: frame of window' 'winehost: clicked' 'winehost: window content changed after the click' \
    'winehost: Wine process exited with code 0'; do
    grep -qF "$expect" "$log" || { echo "missing in the app's log (window): $expect" >&2; exit 1; }
done
rm -rf "$out/window-frames"
mkdir -p "$out/window-frames"
for f in "$data"/Documents/frames/*.bmp; do
    [ -f "$f" ] || { echo "the app wrote no frame of the window" >&2; exit 1; }
    echo "--- window ${f##*/} (newest frame) ---"
    python3 -I "$root/tests/wine-loader/bmp-preview.py" "$f" 64
    sips -s format png "$f" --out "$out/window-frames/$(basename "${f%.bmp}").png" >/dev/null
done
echo "The x86 program with a window drew it and took the tap in the app on the iPad simulator, from its AOT image with NoJIT"

# The same window, closed by the game controllers' A instead of the tap: the
# app draws its touch controller and presses A, which is Enter by default
# (WinPadPadKeys in Library.m) and Space here, remapped as the library's
# settings do (the padKeys setting); the window takes the key, changes colour
# and the program exits.
run_app window-gamepad -program window -gamepadTest YES -padKeys '{a = 32;}'
for expect in 'gamepad: pressing A on the touch controller' 'winehost: key 0x20 down' \
    'winehost: Wine process exited with code 0'; do
    grep -qF "$expect" "$log" || { echo "missing in the app's log (window-gamepad): $expect" >&2; exit 1; }
done
if grep -qF 'gamepad: no key from the touch controller' "$log"; then
    echo "::notice::the simulator's touch controller sent no key for A set from code; the check pressed A through the app's mapping"
fi
echo "A game controller's A reached the x86 program with a window as Enter in the app on the iPad simulator"
