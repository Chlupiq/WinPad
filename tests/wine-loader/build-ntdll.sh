#!/bin/sh
# Builds the unix side of Wine's ntdll the way Madeira's build/ntdll-unix/build.sh
# does (Madeira's *_ios.c files in place of Wine's), with
# the patches in patches/madeira (0001: adopt PE images from dylibs), into
# libntdll_unix.a for SDK.
# Leaves out the unix libraries of other DLLs (GnuTLS, FFmpeg, FreeType):
# a Wine process can start without them.
#
# Usage: build-ntdll.sh WORK_DIR SDK   (SDK: iphoneos or iphonesimulator)
# WORK_DIR must hold the trees build.sh fetched and configured.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work=$1
sdk_name=$2
madeira="$work/madeira"
wine="$madeira/wine"
src="$madeira/build/ntdll-unix"
out="$work/ntdll-$sdk_name"
rm -rf "$out"
mkdir -p "$out"

case $sdk_name in
    iphoneos) target=arm64-apple-ios17.0 ;;
    iphonesimulator) target=arm64-apple-ios17.0-simulator ;;
    *) echo "unknown SDK $sdk_name" >&2; exit 2 ;;
esac
sdk=$(xcrun --sdk "$sdk_name" --show-sdk-path)

git -C "$madeira" apply "$root"/patches/madeira/*.patch
trap 'git -C "$madeira" checkout -q -- build' EXIT

compile() {  # SOURCE NAME
    if xcrun -sdk "$sdk_name" clang -target "$target" -isysroot "$sdk" \
        -O2 -fPIC -fvisibility=hidden -fno-stack-protector -fno-strict-aliasing \
        -Wno-implicit-function-declaration -Wno-int-conversion \
        -include "$wine/build-macos/include/config.h" \
        -include "$src/shims/wine_ios_exit.h" \
        -I"$src/shims" -I"$madeira/build/madsync" -DHAVE_LINUX_NTSYNC_H=1 \
        -I"$wine/build-macos/dlls/ntdll" -I"$wine/dlls/ntdll" -I"$wine/dlls/ntdll/unix" \
        -I"$wine/build-macos/include" -I"$wine/include" -I"$root/tools/pe2macho" \
        -D__WINESRC__ -DLTC_NO_PROTOTYPES -DLTC_SOURCE -D_NTSYSTEM_ \
        -D_ACRTIMP= -DWINBASEAPI= \
        -DBINDIR=\"/usr/local/bin\" -DLIBDIR=\"/usr/local/lib\" \
        -DDATADIR=\"/usr/local/share\" -DSYSTEMDLLPATH=\"\" \
        -DWINE_UNIX_LIB -DWINE_IOS=1 \
        -Dget_thread_context=ntdll_get_thread_context \
        -Dset_thread_context=ntdll_set_thread_context \
        -c "$1" -o "$out/$2.o" 2>"$out/$2.err"; then
        echo "$2" >>"$out/ok"
    else
        echo "$2" >>"$out/failed"
        sed -n '1,15p' "$out/$2.err" >&2
    fi
}

compile "$src/audio_null_ios.c" audio_null_ios
compile "$madeira/build/madsync/madsync.c" madsync
for f in "$wine"/dlls/ntdll/unix/*.c; do
    name=$(basename "$f" .c)
    case $name in
        loader | process | server | env | virtual | thread) f="$src/${name}_ios.c" ;;
        signal_arm64) f="$src/signal_arm64_ios.c" ;;
        cdrom) f="$src/cdrom_stub.c" ;;
    esac
    compile "$f" "$name"
done

ok=$(wc -l <"$out/ok" | tr -d ' ')
failed=0
[ -f "$out/failed" ] && failed=$(wc -l <"$out/failed" | tr -d ' ')
echo "ntdll unix side for $sdk_name: $ok files built, $failed failed"
[ "$failed" = 0 ] || echo "failed: $(tr '\n' ' ' <"$out/failed")"
[ "$failed" = 0 ] || exit 1
xcrun ar rcs "$out/libntdll_unix.a" "$out"/*.o
echo "$out/libntdll_unix.a: $(wc -c <"$out/libntdll_unix.a" | tr -d ' ') bytes"
