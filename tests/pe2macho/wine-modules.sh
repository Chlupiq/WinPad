#!/bin/sh
# Wraps every ARM64 Wine module that Madeira ships (app/Madeira/aarch64-windows)
# into a dylib with tools/pe2macho, checks each with --check and then loads them
# all with dlopen (load-modules.c): PE headers in place, dyld rebased every
# pointer, code sections read+execute.
#
# Modules pe2macho has to refuse are listed in wine-modules-expected.txt with
# the reason; any other refusal, or one of those modules converting cleanly,
# fails the test (then update the list).
#
# Usage: wine-modules.sh WORK_DIR
# Needs: an arm64 Mac with Xcode command line tools, git, python3.
set -eu

MADEIRA_REPO=https://github.com/willfaust/Madeira.git
MADEIRA_COMMIT=48f976429c189f8396e23d251d8a82f43c705922

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work=$1
p2m="$root/tools/pe2macho/pe2macho.py"
mkdir -p "$work/out"

if [ ! -d "$work/madeira/.git" ]; then
    git clone -q --filter=blob:none --no-checkout "$MADEIRA_REPO" "$work/madeira"
    git -C "$work/madeira" sparse-checkout set --no-cone /app/Madeira/aarch64-windows/
fi
git -C "$work/madeira" checkout -q "$MADEIRA_COMMIT"
modules="$work/madeira/app/Madeira/aarch64-windows"

: >"$work/list"
: >"$work/refused"
converted=0
for pe in "$modules"/*.dll "$modules"/*.exe; do
    name=$(basename "$pe")
    out="$work/out/$name"
    if ! python3 -I "$p2m" "$pe" "$out.s" 2>"$out.err"; then
        case $(cat "$out.err") in
            *"is in executable section"*) why=reloc-in-code ;;
            *"is not aligned"*) why=unaligned ;;
            *) why=other ;;
        esac
        echo "$name $why" >>"$work/refused"
        continue
    fi
    xcrun clang -target arm64-apple-macos14 -c -o "$out.o" "$out.s"
    # shellcheck disable=SC2046 # one flag per line
    xcrun clang -target arm64-apple-macos14 -dynamiclib -install_name "@rpath/$name.dylib" \
        -o "$out.dylib" "$out.o" $(cat "$out.ldflags")
    python3 -I "$p2m" --check "$pe" "$out.dylib"
    python3 -I "$p2m" --relocs "$pe" "$out.relocs"
    prefix=$(python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import pe2macho; print(pe2macho.default_prefix(sys.argv[2]))' \
        "$root/tools/pe2macho" "$pe")
    echo "$out.dylib $prefix $out.relocs" >>"$work/list"
    rm -f "$out.s" "$out.o"
    converted=$((converted + 1))
done

sort -o "$work/refused" "$work/refused"
if ! sort "$here/wine-modules-expected.txt" | diff -u - "$work/refused"; then
    echo "pe2macho refused other modules than wine-modules-expected.txt lists" >&2
    for err in "$work"/out/*.err; do
        [ -s "$err" ] && cat "$err" >&2
    done
    exit 1
fi
echo "$converted modules wrapped, $(wc -l <"$work/refused" | tr -d ' ') refused as expected"

xcrun clang -target arm64-apple-macos14 -O2 -o "$work/load-modules" "$here/load-modules.c"
"$work/load-modules" "$work/list"
