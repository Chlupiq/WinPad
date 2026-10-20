"""Names the main executable in FEX code maps that left it unnamed.

FEX names an image in a code map (an ExternalLibraryInfo record) only with
its first compiled block. A run whose main executable came wholly from the
code caches writes a map that sets the main executable's file id but never
names it, and FEX's offline compiler then can't find the image. This puts
that record, with NAME, at the start of each such map.

Usage: codemap-name-main.py NAME FILE...   (NAME as FEX writes it: \\??\\Z:\\...)
"""
import struct
import sys

sys.path.insert(0, __import__("os").path.dirname(__file__))
from codemap import ENTRY, LIBRARY, parse  # noqa: E402


def main():
    name = sys.argv[1].encode("utf-8")
    for path in sys.argv[2:]:
        with open(path, "rb") as f:
            data = f.read()
        names, _, main_id, _ = parse(data)
        if main_id is None or main_id in names:
            continue
        record = ENTRY.pack(*LIBRARY) + struct.pack("<Q", main_id) + name + b"\0"
        record += b"\0" * (-len(record) % 4)
        with open(path, "wb") as f:
            f.write(record + data)
        print(f"{path}: named the main executable {main_id:016x}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
