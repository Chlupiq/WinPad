"""Finds the code of a 32-bit x86 PE image ahead of time and writes it as a FEX code map.

A recorded code map only holds the blocks a run reached, so a NoJIT run of a
large program (a game) meets new code at every new screen and interprets it
slowly until the next round of recording and compiling. This walks the
image's code statically instead, so that one offline compile covers most of
it.

Usage: discover.py IMAGE.EXE MAP OUT [--no-data-pointers] [--max N] [--check] [--no-recorded]

  IMAGE.EXE  the PE file the maps name (the same bytes the guest maps)
  MAP        a recorded code map (or a directory of them) that names IMAGE;
             its image record (file id and path) is copied to OUT, and its
             blocks of IMAGE seed the walk
  OUT        the code map to write: IMAGE's record, the main-executable
             record if MAP had one for it, and one entry per discovered
             block start (offsets relative to the image base, as FEX
             records them)

The walk is a recursive descent with Capstone from the entry point, the
exports and the recorded blocks. It follows direct calls and jumps inside
executable sections and stops at returns, indirect jumps, int3 and anything
that does not decode. Block starts it writes are function entries (direct
call targets), return addresses (the instruction after each call), direct
jump targets that leave the current function (tail calls), immediate
operands that point into code and decode cleanly to a return or jump (a
window procedure stored into a WNDCLASS, a thread start routine), and,
unless --no-data-pointers, addresses found as 32-bit values in the image's data
(vtables, jump and callback tables) whose code decodes cleanly to a
return or jump. Conditional branch targets are not written: FEX compiles
them into the block of the function that holds them.

--no-recorded leaves the recorded blocks out (as seeds and in OUT), so that a
cache built from OUT shows what the static walk alone covers.

--check walks without the recorded blocks as seeds first and prints how many
of them the static walk found on its own (how far to trust it for code no
run reached yet).

Needs the Python packages capstone and pefile.
"""
import os
import struct
import sys

import capstone
import pefile

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from codemap import ENTRY, LIBRARY, SET_MAIN, parse  # noqa: E402

HALF_BARRIER = 0x80000000
# Instructions that never appear in user-mode game code; a data pointer
# whose code reaches one of them is data, not code.
PRIVILEGED = {"hlt", "cli", "sti", "in", "out", "insb", "insd", "outsb", "outsd",
              "lgdt", "lidt", "lldt", "ltr", "invd", "wbinvd", "iretd", "retf"}


def map_files(path):
    if os.path.isdir(path):
        return [os.path.join(path, n) for n in sorted(os.listdir(path)) if not n.startswith(".")]
    return [path]


def image_record(maps, image_name):
    """Returns (file id, raw LIBRARY record, is main, recorded offsets) of the image."""
    want = image_name.lower()
    found = None
    offsets = set()
    for path in maps:
        with open(path, "rb") as f:
            data = f.read()
        names, blocks, main_id, _ = parse(data)
        for file_id, name in names.items():
            if name.replace("/", "\\").lower().rsplit("\\", 1)[-1] != want:
                continue
            if found is None:
                pos = 0
                while pos + ENTRY.size <= len(data):
                    entry = ENTRY.unpack_from(data, pos)
                    if entry == LIBRARY:
                        (fid,) = struct.unpack_from("<Q", data, pos + ENTRY.size)
                        end = data.index(b"\0", pos + ENTRY.size + 8)
                        nxt = (end + 1 + 3) & ~3
                        if fid == file_id:
                            found = (file_id, data[pos:nxt], main_id == file_id)
                            break
                        pos = nxt
                    elif entry == SET_MAIN:
                        pos += ENTRY.size + 8
                    else:
                        pos += ENTRY.size
            if found and file_id == found[0]:
                offsets |= {o & ~HALF_BARRIER for o in blocks.get(file_id, ())}
    if found is None:
        sys.exit(f"discover: no map in {maps[0] if len(maps) == 1 else 'the maps'} names {image_name}")
    return found + (offsets,)


class Image:
    def __init__(self, path):
        self.pe = pefile.PE(path, fast_load=False)
        if self.pe.FILE_HEADER.Machine != 0x14C:
            sys.exit(f"discover: {path} is not a 32-bit x86 image")
        self.base = self.pe.OPTIONAL_HEADER.ImageBase
        self.mem = self.pe.get_memory_mapped_image()
        self.code = []  # (start rva, end rva)
        self.data = []
        for s in self.pe.sections:
            span = (s.VirtualAddress, s.VirtualAddress + max(s.Misc_VirtualSize, s.SizeOfRawData))
            if s.Characteristics & 0x20000000:  # IMAGE_SCN_MEM_EXECUTE
                self.code.append(span)
            else:
                self.data.append(span)
        self.md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
        self.md.skipdata = False
        self.md.detail = True  # immediate operands

    def is_code(self, rva):
        return any(a <= rva < b for a, b in self.code)

    def decode(self, rva, limit=16):
        return next(self.md.disasm(self.mem[rva:rva + limit], self.base + rva, 1), None)


