#!/usr/bin/env python3
"""Unit tests for fix_syscall_stubs on small PE images (no toolchain)."""
import os
import struct
import sys
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import fix_syscall_stubs as fss  # noqa: E402
import pe2macho as p2m  # noqa: E402
from test_pe2macho import DATA, IMAGE_BASE, TEXT, build_pe  # noqa: E402

DISPATCHER = 0xC0BC8  # RVA of __wine_syscall_dispatcher in .data


def stub(syscall_id):
    return struct.pack("<6IQ", fss.MOV_X8 | (syscall_id << 5), fss.MOV_X9_X30, fss.LDR_X16_LIT16,
                       fss.LDR_X16_X16, fss.BLR_X16, fss.RET, IMAGE_BASE + DISPATCHER)


def ntdll(code, relocs):
    return build_pe([(".text", 0x4000, code, TEXT), (".data", 0xC0000, b"\0" * 0x1000, DATA)], relocs=relocs)


class FixSyscallStubsTest(unittest.TestCase):
    def test_stubs_are_rewritten(self):
        dll = ntdll(stub(15) + stub(16), [0x4018, 0x4038])
        fixed, n = fss.fix(dll)
        self.assertEqual(n, 2)
        self.assertEqual(len(fixed), len(dll))
        pe = p2m.PE(fixed)
        self.assertEqual(pe.relocations(), [])
        for at in (0x4000, 0x4020):
            self.assertEqual(fss.stub_target(pe.image, at), DISPATCHER)
            ins = struct.unpack_from("<6I", pe.image, at)
            self.assertEqual(ins[3] & 0xFFC003FF, fss.LDR_X16_X16)  # Wine's tests/virtual.c pattern
            self.assertEqual(ins[4:], (fss.BLR_X16, fss.RET))
        self.assertEqual(struct.unpack_from("<I", pe.image, 0x4000)[0], fss.MOV_X8 | (15 << 5))

    def test_adrp_encoding(self):
        # adrp x16, 0x1800c0000 at 0x180064e08, as llvm-objdump decodes Madeira's fixed ntdll.
        self.assertEqual(fss.adrp_x16(0x64E08, 0xC0BC8), 0x900002F0)
        self.assertEqual(fss.ldr_x16_lo12(0xC0BC8), 0xF945E610)

    def test_other_code_relocation_is_refused(self):
        code = stub(15)[:-8] + struct.pack("<Q", IMAGE_BASE + DISPATCHER) + struct.pack("<Q", IMAGE_BASE)
        with self.assertRaisesRegex(p2m.PEError, "not in a Wine aarch64 syscall stub"):
            fss.fix(ntdll(code, [0x4018, 0x4020]))

    def test_data_relocations_stay(self):
        dll = build_pe([(".text", 0x4000, stub(1), TEXT),
                        (".data", 0xC0000, struct.pack("<Q", IMAGE_BASE + 0x4000), DATA)],
                       relocs=[0x4018, 0xC0000])
        fixed, _ = fss.fix(dll)
        self.assertEqual(p2m.PE(fixed).relocations(), [0xC0000])


if __name__ == "__main__":
    unittest.main()
