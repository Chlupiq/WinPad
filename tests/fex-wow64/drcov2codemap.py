"""Turns a DynamoRIO drcov log of a native Windows run into a FEX code map.

A program run natively on a Windows PC under DynamoRIO's drcov tool
(drrun -t drcov -- GAME.EXE) records every basic block it executed. This
writes the blocks of one image as a code map for FEX's offline compiler, so
that one played session on a PC fills an AOT image that would otherwise take
many slow interpreted rounds on the iPad. Only the image's own code is
useful: the Windows DLLs it ran are not the Wine ones the iPad runs.

Usage: drcov2codemap.py [--all-blocks] IMAGE.EXE MAP OUT DRCOV.LOG...

  IMAGE.EXE  the image's PE file (the same bytes the PC ran; its size is
             checked against the module drcov saw)
  MAP        a recorded code map (or a directory of them) that names IMAGE;
             its image record (file id and path) is copied to OUT, and its
             blocks are kept
  OUT        the code map to write
  DRCOV.LOG  drcov logs (drcov.GAME.EXE.*.log), versions 2 to 5, binary or
             written with -dump_text; their blocks are merged

Block starts are offsets from the image base, as FEX records them. drcov's
blocks are basic blocks, but FEX enters the dispatcher only at function
entries, return addresses and targets of indirect branches, and compiles the
rest into those entries' blocks. Compiling every basic block as an entry
multiplies the code (each one is compiled to its function's end again) past
the 128 MB code buffer of FEX's offline compiler. So OUT holds, of the logged
blocks, the targets of direct calls, the instructions after calls, and the
blocks no other logged block reaches by a direct jump, branch or by falling
through (indirect targets and callbacks). --all-blocks writes every logged
block instead.
"""
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from codemap import ENTRY, SET_MAIN  # noqa: E402
from discover import Image, image_record, map_files, target_of  # noqa: E402

BB = struct.Struct("<IHH")  # start (offset from module start), size, module id


def read_drcov(path):
    with open(path, "rb") as f:
        data = f.read()
    pos = 0

    def line():
        nonlocal pos
        end = data.index(b"\n", pos)
        text = data[pos:end].decode("utf-8", "replace").rstrip("\r")
        pos = end + 1
        return text

    head = line()
    if not head.startswith("DRCOV VERSION:"):
        sys.exit(f"drcov2codemap: {path} is not a drcov log")
    text = line()
    while not text.startswith("Module Table:"):
        text = line()
    m = re.search(r"count (\d+)", text)
    count = int(m.group(1))
    text = line()
    if text.startswith("Columns:"):
        columns = [c.strip() for c in text[len("Columns:"):].split(",")]
    else:  # version 1 table: id, base, end, entry, path
        columns = ["id", "base", "end", "entry", "path"]
        pos -= len(text) + 1
    modules = {}
    for _ in range(count):
        parts = [p.strip() for p in line().split(",", len(columns) - 1)]
        row = dict(zip(columns, parts))
        mid = int(row["id"])
        start = int(row.get("start", row.get("base")), 16)
        end = int(row["end"], 16)
        containing = int(row.get("containing_id", mid))
        modules[mid] = {"start": start, "end": end, "containing": containing,
                        "path": row["path"]}
    text = line()
    m = re.match(r"BB Table: (\d+) bbs", text)
    if not m:
        sys.exit(f"drcov2codemap: no BB table in {path}")
    n = int(m.group(1))
    if data[pos:pos + 7] == b"module ":  # -dump_text: "module[  0]: 0x00001000,   5" per block
        line()
        blocks = []
        for _ in range(n):
            t = re.match(r"module\[\s*(\d+)\]:\s*0x([0-9a-fA-F]+),\s*(\d+)", line())
            blocks.append((int(t.group(2), 16), int(t.group(3)), int(t.group(1))))
        return modules, blocks
    blocks = [BB.unpack_from(data, pos + i * BB.size) for i in range(n)]
    return modules, blocks


def fex_entries(img, blocks):
    """The logged basic blocks FEX would enter through its dispatcher."""
    entries, reached = set(), set()
    for start, size in blocks.items():
        pc, end, last = start, start + size, None
        while pc < end:
            insn = img.decode(pc)
            if insn is None:
                break
            last, pc = insn, pc + insn.size
        if last is None:
            entries.add(start)
            continue
        m, t = last.mnemonic, target_of(last)
        if m == "call":
            if t is not None:
                entries.add(t - img.base)
            entries.add(end)
        elif m == "jmp":
            if t is not None:
                reached.add(t - img.base)
        elif m.startswith("j") or m.startswith("loop") or m == "jecxz":
            if t is not None:
                reached.add(t - img.base)
            reached.add(end)
        elif m not in ("ret", "retn", "int3", "ud2"):
            reached.add(end)
    entries |= set(blocks) - reached
    return {e for e in entries if img.is_code(e)}


def main(argv):
    all_blocks = "--all-blocks" in argv
    args = [a for a in argv if a != "--all-blocks"]
    if len(args) < 4:
        print(__doc__)
        return 2
    image, map_path, out_path, logs = args[0], args[1], args[2], args[3:]
    image_name = os.path.basename(image).lower()
    img = Image(image)
    blocks, logged = {}, 0
    for log_path in logs:
        modules, bbs = read_drcov(log_path)
        ids = {mid for mid, mod in modules.items()
               if mod["path"].replace("/", "\\").rsplit("\\", 1)[-1].lower() == image_name}
        if not ids:
            names = sorted({m["path"].replace("/", "\\").rsplit("\\", 1)[-1] for m in modules.values()})
            sys.exit(f"drcov2codemap: {image_name} is not among the modules of {log_path}: {', '.join(names[:30])}")
        # A module drcov split into segments shares its containing id; offsets
        # are taken from the containing module's start (the image base).
        base = {mid: modules[modules[mid]["containing"]]["start"] for mid in ids}
        span = max(modules[m]["end"] for m in ids) - min(base.values())
        size = img.pe.OPTIONAL_HEADER.SizeOfImage
        if abs(size - span) > 0x10000:
            sys.exit(f"drcov2codemap: {image} maps {size:#x} bytes but {log_path} saw {span:#x}: not the same file")
        for start, bsize, mid in bbs:
            if mid in ids:
                rva = modules[mid]["start"] - base[mid] + start
                blocks[rva] = max(blocks.get(rva, 0), bsize)
                logged += 1

    starts = set(blocks) if all_blocks else fex_entries(img, blocks)
    file_id, record, is_main, recorded = image_record(map_files(map_path), image_name)
    out = bytearray(record)
    if is_main:
        out += ENTRY.pack(*SET_MAIN) + struct.pack("<Q", file_id)
    for rva in sorted(starts | recorded):
        out += ENTRY.pack(file_id, rva)
    with open(out_path, "wb") as f:
        f.write(out)
    known = len(recorded & set(blocks))
    print(f"{out_path}: {len(starts)} block starts of {image_name} from {len(blocks)} distinct logged blocks "
          f"({'all of them' if all_blocks else 'the ones FEX enters'}); the native runs cover {known} of the "
          f"{len(recorded)} blocks the map recorded")
    return 0 if starts else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
