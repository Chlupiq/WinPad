#!/usr/bin/env python3
"""Write the index of an AOT image: which linked cache belongs to which binary.

cache2macho turns each AOT code cache into an object with the symbols
_PREFIX_meta, _PREFIX_text and _PREFIX_data. Linked together into one image
(a dylib, or the app itself), the caches are found through this index, so the
loader needs no symbol lookup by name: the WoW64 FEX module (xtajit.dll) is a
Windows DLL and cannot call dlsym, but the host can hand it the address of
_fexaot_index (WINE_IOS_AOT_INDEX, see patches/fex-wow64/0010).

Layout (little-endian, 8-byte aligned):
  "FXAI", u32 version 1, u64 number of entries, then per entry
  u64 file id, u64 config id, meta pointer, text pointer, data pointer.
The pointers are absolute; dyld fixes them up when the image is loaded.

Usage: aotindex.py OUT.s CACHE_FILE...
Each cache file name ends in -<file id>-<config id>, as cache2macho expects.
"""
import os
import re
import sys


def entry(path):
    m = re.search(r"-([0-9a-f]{16})-([0-9a-f]{16})$", os.path.basename(path))
    if not m:
        raise SystemExit(f"{path}: name does not end in -<file id>-<config id>")
    return m.group(1), m.group(2)


def index_asm(entries):
    out = ["\t.section __DATA,__fexaot_index", "\t.globl _fexaot_index", "\t.p2align 3", "_fexaot_index:",
           '\t.ascii "FXAI"', "\t.long 1", f"\t.quad {len(entries)}"]
    for file_id, config_id in entries:
        prefix = f"_fexaot_{file_id}_{config_id}"
        out += [f"\t.quad 0x{file_id}", f"\t.quad 0x{config_id}",
                f"\t.quad {prefix}_meta", f"\t.quad {prefix}_text", f"\t.quad {prefix}_data"]
    return "\n".join(out) + "\n"


def main():
    if len(sys.argv) < 3:
        raise SystemExit(__doc__.strip().splitlines()[-2])
    entries = [entry(p) for p in sys.argv[2:]]
    if len(set(entries)) != len(entries):
        raise SystemExit("two caches with the same file id and config id")
    with open(sys.argv[1], "w") as f:
        f.write(index_asm(entries))
    print(f"{sys.argv[1]}: index of {len(entries)} caches")


if __name__ == "__main__":
    main()
