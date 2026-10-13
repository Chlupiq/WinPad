#!/bin/sh
# The probe frontend (tests/probe) on an arm64 Mac: the same Darwin FEXCore
# code as on iOS (patches/fex/0007, 0010), without needing an iPad. A Mac can
# not record a code map without a JIT, so it takes the one the Linux job
# recorded (tests/probe/run.sh), compiles it into an AOT cache with NoJIT,
# links cache and dispatcher into a Mach-O dylib with tools/cache2macho and
# runs the guest from that dylib with NoJIT: no memory is ever executable.
#
# Usage: run-macos.sh SRC_DIR BUILD_DIR WORK_DIR LINUX_PROBE_DIR
#   LINUX_PROBE_DIR holds guest.map and guest.h from the Linux run.
# Needs: Xcode command line tools, cmake, ninja, python3.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
src=$1
build=$2
work=$3
linux=$4
mkdir -p "$work"

if [ "$(uname -s)-$(uname -m)" != Darwin-arm64 ]; then
    echo "needs an arm64 Mac" >&2
    exit 1
fi

sh "$root/tests/fex-cache/fetch-fex.sh" "$src"
# TUNE_CPU=none: FEX would read /proc/cpuinfo; the probe fixes its CPU
# features anyway. 14.4: the first macOS with os_sync_wait_on_address.
cmake -S "$src" -B "$build" -G Ninja -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_OSX_ARCHITECTURES=arm64 -DCMAKE_OSX_DEPLOYMENT_TARGET=14.4 \
    -DENABLE_LTO=False -DENABLE_ASSERTIONS=True -DBUILD_TESTING=False \
    -DBUILD_THUNKS=False -DBUILD_FEX_LINUX_TESTS=False -DBUILD_FEXCONFIG=False \
    -DTUNE_CPU=none -DWINPAD_PROBE_DIR="$here"
cmake --build "$build" --target winpad-probe
probe="$build/Bin/winpad-probe"

# Code map offsets only fit the same guest bytes.
cmp "$build/WinPadProbe/guest.h" "$linux/guest.h" ||
    { echo "the guest assembled differently on Linux and macOS" >&2; exit 1; }

"$probe" generate "$linux/guest.map" "$work"
cache=$(ls "$work"/winpad-probe-guest-*)

c2m="$root/tools/cache2macho"
python3 -I "$c2m/cache2macho.py" --macos 14.4 "$cache" "$work/aot.o"
python3 -I "$c2m/cache2macho.py" --dispatcher "$work/dispatcher.bin" "$work/dispatcher.s"
clang -c -mmacosx-version-min=14.4 -o "$work/dispatcher.o" "$work/dispatcher.s"
clang -dynamiclib -mmacosx-version-min=14.4 -o "$work/probe-aot.dylib" "$work/aot.o" "$work/dispatcher.o"
python3 -I "$c2m/check_linked.py" "$cache" "$work/probe-aot.dylib"

status=0
"$probe" run "$work/probe-aot.dylib" >"$work/run.log" 2>&1 || status=$?
cat "$work/run.log"
if [ "$status" != 0 ]; then
    echo "the guest did not run from the AOT image (exit $status)" >&2
    lldb --batch -o run -k bt -k 'disassemble -p -c 12' -k 'register read' -- "$probe" run "$work/probe-aot.dylib" 2>&1 || true
    exit 1
fi
grep -q 'AOT image linked:' "$work/run.log" ||
    { echo "FEX did not load the probe's AOT image" >&2; exit 1; }
grep -q 'Dispatcher: static code from AOT image' "$work/run.log" ||
    { echo "FEX did not run the dispatcher from the AOT image" >&2; exit 1; }
