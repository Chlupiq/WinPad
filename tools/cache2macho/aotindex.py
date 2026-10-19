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

With --dispatcher the image also holds FEX's dispatcher (cache2macho
--dispatcher): its entry has file id 0 and config id ~0, meta pointing at its
"FXAD" header, text at its code and data 0.

Usage: aotindex.py [--dispatcher] OUT.s CACHE_FILE...
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


DISPATCHER_CONFIG_ID = "f" * 16


def index_asm(entries, dispatcher=False):
    out = ["\t.section __DATA,__fexaot_index", "\t.globl _fexaot_index", "\t.p2align 3", "_fexaot_index:",
           '\t.ascii "FXAI"', "\t.long 1", f"\t.quad {len(entries) + dispatcher}"]
    if dispatcher:
        out += ["\t.quad 0", f"\t.quad 0x{DISPATCHER_CONFIG_ID}",
                "\t.quad _fexaot_dispatcher_meta", "\t.quad _fexaot_dispatcher_text", "\t.quad 0"]
    for file_id, config_id in entries:
        prefix = f"_fexaot_{file_id}_{config_id}"
        out += [f"\t.quad 0x{file_id}", f"\t.quad 0x{config_id}",
                f"\t.quad {prefix}_meta", f"\t.quad {prefix}_text", f"\t.quad {prefix}_data"]
    return "\n".join(out) + "\n"


def main():
    args = sys.argv[1:]
    dispatcher = bool(args) and args[0] == "--dispatcher"
    if dispatcher:
        args = args[1:]
    if len(args) < 2:
        raise SystemExit(__doc__.strip().splitlines()[-2])
    entries = [entry(p) for p in args[1:]]
    if len(set(entries)) != len(entries):
        raise SystemExit("two caches with the same file id and config id")
    with open(args[0], "w") as f:
        f.write(index_asm(entries, dispatcher))
    print(f"{args[0]}: index of {len(entries)} caches" + (" and the dispatcher" if dispatcher else ""))


if __name__ == "__main__":
    main()
