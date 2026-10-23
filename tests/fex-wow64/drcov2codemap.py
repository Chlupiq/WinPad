"""Turns a DynamoRIO drcov log of a native Windows run into a FEX code map.

A program run natively on a Windows PC under DynamoRIO's drcov tool
(drrun -t drcov -- GAME.EXE) records every basic block it executed. This
writes the blocks of one image as a code map for FEX's offline compiler, so
that one played session on a PC fills an AOT image that would otherwise take
many slow interpreted rounds on the iPad. Only the image's own code is
useful: the Windows DLLs it ran are not the Wine ones the iPad runs.

Usage: drcov2codemap.py DRCOV.LOG IMAGE.EXE MAP OUT

  DRCOV.LOG  the drcov log (drcov.GAME.EXE.*.log), versions 2 to 5
  IMAGE.EXE  the image's file name as drcov lists it (e.g. SPEED2.EXE); the
             PE file itself, when given as a path, is checked to match the
             module size drcov saw
  MAP        a recorded code map (or a directory of them) that names IMAGE;
             its image record (file id and path) is copied to OUT
  OUT        the code map to write

Block starts are offsets from the image base, as FEX records them. drcov's
blocks are basic blocks, so OUT holds more starts than a FEX run would record
(conditional branch targets too); the offline compiler compiles each one.
"""
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from codemap import ENTRY, SET_MAIN  # noqa: E402
from discover import image_record, map_files  # noqa: E402

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
    blocks = [BB.unpack_from(data, pos + i * BB.size) for i in range(n)]
    return modules, blocks


def main(argv):
    if len(argv) != 4:
        print(__doc__)
        return 2
    log_path, image, map_path, out_path = argv
    image_name = os.path.basename(image).lower()
    modules, blocks = read_drcov(log_path)
    ids = {mid for mid, mod in modules.items()
           if mod["path"].replace("/", "\\").rsplit("\\", 1)[-1].lower() == image_name}
    if not ids:
        names = sorted({m["path"].replace("/", "\\").rsplit("\\", 1)[-1] for m in modules.values()})
        sys.exit(f"drcov2codemap: {image_name} is not among the logged modules: {', '.join(names[:30])}")
    # A module drcov split into segments shares its containing id; offsets
    # are taken from the containing module's start (the image base).
    base = {mid: modules[modules[mid]["containing"]]["start"] for mid in ids}
    span = max(modules[m]["end"] for m in ids) - min(base.values())
    if os.path.isfile(image):
        import pefile
        size = pefile.PE(image, fast_load=True).OPTIONAL_HEADER.SizeOfImage
        if abs(size - span) > 0x10000:
            sys.exit(f"drcov2codemap: {image} maps {size:#x} bytes but drcov saw {span:#x}: not the same file")

    starts = set()
    for start, _size, mid in blocks:
        if mid in ids:
            starts.add(modules[mid]["start"] - base[mid] + start)

    file_id, record, is_main, recorded = image_record(map_files(map_path), image_name)
    out = bytearray(record)
    if is_main:
        out += ENTRY.pack(*SET_MAIN) + struct.pack("<Q", file_id)
    for rva in sorted(starts | recorded):
        out += ENTRY.pack(file_id, rva)
    with open(out_path, "wb") as f:
        f.write(out)
    known = len(recorded & starts)
    print(f"{out_path}: {len(starts)} block starts of {image_name} from {len(blocks)} logged blocks; "
          f"the native run covers {known} of the {len(recorded)} blocks the map recorded"
          + (f", {len(recorded - starts)} recorded ones kept besides" if recorded - starts else ""))
    return 0 if starts else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
