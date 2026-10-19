#!/bin/sh
# Links the AOT code caches FEX's offline compiler made into one dylib for
# the iPad simulator: tools/cache2macho turns each cache into an object (code
# in __TEXT, data area in __DATA, every reference between them resolved by
# the linker), tools/cache2macho/aotindex.py adds the index FEX's WoW64 module
# finds them by (patches/fex-wow64/0010). On a device the same objects would
# be linked into the signed app.
#
# Usage: build-aot-image.sh CACHE_DIR OUT.dylib
# CACHE_DIR is FEX's cache directory (the caches are in CACHE_DIR/cache).
set -eu

cache_dir=$1
out=$2
tools="$(cd "$(dirname "$0")/../../tools/cache2macho" && pwd)"
target=arm64-apple-ios17.4-simulator
objs="$(dirname "$out")/aot-objs"
rm -rf "$objs"
mkdir -p "$objs"

caches=$(find "$cache_dir/cache" -type f -size +0 | grep -E -- '-[0-9a-f]{16}-[0-9a-f]{16}$' | sort)
[ -n "$caches" ] || { echo "no code caches in $cache_dir/cache" >&2; exit 1; }
for c in $caches; do
    python3 -I "$tools/cache2macho.py" --wow64 --ios-simulator 17.4 "$c" "$objs/$(basename "$c").o"
done
# shellcheck disable=SC2086 # one argument per cache
python3 -I "$tools/aotindex.py" "$objs/index.s" $caches
xcrun -sdk iphonesimulator clang -target $target -c "$objs/index.s" -o "$objs/index.o"
xcrun -sdk iphonesimulator clang -target $target -dynamiclib -install_name @rpath/fexaot.dylib \
    -o "$out" "$objs"/*.o
echo "Linked $out: $(wc -c <"$out" | tr -d ' ') bytes, $(echo "$caches" | wc -l | tr -d ' ') caches"
