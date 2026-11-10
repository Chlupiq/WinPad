#!/bin/sh
# Builds the unix side of Wine's ntdll the way Madeira's build/ntdll-unix/build.sh
# does (Madeira's *_ios.c files in place of Wine's), with
# the patches in patches/madeira (0001: adopt PE images from dylibs; 0005 and 0009 are
# for Madeira's wine submodule, the others for build/), into
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
trap 'git -C "$madeira" checkout -q -- build; git -C "$wine" checkout -q -- dlls/ntdll/unix/file.c' EXIT

compile() {  # SOURCE NAME [FLAGS...]
    c_src=$1 c_name=$2
    shift 2
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
        "$@" -c "$c_src" -o "$out/$c_name.o" 2>"$out/$c_name.err"; then
        echo "$c_name" >>"$out/ok"
    else
        echo "$c_name" >>"$out/failed"
        sed -n '1,15p' "$out/$c_name.err" >&2
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

# The unix sides of nsi.dll (network adapters, IP addresses, TCP tables: nsiproxy.sys is
# not shipped, nsi.dll falls back to these) and dnsapi.dll, as Madeira's build.sh builds
# them. Without them their call tables were missing and link-host.sh's stand-ins answer
# every call STATUS_NOT_SUPPORTED. A file that does not build here is left out with a
# warning (the stand-in takes its place) instead of failing the build.
optional() {  # SOURCE NAME [FLAGS...]
    compile "$@"
    if [ -f "$out/failed" ] && grep -qx "$2" "$out/failed"; then
        echo "warning: $2 did not build, its unix calls answer STATUS_NOT_SUPPORTED:" >&2
        sed -n '1,10p' "$out/$2.err" >&2
        grep -vx "$2" "$out/failed" >"$out/failed.tmp" || true
        mv "$out/failed.tmp" "$out/failed"
        [ -s "$out/failed" ] || rm -f "$out/failed"
        rm -f "$out/$2.o"
    fi
}
nsi_ok=1
for f in nsi_unixlib_ios:nsi_unixlib_ios nsi_network_ios:nsi_network_ios nsi_ndis_ios:nsi_ndis nsi_ip_ios:nsi_ip; do
    optional "$src/${f%%:*}.c" "${f#*:}"
    [ -f "$out/${f#*:}.o" ] || nsi_ok=0
done
# The four belong together: nsi_unixlib_ios hands the other tables to nsi_network_ios.
if [ "$nsi_ok" = 0 ]; then
    echo "warning: nsi's unix side is incomplete, leaving all of it out" >&2
    rm -f "$out/nsi_unixlib_ios.o" "$out/nsi_network_ios.o" "$out/nsi_ndis.o" "$out/nsi_ip.o"
fi
optional "$src/dnsapi_unixlib_ios.c" dnsapi_unixlib_ios
# Winsock's unix side (sockets for a game's network code), named as Madeira's
# compile_unixlib names it.
optional "$wine/dlls/ws2_32/unixlib.c" ws2_32_unixlib -I"$wine/dlls/ws2_32" \
    -D__wine_unix_call_funcs=ws2_32_unix_call_funcs -D__wine_unix_call_wow64_funcs=ws2_32_unix_call_wow64_funcs

ok=$(wc -l <"$out/ok" | tr -d ' ')
failed=0
[ -f "$out/failed" ] && failed=$(wc -l <"$out/failed" | tr -d ' ')
echo "ntdll unix side for $sdk_name: $ok files built, $failed failed"
[ "$failed" = 0 ] || echo "failed: $(tr '\n' ' ' <"$out/failed")"
[ "$failed" = 0 ] || exit 1
xcrun ar rcs "$out/libntdll_unix.a" "$out"/*.o
echo "$out/libntdll_unix.a: $(wc -c <"$out/libntdll_unix.a" | tr -d ' ') bytes"
