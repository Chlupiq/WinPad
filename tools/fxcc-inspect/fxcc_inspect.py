#!/usr/bin/env python3
"""Inspect FEX code cache files (FXCC format version 2).

Reports what a no-JIT (AOT) build would have to deal with: the number of
cached blocks and code size, and every relocation by type. Each relocation is
a spot where FEX writes into code when it loads the cache, so in AOT mode each
type needs a replacement that does not write to signed code (docs/M1-findings.md,
section B).

Layout follows FEXCore/Source/Interface/Core/CodeCache.cpp (CodeCache::SaveData)
and JIT/Relocations.h in FEX 14c9268.

Usage: fxcc_inspect.py [--json out.json] CACHE_FILE...
"""
import argparse
import json
import struct
import sys

PAGE = 4096
HEADER = struct.Struct("<4sI20sIIIIIQ")
RELOC_SIZE = 48
RELOC_HEADER = struct.Struct("<QI")  # FEX_PACKED: Offset, Type

RELOC_TYPES = [
    "NAMED_SYMBOL_LITERAL",
    "NAMED_THUNK_MOVE",
    "GUEST_RIP_LITERAL",
    "GUEST_RIP_MOVE",
    "GUEST_PATCHABLE_DATA_MOVE",
    "GUEST_PATCHABLE_RIP_LITERAL",
    "GUEST_PATCHABLE_RIP_MOVE",
    "GUEST_PATCHABLE_CRC_MOVE",
]
NAMED_SYMBOLS = ["EXITFUNCTION_LINKER"]


class FormatError(Exception):
    pass


def align_up(value, alignment):
    return (value + alignment - 1) // alignment * alignment


def parse(data):
    if len(data) < HEADER.size:
        raise FormatError("file too small for header")
    (magic, version, fex_version, num_blocks, num_code_pages, code_size,
     num_relocs, _pad, base) = HEADER.unpack_from(data, 0)
    if magic != b"FXCC":
        raise FormatError(f"bad magic {magic!r}")
    if version != 2:
        raise FormatError(f"unsupported format version {version}")

    off = HEADER.size
    blocks = []
    for _ in range(num_blocks):
        guest, host, npages = struct.unpack_from("<QQQ", data, off)
        off += 24 + 8 * npages
        blocks.append((guest, host, npages))

    relocs = {}
    named = {}
    for i in range(num_relocs):
        roff, rtype = RELOC_HEADER.unpack_from(data, off + i * RELOC_SIZE)
        name = RELOC_TYPES[rtype] if rtype < len(RELOC_TYPES) else f"UNKNOWN_{rtype}"
        relocs[name] = relocs.get(name, 0) + 1
        if name == "NAMED_SYMBOL_LITERAL":
            (sym,) = struct.unpack_from("<I", data, off + i * RELOC_SIZE + RELOC_HEADER.size)
            sname = NAMED_SYMBOLS[sym] if sym < len(NAMED_SYMBOLS) else f"UNKNOWN_{sym}"
            named[sname] = named.get(sname, 0) + 1
    off += num_relocs * RELOC_SIZE

    code_off = align_up(off, PAGE)
    if code_off + code_size > len(data):
        raise FormatError("code buffer runs past end of file")

    return {
        "format_version": version,
        "fex_version": fex_version.hex(),
        "serialized_base": base,
        "blocks": num_blocks,
        "code_pages": num_code_pages,
        "code_bytes": code_size,
        "relocations": num_relocs,
        "relocations_by_type": relocs,
        "named_symbols": named,
        "relocations_per_block": round(num_relocs / num_blocks, 2) if num_blocks else 0,
    }


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("files", nargs="+")
    ap.add_argument("--json", help="write results to this file")
    args = ap.parse_args()
    results = {}
    failed = False
    for path in args.files:
        with open(path, "rb") as fh:
            data = fh.read()
        try:
            r = parse(data)
        except (FormatError, struct.error) as e:
            print(f"{path}: {e}", file=sys.stderr)
            failed = True
            continue
        results[path] = r
        print(f"{path}")
        print(f"  blocks {r['blocks']}, code {r['code_bytes']} bytes, relocations {r['relocations']}"
              f" ({r['relocations_per_block']} per block)")
        for name, count in sorted(r["relocations_by_type"].items(), key=lambda kv: -kv[1]):
            print(f"    {name:28} {count}")
        for name, count in r["named_symbols"].items():
            print(f"      symbol {name:21} {count}")
    if args.json:
        with open(args.json, "w") as fh:
            json.dump(results, fh, indent=1)
    sys.exit(1 if failed or not results else 0)


if __name__ == "__main__":
    main()
