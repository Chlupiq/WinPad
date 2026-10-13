#!/bin/sh
# Builds upstream FEX at a pinned commit (ARM64 Linux host only), runs a small
# x86-64 guest with code caching enabled so FEX records a code map, has
# FEXOfflineCompiler turn it into a code cache, counts what is in that cache
# with tools/fxcc-inspect and checks that a second run loads it. Then does
# the same with an AOT cache (patches/fex/0002-0004), and with that cache
# linked into a shared object (tools/cache2macho, patches/fex/0005).
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
# Every run also writes out FEX's dispatcher (patches/fex/0006): it must be the
# same bytes in every process to be linked into an app.
out=$(FEX_DUMPDISPATCHER="$work/dispatcher1.bin" FEX "$guest")
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

# run_cached NAME CENSUS: run the guest again; FEX must load the cache made by
# "generate CENSUS" and the guest must still print "ok". On failure, print
# diagnostics.
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
        objdump -D -b binary -m aarch64 "$work/$2-code.bin" | sed -n '8,400p' | grep -v '^\s*$' | sed '/udf\s#0$/d' || true
        exit 1
    fi
    grep -q 'Cache load:' "$log" || { echo "FEX did not load the $1 cache" >&2; exit 1; }
}

# Regular cache: the baseline every AOT change is measured against.
generate census
export FEX_DUMPDISPATCHER="$work/dispatcher2.bin"
run_cached cached census
unset FEX_DUMPDISPATCHER
cmp "$work/dispatcher1.bin" "$work/dispatcher2.bin" ||
    { echo "the dispatcher differs between two FEX processes" >&2; exit 1; }

# AOT cache (patches/fex/0002-0004): every relocation only fills the data area
# (guest RIP slots, block link records, block tails), so FEX maps the code
# read+execute at load and any later write into it faults. FEXOfflineCompiler ignores FEX_* variables, so the option
# goes through the config file.
mkdir -p "$XDG_CONFIG_HOME/fex-emu"
echo '{"Config": {"AOTCodeCacheWIP": "1"}}' >"$XDG_CONFIG_HOME/fex-emu/Config.json"
generate aot-census
rm "$XDG_CONFIG_HOME/fex-emu/Config.json"
python3 -I - "$work/aot-census.json" <<'PY'
import json, sys
for path, r in json.load(open(sys.argv[1])).items():
    types = r["relocations_by_type"]
    need = ("GUEST_RIP_DATA_SLOT", "GUEST_RIP_LINK_RECORD", "AOT_BLOCK_TAIL")
    if r["code_patches_on_load"] or not all(types.get(t) for t in need):
        sys.exit(f"{path}: unexpected AOT relocations {types}")
PY

# The AOT cache as a Mach-O object for iOS (tools/cache2macho): link it the way
# the app would and check that the linker resolved every data-area reference.
# The same caches as ELF assembly go into one shared object for the run below.
ld64=$(command -v ld64.lld || ls /usr/lib/llvm-*/bin/ld64.lld 2>/dev/null | tail -n 1)
[ -n "$ld64" ] || { echo "ld64.lld not found" >&2; exit 1; }
n=0
for c in $(find "$cachedir" -type f ! -name '*.tmp' ! -name '*.lock'); do
    n=$((n + 1))
    python3 -I "$root/tools/cache2macho/cache2macho.py" "$c" "$work/aot$n.o"
    "$ld64" -arch arm64 -platform_version ios 15.0 15.0 -dylib -o "$work/aot$n.dylib" "$work/aot$n.o"
    python3 -I "$root/tools/cache2macho/check_linked.py" "$c" "$work/aot$n.dylib"
    python3 -I "$root/tools/cache2macho/cache2macho.py" --elf-asm "$c" "$work/aot$n.s"
    clang -c -o "$work/aot$n-elf.o" "$work/aot$n.s"
done
# The dispatcher goes into the same images.
python3 -I "$root/tools/cache2macho/cache2macho.py" --dispatcher "$work/dispatcher1.bin" "$work/dispatcher-macho.s"
clang --target=arm64-apple-ios15.0 -c -o "$work/dispatcher-macho.o" "$work/dispatcher-macho.s"
"$ld64" -arch arm64 -platform_version ios 15.0 15.0 -dylib -o "$work/aot-dispatcher.dylib" "$work/dispatcher-macho.o" "$work/aot1.o"
python3 -I "$root/tools/cache2macho/cache2macho.py" --dispatcher --elf-asm "$work/dispatcher1.bin" "$work/dispatcher.s"
clang -c -o "$work/dispatcher-elf.o" "$work/dispatcher.s"
clang -shared -nostdlib -fuse-ld=lld -o "$work/aot.so" "$work"/aot*-elf.o "$work/dispatcher-elf.o"
for c in $(find "$cachedir" -type f ! -name '*.tmp' ! -name '*.lock'); do
    python3 -I "$root/tools/cache2macho/check_linked.py" "$c" "$work/aot.so"
done

run_cached aot aot-census
grep -Eq 'AOT data area: .*\([1-9][0-9]* link records\)' "$work/fex-aot-run.log" ||
    { echo "FEX did not set up the AOT data area with link records" >&2; exit 1; }
grep -q 'AOT code mapped read+execute:' "$work/fex-aot-run.log" ||
    { echo "FEX did not map the AOT code read-only" >&2; exit 1; }

# Linked AOT code (patches/fex/0005, 0006): FEX takes code and data area from
# the shared object instead of the cache files, which are moved away to be
# sure, and runs the dispatcher from it; the one it generates is not executable.
mv "$cachedir" "$cachedir.files"
export FEX_AOTIMAGE="$work/aot.so"
run_cached aot-image aot-census
unset FEX_AOTIMAGE
mv "$cachedir.files" "$cachedir"
grep -q 'AOT image linked:' "$work/fex-aot-image-run.log" ||
    { echo "FEX did not load the linked AOT image" >&2; exit 1; }
grep -q 'Dispatcher: static code from AOT image' "$work/fex-aot-image-run.log" ||
    { echo "FEX did not run the dispatcher from the AOT image" >&2; exit 1; }
