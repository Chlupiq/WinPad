"""Summarizes a FEX code map: which guest images ran and how many blocks of each.

A code map is what FEX records while it runs (FEX_ENABLECODECACHINGWIP=1): one
entry per compiled block, as file id + offset into that image. FEX's offline
compiler turns it into a code cache. Format: FEXCore/include/FEXCore/Core/CodeCache.h
(CodeMap::Entry, ExternalLibraryInfo, SetExecutableFileId).

Usage: codemap.py FILE...   Exits with 1 if no file holds a block, or if a
file does not parse cleanly (a block of an image the map never named, or
bytes left over at the end).

       codemap.py drop --every N FILE...   Rewrites each map without every
N-th block entry (the N-th, 2N-th, ... of each file), keeping the image
records. A cache built from it misses those blocks, which is how CI makes a
NoJIT run meet code that is not in its AOT image.

       codemap.py halfbarrier IN OUT   Writes IN with every block entry
marked as one that took unaligned atomic faults in a read-only AOT image
(CodeMap::HalfBarrierTSOBlock, patches/fex-wow64/0030), as such a run
records it. The offline compiler compiles those blocks with plain loads and
stores and half barriers, which CI checks without a CPU that faults.

       codemap.py rehome GAME_DIR FOLDER FILE...   Renames, in each map, the
images the iPad app ran from its Documents/FOLDER (\\??\\Z:\\var\\mobile\\
Containers\\Data\\Application\\UUID\\Documents\\FOLDER\\...) to the same files
under GAME_DIR (as FEX names it: \\??\\Z:\\Users\\...), so that the offline
compiler on the Mac opens them.
"""
import re
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


def drop(every, paths):
    dropped_all = 0
    for path in paths:
        with open(path, "rb") as f:
            data = f.read()
        out, pos, seen, dropped = bytearray(), 0, 0, []
        while pos + ENTRY.size <= len(data):
            entry = ENTRY.unpack_from(data, pos)
            if entry == LIBRARY:
                end = data.index(b"\0", pos + ENTRY.size + 8)
                nxt = (end + 1 + 3) & ~3
            elif entry == SET_MAIN:
                nxt = pos + ENTRY.size + 8
            else:
                nxt = pos + ENTRY.size
                seen += 1
                if seen % every == 0:
                    dropped.append(entry[1])
                    pos = nxt
                    continue
            out += data[pos:nxt]
            pos = nxt
        out += data[pos:]
        with open(path, "wb") as f:
            f.write(out)
        print(f"{path}: dropped {len(dropped)} of {seen} blocks")
        if dropped:
            print("         at " + " ".join(f"{o:#x}" for o in dropped[:40]) + (" ..." if len(dropped) > 40 else ""))
        dropped_all += len(dropped)
    print(f"dropped blocks in all: {dropped_all}")
    return 0 if dropped_all else 1


HALF_BARRIER = 0x80000000


def halfbarrier(src, dst):
    with open(src, "rb") as f:
        data = f.read()
    out, pos, marked = bytearray(), 0, 0
    while pos + ENTRY.size <= len(data):
        entry = ENTRY.unpack_from(data, pos)
        if entry == LIBRARY:
            end = data.index(b"\0", pos + ENTRY.size + 8)
            nxt = (end + 1 + 3) & ~3
        elif entry == SET_MAIN:
            nxt = pos + ENTRY.size + 8
        else:
            out += ENTRY.pack(entry[0], entry[1] | HALF_BARRIER)
            marked += 1
            pos += ENTRY.size
            continue
        out += data[pos:nxt]
        pos = nxt
    out += data[pos:]
    with open(dst, "wb") as f:
        f.write(out)
    print(f"{dst}: {marked} blocks marked for a half-barrier compile")
    return 0 if marked else 1


def rehome(game_dir, folder, paths):
    ipad = re.compile(
        r"^\\\?\?\\Z:\\(?:private\\)?var\\mobile\\Containers\\Data\\Application\\[^\\]+\\Documents\\"
        + re.escape(folder) + r"\\(.+)$",
        re.IGNORECASE,
    )
    for path in paths:
        with open(path, "rb") as f:
            data = f.read()
        out, pos, renamed = bytearray(), 0, 0
        while pos + ENTRY.size <= len(data):
            entry = ENTRY.unpack_from(data, pos)
            if entry == LIBRARY:
                start = pos + ENTRY.size + 8
                end = data.index(b"\0", start)
                nxt = (end + 1 + 3) & ~3
                name = data[start:end].decode("utf-8")
                m = ipad.match(name)
                if m:
                    name = game_dir.rstrip("\\") + "\\" + m.group(1)
                    renamed += 1
                record = data[pos:start] + name.encode("utf-8") + b"\0"
                out += record + b"\0" * (-len(record) % 4)
                pos = nxt
                continue
            nxt = pos + ENTRY.size + (8 if entry == SET_MAIN else 0)
            out += data[pos:nxt]
            pos = nxt
        out += data[pos:]
        if renamed:
            with open(path, "wb") as f:
                f.write(out)
        print(f"{path}: {renamed} images renamed to {game_dir}")
    return 0


def main():
    if len(sys.argv) >= 5 and sys.argv[1] == "rehome":
        return rehome(sys.argv[2], sys.argv[3], sys.argv[4:])
    if len(sys.argv) == 4 and sys.argv[1] == "halfbarrier":
        return halfbarrier(sys.argv[2], sys.argv[3])
    if len(sys.argv) >= 4 and sys.argv[1] == "drop" and sys.argv[2] == "--every":
        return drop(int(sys.argv[3]), sys.argv[4:])
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
            if len(offsets) <= 40:
                print("         at " + " ".join(f"{o:#x}" for o in sorted(offsets)))
            total += len(offsets)
        if unknown:
            print(f"  error: blocks of {len(unknown)} file id(s) the map never named")
        if left:
            print(f"  error: {left} bytes left over at the end")
    print(f"code map blocks in all: {total}")
    return 0 if total and clean else 1


if __name__ == "__main__":
    sys.exit(main())
