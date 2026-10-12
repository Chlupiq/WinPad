#!/usr/bin/env python3
"""Turn a FEX AOT code cache into an arm64 Mach-O object for iOS.

The cache must come from FEXOfflineCompiler with AOTCodeCacheWIP
(patches/fex/0002-0004), so every relocation only fills the data area next to
the code. In the cache file the code reaches that area at a fixed distance
(AlignUp(code size, 16 KiB)). In a linked app the code lives in __TEXT and the
data area in __DATA, so the distance is only known to the linker: each place
that refers to the data area becomes a linker relocation instead, and the code
in the object never needs a fix-up at load time.

Sections of the object:
  __TEXT,__fexaot_text  the code; adrp/ldr and adrp/add pairs carry
                        ARM64_RELOC_PAGE21 / PAGEOFF12 to the data area, block
                        headers carry a SUBTRACTOR/UNSIGNED pair (32-bit offset
                        from the header to the block tail's copy).
  __DATA,__fexaot_data  zero-filled data area, same layout as FEX's loader
                        uses (slots in relocation order); the runtime fills it.
  __TEXT,__fexaot_meta  "FXAM" header followed by the cache file without its
                        code (header, block list, relocations, code pages), for
                        the runtime loader.
Global symbols: _PREFIX_text, _PREFIX_data, _PREFIX_meta (PREFIX defaults to
"fexaot"; give each cache its own when linking several into one app).

Usage: cache2macho.py [--prefix NAME] [--min-ios 15.0] CACHE_FILE OUT.o
"""
import argparse
import os
import struct
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "fxcc-inspect"))
import fxcc_inspect as fi  # noqa: E402

TEXT_ALIGN_LOG2 = 14  # 16 KiB pages on iOS
ANCHOR_SPACING = 1 << 22  # ARM64_RELOC_ADDEND holds 24 signed bits; keep addends below 4 MiB

# Mach-O constants (mach-o/loader.h, mach-o/arm64/reloc.h)
MH_MAGIC_64 = 0xFEEDFACF
CPU_TYPE_ARM64 = 0x0100000C
MH_OBJECT = 1
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
LC_DYSYMTAB = 0xB
LC_BUILD_VERSION = 0x32
PLATFORM_IOS = 2
S_REGULAR = 0x0
S_ZEROFILL = 0x1
S_ATTR_PURE_INSTRUCTIONS = 0x80000000
S_ATTR_SOME_INSTRUCTIONS = 0x00000400
N_SECT = 0xE
N_EXT = 0x1
ARM64_RELOC_UNSIGNED = 0
ARM64_RELOC_SUBTRACTOR = 1
ARM64_RELOC_PAGE21 = 3
ARM64_RELOC_PAGEOFF12 = 4
ARM64_RELOC_ADDEND = 10

META_HEADER = struct.Struct("<4sIQQQ")  # magic, version, code size, data size, code offset in cache file


class ConvertError(Exception):
    pass


def slot_count(reloc):
    if reloc["type"] == "GUEST_RIP_DATA_SLOT":
        return 1
    if reloc["type"] == "GUEST_RIP_LINK_RECORD":
        return 3
    if reloc["type"] == "AOT_BLOCK_TAIL":
        return (reloc["tail_size"] + 7) // 8
    return 0


def read_relocations(data, info):
    """Relocations with the fields cache2macho needs, in file order."""
    # The relocation array starts right after the block list, as in fxcc_inspect.
    off = fi.HEADER.size
    for _ in range(info["blocks"]):
        npages = struct.unpack_from("<Q", data, off + 16)[0]
        off += 24 + 8 * npages
    relocs = []
    for i in range(info["relocations"]):
        base = off + i * fi.RELOC_SIZE
        roff, rtype = fi.RELOC_HEADER.unpack_from(data, base)
        name = fi.RELOC_TYPES[rtype] if rtype < len(fi.RELOC_TYPES) else f"UNKNOWN_{rtype}"
        tail_size, guest_rip, offset_from_header = struct.unpack_from("<IQI", data, base + 12)
        relocs.append({
            "offset": roff,
            "type": name,
            "tail_size": tail_size,
            "guest_rip": guest_rip,
            "offset_from_header": offset_from_header,
        })
    return relocs


