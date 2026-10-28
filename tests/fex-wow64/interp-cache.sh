#!/bin/sh
# Checks the NoJIT interpreter's summary in a run log (patches/fex-wow64/0019, 0034):
#   [interp] fallback ran N blocks (M distinct) that are not in the AOT image,
#   H of them from the IR cache (B IR builds, D dropped by invalidation)
# When the interpreter ran some block more than once (N > M), at least one of
# those runs has to come from the IR cache (H > 0).
#
# Usage: interp-cache.sh RUN_LOG
set -eu

line=$(grep -o '\[interp\] fallback ran .*' "$1" | tail -1 || true)
[ -n "$line" ] || { echo "no [interp] summary in $1"; exit 1; }
echo "$line"
runs=$(echo "$line" | sed -n 's/.*fallback ran \([0-9]*\) blocks (\([0-9]*\) distinct).*/\1/p')
distinct=$(echo "$line" | sed -n 's/.*fallback ran \([0-9]*\) blocks (\([0-9]*\) distinct).*/\2/p')
hits=$(echo "$line" | sed -n 's/.*, \([0-9]*\) of them from the IR cache.*/\1/p')
[ -n "$runs" ] && [ -n "$distinct" ] && [ -n "$hits" ] || { echo "the summary has no IR cache count"; exit 1; }
echo "interpreted runs: $runs, distinct blocks: $distinct, runs from the IR cache: $hits"
if [ "$runs" -gt "$distinct" ] && [ "$hits" -eq 0 ]; then
    echo "blocks ran more than once, but none from the IR cache"
    exit 1
fi
