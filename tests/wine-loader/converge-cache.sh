#!/bin/sh
# Runs an x86 program with its code caches loaded until it takes no block
# that is missing from them. A program does not take quite the same path in
# every run (ntdll's waits and allocations depend on timing), so a run can
# still compile a few blocks the code map did not have. Those blocks land in
# a new code map; FEX's offline compiler adds them to the caches and the
# program runs again, up to ROUNDS times. The last run has to take every
# block from the caches. The environment is that of the cached run
# (WINEHOST_FEX_CACHE, WINEHOST_FEX_CODEMAP=1, WINEHOST_FEX_ALL_CACHED=1...).
#
# Usage: converge-cache.sh WORK_DIR PROGRAM OFFLINE_COMPILER [ROUNDS]
set -eu

here=$(cd "$(dirname "$0")" && pwd)
work=$1
program=$2
compiler=$3
rounds=${4:-4}
round=1
while :; do
    sh "$here/run-host.sh" "$work" "$program" && exit 0
    [ "$round" -lt "$rounds" ] || { echo "still blocks missing from the caches after $rounds runs" >&2; exit 1; }
    # Only a run that left new blocks gets another round; any other failure is final.
    [ -n "$(find "$WINEHOST_FEX_CACHE/codemap/new" -type f -name '*.bin' -size +0 2>/dev/null)" ] ||
        { echo "the run failed without new code map blocks" >&2; exit 1; }
    echo "=== round $round: the run took blocks missing from the caches; compiling them too"
    # shellcheck disable=SC2046 # one argument per code map file
    python3 "$here/../fex-wow64/codemap-name-main.py" "\\??\\Z:$(printf '%s' "$program" | tr / '\\')" \
        $(find "$WINEHOST_FEX_CACHE/codemap/new" -type f -name '*.bin')
    # A round whose blocks the ready code maps already hold would compile the
    # same caches again and fail the same way; say which blocks and stop.
    # shellcheck disable=SC2046 # one argument per code map file
    python3 -I "$here/../fex-wow64/codemap-new-blocks.py" "$WINEHOST_FEX_CACHE" \
        $(find "$WINEHOST_FEX_CACHE/codemap/new" -type f -name '*.bin' -size +0) ||
        { echo "round $round added no new blocks to the code maps; the caches had them already" >&2; exit 1; }
    env -u WINEHOST_CLICK -u WINEHOST_EXPECT_LOG -u WINEHOST_EXPECT_OUTPUT -u WINEHOST_FEX_CODEMAP \
        -u WINEHOST_FEX_ALL_CACHED -u WINEHOST_FEX_DUMP_DISPATCHER \
        WINEHOST_EXPECT_OUTPUT="Successfully populated cache" WINEHOST_EXPECT_FEX_CACHE=1 \
        WINEHOST_SYSWOW64=1 WINEHOST_JIT=1 WINEHOST_JIT_POOL_MB=2048 \
        sh "$here/run-host.sh" "$work" "$compiler" process-all
    round=$((round + 1))
done