def layout(relocs):
    """Data area offset (bytes) of every relocation, as FEX's loader lays it out."""
    slots = []
    index = 0
    for r in relocs:
        if r["type"] not in fi.DATA_ONLY_TYPES:
            raise ConvertError(f"relocation {r['type']} at code+{r['offset']:#x} patches code; "
                               "generate the cache with AOTCodeCacheWIP")
        slots.append(index * 8)
        index += slot_count(r)
    return slots, index * 8


class Symbols:
    def __init__(self):
        self.locals = []  # (name, section index, value)
        self.globals = []

    def add(self, name, sect, value, glob):
        (self.globals if glob else self.locals).append((name, sect, value))

    def index(self, name):
        for i, (n, _, _) in enumerate(self.locals + self.globals):
            if n == name:
                return i
        raise KeyError(name)


def reloc_entry(address, symbolnum, pcrel, length, extern, rtype):
    word = (symbolnum & 0xFFFFFF) | (pcrel << 24) | (length << 25) | (extern << 27) | (rtype << 28)
    return struct.pack("<iI", address, word)


def convert(data, prefix, min_ios):
    info = fi.parse(data)
    if not info["blocks"]:
        raise ConvertError("empty cache")
    relocs = read_relocations(data, info)
    slots, data_size = layout(relocs)
    if not data_size:
        raise ConvertError("cache has no data area; generate it with AOTCodeCacheWIP")

    code_off = info["code_offset"]
    code_size = info["code_bytes"]
    text = bytearray(data[code_off:code_off + code_size])
    meta = META_HEADER.pack(b"FXAM", 1, code_size, data_size, code_off) + data[:code_off] + data[code_off + code_size:]

    # Section addresses inside the object: text, meta, data
    text_addr = 0
    meta_addr = fi.align_up(text_addr + len(text), 8)
    data_addr = fi.align_up(meta_addr + len(meta), 1 << TEXT_ALIGN_LOG2)

    syms = Symbols()
    num_anchors = (data_size + ANCHOR_SPACING - 1) // ANCHOR_SPACING
    for a in range(num_anchors):
        syms.add(f"l_{prefix}_data_{a}", 3, data_addr + a * ANCHOR_SPACING, False)
    syms.add(f"_{prefix}_text", 1, text_addr, True)
    syms.add(f"_{prefix}_meta", 2, meta_addr, True)
    syms.add(f"_{prefix}_data", 3, data_addr, True)
    text_sym = syms.index(f"_{prefix}_text")

    def anchor(slot):
        a = slot // ANCHOR_SPACING
        return syms.index(f"l_{prefix}_data_{a}"), slot - a * ANCHOR_SPACING

    rel = []
    for r, slot in zip(relocs, slots):
        site = r["offset"]
        if r["type"] in ("GUEST_RIP_DATA_SLOT", "GUEST_RIP_LINK_RECORD"):
            adrp, lo12 = struct.unpack_from("<II", text, site)
            if adrp & 0x9F000000 != 0x90000000:
                raise ConvertError(f"expected adrp at code+{site:#x}, found {adrp:#010x}")
            # Clear the immediates; the linker fills them in.
            adrp &= ~((0x3 << 29) | (0x7FFFF << 5)) & 0xFFFFFFFF
            lo12 &= ~(0xFFF << 10) & 0xFFFFFFFF
            struct.pack_into("<II", text, site, adrp, lo12)
            sym, addend = anchor(slot)
            for addr, rtype, pcrel in ((site, ARM64_RELOC_PAGE21, 1), (site + 4, ARM64_RELOC_PAGEOFF12, 0)):
                if addend:
                    rel.append(reloc_entry(addr, addend, 0, 2, 0, ARM64_RELOC_ADDEND))
                rel.append(reloc_entry(addr, sym, pcrel, 2, 1, rtype))
        elif r["type"] == "AOT_BLOCK_TAIL":
            header = site - r["offset_from_header"]
            sym, addend = anchor(slot)
            # header->OffsetToBlockTail = (anchor + addend) - (text + header)
            struct.pack_into("<i", text, header, addend - header)
            rel.append(reloc_entry(header, text_sym, 0, 2, 1, ARM64_RELOC_SUBTRACTOR))
            rel.append(reloc_entry(header, sym, 0, 2, 1, ARM64_RELOC_UNSIGNED))

    # Load commands
    sections = [
        (b"__fexaot_text"[:16], b"__TEXT", text_addr, len(text), TEXT_ALIGN_LOG2,
         S_REGULAR | S_ATTR_PURE_INSTRUCTIONS | S_ATTR_SOME_INSTRUCTIONS, len(rel)),
        (b"__fexaot_meta", b"__TEXT", meta_addr, len(meta), 3, S_REGULAR, 0),
        (b"__fexaot_data", b"__DATA", data_addr, data_size, TEXT_ALIGN_LOG2, S_ZEROFILL, 0),
    ]
    seg_cmd_size = 72 + 80 * len(sections)
    build_cmd_size = 24
    symtab_cmd_size = 24
    dysymtab_cmd_size = 80
    sizeofcmds = seg_cmd_size + build_cmd_size + symtab_cmd_size + dysymtab_cmd_size
    header_size = 32

    file_text = fi.align_up(header_size + sizeofcmds, 1 << TEXT_ALIGN_LOG2)
    file_meta = file_text + (meta_addr - text_addr)
    file_end = file_meta + len(meta)
    reloff = fi.align_up(file_end, 8)
    symoff = reloff + len(b"".join(rel))
    all_syms = syms.locals + syms.globals
    strtab = bytearray(b"\0")
    nlist = bytearray()
    for i, (name, sect, value) in enumerate(all_syms):
        strx = len(strtab)
        strtab += name.encode() + b"\0"
        ntype = N_SECT | (N_EXT if i >= len(syms.locals) else 0)
        nlist += struct.pack("<IBBHQ", strx, ntype, sect, 0, value)
    stroff = symoff + len(nlist)

    out = bytearray()
    out += struct.pack("<IiiIIIII", MH_MAGIC_64, CPU_TYPE_ARM64, 0, MH_OBJECT, 4, sizeofcmds, 0, 0)
    vmsize = data_addr + data_size
    out += struct.pack("<II16sQQQQiiII", LC_SEGMENT_64, seg_cmd_size, b"", 0, vmsize, file_text,
                       file_end - file_text, 7, 7, len(sections), 0)
    for sect, seg, addr, size, align, flags, nreloc in sections:
        if flags == S_ZEROFILL:
            offset = 0
        else:
            offset = file_text + addr
        sreloff = reloff if nreloc else 0
        out += struct.pack("<16s16sQQIIIIIIII", sect, seg, addr, size, offset, align, sreloff, nreloc,
                           flags, 0, 0, 0)
    major, minor = (int(x) for x in min_ios.split("."))
    version = (major << 16) | (minor << 8)
    out += struct.pack("<IIIIII", LC_BUILD_VERSION, build_cmd_size, PLATFORM_IOS, version, version, 0)
    out += struct.pack("<IIIIII", LC_SYMTAB, symtab_cmd_size, symoff, len(all_syms), stroff, len(strtab))
    out += struct.pack("<IIIIIIIIIIIIIIIIIIII", LC_DYSYMTAB, dysymtab_cmd_size,
                       0, len(syms.locals), len(syms.locals), len(syms.globals), len(all_syms), 0,
                       0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
    out += b"\0" * (file_text - len(out))
    out += text
    out += b"\0" * (file_meta - len(out))
    out += meta
    out += b"\0" * (reloff - len(out))
    out += b"".join(rel)
    out += nlist
    out += strtab
    return bytes(out), {"code_bytes": code_size, "data_bytes": data_size, "relocations": len(rel)}


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("cache")
    ap.add_argument("output")
    ap.add_argument("--prefix", default="fexaot", help="symbol and section name prefix")
    ap.add_argument("--min-ios", default="15.0")
    args = ap.parse_args()
    with open(args.cache, "rb") as fh:
        data = fh.read()
    try:
        obj, stats = convert(data, args.prefix, args.min_ios)
    except (ConvertError, fi.FormatError) as e:
        sys.exit(f"{args.cache}: {e}")
    with open(args.output, "wb") as fh:
        fh.write(obj)
    print(f"{args.output}: code {stats['code_bytes']} bytes, data area {stats['data_bytes']} bytes, "
          f"{stats['relocations']} Mach-O relocations")


if __name__ == "__main__":
    main()
