#!/bin/sh
# The probe frontend (tests/probe) end to end on an ARM64 Linux host, the way
# the iPad will use it: one process records which guest blocks run (with the
# JIT), one compiles them into an AOT cache and writes out the dispatcher,
# tools/cache2macho links both into a shared object, and a last process runs
# the guest from that object with NoJIT: no executable memory at all.
#
# Needs a FEX build made by tests/fex-cache/build-fex.sh (FEX_BUILD), clang,
# lld and python3.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work=${WORK_DIR:-$(mktemp -d)}/probe
build=${FEX_BUILD:?set FEX_BUILD to a build from tests/fex-cache/build-fex.sh}
mkdir -p "$work"

if [ "$(uname -m)" != aarch64 ]; then
    echo "the probe needs an ARM64 host" >&2
    exit 1
fi

# The FEX build is cached by CI, so make sure the probe itself is current.
cmake --build "$build" --target winpad-probe
probe="$build/Bin/winpad-probe"

# step ARGS...: run the probe; if it fails, run it again under gdb for a
# backtrace, and if it hangs, attach gdb to a second run.
step() {
    echo "== winpad-probe $*"
    status=0
    timeout 120 "$probe" "$@" || status=$?
    [ "$status" = 0 ] && return
    if [ "$status" = 124 ]; then
        echo "winpad-probe $1 did not finish in 120 s" >&2
        "$probe" "$@" &
        pid=$!
        sleep 20
        sudo gdb -q -batch -p "$pid" -ex 'thread apply all bt' -ex 'x/20i $pc-0x30' -ex 'info registers' 2>&1 || true
        kill -9 "$pid" 2>/dev/null || true
        exit 1
    fi
    echo "winpad-probe $1 failed with exit $status" >&2
    if command -v gdb >/dev/null; then
        gdb -q -batch -ex run -ex bt -ex 'x/20i $pc-0x30' -ex 'info registers' \
            --args "$probe" "$@" 2>&1 || true
    fi
    exit 1
}

step record "$work/guest.map"
# The macOS job (tests/probe/run-macos.sh) compiles this code map; it checks
# that its probe embeds the same guest bytes.
cp "$build/WinPadProbe/guest.h" "$work/guest.h"
step generate "$work/guest.map" "$work"
cache=$(ls "$work"/winpad-probe-guest-*)

c2m="$root/tools/cache2macho"
python3 -I "$c2m/cache2macho.py" --elf-asm "$cache" "$work/aot.s"
python3 -I "$c2m/cache2macho.py" --dispatcher --elf-asm "$work/dispatcher.bin" "$work/dispatcher.s"
clang -c -o "$work/aot.o" "$work/aot.s"
clang -c -o "$work/dispatcher.o" "$work/dispatcher.s"
clang -shared -nostdlib -fuse-ld=lld -o "$work/probe-aot.so" "$work/aot.o" "$work/dispatcher.o"
python3 -I "$c2m/check_linked.py" "$cache" "$work/probe-aot.so"

status=0
(step run "$work/probe-aot.so") >"$work/run.log" 2>&1 || status=$?
cat "$work/run.log"
[ "$status" = 0 ] || { echo "the guest did not run from the AOT image" >&2; exit 1; }
grep -q 'AOT image linked:' "$work/run.log" ||
    { echo "FEX did not load the probe's AOT image" >&2; exit 1; }
grep -q 'Dispatcher: static code from AOT image' "$work/run.log" ||
    { echo "FEX did not run the dispatcher from the AOT image" >&2; exit 1; }
