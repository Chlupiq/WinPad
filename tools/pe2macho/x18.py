"""Rewrite the x18 (TEB) accesses of ARM64 Windows code before it is signed.

Windows keeps the TEB pointer in x18. Darwin reserves x18 as the platform
register and zeroes it on context switches, so Windows code reading the TEB
through x18 finds 0. Madeira patches every such instruction at load time:
a B to a trampoline that loads the TEB from a TSD slot (TPIDRRO_EL0, which
Darwin preserves) and performs the instruction with that register instead
(ios_jit_patch_x18 in Madeira's build/ntdll-unix/virtual_ios.c). Code in a
signed dylib cannot be patched at load time, so pe2macho does the same
rewrite when it builds the dylib.

The classifier (which instructions read x18, and in which field) and the
literal-pool guard follow Madeira's patcher. The trampolines differ in one
way: the TSD slot holding the TEB is only known at run time (it belongs to a
pthread key), so they load the slot's offset from a data word the loader
fills in after dlopen (_PREFIX_teb_slot, see pe2macho), instead of having it
encoded in an instruction.

A trampoline, with A and B two registers the instruction does not use:

    stp  xA, xB, [sp, #-16]!
    mrs  xA, TPIDRRO_EL0
    and  xA, xA, #~7            ; low bits hold the CPU number
    adrp xB, teb_slot
    ldr  xB, [xB, :lo12:teb_slot]
    ldr  xA, [xA, xB]           ; the TEB
    <the instruction with x18 replaced by xA>
    ldp  xA, xB, [sp], #16
    b    <the next instruction>

None of these instructions changes the flags.

One deliberate difference from Madeira's classifier: an LDP/STP of SIMD
registers (q18, d18, s18 in the Rt2 field) does not touch x18 and is left
alone; Madeira rewrites it, which would change the register pair. An instruction that also
addresses through sp is left alone (the trampoline moves sp); it is counted
as skipped, like an instruction with no free scratch register.
"""
import struct

ROLE_NONE, ROLE_RN, ROLE_RM, ROLE_RT2 = 0, 1, 2, 3
TRAMPOLINE_SIZE = 9 * 4
SCRATCH = (17, 16, 15, 14, 13, 12, 11, 10, 9)


def classify(insn):
    """(role, kind): which field of `insn` reads x18 (ROLE_*, as Madeira's
    ios_insn_x18_role) and the instruction class ("mem", "pair", "mov",
    "addi", "addr"), or (ROLE_NONE, None)."""
    rn, rm, rt2 = (insn >> 5) & 31, (insn >> 16) & 31, (insn >> 10) & 31
    if 18 not in (rn, rm, rt2):
        return ROLE_NONE, None
    top8, top11 = insn >> 24, insn >> 21
    # LDR/STR (unsigned immediate), any size
    if top8 & 0x3F in (0x39, 0x3D) and rn == 18:
        return ROLE_RN, "mem"
    # LDR/STR (register offset)
    if top11 & 0x1F9 == 0x1C1 and (insn >> 10) & 3 == 2:
        if rn == 18:
            return ROLE_RN, "mem"
        if rm == 18:
            return ROLE_RM, "mem"
    # LDR/STR (pre/post-indexed, unscaled)
    if top11 & 0x3E7 == 0x1C0 and rn == 18:
        return ROLE_RN, "mem"
    # LDP/STP
    if top8 & 0x3E in (0x28, 0x2C, 0xA8, 0xAC, 0x68, 0x6C):
        if rn == 18:
            return ROLE_RN, "pair"
        # Rt2 is x18 only in the integer forms; with V set it is q18/d18/s18
        # (Madeira's classifier rewrites those too, see the module docstring).
        if rt2 == 18 and not insn >> 26 & 1:
            return ROLE_RT2, "pair"
    # MOV (register) = ORR Rd, XZR, Rm
    if top11 & 0x7FF in (0x150, 0x550) and rm == 18:
        return ROLE_RM, "mov"
    # ADD/SUB (immediate)
    if top8 & 0x5F == 0x11 and rn == 18:
        return ROLE_RN, "addi"
    # ADD/SUB (shifted register)
    if top8 & 0x5F == 0x0B:
        if rn == 18:
            return ROLE_RN, "addr"
        if rm == 18:
            return ROLE_RM, "addr"
    return ROLE_NONE, None


