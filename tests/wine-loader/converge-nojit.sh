#!/bin/sh
# Runs an x86 program with NoJIT from an AOT image until FEX's interpreter has
# no block left to run. A NoJIT run takes blocks the JIT runs never took
# (timing-dependent paths in ntdll and kernelbase, and from there blocks that
# start inside code the image compiled as part of a longer block). FEX's
# interpreter runs each of them and writes it to a new code map
# (patches/fex-wow64/0019). Those maps go into the code caches the image is
# built from; FEX's offline compiler adds the blocks, the image is linked
# again and the program runs again, up to ROUNDS times. The last run has to
# take every block from the image.
#
# The environment is that of the NoJIT run: WINEHOST_AOT_IMAGE (the image,
# rebuilt in place), WINEHOST_FEX_NOJIT=1, WINEHOST_FEX_CACHE (the run's own
# cache directory, where its new code maps land), WINEHOST_FEX_CODEMAP=1 and
# WINEHOST_FEX_ALL_CACHED=1.
#
# Usage: converge-nojit.sh WORK_DIR PROGRAM OFFLINE_COMPILER CACHE_DIR [ROUNDS]
# CACHE_DIR is the cache directory the image is built from.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
work=$1
program=$2
compiler=$3
cache_dir=$4
rounds=${5:-4}
name=${program##*/}
name=$(echo "${name%.*}" | tr 'A-Z' 'a-z')
round=1
while :; do
    status=0
    sh "$here/run-host.sh" "$work" "$program" || status=$?
    interp=$(grep -o '\[interp\] fallback ran [0-9]* blocks ([0-9]* distinct)' "$work/host-$name/run.log" | tail -1 || true)
    echo "=== round $round: ${interp:-the interpreter ran no block}"
    [ "$status" -eq 0 ] && exit 0
    [ "$round" -lt "$rounds" ] || { echo "the interpreter still ran blocks after $rounds runs" >&2; exit 1; }
    new=$(find "$WINEHOST_FEX_CACHE/codemap/new" -type f -name '*.bin' -size +0 2>/dev/null)
    [ -n "$new" ] || { echo "the run failed without new code map blocks" >&2; exit 1; }
    # shellcheck disable=SC2086 # one argument per code map file
    python3 "$here/../fex-wow64/codemap-name-main.py" "\\??\\Z:$(printf '%s' "$program" | tr / '\\')" $new
    # Blocks the image's code maps hold already would come out the same; say which and stop.
    # shellcheck disable=SC2086 # one argument per code map file
    python3 -I "$here/../fex-wow64/codemap-new-blocks.py" "$cache_dir" $new ||
        { echo "round $round added no new blocks to the code maps; the image had them already" >&2; exit 1; }
    mkdir -p "$cache_dir/codemap/new"
    # shellcheck disable=SC2086 # one argument per code map file
    mv $new "$cache_dir/codemap/new/"
    # The bytes of code the program made at run time, which those maps hold blocks of
    # (patches/fex-wow64/0036).
    if [ -d "$WINEHOST_FEX_CACHE/codemap/new/runtime" ]; then
        mkdir -p "$cache_dir/codemap/new/runtime"
        find "$WINEHOST_FEX_CACHE/codemap/new/runtime" -type f -exec mv {} "$cache_dir/codemap/new/runtime/" \;
    fi
    echo "=== round $round: compiling the blocks the interpreter ran into the image's code caches"
    env -u WINEHOST_CLICK -u WINEHOST_EXPECT_LOG -u WINEHOST_EXPECT_OUTPUT -u WINEHOST_FEX_CODEMAP \
        -u WINEHOST_FEX_ALL_CACHED -u WINEHOST_FEX_DUMP_DISPATCHER -u WINEHOST_FEX_NOJIT -u WINEHOST_AOT_IMAGE \
        -u WINEHOST_WOW_MAP_END -u WINEHOST_PAGE0 -u WINEHOST_VA_HOLES \
        WINEHOST_FEX_CACHE="$cache_dir" \
        WINEHOST_EXPECT_OUTPUT="Successfully populated cache" WINEHOST_EXPECT_FEX_CACHE=1 \
        WINEHOST_SYSWOW64=1 WINEHOST_JIT=1 WINEHOST_JIT_POOL_MB=2048 \
        sh "$here/run-host.sh" "$work" "$compiler" process-all
    sh "$here/../fex-wow64/build-aot-image.sh" "$cache_dir" "$WINEHOST_AOT_IMAGE"
    round=$((round + 1))
done
