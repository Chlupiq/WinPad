#!/bin/sh
# SPDX-License-Identifier: MIT
# Packs WinPad Wine into an unsigned IPA, for AltStore, SideStore or Sideloadly to
# sign with the user's Apple ID and install.
#
# usage: make-ipa.sh SOURCE OUT.ipa
#   SOURCE: the Xcode project folder (WinPadWine-xcode), which is then built for the
#   iPad without signing, or an iphoneos build of WinPadWine.app.
#
# On the Mac run it after game-aot.sh, so the IPA carries the game's AOT image;
# CI packs only the test programs (an IPA with a game's image never leaves the Mac).
set -eu

[ $# -eq 2 ] || { echo "usage: $0 SOURCE OUT.ipa" >&2; exit 2; }
src=$1
ipa=$(cd "$(dirname "$2")" && pwd)/$(basename "$2")
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT

if [ -d "$src/WinPadWine.xcodeproj" ]; then
    xcodebuild -project "$src/WinPadWine.xcodeproj" -scheme WinPadWine -configuration Debug \
        -sdk iphoneos -derivedDataPath "$work/derived" CODE_SIGNING_ALLOWED=NO build \
        >"$work/xcodebuild.log" 2>&1 || { tail -60 "$work/xcodebuild.log" >&2; exit 1; }
    app="$work/derived/Build/Products/Debug-iphoneos/WinPadWine.app"
elif [ -f "$src/WinPadWine" ] && [ -f "$src/Info.plist" ]; then
    app=$src
else
    echo "$src is neither the Xcode project folder nor WinPadWine.app" >&2
    exit 1
fi
# A simulator build would install but not run.
plat=$(plutil -extract CFBundleSupportedPlatforms.0 raw "$app/Info.plist")
[ "$plat" = iPhoneOS ] || { echo "$app is a $plat build, not one for the iPad" >&2; exit 1; }

mkdir "$work/Payload"
cp -R "$app" "$work/Payload/"
# Signing is the installer's part: no leftover signature of the build.
find "$work/Payload" -name _CodeSignature -prune -exec rm -rf {} +
rm -f "$work/Payload/WinPadWine.app/embedded.mobileprovision"
rm -f "$ipa"
(cd "$work" && zip -qry "$ipa" Payload)

dylibs=$(find "$work/Payload" -name '*.dylib' | wc -l | tr -d ' ')
echo "$ipa: $(du -h "$ipa" | cut -f1), $dylibs dylibs for the installer to sign"
