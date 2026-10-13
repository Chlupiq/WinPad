"""Unit test for cache2macho with a synthetic AOT cache laid out like CodeCache::SaveData."""
import os
import struct
import sys
import unittest

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, here)
sys.path.insert(0, os.path.join(here, "..", "fxcc-inspect"))
import cache2macho as c2m  # noqa: E402
from test_fxcc_inspect import build_cache  # noqa: E402

ADRP_X0 = 0x90000000
LDR_X0 = 0xF9400000
ADD_X0 = 0x91000000
DATA_SLOT, LINK_RECORD, BLOCK_TAIL, GUEST_RIP_MOVE = 8, 9, 10, 3


def aot_code():
    code = bytearray(b"\x1f\x20\x03\xd5" * 32)  # nop
    struct.pack_into("<I", code, 0, 0x60)  # block header: OffsetToBlockTail
    struct.pack_into("<II", code, 0x10, ADRP_X0 | (1 << 5), LDR_X0 | (1 << 10))  # stored immediates
    struct.pack_into("<II", code, 0x20, ADRP_X0, ADD_X0 | (8 << 10))
    return bytes(code)


def unpack_relocs(obj):
    seg = 32
    nsects = struct.unpack_from("<I", obj, seg + 64)[0]
    for i in range(nsects):
        s = seg + 72 + 80 * i
        if obj[s:s + 16].rstrip(b"\0") == b"__fexaot_text":
            reloff, nreloc = struct.unpack_from("<II", obj, s + 56)
            out = []
            for j in range(nreloc):
                addr, word = struct.unpack_from("<iI", obj, reloff + 8 * j)
                out.append((addr, word >> 28, word & 0xFFFFFF))
            return out
    raise AssertionError("no text section")


class ConvertTest(unittest.TestCase):
    def test_relocations_and_cleared_immediates(self):
        tail = struct.pack("<IQI", 16, 0x1000, 0x60)
        data = build_cache(
            blocks=[(0x1000, 4, [0x1000])],
            relocs=[(0x10, DATA_SLOT, b""), (0x20, LINK_RECORD, b""), (0x60, BLOCK_TAIL, tail)],
            code=aot_code(),
        )
        obj, stats = c2m.convert(data, "t", "15.0")
        self.assertEqual(stats["data_bytes"], 8 + 24 + 16)
        relocs = unpack_relocs(obj)
        types = [t for _, t, _ in relocs]
        # slot 0: PAGE21 + PAGEOFF12; link record at +8: ADDEND before each; tail: SUBTRACTOR + UNSIGNED
        self.assertEqual(types, [c2m.ARM64_RELOC_PAGE21, c2m.ARM64_RELOC_PAGEOFF12,
                                 c2m.ARM64_RELOC_ADDEND, c2m.ARM64_RELOC_PAGE21,
                                 c2m.ARM64_RELOC_ADDEND, c2m.ARM64_RELOC_PAGEOFF12,
                                 c2m.ARM64_RELOC_SUBTRACTOR, c2m.ARM64_RELOC_UNSIGNED])
        self.assertEqual(relocs[2][2], 8)
        text_off = obj.index(struct.pack("<II", ADRP_X0, LDR_X0))  # immediates cleared
        self.assertEqual(struct.unpack_from("<i", obj, text_off - 0x10)[0], 32 - 0)  # tail slot 32 minus header 0

    def test_elf_asm_references_data_area(self):
        tail = struct.pack("<IQI", 16, 0x1000, 0x60)
        data = build_cache(
            blocks=[(0x1000, 4, [0x1000])],
            relocs=[(0x10, DATA_SLOT, b""), (0x20, LINK_RECORD, b""), (0x60, BLOCK_TAIL, tail)],
            code=aot_code(),
        )
        text, stats = c2m.convert_elf_asm(data, "t")
        lines = [line.strip() for line in text.splitlines()]
        self.assertEqual(stats["relocations"], 5)
        self.assertEqual(lines.count(".word .Lfexaot_data+32-."), 1)  # header at code+0
        self.assertIn("adrp x0, .Lfexaot_data+0", lines)
        self.assertIn("ldr x0, [x0, :lo12:.Lfexaot_data+0]", lines)
        self.assertIn("adrp x0, .Lfexaot_data+8", lines)
        self.assertIn("add x0, x0, :lo12:.Lfexaot_data+8", lines)
        self.assertIn(".zero 48", lines)

    def test_default_prefix(self):
        self.assertEqual(c2m.default_prefix("/c/guest-00000000deadbeef-0123456789abcdef"),
                         "fexaot_00000000deadbeef_0123456789abcdef")
        with self.assertRaises(c2m.ConvertError):
            c2m.default_prefix("guest.bin")

    def test_rejects_cache_that_patches_code(self):
        data = build_cache(blocks=[(0x1000, 0, [])], relocs=[(0x10, GUEST_RIP_MOVE, b"")], code=aot_code())
        with self.assertRaises(c2m.ConvertError):
            c2m.convert(data, "t", "15.0")


if __name__ == "__main__":
    unittest.main()
