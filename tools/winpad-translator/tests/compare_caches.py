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
    if not info:
        return
    # Blocks whose code starts at another offset or is another size: the first of them is where
    # the two compilers part.
    other = {}
    try:
        other = {blk["guest"]: blk["host"] for blk in fxcc_inspect.parse(b)["block_list"]}
    except fxcc_inspect.FormatError:
        pass
    by_host = sorted((blk["host"], blk["guest"]) for blk in info["block_list"])
    ends = {g: (by_host[i + 1][0] if i + 1 < len(by_host) else info["code_bytes"]) - h for i, (h, g) in enumerate(by_host)}
    other_sorted = sorted((h, g) for g, h in other.items())
    other_ends = {g: (other_sorted[i + 1][0] if i + 1 < len(other_sorted) else info["code_bytes"]) - h
                  for i, (h, g) in enumerate(other_sorted)}
    moved = [(h, g) for h, g in by_host if other.get(g) != h or other_ends.get(g) != ends[g]]
    print(f"    {len(moved)} of {len(by_host)} blocks at another offset or of another size")
    for h, g in moved[:6]:
        print(f"      guest {g:#x}: code+{h:#x} {ends[g]} bytes | "
              f"code+{other.get(g, -1):#x} {other_ends.get(g, -1)} bytes")
    if moved:
        # The first such block side by side, from the start of its code
        h, g = moved[0]
        hb = other.get(g)
        n = max(ends[g], other_ends.get(g, 0)) // 4
        print(f"    guest {g:#x}, both compilers' code:")
        for i in range(min(n, 160)):
            oa, ob = info["code_offset"] + h + 4 * i, info["code_offset"] + (hb or 0) + 4 * i
            wa = struct.unpack_from("<I", a, oa)[0] if 4 * i < ends[g] else None
            wb = struct.unpack_from("<I", b, ob)[0] if hb is not None and 4 * i < other_ends.get(g, 0) else None
            ta = f"{wa:08x} {disasm(wa, h + 4 * i)}" if wa is not None else ""
            tb = f"{wb:08x} {disasm(wb, hb + 4 * i)}" if wb is not None else ""
            print(f"      {'  ' if wa == wb else '! '}+{4 * i:#05x} {ta:44} | {tb}")
    code = [off for off in words if off >= info["code_offset"]]
    print(f"    {len(words) - len(code)} differing words in the header and tables, {len(code)} in the code")
    for off in code[:limit]:
        wa, wb = struct.unpack_from("<I", a, off)[0], struct.unpack_from("<I", b, off)[0]
        rel = off - info["code_offset"]
        owner = [g for h, g in by_host if h <= rel]
        where = f"code+{rel:#x}" + (f" (block of guest {owner[-1]:#x})" if owner else "")
        print(f"    {where}: {wa:08x} {disasm(wa, rel):32} | {wb:08x} {disasm(wb, rel)}")


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
