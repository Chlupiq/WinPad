#!/bin/sh
# Builds the unix side of Wine's win32u (window manager, GDI, the winios
# display driver in driver_ios.c) the way Madeira's build/win32u-unix/build.sh
# does, Madeira's *_ios.c files in place of Wine's, into libwin32u_unix.a for
# SDK. FreeType is built statically from its own source (as Madeira's
# build/freetype-ios does) and merged into the library, so win32u can load
# Wine's TrueType fonts and draw text.
#
# Usage: build-win32u.sh WORK_DIR SDK   (SDK: iphoneos or iphonesimulator)
# WORK_DIR must hold the trees build.sh fetched and configured. win32u needs
# the COM headers Wine generates from IDL files; they are made here with
# Wine's own widl (needs bison and flex on PATH) when they are missing.
set -eu

work=$1
sdk_name=$2
root=$(cd "$(dirname "$0")/../.." && pwd)
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

# FreeType 2.13.3, the version Madeira builds; no optional dependencies,
# the fonts are plain TrueType files from wine/fonts.
FREETYPE_TAG=VER-2-13-3
ft_src="$work/freetype"
ft_build="$work/freetype-$sdk_name"
if [ ! -f "$ft_src/include/ft2build.h" ]; then
    rm -rf "$ft_src"
    git clone -q --depth 1 --branch "$FREETYPE_TAG" https://github.com/freetype/freetype.git "$ft_src"
fi
if [ ! -f "$ft_build/libfreetype.a" ]; then
    cmake -S "$ft_src" -B "$ft_build" -G "Unix Makefiles" \
        -DCMAKE_SYSTEM_NAME=iOS -DCMAKE_OSX_ARCHITECTURES=arm64 \
        -DCMAKE_OSX_DEPLOYMENT_TARGET=17.0 -DCMAKE_OSX_SYSROOT="$sdk" \
        -DCMAKE_BUILD_TYPE=Release -DBUILD_SHARED_LIBS=OFF \
        -DFT_DISABLE_ZLIB=ON -DFT_DISABLE_BZIP2=ON -DFT_DISABLE_PNG=ON \
        -DFT_DISABLE_HARFBUZZ=ON -DFT_DISABLE_BROTLI=ON \
        -DCMAKE_C_FLAGS="-target $target -fno-stack-protector" >"$work/freetype-$sdk_name.log" 2>&1 &&
    cmake --build "$ft_build" -j"$(sysctl -n hw.ncpu)" >>"$work/freetype-$sdk_name.log" 2>&1 ||
        { tail -20 "$work/freetype-$sdk_name.log" >&2; exit 1; }
fi
echo "FreeType for $sdk_name: $ft_build/libfreetype.a"

compile() {  # SOURCE NAME [FLAGS...]
    f=$1
    name=$2
    shift 2
    if xcrun -sdk "$sdk_name" clang -target "$target" -isysroot "$sdk" \
        -O2 -fPIC -fvisibility=hidden -fno-stack-protector -fno-strict-aliasing \
        -Wno-implicit-function-declaration -Wno-int-conversion \
        -include "$src/config_ios.h" \
        -include "$madeira/build/ntdll-unix/shims/wine_ios_exit.h" \
        -I"$src" -I"$wine/build-macos/include" -I"$madeira/build/ntdll-unix/shims" \
        -I"$wine/build-macos/dlls/win32u" -I"$wine/dlls/win32u" -I"$wine/include" \
        -D__WINESRC__ -D_WIN32U_ -D_ACRTIMP= -DWINBASEAPI= -DSYSTEMDLLPATH=\"\" \
        -DWINE_UNIX_LIB -DWINE_IOS=1 \
        -D__wine_unix_lib_init=win32u_unix_lib_init "$@" \
        -c "$f" -o "$out/$name.o" 2>"$out/$name.err"; then
        echo "$name" >>"$out/ok"
    else
        echo "$name" >>"$out/failed"
        sed -n '1,15p' "$out/$name.err" >&2
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
        window)
            # Patched copy: patches/wine/0002 logs why show_window skips the
            # redraw (the parent desktop window, as win32u sees it).
            mkdir -p "$out/src"
            cp "$f" "$out/src/window.c"
            patch -s "$out/src/window.c" "$root/patches/wine/0002-ios-trace-show-window-parent.patch"
            f="$out/src/window.c" ;;
        freetype)
            # Madeira's wrapper turns FreeType on for this file only and
            # resolves its dlsym calls against the static library.
            compile "$src/freetype_ios.c" "$name" -I"$ft_build/include" -I"$ft_src/include"
            continue ;;
    esac
    compile "$f" "$name"
done

ok=$(wc -l <"$out/ok" | tr -d ' ')
failed=0
[ -f "$out/failed" ] && failed=$(wc -l <"$out/failed" | tr -d ' ')
echo "win32u unix side for $sdk_name: $ok files built, $failed failed"
[ "$failed" = 0 ] || echo "failed: $(tr '\n' ' ' <"$out/failed")"
[ "$failed" = 0 ] || exit 1
xcrun ar rcs "$out/libwin32u_unix-objs.a" "$out"/*.o
xcrun libtool -static -o "$out/libwin32u_unix.a" "$out/libwin32u_unix-objs.a" "$ft_build/libfreetype.a"
rm "$out/libwin32u_unix-objs.a"
echo "$out/libwin32u_unix.a: $(wc -c <"$out/libwin32u_unix.a" | tr -d ' ') bytes"
