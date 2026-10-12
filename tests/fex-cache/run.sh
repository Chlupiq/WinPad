#!/bin/sh
# Builds upstream FEX at a pinned commit (ARM64 Linux host only), runs a small
# x86-64 guest with code caching enabled so FEX records a code map, has
# FEXOfflineCompiler turn it into a code cache, counts what is in that cache
# with tools/fxcc-inspect and checks that a second run loads it. Then does
# the same with an AOT cache (patches/fex/0002, 0003).
#
# This is the baseline for the AOT mode (docs/M1-findings.md, section B): every
# relocation reported here is a write into code that iOS without JIT forbids.
#
# Needs: git, cmake, ninja, clang, lld, python3. Set FEX_BUILD to reuse a build
# made by build-fex.sh.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work=${WORK_DIR:-$(mktemp -d)}
mkdir -p "$work"

if [ "$(uname -m)" != aarch64 ]; then
    echo "FEX needs an ARM64 host" >&2
    exit 1
fi

build=${FEX_BUILD:-$work/fex-build}
[ -x "$build/Bin/FEX" ] || sh "$here/build-fex.sh" "$work/fex" "$build"

guest="$work/guest"
# --no-rosegment puts the ELF headers and code in one segment at file offset 0.
# With lld's default layout both the read-only and the code segment map file
# offset 0, FEX at runtime records code offsets from the code segment's base
# while FEXOfflineCompiler uses the first mapping, so the cache holds code
# compiled from the wrong guest bytes.
clang --target=x86_64-linux-gnu -nostdlib -static -fuse-ld=lld -Wl,--no-rosegment -o "$guest" "$here/guest.S"

# Isolated FEX config and cache directories.
export HOME="$work/home"
export XDG_DATA_HOME="$HOME/.local/share" XDG_CACHE_HOME="$HOME/.cache" XDG_CONFIG_HOME="$HOME/.config"
mkdir -p "$XDG_DATA_HOME" "$XDG_CACHE_HOME" "$XDG_CONFIG_HOME"
export FEX_ENABLECODECACHINGWIP=1
export PATH="$build/Bin:$PATH"

# One run records a code map. FEXServer would only compile it on the next
# start of the same program, so FEXOfflineCompiler is called directly; a static
# guest's map names a single file, which "generate" accepts without the
# main-executable marker (see build-fex.sh).
FEXServer -f -p 5 >>"$work/fexserver.log" 2>&1 &
server=$!
sleep 1
out=$(FEX "$guest")
[ "$out" = ok ] || { echo "guest printed '$out'" >&2; exit 1; }
FEXServer -k >/dev/null 2>&1 || true
wait "$server" || true

echo "FEXServer log:"
cat "$work/fexserver.log"
echo "FEX files:"
find "$HOME" -path '*fex-emu*' | sed "s|$HOME/||"

cachedir="$XDG_CACHE_HOME/fex-emu/cache"
maps=$(find "$HOME" -path '*fex-emu/codemap/*' -type f -name '*.bin')
[ -n "$maps" ] || { echo "no code map was recorded" >&2; exit 1; }
# Keep the maps: FEXServer merges and deletes them on later runs.
mkdir -p "$work/codemaps"
cp $maps "$work/codemaps/"

# generate NAME: compile the recorded code maps into the cache directory and
# census the result into $work/NAME.json.
generate() {
    rm -rf "$cachedir"
    for m in "$work"/codemaps/*.bin; do
        FEXOfflineCompiler generate --outdir "$cachedir" "$m"
    done
    caches=$(find "$cachedir" -type f ! -name '*.tmp' ! -name '*.lock')
    [ -n "$caches" ] || { echo "no code cache was generated" >&2; exit 1; }
    # shellcheck disable=SC2086
    python3 -I "$root/tools/fxcc-inspect/fxcc_inspect.py" --json "$work/$1.json" --list \
        --code-out "$work/$1-code.bin" $caches
}

# run_cached NAME: run the guest again; FEX must load the cache and the guest
# must still print "ok". On failure, print diagnostics.
run_cached() {
    log="$work/fex-$1-run.log"
    FEXServer -f -p 5 >>"$work/fexserver.log" 2>&1 &
    server=$!
    sleep 1
    status=0
    out=$(FEX_SILENTLOG=0 FEX_OUTPUTLOG=stderr FEX "$guest" 2>"$log") || status=$?
    FEXServer -k >/dev/null 2>&1 || true
    wait "$server" || true
    echo "FEX log of the $1 run:"
    cat "$log"
    if [ "$status" != 0 ] || [ "$out" != ok ]; then
        echo "guest printed '$out' and exited with $status with the $1 cache" >&2
        # Compare cached code against a fresh compile, then get a backtrace.
        FEXServer -f -p 5 >>"$work/fexserver.log" 2>&1 &
        server=$!
        sleep 1
        echo "== cached run with EnableCodeCacheValidation"
        FEX_ENABLECODECACHEVALIDATION=1 FEX_SILENTLOG=0 FEX_OUTPUTLOG=stderr FEX "$guest" 2>&1 || true
        if command -v gdb >/dev/null; then
            echo "== cached run under gdb"
            FEX_SILENTLOG=0 FEX_OUTPUTLOG=stderr gdb -q -batch -ex 'handle SIGSEGV nostop noprint pass' \
                -ex run -ex bt -ex 'info registers pc' -ex 'x/160i ($pc & ~0xfff)' --args "$build/Bin/FEX" "$guest" 2>&1 || true
        fi
        FEXServer -k >/dev/null 2>&1 || true
        wait "$server" || true
        echo "== code in the cache file (before relocation)"
        objdump -D -b binary -m aarch64 "$work/$1-code.bin" | sed -n '8,400p' | grep -v '^\s*$' | sed '/udf\s#0$/d' || true
        exit 1
    fi
    grep -q 'Cache load:' "$log" || { echo "FEX did not load the $1 cache" >&2; exit 1; }
}

# Regular cache: the baseline every AOT change is measured against.
generate census
run_cached cached

# AOT cache (patches/fex/0002, 0003): no named-symbol literals, guest RIPs come
# from data slots and block link records live in the data area. FEXOfflineCompiler ignores FEX_* variables, so the option
# goes through the config file.
mkdir -p "$XDG_CONFIG_HOME/fex-emu"
echo '{"Config": {"AOTCodeCacheWIP": "1"}}' >"$XDG_CONFIG_HOME/fex-emu/Config.json"
generate aot-census
rm "$XDG_CONFIG_HOME/fex-emu/Config.json"
python3 -I - "$work/aot-census.json" <<'PY'
import json, sys
for path, r in json.load(open(sys.argv[1])).items():
    types = r["relocations_by_type"]
    bad = {t: types.get(t, 0) for t in ("NAMED_SYMBOL_LITERAL", "GUEST_RIP_MOVE") if types.get(t)}
    if bad or not types.get("GUEST_RIP_DATA_SLOT") or not types.get("GUEST_RIP_LINK_RECORD"):
        sys.exit(f"{path}: unexpected AOT relocations {types}")
PY
run_cached aot
grep -Eq 'AOT data area: .*\([1-9][0-9]* link records\)' "$work/fex-aot-run.log" ||
    { echo "FEX did not set up the AOT data area with link records" >&2; exit 1; }
