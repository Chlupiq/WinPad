#!/bin/sh
# Builds a tiny aarch64 PE DLL with Wine's syscall stub macro, before and after
# patches/wine/0001-aarch64-syscall-stubs-adrp.patch, and checks that the patched
# stubs leave no base relocations in executable sections.
#
# Needs: git, clang, lld-link, python3 with pefile.
set -eu

WINE_REPO=https://github.com/willfaust/wine.git
WINE_COMMIT=257f271cfffed9f22f7987cac53bc00095d092fe

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work=${WORK_DIR:-$(mktemp -d)}

if [ ! -d "$work/wine/.git" ]; then
    git clone -q --filter=blob:none --no-checkout "$WINE_REPO" "$work/wine"
    git -C "$work/wine" sparse-checkout set --no-cone /include/ /dlls/ntdll/tests/virtual.c
fi
git -C "$work/wine" checkout -q "$WINE_COMMIT"

build() {
    clang --target=aarch64-w64-mingw32 -D__WINE_PE_BUILD -O2 -I"$work/wine/include" \
        -c "$here/stubs.c" -o "$work/stubs-$1.o"
    lld-link /dll /noentry /nodefaultlib /machine:arm64 /dynamicbase /align:65536 \
        /export:NtWaitForSingleObject /export:NtSetEvent \
        "$work/stubs-$1.o" /out:"$work/stubs-$1.dll" 2>/dev/null
}

build before
git -C "$work/wine" apply "$root/patches/wine/0001-aarch64-syscall-stubs-adrp.patch"
build after
git -C "$work/wine" checkout -q -- .

python3 -I "$root/tools/pe-reloc-audit/pe_reloc_audit.py" --json "$work/audit.json" \
    "$work/stubs-before.dll" "$work/stubs-after.dll"

python3 -I - "$work" <<'EOF'
import json, struct, sys
import pefile

work = sys.argv[1]
res = {r["file"]: r for r in json.load(open(f"{work}/audit.json"))}
assert res["stubs-before.dll"]["relocs_in_exec"] > 0, "unpatched stubs should have code relocations"
assert res["stubs-after.dll"]["relocs_in_exec"] == 0, "patched stubs still have code relocations"

# The stub must still match the "wine" pattern in dlls/ntdll/tests/virtual.c.
pe = pefile.PE(f"{work}/stubs-after.dll")
for sym in pe.DIRECTORY_ENTRY_EXPORT.symbols:
    ins = struct.unpack("<6I", pe.get_data(sym.address, 24))
    assert (ins[0] & 0xffe0001f) == 0xd2800008 and ins[1] == 0xaa1e03e9, sym.name
    assert (ins[3] & 0xffc003ff) == 0xf9400210 and ins[4] == 0xd63f0200 and ins[5] == 0xd65f03c0, sym.name
print("OK: patched syscall stubs have no relocations in code")
EOF
