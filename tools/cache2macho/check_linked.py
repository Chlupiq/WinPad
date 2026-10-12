#!/usr/bin/env python3
"""Check a linked Mach-O image built from cache2macho output.

For every data-area reference in the AOT cache, decodes the adrp/ldr or
adrp/add pair (or the block header's 32-bit tail offset) in the linked image
and checks that it reaches the same data area offset FEX's loader would use.
All other code bytes must be identical to the cache, and the code must sit in
a read+execute segment, so the image needs no fix-ups in code at load time.

Usage: check_linked.py CACHE_FILE LINKED_IMAGE
"""
import os
import struct
import sys

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
sys.path.insert(0, os.path.join(here, "..", "fxcc-inspect"))
import cache2macho as c2m  # noqa: E402
import fxcc_inspect as fi  # noqa: E402

VM_PROT_READ, VM_PROT_WRITE, VM_PROT_EXECUTE = 1, 2, 4


def sections(image):
    magic, _, _, _, ncmds, _, _, _ = struct.unpack_from("<IiiIIIII", image, 0)
    if magic != c2m.MH_MAGIC_64:
        raise SystemExit("not a 64-bit Mach-O image")
    off = 32
    found = {}
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", image, off)
        if cmd == c2m.LC_SEGMENT_64:
            segname = image[off + 8:off + 24].rstrip(b"\0").decode()
            initprot, nsects = struct.unpack_from("<iI", image, off + 60)
            for i in range(nsects):
                s = off + 72 + 80 * i
                name = image[s:s + 16].rstrip(b"\0").decode()
                addr, sz, fileoff = struct.unpack_from("<QQI", image, s + 32)
                found[name] = {"segment": segname, "prot": initprot, "addr": addr, "size": sz, "offset": fileoff}
        off += size
    return found


def adrp_target(insn, pc):
    imm = (((insn >> 5) & 0x7FFFF) << 2) | ((insn >> 29) & 0x3)
    if imm & (1 << 20):
        imm -= 1 << 21
    return (pc & ~0xFFF) + (imm << 12)


def main():
    cache_path, image_path = sys.argv[1:3]
    data = open(cache_path, "rb").read()
    image = open(image_path, "rb").read()
    info = fi.parse(data)
    relocs = c2m.read_relocations(data, info)
    slots, data_size = c2m.layout(relocs)
    code = data[info["code_offset"]:info["code_offset"] + info["code_bytes"]]

    sects = sections(image)
    text, area = sects.get("__fexaot_text"), sects.get("__fexaot_data")
    if not text or not area:
        raise SystemExit("image has no __fexaot_text/__fexaot_data sections")
    errors = []
    if text["prot"] & VM_PROT_WRITE or not text["prot"] & VM_PROT_EXECUTE:
        errors.append(f"code segment {text['segment']} has protection {text['prot']}, expected r-x")
    if area["size"] < data_size:
        errors.append(f"data area has {area['size']} bytes, cache needs {data_size}")
    linked = image[text["offset"]:text["offset"] + text["size"]]
    if len(linked) != len(code):
        errors.append(f"code size {len(linked)} differs from cache ({len(code)})")

    patched = set()
    checked = 0
    for r, slot in zip(relocs, slots):
        want = area["addr"] + slot
        site = r["offset"]
        if r["type"] in ("GUEST_RIP_DATA_SLOT", "GUEST_RIP_LINK_RECORD"):
            adrp, lo = struct.unpack_from("<II", linked, site)
            page = adrp_target(adrp, text["addr"] + site)
            imm12 = (lo >> 10) & 0xFFF
            got = page + (imm12 * 8 if r["type"] == "GUEST_RIP_DATA_SLOT" else imm12)
            patched.update(range(site, site + 8))
        else:
            header = site - r["offset_from_header"]
            (rel,) = struct.unpack_from("<I", linked, header)
            got = text["addr"] + header + rel
            patched.update(range(header, header + 4))
        checked += 1
        if got != want:
            errors.append(f"{r['type']} at code+{site:#x} reaches {got:#x}, expected {want:#x}")

    for i in range(min(len(code), len(linked))):
        if i not in patched and code[i] != linked[i]:
            errors.append(f"code byte at +{i:#x} changed by linking")
            break

    for e in errors:
        print(e, file=sys.stderr)
    if errors:
        sys.exit(1)
    print(f"{image_path}: {checked} data-area references resolved by the linker, "
          f"code {len(code)} bytes otherwise identical, code segment r-x")


if __name__ == "__main__":
    main()