def target_of(insn):
    if insn.op_str.startswith("0x"):
        try:
            return int(insn.op_str, 16)
        except ValueError:
            return None
    return None


def walk(img, seeds, max_blocks):
    """Recursive descent; returns the set of block-start rvas."""
    starts = set()
    seen = set()
    # (rva, block start?) -- conditional-branch targets are walked but are
    # not block starts.
    work = [(s, True) for s in seeds]
    while work and len(starts) < max_blocks:
        rva, start = work.pop()
        if not img.is_code(rva):
            continue
        if start:
            starts.add(rva)
        pc = rva
        while img.is_code(pc) and pc not in seen:
            insn = img.decode(pc)
            if insn is None:
                break
            seen.add(pc)
            nxt = pc + insn.size
            m = insn.mnemonic
            t = target_of(insn)
            if m == "call":
                if t is not None:
                    work.append((t - img.base, True))
                # FEX enters the dispatcher again at the return address.
                work.append((nxt, True))
                break
            if m == "jmp":
                if t is not None:
                    work.append((t - img.base, True))
                break
            if m.startswith("j") or m.startswith("loop") or m == "jecxz":
                if t is not None:
                    work.append((t - img.base, False))
                pc = nxt
                continue
            if m in ("ret", "retn", "int3", "ud2") or m in PRIVILEGED:
                break
            # Code addresses as immediates (mov [wc.lpfnWndProc], proc;
            # push proc) are entered later through a pointer.
            for op in insn.operands:
                if op.type == capstone.x86.X86_OP_IMM:
                    target = (op.imm & 0xFFFFFFFF) - img.base
                    if target not in seen and img.is_code(target) and plausible(img, target):
                        work.append((target, True))
            pc = nxt
    return starts


def plausible(img, rva, budget=400):
    """True if code at rva decodes cleanly to a return or jump."""
    pc = rva
    for _ in range(budget):
        if not img.is_code(pc):
            return False
        insn = img.decode(pc)
        if insn is None or insn.mnemonic in PRIVILEGED:
            return False
        if insn.mnemonic in ("ret", "retn", "jmp"):
            return True
        if insn.mnemonic in ("int3", "ud2"):
            return False
        pc += insn.size
    return False


def data_pointers(img):
    found = set()
    for a, b in img.data:
        chunk = img.mem[a:b]
        for off in range(0, len(chunk) - 3, 4):
            (v,) = struct.unpack_from("<I", chunk, off)
            rva = v - img.base
            if 0 <= rva < len(img.mem) and img.is_code(rva):
                found.add(rva)
    return found


def main(argv):
    args = [a for a in argv if not a.startswith("--")]
    use_data = "--no-data-pointers" not in argv
    check = "--check" in argv
    no_recorded = "--no-recorded" in argv
    max_blocks = 1 << 30
    if "--max" in argv:
        max_blocks = int(argv[argv.index("--max") + 1])
        args.remove(str(max_blocks))
    if len(args) != 3:
        print(__doc__)
        return 2
    image_path, map_path, out_path = args
    img = Image(image_path)
    file_id, record, is_main, recorded = image_record(map_files(map_path), os.path.basename(image_path))

    seeds = {img.pe.OPTIONAL_HEADER.AddressOfEntryPoint}
    if hasattr(img.pe, "DIRECTORY_ENTRY_EXPORT"):
        seeds |= {e.address for e in img.pe.DIRECTORY_ENTRY_EXPORT.symbols if img.is_code(e.address)}
    pointers = set()
    if use_data:
        pointers = {p for p in data_pointers(img) if plausible(img, p)}
        seeds |= pointers
    if check and recorded:
        alone = walk(img, sorted(seeds, reverse=True), max_blocks)
        hit = len(recorded & alone)
        print(f"check: the walk without recorded seeds finds {hit} of {len(recorded)} recorded blocks "
              f"({100 * hit // len(recorded)}%), {len(alone)} block starts in all")
    if not no_recorded:
        seeds |= recorded
    starts = walk(img, sorted(seeds, reverse=True), max_blocks)
    if not no_recorded:
        starts |= {s for s in recorded if img.is_code(s)}

    out = bytearray(record)
    if is_main:
        out += ENTRY.pack(*SET_MAIN) + struct.pack("<Q", file_id)
    for rva in sorted(starts):
        out += ENTRY.pack(file_id, rva)
    with open(out_path, "wb") as f:
        f.write(out)
    code_bytes = sum(b - a for a, b in img.code)
    print(f"{out_path}: {len(starts)} block starts in {os.path.basename(image_path)} "
          f"({len(recorded)} recorded, {len(pointers)} from data pointers, "
          f"{code_bytes // 1024} KB of code sections)")
    missing = sorted(recorded - starts)
    if missing and not no_recorded:
        print("  recorded blocks outside the code sections: " + " ".join(f"{o:#x}" for o in missing[:20]))
    return 0 if starts else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
