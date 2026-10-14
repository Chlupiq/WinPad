#!/usr/bin/env python3
"""Rewrite the aarch64 syscall stubs of an already built Wine module (ntdll,
win32u) so its code has no base relocations, without rebuilding Wine.

patches/wine/0001-aarch64-syscall-stubs-adrp.patch does this in the source;
this tool does the same to the binaries Madeira ships. Each stub is

    mov  x8, #id
    mov  x9, x30
    ldr  x16, 1f              ; literal address of __wine_syscall_dispatcher
    ldr  x16, [x16]
    blr  x16
    ret
 1: .quad __wine_syscall_dispatcher   ; DIR64 base relocation in .text

and becomes

    mov  x8, #id
    mov  x9, x30
    adrp x16, __wine_syscall_dispatcher
    ldr  x16, [x16, :lo12:__wine_syscall_dispatcher]
    blr  x16
    ret
    .quad 0                   ; unused, no relocation

The relocation entries of the literals become IMAGE_REL_BASED_ABSOLUTE
(padding), so the layout of the file and of the .reloc section stay the
same. Anything in a code section that is not exactly such a stub makes the
tool fail; it never guesses.

Usage: fix_syscall_stubs.py IN.dll OUT.dll
"""
import os
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import pe2macho as p2m  # noqa: E402

MOV_X8_MASK, MOV_X8 = 0xFFE0001F, 0xD2800008
MOV_X9_X30 = 0xAA1E03E9
LDR_X16_LIT16 = 0x58000090  # ldr x16, .+16
LDR_X16_X16 = 0xF9400210
BLR_X16 = 0xD63F0200
RET = 0xD65F03C0


def adrp_x16(pc, target):
    delta = (target >> 12) - (pc >> 12)
    if not -(1 << 20) <= delta < (1 << 20):
        raise p2m.PEError(f"adrp at RVA {pc:#x} cannot reach RVA {target:#x}")
    delta &= (1 << 21) - 1
    return 0x90000000 | ((delta & 3) << 29) | ((delta >> 2) << 5) | 16


def ldr_x16_lo12(target):
    if target % 8:
        raise p2m.PEError(f"__wine_syscall_dispatcher at RVA {target:#x} is not 8-byte aligned")
    return LDR_X16_X16 | (((target & 0xFFF) // 8) << 10)


def stub_target(image, stub):
    """The RVA a rewritten stub at RVA `stub` loads the dispatcher from."""
    adrp, ldr = struct.unpack_from("<II", image, stub + 8)
    delta = ((adrp >> 29) & 3) | (((adrp >> 5) & 0x7FFFF) << 2)
    if delta & (1 << 20):
        delta -= 1 << 21
    return (((stub + 8) >> 12) + delta << 12) + ((ldr >> 10) & 0xFFF) * 8


def file_offset(pe, rva):
    s = pe.section_at(rva)
    if s is None or rva - s.rva >= s.raw_size:
        raise p2m.PEError(f"RVA {rva:#x} has no bytes in the file")
    return s.raw_off + rva - s.rva


def fix(data):
    """The fixed file and the number of stubs rewritten."""
    pe = p2m.PE(bytes(data))
    out = bytearray(data)
    code_relocs = {r for r in pe.relocations() if pe.section_at(r).executable}
    for lit in sorted(code_relocs):
        stub = lit - 24
        ins = struct.unpack_from("<6I", pe.image, stub)
        if ((ins[0] & MOV_X8_MASK) != MOV_X8 or ins[1] != MOV_X9_X30 or ins[2] != LDR_X16_LIT16 or
                ins[3] != LDR_X16_X16 or ins[4] != BLR_X16 or ins[5] != RET):
            raise p2m.PEError(f"code relocation at RVA {lit:#x} is not in a Wine aarch64 syscall stub")
        target = pe.pointer_target(lit)
        off = file_offset(pe, stub)
        struct.pack_into("<II", out, off + 8, adrp_x16(stub + 8, target), ldr_x16_lo12(target))
        struct.pack_into("<Q", out, off + 24, 0)
    # Turn the literals' relocation entries into padding.
    rva, size = pe.dirs[p2m.IMAGE_DIRECTORY_ENTRY_BASERELOC]
    pos = rva
    while pos < rva + size:
        page, block = struct.unpack_from("<II", pe.image, pos)
        for i in range(8, block, 2):
            (entry,) = struct.unpack_from("<H", pe.image, pos + i)
            if entry >> 12 == p2m.IMAGE_REL_BASED_DIR64 and page + (entry & 0xFFF) in code_relocs:
                struct.pack_into("<H", out, file_offset(pe, pos + i), 0)
        pos += block
    # Read the result back like a loader would and check every stub.
    fixed = p2m.PE(bytes(out))
    if any(fixed.section_at(r).executable for r in fixed.relocations()):
        raise p2m.PEError("relocations left in code")
    for lit in code_relocs:
        stub = lit - 24
        if (fixed.image[stub:stub + 8] != pe.image[stub:stub + 8] or
                fixed.image[stub + 16:stub + 24] != pe.image[stub + 16:stub + 24] or
                stub_target(fixed.image, stub) != pe.pointer_target(lit)):
            raise p2m.PEError(f"rewritten stub at RVA {stub:#x} does not load the dispatcher")
    return bytes(out), len(code_relocs)


def main():
    if len(sys.argv) != 3:
        print(__doc__.strip().splitlines()[-1], file=sys.stderr)
        return 2
    with open(sys.argv[1], "rb") as fh:
        data = fh.read()
    try:
        fixed, n = fix(data)
    except p2m.PEError as e:
        print(f"{sys.argv[1]}: {e}", file=sys.stderr)
        return 1
    with open(sys.argv[2], "wb") as fh:
        fh.write(fixed)
    print(f"{sys.argv[2]}: {n} syscall stubs load the dispatcher with adrp/ldr")
    return 0


if __name__ == "__main__":
    sys.exit(main())
