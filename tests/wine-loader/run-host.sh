#!/bin/sh
# Links host/winehost.c with the libntdll_unix.a and libwineserver.a that
# build-ntdll.sh and build-wineserver.sh built for the simulator, then runs it
# on an iPad simulator. What the app around Madeira's Wine would provide
# (Swift bridges, the gamepad, DXMT, FEX) is not linked: every symbol the
# linker reports missing gets a stub that logs its first call and returns 0.
# The stub list says what a Wine host has to bring along.
#
# Usage: run-host.sh WORK_DIR [PROGRAM [ARGS...]]
# WORK_DIR must hold the outputs of build-ntdll.sh, build-wineserver.sh and
# wrap-modules.sh for iphonesimulator.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work=$1
shift
[ $# -gt 0 ] || set -- 'C:\windows\system32\cmd.exe' /c echo Hello from Wine
out="$work/host"
rm -rf "$out"
mkdir -p "$out"

sdk=$(xcrun --sdk iphonesimulator --show-sdk-path)
cc="xcrun -sdk iphonesimulator clang -target arm64-apple-ios17.0-simulator -isysroot $sdk"
libs="$work/ntdll-iphonesimulator/libntdll_unix.a $work/wineserver-iphonesimulator/libwineserver.a"

# shellcheck disable=SC2086 # $cc and $libs are lists
$cc -O1 -g -Wall -c "$here/host/winehost.c" -o "$out/winehost.o"
link() {
    # shellcheck disable=SC2086
    $cc -o "$out/winehost" "$out/winehost.o" "$@" $libs \
        -framework Foundation -framework CoreFoundation -framework AudioToolbox -lc++ -lz
}

if link 2>"$out/link1.log"; then
    : >"$out/missing"
else
    sed -n 's/^ *"\([^"]*\)", referenced from:.*/\1/p' "$out/link1.log" | sort -u >"$out/missing"
    if [ ! -s "$out/missing" ]; then
        tail -30 "$out/link1.log" >&2
        exit 1
    fi
fi
n=$(wc -l <"$out/missing" | tr -d ' ')
echo "Symbols a Wine host has to provide: $n"
sed 's/^/  /' "$out/missing"

{
    echo '#include <stdio.h>'
    echo 'static long winehost_stub(const char* name, int* seen) {'
    # printf: the sh echo on macOS would turn the \n into a newline.
    printf '%s\n' '  if (!*seen) { *seen = 1; fprintf(stderr, "winehost: stub %s called\n", name); }'
    echo '  return 0;'
    echo '}'
    i=0
    while read -r sym; do
        name=${sym#_}
        echo "static int seen_$i;"
        echo "long stub_$i(void) __asm__(\"$sym\");"
        echo "long stub_$i(void) { return winehost_stub(\"$name\", &seen_$i); }"
        i=$((i + 1))
    done <"$out/missing"
} >"$out/stubs.c"
# shellcheck disable=SC2086
$cc -O1 -c "$out/stubs.c" -o "$out/stubs.o"
if ! link "$out/stubs.o" 2>"$out/link2.log"; then
    tail -30 "$out/link2.log" >&2
    exit 1
fi
echo "Linked $out/winehost: $(wc -c <"$out/winehost" | tr -d ' ') bytes"

# ntdll looks for the NLS files next to the executable.
ln -s "$work/madeira/wine/nls" "$out/nls"

udid=$(xcrun simctl list devices available -j | python3 -I "$root/tests/ios/xcode/pick-ipad.py" 17.0)
[ -n "$udid" ] || { echo "no iPad simulator with iOS 17 or newer" >&2; exit 1; }
echo "iPad simulator $udid"
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null
seconds=30
SIMCTL_CHILD_WINEPREFIX="$out/prefix" SIMCTL_CHILD_WINEDLLPATH="$work/modules-iphonesimulator" \
    SIMCTL_CHILD_WINEHOST_NLS="$work/madeira/wine/nls" \
    perl -e 'alarm shift; exec @ARGV' 120 \
    xcrun simctl spawn "$udid" "$out/winehost" $seconds "$@" >"$out/run.log" 2>&1 &
spawn=$!
# A simulator process is a Mac process: shortly before the host gives up,
# sample its threads, so a Wine process that hangs shows where.
sleep $((seconds - 5))
pid=$(sed -n 's/^winehost: pid \([0-9]*\)$/\1/p' "$out/run.log")
if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    sample "$pid" 2 -file "$out/sample.txt" >/dev/null 2>&1 || true
fi
status=0
wait $spawn || status=$?
# Madeira's ntdll reports some things (exit() it intercepts, for one) only
# through os_log.
if [ -n "$pid" ]; then
    xcrun simctl spawn "$udid" log show --last 5m --style compact \
        --predicate "processID == $pid" >"$out/oslog.txt" 2>&1 || true
fi
xcrun simctl shutdown "$udid" || true
echo "winehost exit status: $status"
cat "$out/run.log"
if [ -s "$out/sample.txt" ]; then
    echo "--- threads of winehost $seconds s in (sample) ---"
    sed -n '/^Call graph:/,/^Total number in stack/p' "$out/sample.txt" | head -150
fi
if [ -s "$out/oslog.txt" ]; then
    echo "--- os_log of winehost (Wine and errors) ---"
    grep -i 'wine\|error\|fault' "$out/oslog.txt" | tail -80
fi
grep -q '^winehost: wineserver ready' "$out/run.log"
# The Wine process loads the program from its dylib (patches/madeira/0001).
grep -q 'load_main_exe = 0x0' "$out/run.log"
