#!/usr/bin/env python3
"""Unit tests for pe2macho on small PE images built here (no toolchain)."""
import os
import struct
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pe2macho as p2m  # noqa: E402

IMAGE_BASE = 0x180000000
TEXT = 0x60000020  # code, execute, read
DATA = 0xC0000040  # initialized data, read, write


def build_pe(sections, relocs=(), image_base=IMAGE_BASE):
    """A PE32+ ARM64 DLL: sections [(name, rva, bytes, characteristics)],
    DIR64 base relocations at the given RVAs (in a .reloc section added last)."""
    sections = list(sections)
    if relocs:
        blocks = b""
        pages = sorted({r & ~0xFFF for r in relocs})
        for page in pages:
            entries = [(10 << 12) | (r - page) for r in relocs if r & ~0xFFF == page]
            if len(entries) % 2:
                entries.append(0)  # IMAGE_REL_BASED_ABSOLUTE padding
            blocks += struct.pack("<II", page, 8 + 2 * len(entries)) + struct.pack(f"<{len(entries)}H", *entries)
        reloc_rva = p2m.align(max(rva + len(data) for _, rva, data, _ in sections), p2m.PAGE)
        sections.append((".reloc", reloc_rva, blocks, 0x42000040))
    else:
        blocks, reloc_rva = b"", 0
    file_align = 0x200
    headers = 0x400
    pe_off = 0x80
    opt_size = 112 + 16 * 8
    size_of_image = p2m.align(max(rva + len(data) for _, rva, data, _ in sections), p2m.PAGE)
    out = bytearray(headers)
    out[:2] = b"MZ"
    struct.pack_into("<I", out, 0x3C, pe_off)
    out[pe_off:pe_off + 4] = b"PE\0\0"
    struct.pack_into("<HHIIIHH", out, pe_off + 4, 0xAA64, len(sections), 0, 0, 0, opt_size, 0x2022)
    opt = pe_off + 24
    struct.pack_into("<H", out, opt, 0x20B)
    struct.pack_into("<Q", out, opt + 24, image_base)
    struct.pack_into("<II", out, opt + 32, p2m.PAGE, file_align)
    struct.pack_into("<II", out, opt + 56, size_of_image, headers)
    struct.pack_into("<I", out, opt + 108, 16)
    struct.pack_into("<II", out, opt + 112 + 8 * 5, reloc_rva, len(blocks))
    table = opt + opt_size
    raw = headers
    body = bytearray()
    for i, (name, rva, data, flags) in enumerate(sections):
        size = p2m.align(len(data), file_align)
        struct.pack_into("<8sIIII12xI", out, table + 40 * i, name.encode(), len(data), rva, size, raw, flags)
        body += data + b"\0" * (size - len(data))
        raw += size
    return bytes(out + body)


class Pe2MachoTest(unittest.TestCase):
    def test_groups_follow_protection(self):
        pe = p2m.PE(build_pe([(".text", 0x4000, b"\x1f\x20\x03\xd5" * 4, TEXT),
                              (".rdata", 0x8000, b"abc", DATA),
                              (".data", 0xC000, b"\0" * 8, DATA),
                              (".text2", 0x10000, b"\xc0\x03\x5f\xd6", TEXT)]))
        self.assertEqual(pe.groups(), [(0, 0x4000, False), (0x4000, 0x8000, True),
                                       (0x8000, 0x10000, False), (0x10000, 0x14000, True)])

    def test_relocation_becomes_rebase(self):
        data = struct.pack("<Q", IMAGE_BASE + 0x4008)
        pe = p2m.PE(build_pe([(".text", 0x4000, b"\xc0\x03\x5f\xd6", TEXT),
                              (".data", 0x8000, data, DATA)], relocs=[0x8000]))
        self.assertEqual(pe.relocations(), [0x8000])
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "x.s")
            p2m.write_asm(pe, "pe_x", out)
            with open(out) as fh:
                asm = fh.read()
            with open(os.path.join(tmp, "x.ldflags")) as fh:
                flags = fh.read().split()
        self.assertIn("\t.quad _pe_x_image + 0x4008\n", asm)
        self.assertEqual(pe.pointer_target(0x8000), 0x4008)
        self.assertEqual(asm.count(".section"), 3)
        self.assertEqual(flags, ["-Wl,-segprot,__PE0,rw,rw", "-Wl,-segprot,__PE1,rx,rx", "-Wl,-segprot,__PE2,rw,rw"])

    def test_zero_runs_are_compact(self):
        pe = p2m.PE(build_pe([(".text", 0x4000, b"\xc0\x03\x5f\xd6", TEXT),
                              (".data", 0x8000, b"\0" * 0x1000 + b"x", DATA)]))
        with tempfile.TemporaryDirectory() as tmp:
            out = os.path.join(tmp, "x.s")
            p2m.write_asm(pe, "pe_x", out)
            with open(out) as fh:
                asm = fh.read()
        self.assertIn("\t.zero 4096\n\t.byte 120,0,", asm)
        self.assertLess(len(asm), 4000)

    def test_relocation_list(self):
        data = struct.pack("<QQ", IMAGE_BASE + 0x4000, IMAGE_BASE + 0x8010)
        dll = build_pe([(".text", 0x4000, b"\xc0\x03\x5f\xd6", TEXT),
                        (".data", 0x8000, data, DATA)], relocs=[0x8000, 0x8008])
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "x.dll")
            with open(path, "wb") as fh:
                fh.write(dll)
            sys.argv = ["pe2macho.py", "--relocs", path, os.path.join(tmp, "r.txt")]
            self.assertEqual(p2m.main(), 0)
            with open(os.path.join(tmp, "r.txt")) as fh:
                self.assertEqual(fh.read(), "8000 4000\n8008 8010\n")

    def test_relocation_in_code_is_an_error(self):
        pe = p2m.PE(build_pe([(".text", 0x4000, struct.pack("<Q", IMAGE_BASE), TEXT)], relocs=[0x4000]))
        with tempfile.TemporaryDirectory() as tmp:
            with self.assertRaisesRegex(p2m.PEError, "executable section .text"):
                p2m.write_asm(pe, "pe_x", os.path.join(tmp, "x.s"))

    def test_section_must_be_page_aligned(self):
        with self.assertRaisesRegex(p2m.PEError, "not aligned"):
            p2m.PE(build_pe([(".text", 0x1000, b"\xc0\x03\x5f\xd6", TEXT)]))

    def test_rejects_x86(self):
        data = bytearray(build_pe([(".text", 0x4000, b"\xc3", TEXT)]))
        struct.pack_into("<H", data, 0x80 + 4, 0x8664)
        with self.assertRaisesRegex(p2m.PEError, "not ARM64"):
            p2m.PE(bytes(data))

    def test_default_prefix(self):
        self.assertEqual(p2m.default_prefix("/x/kernel32.dll"), "pe_kernel32")
        self.assertEqual(p2m.default_prefix("d3d-11.dll"), "pe_d3d_11")


if __name__ == "__main__":
    unittest.main()
