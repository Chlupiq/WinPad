#!/bin/sh
# Packs the iPad test app (tests/ios/app) as an Xcode project for a Mac with
# Xcode: open WinPadProbe.xcodeproj, pick a team, Run on the iPad. Xcode signs
# the app with the user's account and shows the probe's log in its console.
#
# Everything that needs FEX's sources is prebuilt: the probe and FEXCore as
# static libraries (from build-app.sh's build directory) and the AOT image
# (probe-aot.dylib from build-app.sh's output). Only main.mm is compiled.
# The project is generated with XcodeGen and then checked with xcodebuild.
#
# Usage: build-xcode.sh APP_BUILD_DIR APP_OUT_DIR OUT_DIR
#   APP_BUILD_DIR, APP_OUT_DIR: build-app.sh's BUILD_DIR and OUT_DIR
# Needs: Xcode, ninja, xcodegen, python3. Writes OUT_DIR/WinPadProbe-xcode.zip.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
build=$1
app_out=$2
out=$3
min_ios=17.4
proj="$out/WinPadProbe-xcode"
rm -rf "${proj:?}"
mkdir -p "$proj/lib" "$proj/Frameworks"

# Libraries and flags from CMake's link of the app, in link order.
ninja -C "$build" -t commands WinPadProbe | tail -n 1 >"$out/link-command.txt"
python3 -I - "$build" "$out/link-command.txt" "$proj/lib" "$proj/ldflags.txt" <<'EOF'
import os, shlex, shutil, sys
build, command, libdir, flags_out = sys.argv[1:]
# CMake's Ninja link rule is ": && <link> && :".
args = shlex.split(max(open(command).read().split("&&"), key=len))
flags, seen = [], set()
i = 0
while i < len(args):
    a = args[i]
    if a.endswith(".a"):
        name = os.path.basename(a)
        if name in seen:
            sys.exit("two libraries named " + name)
        seen.add(name)
        shutil.copy(os.path.join(build, a), os.path.join(libdir, name))
        flags.append("$(PROJECT_DIR)/lib/" + name)
    elif a == "-framework":
        flags += [a, args[i + 1]]
        i += 1
    elif a.startswith("-framework "):
        flags += a.split()
    elif a.startswith("-l"):
        flags.append(a)
    i += 1
if not any(f.endswith("libWinPadProbeCore.a") for f in flags):
    sys.exit("libWinPadProbeCore.a is not on the link line")
open(flags_out, "w").write("\n".join(flags) + "\n")
print("\n".join(flags))
EOF

cp "$here/app/main.mm" "$proj/"
cp "$app_out/probe-aot.dylib" "$proj/Frameworks/"
# Xcode fills in the bundle id and executable name from the build settings.
sed -e "s/\${WINPAD_IOS_MIN}/$min_ios/" \
    -e 's/<string>com.chlupiq.winpad.probe</<string>$(PRODUCT_BUNDLE_IDENTIFIER)</' \
    -e 's/<string>WinPadProbe<\/string>/<string>$(EXECUTABLE_NAME)<\/string>/' \
    "$here/app/Info.plist.in" >"$proj/Info.plist"
plutil -lint "$proj/Info.plist"

{
    cat <<EOF
name: WinPadProbe
options:
  deploymentTarget:
    iOS: "$min_ios"
targets:
  WinPadProbe:
    type: application
    platform: iOS
    sources:
      - main.mm
    dependencies:
      # The AOT image: copied into Frameworks/ and signed, never linked;
      # the probe loads it with dlopen.
      - framework: Frameworks/probe-aot.dylib
        embed: true
        link: false
        codeSign: true
    settings:
      base:
        INFOPLIST_FILE: Info.plist
        PRODUCT_BUNDLE_IDENTIFIER: com.chlupiq.winpad.probe
        TARGETED_DEVICE_FAMILY: "1,2"
        SUPPORTED_PLATFORMS: iphoneos
        CLANG_ENABLE_OBJC_ARC: YES
        CODE_SIGN_STYLE: Automatic
        LD_RUNPATH_SEARCH_PATHS: "@executable_path/Frameworks"
        OTHER_LDFLAGS:
EOF
    sed 's/^/          - "/; s/$/"/' "$proj/ldflags.txt"
} >"$proj/project.yml"
rm "$proj/ldflags.txt"
cp "$here/xcode/README.md" "$proj/"
(cd "$proj" && xcodegen generate --spec project.yml)

# The project must build and embed the image; signing is the user's part.
xcodebuild -project "$proj/WinPadProbe.xcodeproj" -scheme WinPadProbe -configuration Debug \
    -sdk iphoneos -derivedDataPath "$out/xcode-derived" CODE_SIGNING_ALLOWED=NO build
product="$out/xcode-derived/Build/Products/Debug-iphoneos/WinPadProbe.app"
test -f "$product/Frameworks/probe-aot.dylib" ||
    { echo "the Xcode build did not embed probe-aot.dylib" >&2; exit 1; }
nm "$product/WinPadProbe" | grep -q WinPadProbeMain ||
    { echo "the Xcode build did not link the probe" >&2; exit 1; }

(cd "$out" && rm -f WinPadProbe-xcode.zip && zip -qr WinPadProbe-xcode.zip WinPadProbe-xcode)
ls -l "$out/WinPadProbe-xcode.zip"
