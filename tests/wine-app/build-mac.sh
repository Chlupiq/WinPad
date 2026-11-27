#!/bin/sh
# Builds the Mac app (Mac Catalyst) from the Xcode project build-xcode.sh made, when Wine was
# built for the Mac too (lib/macosx, wine/macosx): signed to run on this Mac (ad hoc, with
# WinPadMac.entitlements, whose hardened runtime allows FEX's JIT), and runs it here as a Mac
# app: hello.exe with FEX's JIT and, with DXMT, the D3D11 triangle. Its sandbox keeps
# Documents in its container (~/Library/Containers/BUNDLE/Data/Documents).
#
# Usage: build-mac.sh OUT_DIR   (build-xcode.sh's OUT_DIR, with WinPadWine-xcode in it)
set -eu
# The iPad's extensions (JIT helper, VPN) are iOS targets the scheme still builds for an iPad
# alongside; they stay unsigned (ad hoc signing is the Mac's only).

out=$1
proj="$out/WinPadWine-xcode"
bundle=com.chlupiq.winpad.wine
[ -f "$proj/lib/macosx/libntdll_unix.a" ] || { echo "the project has no Wine for the Mac (lib/macosx)" >&2; exit 1; }
d3d9=
[ ! -f "$proj/lib/macosx/libdxmt_combined.a" ] || d3d9=1
xcodebuild -project "$proj/WinPadWine.xcodeproj" -scheme WinPadWine -configuration Debug \
    -destination 'generic/platform=macOS,variant=Mac Catalyst' -derivedDataPath "$out/xcode-derived" \
    CODE_SIGN_IDENTITY=- CODE_SIGN_STYLE=Manual DEVELOPMENT_TEAM= PROVISIONING_PROFILE_SPECIFIER= \
    'CODE_SIGNING_ALLOWED[sdk=iphoneos*]=NO' \
    build >"$out/xcodebuild-maccatalyst.log" 2>&1 ||
    { tail -80 "$out/xcodebuild-maccatalyst.log" >&2; exit 1; }
mac_app="$out/xcode-derived/Build/Products/Debug-maccatalyst/WinPadWine.app"
res="$mac_app/Contents/Resources"
for f in aarch64-windows/ntdll.dll.dylib aarch64-windows/xtajit.dll.dylib i386-windows/ntdll.dll \
    i386-windows/hello.exe nls/locale.nls system.reg profiles/mafia.json; do
    test -f "$res/$f" || { echo "the Mac app lacks Contents/Resources/$f" >&2; exit 1; }
done
test ! -e "$mac_app/Contents/PlugIns/WinPadJITHelper.appex" || { echo "the Mac app carries the iPad's JIT helper" >&2; exit 1; }
codesign -d --entitlements - "$mac_app" 2>/dev/null | grep -q 'com.apple.security.cs.allow-jit' ||
    { echo "the Mac app is not signed with WinPadMac.entitlements" >&2; exit 1; }
mac_docs="$HOME/Library/Containers/$bundle/Data/Documents"
# run_mac NAME [ARGS...]: runs the Mac app with ARGS until the program in it has ended.
run_mac() {
    name=$1
    shift
    rm -f "$mac_docs/wine.log"
    "$mac_app/Contents/MacOS/WinPadWine" "$@" >"$out/mac-$name.out" 2>&1 &
    pid=$!
    for _ in $(seq 240); do
        grep -q '== finished' "$mac_docs/wine.log" 2>/dev/null && break
        kill -0 $pid 2>/dev/null || break
        sleep 1
    done
    kill $pid 2>/dev/null || true
    wait $pid 2>/dev/null || true
    cp "$mac_docs/wine.log" "$out/wine-mac-$name.log" 2>/dev/null || true
    echo "--- the Mac app's log, $name ---"
    awk '{ k = $0; gsub(/[0-9]+/, "#", k); k = substr(k, 1, 30); if (++same[k] > 40) next } { print }' \
        "$mac_docs/wine.log" 2>/dev/null || tail -40 "$out/mac-$name.out"
}
run_mac hello -program hello
for expect in 'Hello from x86' 'Mac Catalyst: the program runs with FEX' 'winehost: JIT pool' '== finished, exit 0'; do
    grep -qF "$expect" "$mac_docs/wine.log" || { echo "missing in the Mac app's log (hello): $expect" >&2; exit 1; }
done
echo "The x86 program ran in Wine in the Mac app (Mac Catalyst) with FEX's JIT"
if [ -n "$d3d9" ]; then
    run_mac d3d11 -program d3d11-triangle
    if grep -qF '[clock]' "$mac_docs/wine.log" && ! grep -q '\[clock\] [0-9]* s, 0 frames' "$mac_docs/wine.log"; then
        echo "The D3D11 triangle drew frames in the Mac app: $(grep -F '[clock]' "$mac_docs/wine.log" | tail -1)"
    else
        # A CI Mac's GPU is a virtual machine's: say what happened rather than fail.
        echo "::warning::the D3D11 triangle drew no frame in the Mac app on this CI Mac: $(grep -F '[clock]' "$mac_docs/wine.log" | tail -1)"
    fi
fi
