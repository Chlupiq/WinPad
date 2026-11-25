#!/bin/sh
# Prints the part of a winehost run log (run-host.sh's WORK/host-NAME/run.log)
# that tells how a program did, without the loader's and FEX's chatter: its
# failed checks, how the run ended, exceptions, and the lines before the
# process was stopped.
#
# Usage: show-run.sh RUN_LOG
log=$1
[ -f "$log" ] || { echo "no run log $log"; exit 0; }
echo "=== $log"
grep -E '^  FAIL|checks,|cube:|^winehost: (Wine process|[0-9]* s passed|done)|\[madeira-ir\]|converted at runtime|EXCEPTION|[Ee]xception code|unhandled|fault' "$log" |
    cut -c1-300 | head -200
echo "--- the last lines before the process stopped"
stop=$(grep -nE 'srv-kill\] kill_process|^winehost: Wine process' "$log" | head -1 | cut -d: -f1)
if [ -n "$stop" ]; then
    sed -n "$((stop > 400 ? stop - 400 : 1)),$((stop + 3))p" "$log" |
        grep -vE '^\[(xp|xp-t|xp-api|phys-map|vname|TI-IC|lookup-cache|holes<64G|malloc-zones|footprint|waiters|alert-ring)\]|err:virtual|ios_jit_patch|tramp\[|file-fail|iOS-xins' |
        tail -60 | cut -c1-300
else
    echo "(still running when the host stopped)"
fi
exit 0
