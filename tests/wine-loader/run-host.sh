#!/bin/sh
# Links host/winehost.c with Wine's unix side for the simulator
# (link-host.sh, which also says what gets stubbed), then runs it
# on an iPad simulator.
#
# Usage: run-host.sh WORK_DIR [PROGRAM [ARGS...]]
# WORK_DIR must hold the outputs of build-ntdll.sh, build-win32u.sh,
# build-wineserver.sh and wrap-modules.sh for iphonesimulator.
# Without PROGRAM it runs cmd.exe /c echo Hello from Wine, which has to print
# the line and exit with 0; any other program has to show a window. The
# newest content of each window ends up in WORK_DIR/host-NAME/frames as PNG.
# With WINEHOST_TYPE set, the host types that text into the first window and
# it has to show up there; with WINEHOST_CLICK_MENU=1 it clicks the window's
# first menu, which has to open (a new window); with WINEHOST_CLICK=X,Y it
# taps at X %, Y % of the window's client area, which has to change what the
# window shows. WINEHOST_WINEDEBUG replaces
# WINEDEBUG=+loaddll. A console program has to exit with
# WINEHOST_EXPECT_EXIT (default 0); WINEHOST_SECONDS (default 30) is how
# long the host waits for the program.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work=$1
shift
default_program=
expect_window=1
# A console program (WINEHOST_EXPECT_OUTPUT set) has to print that line and
# exit with 0, like the default cmd.exe run; it shows no window.
[ -n "${WINEHOST_EXPECT_OUTPUT:-}" ] && expect_window=
if [ $# -eq 0 ]; then
    default_program=1
    expect_window=
    set -- 'C:\windows\system32\cmd.exe' /c echo Hello from Wine
fi
name=${1##*\\}
name=${name##*/}
name=$(echo "${name%.*}" | tr 'A-Z' 'a-z')
out="$work/host-$name"
rm -rf "$out"
mkdir -p "$out"

sh "$here/link-host.sh" iphonesimulator "$work" "$out"

# ntdll looks for the NLS files next to the executable, and for ntdll.dll
# itself in the PE subdirectory there (load_ntdll: dll_dir + get_pe_dir(),
# <exe dir>/aarch64-windows/ntdll.dll, as in Madeira's app bundle).
# The fonts too: Wine's data dir is the executable's directory on iOS.
ln -s "$work/madeira/wine/nls" "$out/nls"
ln -s "$work/madeira/wine/fonts" "$out/fonts"
ln -s "$work/modules-iphonesimulator/aarch64-windows" "$out/aarch64-windows"
# 32-bit x86 modules (tests/wine-i386/build.sh), for WoW64 programs.
[ -d "$work/i386-windows" ] && ln -s "$work/i386-windows" "$out/i386-windows"
# WINEHOST_SYSWOW64=1 makes the same prefix for a 64-bit program that reads
# the 32-bit DLLs by their C:\windows\syswow64 paths (FEX's offline compiler).
wow64=${WINEHOST_SYSWOW64:-}
case "$1" in */i386-windows/*) wow64=1 ;; esac
if [ "$wow64" = 1 ]; then
    # A 32-bit process's system32 is C:\windows\syswow64; Madeira's app links
    # the i386 set there (madeira_link_syswow64 in WineProcessBridge.m).
    mkdir -p "$out/prefix/drive_c/windows/syswow64"
    for f in "$work/i386-windows"/*.dll; do ln -s "$f" "$out/prefix/drive_c/windows/syswow64/"; done
    # The 64-bit half (wow64.dll, xtajit.dll) is loaded by its full
    # C:\windows\system32 path, so that farm is needed too, as the app makes it.
    mkdir -p "$out/prefix/drive_c/windows/system32"
    for f in "$work/modules-iphonesimulator/aarch64-windows"/*; do
        ln -s "$f" "$out/prefix/drive_c/windows/system32/"
    done
fi
# WINEHOST_WOW_MAP_END=ADDR has ntdll place the 32-bit guest window as if the
# address map ended at ADDR (MADEIRA_WOW_MAP_END, patches/madeira/0003), as an
# iPad's smaller map does; it only narrows the simulator's map.
# WINEHOST_PAGE0=0 has ntdll take page 0 to be unavailable, as on an iPad, and
# not map the first thread's TEB there (MADEIRA_PAGE0, patches/madeira/0004).
# WINEHOST_VA_HOLES=LO-HI[,...] has the host hold address ranges such an iPad
# cannot map before Wine starts (hold_va_holes in host/winehost.c).
# WINEHOST_FEX_CACHE=DIR is FEX's cache directory (code maps, caches), shared
# by runs. With WINEHOST_FEX_CODEMAP=1, FEX records there which blocks of the
# x86 code it compiled (a code map, the input of its offline compiler).
# WINEHOST_AOT_IMAGE=DYLIB gives FEX code caches linked into a dylib instead
# (tests/fex-wow64/build-aot-image.sh); the host loads it. With
# WINEHOST_FEX_NOJIT=1 FEX runs only that image and makes no memory executable.
fex_codemap=
fex_cache=
fex_dump_dispatcher=
if [ -n "${WINEHOST_FEX_CACHE:-}" ]; then
    mkdir -p "$WINEHOST_FEX_CACHE/codemap/new"
    fex_cache="Z:$(printf '%s' "$WINEHOST_FEX_CACHE" | tr / '\\')\\"
    [ "${WINEHOST_FEX_CODEMAP:-}" = 1 ] && fex_codemap=1
    # With WINEHOST_FEX_DUMP_DISPATCHER=1, FEX writes its dispatcher code there
    # too (dispatcher.bin, for build-aot-image.sh).
    [ "${WINEHOST_FEX_DUMP_DISPATCHER:-}" = 1 ] && fex_dump_dispatcher="${fex_cache}dispatcher.bin"
fi

udid=$(xcrun simctl list devices available -j | python3 -I "$root/tests/ios/xcode/pick-ipad.py" 17.0)
[ -n "$udid" ] || { echo "no iPad simulator with iOS 17 or newer" >&2; exit 1; }
echo "iPad simulator $udid"
xcrun simctl boot "$udid" 2>/dev/null || true
xcrun simctl bootstatus "$udid" -b >/dev/null
seconds=${WINEHOST_SECONDS:-30}
SIMCTL_CHILD_WINEPREFIX="$out/prefix" SIMCTL_CHILD_WINEDLLPATH="$work/modules-iphonesimulator" \
    SIMCTL_CHILD_WINEHOST_NLS="$work/madeira/wine/nls" SIMCTL_CHILD_WINEDEBUG="${WINEHOST_WINEDEBUG:-+loaddll}" \
    SIMCTL_CHILD_MADEIRA_WIN32U=1 SIMCTL_CHILD_MADEIRA_DESKTOP=1 \
    SIMCTL_CHILD_WINEHOST_FRAMES="$out/frames" \
    SIMCTL_CHILD_WINEHOST_TYPE="${WINEHOST_TYPE:-}" SIMCTL_CHILD_WINEHOST_CLICK_MENU="${WINEHOST_CLICK_MENU:-}" \
    SIMCTL_CHILD_WINEHOST_CLICK="${WINEHOST_CLICK:-}" SIMCTL_CHILD_WINEHOST_WINDOW="$expect_window" \
    SIMCTL_CHILD_FEX_ENABLECODECACHINGWIP="${fex_codemap:-0}" SIMCTL_CHILD_FEX_APP_CACHE_LOCATION="$fex_cache" \
    SIMCTL_CHILD_WINEHOST_JIT="${WINEHOST_JIT:-}" SIMCTL_CHILD_WINEHOST_JIT_POOL_MB="${WINEHOST_JIT_POOL_MB:-}" \
    SIMCTL_CHILD_WINEHOST_AOT_IMAGE="${WINEHOST_AOT_IMAGE:-}" \
    SIMCTL_CHILD_FEX_DUMPDISPATCHER="$fex_dump_dispatcher" SIMCTL_CHILD_FEX_NOJIT="${WINEHOST_FEX_NOJIT:-0}" \
    SIMCTL_CHILD_FEX_ENABLECODECACHEVALIDATION="${WINEHOST_FEX_VALIDATE:-0}" \
    SIMCTL_CHILD_MADEIRA_WOW_MAP_END="${WINEHOST_WOW_MAP_END:-}" \
    SIMCTL_CHILD_MADEIRA_PAGE0="${WINEHOST_PAGE0:-}" \
    SIMCTL_CHILD_WINEHOST_VA_HOLES="${WINEHOST_VA_HOLES:-}" \
    perl -e 'alarm shift; exec @ARGV' 120 \
    xcrun simctl spawn "$udid" "$out/winehost" $seconds "$@" >"$out/run.log" 2>&1 &
spawn=$!
# A simulator process is a Mac process: shortly before the host gives up,
# sample its threads, so a Wine process that hangs shows where.
# The host exits early once the run has shown what it checks.
waited=0
while [ $waited -lt $((seconds - 5)) ] && kill -0 $spawn 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
done
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
# The simulator stays booted for the next run (booting takes most of a minute).
echo "winehost exit status: $status"
# Trace channels (WINEHOST_WINEDEBUG) can print a lot: the first 150 lines of
# each, then how often each function traced. A fault storm repeats the same
# line thousands of times and pushes the start of the run out of the job log:
# the first 40 lines of each kind (first 30 characters, numbers aside), then a count.
awk '/:trace:/ { split($0, f, ":"); ch = f[3]; split(f[4], g, " "); calls[ch ":" g[1]]++
        if (++n[ch] > 150) next }
    { k = $0; gsub(/[0-9]+/, "#", k); k = substr(k, 1, 30); if (++same[k] > 40) next }
    { print }
    END { for (ch in n) if (n[ch] > 150) printf "(%d trace lines of %s in all)\n", n[ch], ch
          for (c in calls) printf "(trace %s: %d)\n", c, calls[c]
          for (k in same) if (same[k] > 40) printf "(%d lines starting \"%s\" in all)\n", same[k], k }' "$out/run.log"
if [ -s "$out/sample.txt" ]; then
    echo "--- threads of winehost $seconds s in (sample) ---"
    sed -n '/^Call graph:/,/^Total number in stack/p' "$out/sample.txt" | head -150
fi
if [ -s "$out/oslog.txt" ]; then
    echo "--- os_log of winehost (Wine and errors) ---"
    grep -i 'wine\|error\|fault' "$out/oslog.txt" | tail -80
fi
for f in "$out"/frames/*.bmp; do
    [ -f "$f" ] || continue
    echo "--- window ${f##*/} ---"
    python3 -I "$here/bmp-preview.py" "$f" 64
    sips -s format png "$f" --out "${f%.bmp}.png" >/dev/null && rm "$f"
    echo "window content: ${f%.bmp}.png"
done
grep -q '^winehost: wineserver ready' "$out/run.log"
# The Wine process loads the program from its dylib (patches/madeira/0001);
# an x86 program stays a PE file.
[ -n "${WINEHOST_EXPECT_OUTPUT:-}" ] || grep -q 'load_main_exe = 0x0' "$out/run.log"
# Every DLL comes from its dylib too (load_builtin). cmd.exe runs to its end:
# it prints the line and exits with 0. Any other program draws a window
# through win32u's winios driver.
if [ -n "$default_program" ]; then
    grep -q '^winehost: Wine process exited with code 0$' "$out/run.log"
    grep -q '^Hello from Wine' "$out/run.log"
elif [ -n "${WINEHOST_EXPECT_OUTPUT:-}" ]; then
    grep -q "^winehost: Wine process exited with code ${WINEHOST_EXPECT_EXIT:-0}\$" "$out/run.log"
    grep -qF "$WINEHOST_EXPECT_OUTPUT" "$out/run.log"
else
    grep -q '^winehost: frame of window' "$out/run.log"
fi
# WINEHOST_EXPECT_LOG: text the run has to log (FEX's own messages, say),
# one string per line; every one of them has to show up.
if [ -n "${WINEHOST_EXPECT_LOG:-}" ]; then
    printf '%s\n' "$WINEHOST_EXPECT_LOG" | while IFS= read -r expect; do
        [ -n "$expect" ] || continue
        grep -F "$expect" "$out/run.log" | head -20
        grep -qF "$expect" "$out/run.log" || { echo "missing in the log: $expect"; exit 1; }
    done || exit 1
fi
# Keys and taps reach the program through the winios driver.
if [ -n "${WINEHOST_TYPE:-}" ]; then
    grep -q '^winehost: typed text shows up' "$out/run.log"
fi
if [ "${WINEHOST_CLICK_MENU:-}" = 1 ]; then
    grep -q '^winehost: new window .* after the click$' "$out/run.log"
fi
if [ -n "${WINEHOST_CLICK:-}" ]; then
    grep -q '^winehost: window content changed after the click, [0-9]* pixels$' "$out/run.log"
fi
if [ -n "$fex_cache" ]; then
    echo "--- FEX cache directory ---"
    find "$WINEHOST_FEX_CACHE" -type f -exec ls -l {} + | sed 's/^/  /'
fi
if [ -n "$fex_codemap" ] && [ "${WINEHOST_FEX_ALL_CACHED:-}" = 1 ]; then
    # Everything the program ran came from the code caches: FEX compiled no
    # block of a tracked image itself, so the new code maps are empty.
    # shellcheck disable=SC2046 # one argument per code map file
    blocks=$(python3 -I "$root/tests/fex-wow64/codemap.py" $(find "$WINEHOST_FEX_CACHE/codemap/new" -type f -name '*.bin') || true)
    echo "$blocks"
    echo "$blocks" | grep -qx 'code map blocks in all: 0'
elif [ -n "$fex_codemap" ]; then
    # shellcheck disable=SC2046 # one argument per code map file
    python3 -I "$root/tests/fex-wow64/codemap.py" $(find "$WINEHOST_FEX_CACHE/codemap/new" -type f -name '*.bin')
fi
# With WINEHOST_EXPECT_FEX_CACHE=1 the run has to leave code caches.
if [ "${WINEHOST_EXPECT_FEX_CACHE:-}" = 1 ]; then
    [ -n "$(find "$WINEHOST_FEX_CACHE/cache" -type f -size +0 2>/dev/null)" ]
fi
