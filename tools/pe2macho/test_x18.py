#!/usr/bin/env python3
"""Unit tests for the x18 rewrite (x18.py), with encodings checked against
llvm-mc. No toolchain needed."""
import os
import struct
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pe2macho as p2m  # noqa: E402
import x18  # noqa: E402
from test_pe2macho import DATA, TEXT, build_pe  # noqa: E402

# Instructions from Wine's ARM64 modules (llvm-mc encodings).
READS = {
    0xF9401A40: (x18.ROLE_RN, "mem"),   # ldr x0, [x18, #0x30]
    0xB9006A48: (x18.ROLE_RN, "mem"),   # str w8, [x18, #0x68]
    0xB8616A40: (x18.ROLE_RN, "mem"),   # ldr w0, [x18, x1]
    0xAA1203E0: (x18.ROLE_RM, "mov"),   # mov x0, x18
    0x9101A240: (x18.ROLE_RN, "addi"),  # add x0, x18, #0x68
    0xA9004811: (x18.ROLE_RT2, "pair"), # stp x17, x18, [x0]
    0xA9409646: (x18.ROLE_RN, "pair"),  # ldp x6, x5, [x18, #8]
    0x8B080240: (x18.ROLE_RN, "addr"),  # add x0, x18, x8
}
NOT_READS = (
    0xAD44CBF5,  # ldp q21, q18, [sp, #0x90]: q18 is not x18
    0x2D0ACBF1,  # stp s17, s18, [sp, #0x54]
    0xF9400240 & ~(31 << 5) | (1 << 5),  # ldr x0, [x1]
    0xD65F03C0,  # ret
)


class X18Test(unittest.TestCase):
    def test_classify(self):
        for insn, want in READS.items():
            self.assertEqual(x18.classify(insn), want, hex(insn))
        for insn in NOT_READS:
            self.assertEqual(x18.classify(insn)[0], x18.ROLE_NONE, hex(insn))

    def test_trampoline_encoding(self):
        # str w8, [x18, #0x68] at 0x234a4, trampoline at 0x174000, slot at 0x184000.
        words = struct.unpack("<9I", x18.trampoline(0xB9006A48, x18.ROLE_RN, 17, 16, 0x174000, 0x234A8, 0x184000))
        self.assertEqual(words, (
            0xA9BF43F1,  # stp x17, x16, [sp, #-16]!
            0xD53BD071,  # mrs x17, TPIDRRO_EL0
            0x927DF231,  # and x17, x17, #0xfffffffffffffff8
            0x90000090,  # adrp x16, (page + 0x10000)
            0xF9400210,  # ldr x16, [x16]
            0xF8706A31,  # ldr x17, [x17, x16]
            0xB9006A28,  # str w8, [x17, #0x68]
            0xA8C143F1,  # ldp x17, x16, [sp], #16
            x18.branch(0x174020, 0x234A8),
        ))

    def test_scratch_avoids_operands(self):
        # ldr w0, [x18, x17]: x17 is taken, so the trampoline uses x16 and x15.
        image = bytearray(0x8000)
        struct.pack_into("<I", image, 0x4000, 0xB8716A40)
        tramps, n, skipped = x18.rewrite(image, [(0x4000, 4)], 0x8000, 0xC000)
        self.assertEqual((n, skipped), (1, []))
        first, insn = struct.unpack_from("<I", tramps, 0)[0], struct.unpack_from("<I", tramps, 24)[0]
        self.assertEqual(first, 0xA9BF3FF0)  # stp x16, x15, [sp, #-16]!
        self.assertEqual(insn, 0xB8716A00)   # ldr w0, [x16, x17]

    def test_sp_forms_are_skipped(self):
        image = bytearray(0x8000)
        struct.pack_into("<I", image, 0x4000, 0xB8726BE0)  # ldr w0, [sp, x18]
        _, n, skipped = x18.rewrite(image, [(0x4000, 4)], 0x8000, 0xC000)
        self.assertEqual((n, skipped), (0, [(0x4000, 0xB8726BE0)]))

    def test_literal_pool_is_data(self):
        # ldr x16, .+8 ; ret ; <8 bytes that decode as ldr x0, [x18, #0x30]>
        image = bytearray(0x8000)
        struct.pack_into("<IIII", image, 0x4000, 0x58000050, 0xD65F03C0, 0xF9401A40, 0)
        _, n, _ = x18.rewrite(image, [(0x4000, 16)], 0x8000, 0xC000)
        self.assertEqual(n, 0)

    def test_pe_gets_trampoline_and_slot_segments(self):
        code = struct.pack("<II", 0xF9401A40, 0xD65F03C0)  # ldr x0, [x18, #0x30]; ret
        pe = p2m.PE(build_pe([(".text", 0x4000, code, TEXT), (".data", 0x8000, b"x", DATA)]))
        pe.rewrite_x18()
        self.assertEqual(pe.x18_patched, 1)
        self.assertEqual(pe.groups()[-2:], [(0xC000, 0x10000, True), (0x10000, 0x14000, False)])
        self.assertEqual(pe.teb_slot_rva, 0x10000)
        self.assertEqual(struct.unpack_from("<I", pe.image, pe.opt + 56)[0], 0x14000)  # SizeOfImage
        self.assertEqual(struct.unpack_from("<I", pe.image, 0x4000)[0], x18.branch(0x4000, 0xC000))
        self.assertEqual(struct.unpack_from("<I", pe.image, 0xC000 + 32)[0], x18.branch(0xC020, 0x4004))

    def test_pe_without_x18_is_unchanged(self):
        pe = p2m.PE(build_pe([(".text", 0x4000, struct.pack("<I", 0xD65F03C0), TEXT)]))
        before = bytes(pe.image)
        pe.rewrite_x18()
        self.assertEqual((bytes(pe.image), pe.extra_groups, pe.teb_slot_rva), (before, [], None))


if __name__ == "__main__":
    unittest.main()
