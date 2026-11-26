#!/bin/sh
# JITPool.c (FEX's JIT pool from StikDebug's universal.js script) on a Mac, with the script
# played by a signal handler (jit-protocol-test.c); and JITPool.c and WinPadJIT.m built for
# an iPad and its simulator, as the app builds them.
# Usage: sh tests/wine-app/jit-protocol-test.sh WORKDIR
set -eu
here=$(cd "$(dirname "$0")" && pwd)
work=${1:?usage: jit-protocol-test.sh WORKDIR}
mkdir -p "$work"
clang -arch arm64 -O1 -Wall -Werror -framework CoreFoundation \
    "$here/jit-protocol-test.c" "$here/JITPool.c" -o "$work/jit-protocol-test"
"$work/jit-protocol-test" "$work/jit-check-marker"
for sdk in iphoneos iphonesimulator; do
    target=arm64-apple-ios17.4
    [ "$sdk" = iphonesimulator ] && target=arm64-apple-ios17.4-simulator
    xcrun -sdk "$sdk" clang -target "$target" -Wall -Werror -c "$here/JITPool.c" -o "$work/JITPool-$sdk.o"
    xcrun -sdk "$sdk" clang -target "$target" -fobjc-arc -Wall -Werror -c "$here/WinPadJIT.m" -o "$work/WinPadJIT-$sdk.o"
    # The game detection and automatic settings (no UIKit), quick to check here.
    xcrun -sdk "$sdk" clang -target "$target" -Wall -Werror -c "$here/GameDetect.c" -o "$work/GameDetect-$sdk.o"
    xcrun -sdk "$sdk" clang -target "$target" -fobjc-arc -Wall -Werror -c "$here/WinPadAuto.m" -o "$work/WinPadAuto-$sdk.o"
done
echo "JITPool.c, WinPadJIT.m, GameDetect.c and WinPadAuto.m build for iphoneos and iphonesimulator"
