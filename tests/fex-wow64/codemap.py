"""Summarizes a FEX code map: which guest images ran and how many blocks of each.

A code map is what FEX records while it runs (FEX_ENABLECODECACHINGWIP=1): one
entry per compiled block, as file id + offset into that image. FEX's offline
compiler turns it into a code cache. Format: FEXCore/include/FEXCore/Core/CodeCache.h
(CodeMap::Entry, ExternalLibraryInfo, SetExecutableFileId).

Usage: codemap.py FILE...   Exits with 1 if no file holds a block, or if a
file does not parse cleanly (a block of an image the map never named, or
bytes left over at the end).
"""
import struct
import sys

ENTRY = struct.Struct("<QI")
LIBRARY = (0xFFFFFFFFFFFFFFFF, 0xFFFFFFFF)
SET_MAIN = (0xFFFFFFFFFFFFFFFF, 0xFFFFFFFE)


def parse(data):
    names, blocks, main = {}, {}, None
    pos = 0
    while pos + ENTRY.size <= len(data):
        entry = ENTRY.unpack_from(data, pos)
        if entry == LIBRARY:
            (file_id,) = struct.unpack_from("<Q", data, pos + ENTRY.size)
            start = pos + ENTRY.size + 8
            end = data.index(b"\0", start)
            names[file_id] = data[start:end].decode("utf-8", "replace")
            pos = (end + 1 + 3) & ~3
        elif entry == SET_MAIN:
            (main,) = struct.unpack_from("<Q", data, pos + ENTRY.size)
            pos += ENTRY.size + 8
        else:
            blocks.setdefault(entry[0], set()).add(entry[1])
            pos += ENTRY.size
    return names, blocks, main, len(data) - pos


def main():
    total = 0
    clean = True
    for path in sys.argv[1:]:
        with open(path, "rb") as f:
            names, blocks, main_id, left = parse(f.read())
        unknown = [i for i in blocks if i not in names]
        if unknown or left:
            clean = False
        print(f"{path}:")
        for file_id, offsets in sorted(blocks.items(), key=lambda kv: -len(kv[1])):
            tag = " (main executable)" if file_id == main_id else ""
            print(f"  {len(offsets):5} blocks  {names.get(file_id, '?')} [{file_id:016x}]{tag}")
            total += len(offsets)
        if unknown:
            print(f"  error: blocks of {len(unknown)} file id(s) the map never named")
        if left:
            print(f"  error: {left} bytes left over at the end")
    print(f"code map blocks in all: {total}")
    return 0 if total and clean else 1


if __name__ == "__main__":
    sys.exit(main())