def uses_sp(insn, kind):
    """Whether register number 31 in `insn` means sp (the trampoline moves sp)."""
    rd, rn = insn & 31, (insn >> 5) & 31
    if kind in ("mem", "pair"):
        return rn == 31  # base register; 31 as a data register is xzr
    if kind == "addi" or kind == "addr" and insn >> 21 & 1:
        return 31 in (rd, rn)  # ADD/SUB immediate and extended register: 31 is sp
    return False  # ORR and shifted-register ADD/SUB read 31 as xzr


def replace(insn, which, reg):
    shift = {ROLE_RN: 5, ROLE_RM: 16, ROLE_RT2: 10}[which]
    return (insn & ~(31 << shift)) | (reg << shift)


def literal_words(code):
    """Word offsets in `code` that LDR (literal) instructions read: data, not code."""
    data = set()
    for i in range(0, len(code) - 3, 4):
        (insn,) = struct.unpack_from("<I", code, i)
        size = {0x18: 4, 0x1C: 4, 0x98: 4, 0x58: 8, 0x5C: 8, 0xD8: 8, 0x9C: 16}.get(insn >> 24)
        if size is None:
            continue
        imm19 = ((insn >> 5) & 0x7FFFF) - ((insn >> 5) & 0x40000) * 2
        target = i + imm19 * 4
        if 0 <= target < len(code):
            data.update(range(target, min(target + size, len(code)), 4))
    return data


def branch(pc, target):
    delta = target - pc
    if delta % 4 or not -(1 << 27) <= delta < (1 << 27):
        raise ValueError(f"branch from {pc:#x} to {target:#x} is out of reach")
    return 0x14000000 | ((delta >> 2) & 0x3FFFFFF)


def adrp(reg, pc, target):
    delta = (target >> 12) - (pc >> 12)
    return 0x90000000 | ((delta & 3) << 29) | (((delta >> 2) & 0x7FFFF) << 5) | reg


def trampoline(insn, which, a, b, at, back, slot):
    """The trampoline at RVA `at` for `insn`, returning to RVA `back`; the TEB
    slot offset is the 64-bit word at RVA `slot`."""
    words = [
        0xA9BF0000 | (b << 10) | (31 << 5) | a,          # stp xA, xB, [sp, #-16]!
        0xD53BD060 | a,                                   # mrs xA, TPIDRRO_EL0
        0x927DF000 | (a << 5) | a,                        # and xA, xA, #~7
        adrp(b, at + 12, slot),                           # adrp xB, slot
        0xF9400000 | (((slot & 0xFFF) // 8) << 10) | (b << 5) | b,  # ldr xB, [xB, :lo12:slot]
        0xF8606800 | (b << 16) | (a << 5) | a,            # ldr xA, [xA, xB]
        replace(insn, which, a),
        0xA8C10000 | (b << 10) | (31 << 5) | a,           # ldp xA, xB, [sp], #16
    ]
    words.append(branch(at + 4 * len(words), back))
    return struct.pack(f"<{len(words)}I", *words)


def rewrite(image, sections, tramp_rva, slot_rva):
    """Rewrite the x18 reads of the executable `sections` [(rva, size)] in
    `image` (a bytearray, changed in place). Returns (trampoline bytes for
    RVA tramp_rva, patched count, skipped [(rva, insn)])."""
    if slot_rva % 8:
        raise ValueError("the TEB slot word must be 8-byte aligned")
    tramps = bytearray()
    patched, skipped = 0, []
    for start, size in sections:
        code = bytes(image[start:start + size])
        data = literal_words(code)
        for i in range(0, len(code) - 3, 4):
            if i in data:
                continue
            (insn,) = struct.unpack_from("<I", code, i)
            which, kind = classify(insn)
            if which == ROLE_NONE:
                continue
            used = {insn & 31, (insn >> 5) & 31, (insn >> 16) & 31, (insn >> 10) & 31}
            free = [r for r in SCRATCH if r not in used]
            if uses_sp(insn, kind) or len(free) < 2:
                skipped.append((start + i, insn))
                continue
            at = tramp_rva + len(tramps)
            tramps += trampoline(insn, which, free[0], free[1], at, start + i + 4, slot_rva)
            struct.pack_into("<I", image, start + i, branch(start + i, at))
            patched += 1
    return bytes(tramps), patched, skipped
