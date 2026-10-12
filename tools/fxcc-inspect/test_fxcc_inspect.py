"""Unit test for fxcc_inspect with a synthetic cache file laid out like CodeCache::SaveData."""
import os
import struct
import sys
import unittest

sys.path.insert(0, os.path.dirname(__file__))
import fxcc_inspect as fi  # noqa: E402


def build_cache(blocks, relocs, code):
    out = bytearray(fi.HEADER.pack(b"FXCC", 2, b"\0" * 20, len(blocks), 1, len(code), len(relocs), 0, 0x10000))
    for guest, host, pages in blocks:
        out += struct.pack("<QQQ", guest, host, len(pages))
        for p in pages:
            out += struct.pack("<Q", p)
    for offset, rtype, extra in relocs:
        entry = fi.RELOC_HEADER.pack(offset, rtype) + extra
        out += entry.ljust(fi.RELOC_SIZE, b"\0")
    out += b"\0" * (fi.align_up(len(out), fi.PAGE) - len(out))
    out += code
    return bytes(out)


class ParseTest(unittest.TestCase):
    def test_counts(self):
        data = build_cache(
            blocks=[(0x1000, 0, [0x1000]), (0x1040, 0x80, [0x1000, 0x2000])],
            relocs=[(0x10, 0, struct.pack("<I", 0)), (0x20, 0, struct.pack("<I", 0)), (0x30, 3, b"")],
            code=b"\x1f\x20\x03\xd5" * 64,
        )
        r = fi.parse(data)
        self.assertEqual(r["blocks"], 2)
        self.assertEqual(r["code_bytes"], 256)
        self.assertEqual(r["relocations"], 3)
        self.assertEqual(r["relocations_by_type"], {"NAMED_SYMBOL_LITERAL": 2, "GUEST_RIP_MOVE": 1})
        self.assertEqual(r["named_symbols"], {"EXITFUNCTION_LINKER": 2})
        self.assertEqual(r["code_patches_on_load"], 3)

    def test_data_slots_do_not_patch_code(self):
        data = build_cache(
            blocks=[(0x1000, 0, [0x1000])],
            relocs=[(0x10, 8, b""), (0x20, 8, b""), (0x28, 9, b""), (0x30, 2, b""), (0x38, 10, b"")],
            code=b"\x1f\x20\x03\xd5" * 16,
        )
        r = fi.parse(data)
        self.assertEqual(
            r["relocations_by_type"], {"GUEST_RIP_DATA_SLOT": 2, "GUEST_RIP_LINK_RECORD": 1, "GUEST_RIP_LITERAL": 1, "AOT_BLOCK_TAIL": 1}
        )
        self.assertEqual(r["code_patches_on_load"], 1)

    def test_bad_magic(self):
        data = bytearray(build_cache([], [], b""))
        data[0:4] = b"XXXX"
        with self.assertRaises(fi.FormatError):
            fi.parse(bytes(data))

    def test_truncated_code(self):
        data = build_cache([(0, 0, [])], [], b"\0" * 64)
        with self.assertRaises(fi.FormatError):
            fi.parse(data[:-1])


if __name__ == "__main__":
    unittest.main()
