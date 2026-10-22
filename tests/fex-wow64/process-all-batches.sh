#!/bin/sh
# Runs FEX's offline compiler's process-all until no code cache is left to
# generate, at most PER_RUN caches per process (patches/fex-wow64/0028). The
# code buffers of every cache one process generates stay in its JIT pool, so a
# game's few dozen DLLs in one process run out of it; each process-all starts
# with an empty pool and picks up where the last one stopped.
#
# The environment is that of run-host.sh for the compiler (WINEHOST_FEX_CACHE,
# WINEHOST_SYSWOW64=1, WINEHOST_JIT=1, ...); WINEHOST_EXPECT_OUTPUT is set here.
#
# Usage: process-all-batches.sh WORK_DIR OFFLINE_COMPILER [PER_RUN]
set -eu

here=$(cd "$(dirname "$0")" && pwd)
work=$1
compiler=$2
per_run=${3:-8}
name=${compiler##*/}
name=$(echo "${name%.*}" | tr 'A-Z' 'a-z')
prev=
while :; do
    WINEHOST_EXPECT_OUTPUT='[process-all]' \
        sh "$here/../wine-loader/run-host.sh" "$work" "$compiler" process-all --max-caches "$per_run"
    line=$(grep -o '\[process-all\] [0-9]* caches generated ([0-9]* failed), [0-9]* left' \
        "$work/host-$name/run.log" | tail -1)
    echo "=== $line"
    left=${line##*, }
    left=${left%% *}
    [ "$left" -gt 0 ] || break
    # A cache that fails is generated again first in the next process; when
    # that leaves nothing for the rest, stop.
    [ -z "$prev" ] || [ "$left" -lt "$prev" ] ||
        { echo "process-all made no progress: $left caches still left" >&2; exit 1; }
    prev=$left
done
[ -n "$(find "$WINEHOST_FEX_CACHE/cache" -type f -size +0 2>/dev/null)" ] ||
    { echo "no code caches in $WINEHOST_FEX_CACHE/cache" >&2; exit 1; }
