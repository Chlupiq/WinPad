#!/bin/sh
# Links host/winehost.c with the libntdll_unix.a, libwin32u_unix.a and
# libwineserver.a that build-ntdll.sh, build-win32u.sh and build-wineserver.sh
# built for SDK. What the app around Madeira's Wine would provide
# (Swift bridges, the gamepad, DXMT, FEX) is not linked: every symbol the
# linker reports missing gets a stub that logs its first call and returns 0.
# Except the weak winios_* hooks of win32u's display driver: those stay
# undefined (NULL), so the driver falls back to Wine's null driver,
# where a stub returning 0 would fail the call (pCreateWindow kills every
# window).
# The stub list says what a Wine host has to bring along.
# When WORK_DIR/dxmt-SDK/libdxmt_combined.a is there (DXMT's unix side,
# tests/wine-i386/build-dxmt-unix.sh), it is linked too, with
# host/metal-display.m, which gives DXMT a CAMetalLayer for each window.
#
# Usage: link-host.sh SDK WORK_DIR OUT_DIR   (SDK: iphoneos or iphonesimulator)
# Writes OUT_DIR/winehost (the command-line host), OUT_DIR/stubs.o, the
# linker flags for the weak hooks in OUT_DIR/weak-flags, and, for an app
# that calls winehost_main itself (tests/wine-app), OUT_DIR/winehost-lib.o.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
sdk_name=$1
work=$2
out=$3
mkdir -p "$out"
case $sdk_name in
    iphoneos) target=arm64-apple-ios17.0 ;;
    iphonesimulator) target=arm64-apple-ios17.0-simulator ;;
    *) echo "unknown SDK $sdk_name" >&2; exit 2 ;;
esac
sdk=$(xcrun --sdk "$sdk_name" --show-sdk-path)
cc="xcrun -sdk $sdk_name clang -target $target -isysroot $sdk"
libs="$work/ntdll-$sdk_name/libntdll_unix.a $work/win32u-$sdk_name/libwin32u_unix.a
    $work/wineserver-$sdk_name/libwineserver.a"
objs="$out/winehost.o"
frameworks=
if [ -f "$work/dxmt-$sdk_name/libdxmt_combined.a" ]; then
    libs="$libs $work/dxmt-$sdk_name/libdxmt_combined.a"
    frameworks="-framework Metal -framework QuartzCore -framework IOSurface"
    # shellcheck disable=SC2086
    $cc -O1 -g -Wall -fobjc-arc -c "$here/host/metal-display.m" -o "$out/metal-display.o"
    objs="$objs $out/metal-display.o"
fi

# shellcheck disable=SC2086 # $cc and $libs are lists
$cc -O1 -g -Wall -c "$here/host/winehost.c" -o "$out/winehost.o"
# shellcheck disable=SC2086
$cc -O1 -g -Wall -DWINEHOST_LIBRARY -c "$here/host/winehost.c" -o "$out/winehost-lib.o"
link() {
    # shellcheck disable=SC2086
    $cc -o "$out/winehost" $objs "$@" $libs $frameworks \
        -framework Foundation -framework CoreFoundation -framework CoreText -framework CoreGraphics -framework AudioToolbox -lc++ -lz
}

if link 2>"$out/link1.log"; then
    : >"$out/missing"
else
    sed -n 's/^ *"\([^"]*\)", referenced from:.*/\1/p' "$out/link1.log" | sort -u >"$out/missing"
    if [ ! -s "$out/missing" ]; then
        tail -30 "$out/link1.log" >&2
        exit 1
    fi
fi
# A hook counts as weak only if no object refers to it strongly.
# shellcheck disable=SC2086
xcrun nm -m $libs 2>/dev/null >"$out/refs"
sed -n 's/.*(undefined) external \(_winios_[^ ]*\).*/\1/p' "$out/refs" | sort -u >"$out/strong-refs"
sed -n 's/.*(undefined) weak external \(_winios_[^ ]*\).*/\1/p' "$out/refs" | sort -u |
    grep -vFxf "$out/strong-refs" >"$out/weak-refs" || true
grep -Fxf "$out/weak-refs" "$out/missing" >"$out/weak" || true
grep -vFxf "$out/weak-refs" "$out/missing" >"$out/stubbed" || true
sed 's/^/-Wl,-U,/' "$out/weak" >"$out/weak-flags"
n=$(wc -l <"$out/missing" | tr -d ' ')
echo "Symbols a Wine host has to provide: $n"
sed 's/^/  /' "$out/missing"

{
    echo '#include <stdio.h>'
    echo 'static long winehost_stub(const char* name, int* seen) {'
    # printf: the sh echo on macOS would turn the \n into a newline.
    printf '%s\n' '  if (!*seen) { *seen = 1; fprintf(stderr, "winehost: stub %s called\n", name); }'
    echo '  return 0;'
    echo '}'
    i=0
    while read -r sym; do
        name=${sym#_}
        echo "static int seen_$i;"
        echo "long stub_$i(void) __asm__(\"$sym\");"
        echo "long stub_$i(void) { return winehost_stub(\"$name\", &seen_$i); }"
        i=$((i + 1))
    done <"$out/stubbed"
} >"$out/stubs.c"
# shellcheck disable=SC2086
$cc -O1 -c "$out/stubs.c" -o "$out/stubs.o"
# shellcheck disable=SC2046 # one flag per hook
if ! link "$out/stubs.o" $(cat "$out/weak-flags") 2>"$out/link2.log"; then
    tail -30 "$out/link2.log" >&2
    exit 1
fi
echo "Linked $out/winehost for $sdk_name: $(wc -c <"$out/winehost" | tr -d ' ') bytes"
