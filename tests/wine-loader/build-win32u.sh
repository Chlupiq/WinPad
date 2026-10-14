#!/bin/sh
# Builds the unix side of Wine's win32u (window manager, GDI, the winios
# display driver in driver_ios.c) the way Madeira's build/win32u-unix/build.sh
# does, Madeira's *_ios.c files in place of Wine's, into libwin32u_unix.a for
# SDK. Leaves out FreeType (Madeira links a static build of it): without it
# win32u has no fonts, but windows and GDI drawing work.
#
# Usage: build-win32u.sh WORK_DIR SDK   (SDK: iphoneos or iphonesimulator)
# WORK_DIR must hold the trees build.sh fetched and configured. win32u needs
# the COM headers Wine generates from IDL files; they are made here with
# Wine's own widl (needs bison and flex on PATH) when they are missing.
set -eu

work=$1
sdk_name=$2
madeira="$work/madeira"
wine="$madeira/wine"
src="$madeira/build/win32u-unix"
out="$work/win32u-$sdk_name"
rm -rf "$out"
mkdir -p "$out"

case $sdk_name in
    iphoneos) target=arm64-apple-ios17.0 ;;
    iphonesimulator) target=arm64-apple-ios17.0-simulator ;;
    *) echo "unknown SDK $sdk_name" >&2; exit 2 ;;
esac
sdk=$(xcrun --sdk "$sdk_name" --show-sdk-path)

if [ ! -f "$wine/build-macos/include/objidlbase.h" ]; then
    headers=$(cd "$wine" && ls include/*.idl | sed 's/\.idl$/.h/')
    # shellcheck disable=SC2086 # one target per header
    # -k: a few IDL files make no header (type libraries only).
    make -k -C "$wine/build-macos" -j"$(sysctl -n hw.ncpu)" $headers >"$work/make-include.log" 2>&1 || true
    [ -f "$wine/build-macos/include/objidlbase.h" ] || { tail -20 "$work/make-include.log" >&2; exit 1; }
    echo "Generated Wine's IDL headers: $(echo "$headers" | wc -w | tr -d ' ')"
fi

compile() {  # SOURCE NAME
    if xcrun -sdk "$sdk_name" clang -target "$target" -isysroot "$sdk" \
        -O2 -fPIC -fvisibility=hidden -fno-stack-protector -fno-strict-aliasing \
        -Wno-implicit-function-declaration -Wno-int-conversion \
        -include "$src/config_ios.h" \
        -include "$madeira/build/ntdll-unix/shims/wine_ios_exit.h" \
        -I"$src" -I"$wine/build-macos/include" -I"$madeira/build/ntdll-unix/shims" \
        -I"$wine/build-macos/dlls/win32u" -I"$wine/dlls/win32u" -I"$wine/include" \
        -D__WINESRC__ -D_WIN32U_ -D_ACRTIMP= -DWINBASEAPI= -DSYSTEMDLLPATH=\"\" \
        -DWINE_UNIX_LIB -DWINE_IOS=1 \
        -D__wine_unix_lib_init=win32u_unix_lib_init \
        -c "$1" -o "$out/$2.o" 2>"$out/$2.err"; then
        echo "$2" >>"$out/ok"
    else
        echo "$2" >>"$out/failed"
        sed -n '1,15p' "$out/$2.err" >&2
    fi
}

for f in "$wine"/dlls/win32u/*.c "$wine"/dlls/win32u/dibdrv/*.c; do
    name=$(basename "$f" .c)
    case $f in
        */dibdrv/*) name="dibdrv_$name" ;;  # dibdrv has its own dc.c, bitblt.c, objects.c
    esac
    case $name in
        main) continue ;;  # the PE side (win32u.dll)
        class | winstation | sysparams | defwnd | driver | message | d3dkmt | syscall)
            f="$src/${name}_ios.c" ;;
    esac
    compile "$f" "$name"
done

ok=$(wc -l <"$out/ok" | tr -d ' ')
failed=0
[ -f "$out/failed" ] && failed=$(wc -l <"$out/failed" | tr -d ' ')
echo "win32u unix side for $sdk_name: $ok files built, $failed failed"
[ "$failed" = 0 ] || echo "failed: $(tr '\n' ' ' <"$out/failed")"
[ "$failed" = 0 ] || exit 1
xcrun ar rcs "$out/libwin32u_unix.a" "$out"/*.o
echo "$out/libwin32u_unix.a: $(wc -c <"$out/libwin32u_unix.a" | tr -d ' ') bytes"
