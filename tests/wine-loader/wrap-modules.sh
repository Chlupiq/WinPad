#!/bin/sh
# Wraps Madeira's ARM64 Wine modules (app/Madeira/aarch64-windows) into dylibs
# for SDK with tools/pe2macho and lays them out as a Wine DLL directory:
# OUT/aarch64-windows/NAME next to OUT/aarch64-windows/NAME.dylib, which is
# where patches/madeira/0001's loader looks for the dylib of a module it
# opens. Modules pe2macho refuses (tests/pe2macho/wine-modules-expected.txt)
# are copied as plain PE files only.
#
# Usage: wrap-modules.sh WORK_DIR SDK [MODULE...]
# WORK_DIR must hold the Madeira checkout build.sh made. With MODULEs (PE
# files already in OUT/aarch64-windows, such as an xtajit.dll built from
# source), only those are wrapped, next to the modules wrapped before.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work=$1
sdk_name=$2
p2m="$root/tools/pe2macho/pe2macho.py"
modules="$work/madeira/app/Madeira/aarch64-windows"
out="$work/modules-$sdk_name/aarch64-windows"
tmp="$work/modules-$sdk_name/tmp"
shift 2
if [ $# = 0 ]; then
    rm -rf "$work/modules-$sdk_name"
    set -- "$modules"/*.dll "$modules"/*.exe
fi
mkdir -p "$out" "$tmp"

case $sdk_name in
    iphoneos) target=arm64-apple-ios17.0 ;;
    iphonesimulator) target=arm64-apple-ios17.0-simulator ;;
    *) echo "unknown SDK $sdk_name" >&2; exit 2 ;;
esac
cc="xcrun -sdk $sdk_name clang -target $target"

wrapped=0
plain=0
for pe in "$@"; do
    name=$(basename "$pe")
    case $name in
        ntdll.dll | win32u.dll)
            python3 -I "$root/tools/pe2macho/fix_syscall_stubs.py" "$pe" "$out/$name"
            ;;
        *) [ "$pe" -ef "$out/$name" ] || cp "$pe" "$out/$name" ;;
    esac
    if ! python3 -I "$p2m" "$out/$name" "$tmp/$name.s" 2>"$tmp/$name.err"; then
        plain=$((plain + 1))
        continue
    fi
    # shellcheck disable=SC2086 # $cc is a command line
    $cc -c -o "$tmp/$name.o" "$tmp/$name.s"
    # shellcheck disable=SC2046,SC2086 # one flag per line
    $cc -dynamiclib -install_name "@rpath/$name.dylib" \
        -o "$out/$name.dylib" "$tmp/$name.o" $(cat "$tmp/$name.ldflags")
    rm -f "$tmp/$name.s" "$tmp/$name.o"
    wrapped=$((wrapped + 1))
done
rm -rf "$tmp"
echo "Wine modules for $sdk_name: $wrapped wrapped into dylibs, $plain as plain PE files"
