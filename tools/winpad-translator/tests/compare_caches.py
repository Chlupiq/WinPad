"""Compares the code caches FEX's offline compiler made on two computers, file by file.

Usage: compare_caches.py REFERENCE_CACHE_DIR OTHER_CACHE_DIR
(each FEX's cache directory, the caches in its cache/). Exits with 1 unless
both hold the same caches with the same bytes.
"""
import hashlib
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "fxcc-inspect"))
import fxcc_inspect  # noqa: E402

fxcc_inspect.RELOC_TYPES = fxcc_inspect.RELOC_TYPES_WOW64


def caches(cache_dir):
    folder = os.path.join(cache_dir, "cache")
    out = {}
    for name in sorted(os.listdir(folder)):
        with open(os.path.join(folder, name), "rb") as f:
            data = f.read()
        out[name] = (len(data), hashlib.sha256(data).hexdigest())
    return out


def disasm(word, address):
    try:
        import capstone
    except ImportError:
        return ""
    md = capstone.Cs(capstone.CS_ARCH_ARM64, capstone.CS_MODE_ARM)
    for insn in md.disasm(struct.pack("<I", word), address):
        return f"{insn.mnemonic} {insn.op_str}"
    return "?"


def explain(path_a, path_b, limit=24):
    """Where two caches of the same size differ: the part of the file, and in the code
    the block (guest address) and both instructions."""
    with open(path_a, "rb") as f:
        a = f.read()
    with open(path_b, "rb") as f:
        b = f.read()
    try:
        info = fxcc_inspect.parse(a)
    except fxcc_inspect.FormatError as e:
        print(f"    (not a cache: {e})")
        info = None
    words = [off for off in range(0, min(len(a), len(b)) - 3, 4) if a[off:off + 4] != b[off:off + 4]]
    print(f"    {len(words)} differing 32-bit words")
    blocks = sorted((blk["host"], blk["guest"]) for blk in info["block_list"]) if info else []
    for off in words[:limit]:
        wa, wb = struct.unpack_from("<I", a, off)[0], struct.unpack_from("<I", b, off)[0]
        where = "header/tables"
        if info and off >= info["code_offset"]:
            code = off - info["code_offset"]
            owner = [g for h, g in blocks if h <= code]
            where = f"code+{code:#x}" + (f" (block of guest {owner[-1]:#x})" if owner else "")
            print(f"    {where}: {wa:08x} {disasm(wa, code):32} | {wb:08x} {disasm(wb, code)}")
        else:
            print(f"    {where} @{off:#x}: {wa:08x} | {wb:08x}")


def main(argv):
    ref, other = caches(argv[0]), caches(argv[1])
    same = 0
    for name in sorted(set(ref) | set(other)):
        a, b = ref.get(name), other.get(name)
        if a == b:
            same += 1
            print(f"  same       {name} ({a[0]} bytes)")
        elif a and b:
            print(f"  DIFFERENT  {name} ({a[0]} vs {b[0]} bytes)")
            explain(os.path.join(argv[0], "cache", name), os.path.join(argv[1], "cache", name))
        else:
            print(f"  ONLY IN {'reference' if a else 'other'}  {name}")
    print(f"{same} of {len(set(ref) | set(other))} code caches identical")
    return 0 if ref and ref == other else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
