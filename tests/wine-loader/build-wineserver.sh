#!/bin/sh
# Builds wineserver as the static library Madeira links into the app
# (in-process server), from Wine's server/*.c with Madeira's *_ios.c in place
# of the files it forks, with the flags of Madeira's build/wineserver/build.sh.
# Madeira's script only swaps objects into a prebuilt libwineserver.a that is
# not in its repository; this builds every object from source instead.
#
# Usage: build-wineserver.sh WORK_DIR SDK   (SDK: iphoneos or iphonesimulator)
# WORK_DIR must hold the trees build.sh fetched and configured.
# Needs llvm-objcopy (Homebrew llvm) for the symbol renames.
set -eu

work=$1
sdk_name=$2
madeira="$work/madeira"
wine="$madeira/wine"
src="$madeira/build/wineserver"
out="$work/wineserver-$sdk_name"
rm -rf "$out"
mkdir -p "$out/obj"

case $sdk_name in
    iphoneos) target=arm64-apple-ios17.0 ;;
    iphonesimulator) target=arm64-apple-ios17.0-simulator ;;
    *) echo "unknown SDK $sdk_name" >&2; exit 2 ;;
esac
sdk=$(xcrun --sdk "$sdk_name" --show-sdk-path)
cc="xcrun -sdk $sdk_name clang -target $target -isysroot $sdk -O2"

compile() {  # SOURCE NAME
    # shellcheck disable=SC2086 # $cc is a command line
    if $cc -I"$wine/include" -I"$wine/include/wine" -I"$wine/build-macos/include" \
        -I"$src" -I"$wine/server" -I"$madeira/build/ntdll-unix/shims" \
        -I"$madeira/build/madsync" -DHAVE_LINUX_NTSYNC_H=1 \
        -include "$src/config_ios.h" -include stdarg.h \
        -include "$src/unicode_fix.h" -include "$src/wineserver_ios_kill.h" \
        -DBINDIR=\"/usr/local/bin\" -DDATADIR=\"/usr/local/share\" \
        -D__WINESRC__ -DWINE_IOS=1 -Dmain=wineserver_main \
        -Wno-implicit-function-declaration \
        -c "$1" -o "$out/obj/$2.o" 2>"$out/$2.err"; then
        echo "$2" >>"$out/ok"
    else
        echo "$2" >>"$out/failed"
        sed -n '1,15p' "$out/$2.err" >&2
    fi
}

# The kill wrapper is built without its own -include (the macro would recurse).
# shellcheck disable=SC2086
$cc -I"$src" -DWINE_IOS=1 -Wno-implicit-function-declaration \
    -c "$src/wineserver_ios_kill.c" -o "$out/obj/wineserver_ios_kill.o"

for f in "$wine"/server/*.c; do
    name=$(basename "$f" .c)
    case $name in
        request | main | mach | unicode | fd | window | mapping | queue) f="$src/${name}_ios.c" ;;
    esac
    compile "$f" "$name"
done
compile "$src/wine_log_ios.c" wine_log_ios
compile "$src/hidpad_ios.c" hidpad_ios
compile "$madeira/build/hidpad/hidparse_ios.c" hidparse_ios

ok=$(wc -l <"$out/ok" | tr -d ' ')
failed=0
[ -f "$out/failed" ] && failed=$(wc -l <"$out/failed" | tr -d ' ')
echo "wineserver for $sdk_name: $ok files built, $failed failed"
[ "$failed" = 0 ] || echo "failed: $(tr '\n' ' ' <"$out/failed")"
[ "$failed" = 0 ] || exit 1

# Symbols that collide with win32u's and ntdll's unix sides in the one-process
# link get a ws_ prefix in every object (Madeira's list and reasons). The last
# three are defined by ntdll's server.c too; in Wine they live in two processes,
# so each side keeps its own.
rename=""
for s in alloc_user_handle free_user_handle get_virtual_screen_rect \
    destroy_thread_windows get_window_thread is_desktop_class is_message_class \
    is_window_visible mirror_region send_notify_message shared_session user_shared_data \
    native_machine server_start_time supported_machines_count; do
    rename="$rename --redefine-sym _$s=_ws_$s"
done
for o in "$out"/obj/*.o; do
    # shellcheck disable=SC2086
    llvm-objcopy $rename "$o"
done
xcrun ar rcs "$out/libwineserver.a" "$out"/obj/*.o
echo "$out/libwineserver.a: $(wc -c <"$out/libwineserver.a" | tr -d ' ') bytes"
