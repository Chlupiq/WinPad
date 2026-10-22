#!/bin/sh
# Builds the AOT image of a game for the iPad app (main.m's game program) on
# the Mac the game is on, so the iPad runs it with NoJIT: an iPad with TXM
# (iPadOS 26 and later) runs no JIT code under Xcode's debugger.
#
# The game runs in Wine on an iPad simulator with FEX's JIT RUNS times
# (default 3), each writing a code map of the x86 code it took; FEX's offline
# compiler turns their union into code caches; a run with those caches loaded
# dumps FEX's dispatcher; the caches and the dispatcher are linked into
# fexaot-game.dylib for the simulator and the iPad, in the Xcode project's
# Frameworks/<platform>/, where the app finds them.
#
# The iPad's runs take code the simulator's did not (Metal 3 and BC textures
# are there, and the game gets further). FEX's interpreter runs those blocks
# and writes them to code maps in the app's Documents/fexcache/codemap/new;
# copied to the Mac (Finder) and given as NEW_MAPS, they go into the caches
# too, and the next image has them.
#
# The game, its code maps, caches and image stay on this Mac and the iPad:
# they are copyrighted code, never for the repository or CI.
#
# Usage: game-aot.sh WORK_DIR GAME_EXE OFFLINE_COMPILER CACHE_DIR XCODE_PROJECT [NEW_MAPS]
# WORK_DIR: tests/wine-loader's work directory (as for build-xcode.sh).
# OFFLINE_COMPILER: FEXOfflineCompiler.exe (tests/fex-wow64/build.sh).
# CACHE_DIR: the game's FEX cache directory, kept from one image to the next.
# XCODE_PROJECT: the WinPadWine-xcode directory build-xcode.sh wrote.
# Environment: RUNS (default 3; 0 makes no JIT runs and builds the image from
# the code maps and caches CACHE_DIR has), SECONDS_PER_RUN (default 60),
# GAME_AOT_CACHES_PER_RUN: caches the offline compiler generates in one process
# (default 8, tests/fex-wow64/process-all-batches.sh), GAME_AOT_JIT_POOL_MB:
# its JIT pool (default 4096), GAME_AOT_COMPILE_SECONDS: how long one such
# process may take (default 600), REBUILD_CACHES=1: generate every cache again
# (after a change to FEX's code generation).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
loader="$here/../wine-loader"
work=$1
game=$2
compiler=$3
cache_dir=$4
proj=$5
new_maps=${6:-}
runs=${RUNS:-3}
name=$(basename "$game" | tr 'A-Z' 'a-z')
name=${name%.*}
maps() { find "$cache_dir/codemap/new" -type f -name '*.bin' -size +0 2>/dev/null; }

# As main.m's game program, so the code maps hold the blocks the app's runs take.
export WINEHOST_DLLOVERRIDES=dinput8=n,b WINEHOST_WOW_MIN_FREE_GB=2
export WINEHOST_FEX_CACHE="$cache_dir" WINEHOST_SECONDS="${SECONDS_PER_RUN:-60}"
# Whatever the game does in the simulator, the code map is what counts.
export WINEHOST_EXPECT_OUTPUT='winehost: starting' WINEHOST_EXPECT_EXIT=running
mkdir -p "$cache_dir/codemap/new"
if [ "${REBUILD_CACHES:-}" = 1 ]; then
    rm -rf "$cache_dir/cache"
    echo "=== generating every code cache again"
fi

if [ -n "$new_maps" ]; then
    set -- $(find "$new_maps" -type f -name '*.bin' -size +0)
    [ $# -gt 0 ] || { echo "no code maps in $new_maps" >&2; exit 1; }
    cp "$@" "$cache_dir/codemap/new/"
    echo "=== $# code maps from the iPad"
else
    run=1
    while [ $run -le "$runs" ]; do
        echo "=== JIT run $run of $runs, writing a code map"
        before=$(maps | wc -l)
        WINEHOST_FEX_CODEMAP=1 sh "$loader/run-host.sh" "$work" "$game" || true
        [ "$(maps | wc -l)" -gt "$before" ] ||
            { echo "run $run wrote no code map (did the game end before NtTerminateProcess?)" >&2; exit 1; }
        run=$((run + 1))
    done
fi
# A map whose main executable came wholly from caches leaves it unnamed;
# the offline compiler opens it by its path on this Mac.
# shellcheck disable=SC2046 # one argument per code map file
python3 "$loader/../fex-wow64/codemap-name-main.py" "\\??\\Z:$(printf '%s' "$game" | tr / '\\')" $(maps)

compile() {
    echo "=== compiling the code maps into code caches"
    env -u WINEHOST_EXPECT_EXIT -u WINEHOST_DLLOVERRIDES -u WINEHOST_EXPECT_OUTPUT \
        WINEHOST_SECONDS="${GAME_AOT_COMPILE_SECONDS:-600}" \
        WINEHOST_SYSWOW64=1 WINEHOST_JIT=1 WINEHOST_JIT_POOL_MB="${GAME_AOT_JIT_POOL_MB:-4096}" \
        sh "$loader/../fex-wow64/process-all-batches.sh" "$work" "$compiler" "${GAME_AOT_CACHES_PER_RUN:-8}"
}
compile
echo "=== a run with the code caches loaded, dumping FEX's dispatcher"
rm -f "$cache_dir/dispatcher.bin"
WINEHOST_FEX_CODEMAP=1 WINEHOST_FEX_DUMP_DISPATCHER=1 sh "$loader/run-host.sh" "$work" "$game" || true
test -s "$cache_dir/dispatcher.bin" || { echo "the cached run dumped no dispatcher" >&2; exit 1; }
# That run compiles what the caches lacked; those blocks go in too.
if [ -n "$(maps)" ]; then
    # shellcheck disable=SC2046 # one argument per code map file
    python3 "$loader/../fex-wow64/codemap-name-main.py" "\\??\\Z:$(printf '%s' "$game" | tr / '\\')" $(maps)
    compile
fi

for sdk in iphonesimulator iphoneos; do
    sh "$loader/../fex-wow64/build-aot-image.sh" "$cache_dir" "$cache_dir/image-$sdk/fexaot.dylib" $sdk
    mkdir -p "$proj/Frameworks/$sdk"
    cp "$cache_dir/image-$sdk/fexaot.dylib" "$proj/Frameworks/$sdk/fexaot-game.dylib"
done
echo "fexaot-game.dylib for the simulator and the iPad is in $proj/Frameworks:" \
    "the scheme \"WinPadWine Game\" now runs $name with NoJIT"
