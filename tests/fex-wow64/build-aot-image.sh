#!/bin/sh
# Links the AOT code caches FEX's offline compiler made into one dylib for
# an iPad or the iPad simulator: tools/cache2macho turns each cache into an object (code
# in __TEXT, data area in __DATA, every reference between them resolved by
# the linker), tools/cache2macho/aotindex.py adds the index FEX's WoW64 module
# finds them by (patches/fex-wow64/0010), and FEX's dispatcher if a run
# dumped it (patches/fex-wow64/0011). The code is the same for both SDKs;
# only the platform the dylib is built for differs.
#
# Usage: build-aot-image.sh CACHE_DIR OUT.dylib [SDK]   (SDK: iphoneos or iphonesimulator, the default)
# CACHE_DIR is FEX's cache directory (the caches are in CACHE_DIR/cache).
set -eu

cache_dir=$1
out=$2
sdk=${3:-iphonesimulator}
tools="$(cd "$(dirname "$0")/../../tools/cache2macho" && pwd)"
case $sdk in
    iphoneos) target=arm64-apple-ios17.4 platform="--min-ios 17.4" ;;
    iphonesimulator) target=arm64-apple-ios17.4-simulator platform="--ios-simulator 17.4" ;;
    *) echo "unknown SDK $sdk" >&2; exit 2 ;;
esac
objs="$(dirname "$out")/aot-objs"
rm -rf "$objs"
mkdir -p "$objs"

caches=$(find "$cache_dir/cache" -type f -size +0 | grep -E -- '-[0-9a-f]{16}-[0-9a-f]{16}$' | sort)
[ -n "$caches" ] || { echo "no code caches in $cache_dir/cache" >&2; exit 1; }
# A cache can come out without blocks (its code map held only blocks the
# offline compiler did not keep); the image leaves it out, and FEX treats that
# module as it would one with no cache.
kept=
for c in $caches; do
    # shellcheck disable=SC2086 # $platform is two arguments
    python3 -I "$tools/cache2macho.py" --wow64 --skip-empty $platform "$c" "$objs/$(basename "$c").o"
    [ -f "$objs/$(basename "$c").o" ] && kept="$kept $c"
done
# shellcheck disable=SC2086 # one cache per word
caches=$(echo $kept | tr ' ' '\n')
[ -n "$caches" ] || { echo "only empty code caches in $cache_dir/cache" >&2; exit 1; }
# The dispatcher, if a run dumped it there (WINEHOST_FEX_DUMP_DISPATCHER=1)
dispatcher=
if [ -s "$cache_dir/dispatcher.bin" ]; then
    python3 -I "$tools/cache2macho.py" --dispatcher "$cache_dir/dispatcher.bin" "$objs/dispatcher.s"
    xcrun -sdk $sdk clang -target $target -c "$objs/dispatcher.s" -o "$objs/dispatcher.o"
    dispatcher=--dispatcher
fi
# shellcheck disable=SC2086 # one argument per cache
python3 -I "$tools/aotindex.py" $dispatcher "$objs/index.s" $caches
xcrun -sdk $sdk clang -target $target -c "$objs/index.s" -o "$objs/index.o"
xcrun -sdk $sdk clang -target $target -dynamiclib -install_name @rpath/fexaot.dylib \
    -o "$out" "$objs"/*.o
echo "Linked $out: $(wc -c <"$out" | tr -d ' ') bytes, $(echo "$caches" | wc -l | tr -d ' ') caches${dispatcher:+ and the dispatcher}"
