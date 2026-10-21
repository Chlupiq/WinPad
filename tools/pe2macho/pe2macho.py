#!/usr/bin/env python3
"""Wrap a PE image (an ARM64 or ARM64EC Windows DLL, such as a Wine module)
into arm64 Mach-O assembly, so it can be linked into a signed dylib.

iOS only runs code from Mach-O files that dyld loaded and the code signature
covers. Wine on iOS copies PE modules into JIT memory instead; with the image
inside a dylib, dyld maps it and its code is ordinary signed code. Wine's
loader then only has to adopt the image that is already there (PLAN.md 2A).

The dylib keeps the PE layout: every byte of the image (headers included)
sits at its RVA from the symbol _PREFIX_image, so PC-relative code (adrp,
adr, b/bl) works unchanged. The sections are grouped, in RVA order, into one
Mach-O segment per run of sections with the same protection:
  executable sections  r-x
  all other sections   rw-  (Wine still writes the IAT and the like there)
Each segment is padded to the next group's RVA, so with the segments laid
out back to back each group starts at its RVA. The linker gets that order
and the protections from the flags pe2macho writes (OUT.ldflags); the
--check mode verifies the linked dylib.

Base relocations (IMAGE_REL_BASED_DIR64) become Mach-O relocations against
_PREFIX_image, so dyld rebases them for wherever the dylib lands and the PE
image needs no fix-up at load time. The header's ImageBase field is rebased
the same way, so it holds the address the image landed at, as if the loader
had mapped it there (Wine's loader reads it as the module's base). A
relocation in an executable section
is an error: the code pages are signed and cannot change (for Wine's aarch64
syscall stubs see tests/syscall-stubs).

Each export becomes a global symbol _PREFIX_export_NAME at its RVA.

Usage: pe2macho.py [--prefix NAME] DLL OUT.s     (also writes OUT.ldflags)
       pe2macho.py --check [--prefix NAME] DLL DYLIB
       pe2macho.py --relocs DLL OUT.txt   ("RVA TARGET_RVA" per rebased pointer)
PREFIX defaults to pe_<DLL name without extension>, with characters outside
[A-Za-z0-9_] replaced by _.
"""
import argparse
import os
import re
import struct
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import x18  # noqa: E402

PAGE = 1 << 14  # iOS page size; Wine aligns PE sections to 64 KiB

IMAGE_FILE_MACHINE_ARM64 = 0xAA64
IMAGE_FILE_MACHINE_ARM64EC = 0xA641
IMAGE_SCN_MEM_EXECUTE = 0x20000000
IMAGE_DIRECTORY_ENTRY_EXPORT = 0
IMAGE_DIRECTORY_ENTRY_BASERELOC = 5
IMAGE_REL_BASED_ABSOLUTE = 0
IMAGE_REL_BASED_DIR64 = 10

# Mach-O (mach-o/loader.h, mach-o/nlist.h)
MH_MAGIC_64 = 0xFEEDFACF
LC_SEGMENT_64 = 0x19
LC_SYMTAB = 0x2
N_TYPE = 0x0E
N_SECT = 0x0E
N_EXT = 0x01
VM_PROT_READ, VM_PROT_WRITE, VM_PROT_EXECUTE = 1, 2, 4


class PEError(Exception):
    pass


class Section:
    def __init__(self, name, rva, vsize, raw_size, raw_off, flags):
        self.name, self.rva, self.vsize = name, rva, vsize
        self.raw_size, self.raw_off, self.flags = raw_size, raw_off, flags

    @property
    def executable(self):
        return bool(self.flags & IMAGE_SCN_MEM_EXECUTE)


class PE:
    """The parts of a PE32+ image pe2macho needs."""

    def __init__(self, data):
        if data[:2] != b"MZ":
            raise PEError("not a PE file (no MZ header)")
        (pe_off,) = struct.unpack_from("<I", data, 0x3C)
        if data[pe_off:pe_off + 4] != b"PE\0\0":
            raise PEError("not a PE file (no PE signature)")
        machine, nsections = struct.unpack_from("<HH", data, pe_off + 4)
        (opt_size,) = struct.unpack_from("<H", data, pe_off + 20)
        if machine not in (IMAGE_FILE_MACHINE_ARM64, IMAGE_FILE_MACHINE_ARM64EC):
            raise PEError(f"machine {machine:#x} is not ARM64 or ARM64EC")
        opt = pe_off + 24
        self.opt = opt
        if struct.unpack_from("<H", data, opt)[0] != 0x20B:
            raise PEError("not a PE32+ image")
        (self.image_base,) = struct.unpack_from("<Q", data, opt + 24)
        self.section_alignment, = struct.unpack_from("<I", data, opt + 32)
        self.size_of_image, self.size_of_headers = struct.unpack_from("<II", data, opt + 56)
        (ndirs,) = struct.unpack_from("<I", data, opt + 108)
        self.dirs = [struct.unpack_from("<II", data, opt + 112 + 8 * i) for i in range(ndirs)]
        self.sections = []
        table = opt + opt_size
        for i in range(nsections):
            raw = struct.unpack_from("<8sIIII12xI", data, table + 40 * i)
            name = raw[0].rstrip(b"\0").decode("ascii", "replace")
            self.sections.append(Section(name, raw[2], raw[1], raw[3], raw[4], raw[5]))
        self.sections.sort(key=lambda s: s.rva)

        # The image as the loader would map it.
        self.image = bytearray(self.size_of_image)
        self.image[:self.size_of_headers] = data[:self.size_of_headers]
        for s in self.sections:
            if s.rva % PAGE:
                raise PEError(f"section {s.name} at RVA {s.rva:#x} is not aligned to {PAGE:#x} "
                              "(link with /ALIGN:65536 or /ALIGN:16384)")
            n = min(s.raw_size, s.vsize)
            self.image[s.rva:s.rva + n] = data[s.raw_off:s.raw_off + n]
        self.extra_groups = []
        self.teb_slot_rva = None
        self.x18_patched, self.x18_skipped = 0, []

    def rewrite_x18(self):
        """Rewrite the x18 (TEB) reads in the code (see x18.py). The
        trampolines go in an executable segment after the image, the TEB slot
        word in a writable one after that."""
        code = [(s.rva, min(s.vsize, self.size_of_image - s.rva)) for s in self.sections if s.executable]
        tramp_rva = align(self.size_of_image, PAGE)
        # The slot's RVA depends on the trampolines' size; their bytes do not
        # depend on where the slot is, beyond the adrp/ldr pair, so size first.
        probe = bytearray(self.image)
        tramps, _, _ = x18.rewrite(probe, code, tramp_rva, tramp_rva)
        if not tramps:
            return
        slot_rva = tramp_rva + align(len(tramps), PAGE)
        tramps, self.x18_patched, self.x18_skipped = x18.rewrite(self.image, code, tramp_rva, slot_rva)
        self.image += bytes(slot_rva + PAGE - len(self.image))
        # SizeOfImage covers the new segments, so the loader's view of the
        # module (and unwinding through a trampoline) includes them.
        struct.pack_into("<I", self.image, self.opt + 56, len(self.image))
        self.image[tramp_rva:tramp_rva + len(tramps)] = tramps
        self.extra_groups = [(tramp_rva, slot_rva, True), (slot_rva, slot_rva + PAGE, False)]
        self.teb_slot_rva = slot_rva

    def section_at(self, rva):
        for s in self.sections:
            if s.rva <= rva < s.rva + max(s.vsize, 1):
                return s
        return None

    def relocations(self):
        """RVAs of the 64-bit base relocations."""
        rva, size = self.dirs[IMAGE_DIRECTORY_ENTRY_BASERELOC] if len(self.dirs) > 5 else (0, 0)
        out, pos = [], rva
        while pos < rva + size:
            page, block = struct.unpack_from("<II", self.image, pos)
            if block < 8:
                raise PEError(f"bad base relocation block at RVA {pos:#x}")
            for i in range(8, block, 2):
                (entry,) = struct.unpack_from("<H", self.image, pos + i)
                kind, off = entry >> 12, entry & 0xFFF
                if kind == IMAGE_REL_BASED_ABSOLUTE:
                    continue
                if kind != IMAGE_REL_BASED_DIR64:
                    raise PEError(f"base relocation type {kind} at RVA {page + off:#x} is not supported")
                out.append(page + off)
            pos += block
        return sorted(out)

    def rebased(self):
        """RVAs of every pointer dyld rebases: the base relocations and the
        header's ImageBase field."""
        field = self.opt + 24
        if field % 8:
            raise PEError(f"ImageBase field at {field:#x} is not 8-byte aligned")
        return sorted(self.relocations() + [field])

    def pointer_target(self, rva):
        """The RVA a 64-bit base-relocated pointer at RVA points to."""
        (value,) = struct.unpack_from("<Q", self.image, rva)
        return value - self.image_base

    def exports(self):
        """{name: RVA} of the exported functions and data (forwarders skipped)."""
        rva, size = self.dirs[IMAGE_DIRECTORY_ENTRY_EXPORT] if self.dirs else (0, 0)
        if not size:
            return {}
        nfuncs, nnames, funcs, names, ordinals = struct.unpack_from("<IIIII", self.image, rva + 20)
        out = {}
        for i in range(nnames):
            (name_rva,) = struct.unpack_from("<I", self.image, names + 4 * i)
            (ordinal,) = struct.unpack_from("<H", self.image, ordinals + 2 * i)
            (target,) = struct.unpack_from("<I", self.image, funcs + 4 * ordinal)
            if rva <= target < rva + size:
                continue  # forwarder string, not code or data in this image
            end = self.image.index(b"\0", name_rva)
            out[self.image[name_rva:end].decode("ascii")] = target
        return out

    def groups(self):
        """[(start RVA, end RVA, executable)]: the image split into runs of the
        same protection, the headers counting as data, padded to the next run."""
        runs = [[0, False]]
        for s in self.sections:
            if s.executable != runs[-1][1]:
                runs.append([s.rva, s.executable])
        out = []
        for i, (start, exe) in enumerate(runs):
            end = runs[i + 1][0] if i + 1 < len(runs) else align(self.size_of_image, PAGE)
            out.append((start, end, exe))
        return out + self.extra_groups


def align(value, alignment):
    return (value + alignment - 1) // alignment * alignment


def default_prefix(path):
    name = os.path.splitext(os.path.basename(path))[0]
    return "pe_" + re.sub(r"[^A-Za-z0-9_]", "_", name)


def segment_name(i):
    return f"__PE{i}"


def write_asm(pe, prefix, out):
    relocs = pe.relocations()
    for r in relocs:
        s = pe.section_at(r)
        if s is None or s.executable:
            raise PEError(f"base relocation at RVA {r:#x} is in {'executable section ' + s.name if s else 'no section'}; "
                          "signed code pages cannot be rebased")
    exports = pe.exports()
    labels = {}
    for name, rva in exports.items():
        labels.setdefault(rva, []).append(f"_{prefix}_export_{name}")
    if pe.teb_slot_rva is not None:
        labels.setdefault(pe.teb_slot_rva, []).append(f"_{prefix}_teb_slot")
    reloc_set = set(pe.rebased())
    lines = [f"// Generated by tools/pe2macho from a PE image, ImageBase {pe.image_base:#x}.",
             f"// Do not edit; every byte sits at its RVA from _{prefix}_image."]
    for i, (start, end, exe) in enumerate(pe.groups()):
        attrs = ",regular,pure_instructions" if exe else ""
        lines.append(f"\t.section {segment_name(i)},__pe{attrs}")
        lines.append(f"\t.p2align {PAGE.bit_length() - 1}")
        if start == 0:
            lines += [f"\t.globl _{prefix}_image", f"_{prefix}_image:"]
        # Pieces between labels and relocations; a relocation is a piece of 8.
        points = sorted({start, end} | {p for r in reloc_set for p in (r, r + 8) if start <= r < end} |
                        {rva for rva in labels if start <= rva < end})
        for pos, cut in zip(points, points[1:]):
            for label in labels.get(pos, []):
                # C++ exports (concrt140's ?...@@...) need quoting in the assembler.
                q = label if re.fullmatch(r"[A-Za-z0-9_$.]+", label) else f'"{label}"'
                lines += [f"\t.globl {q}", f"{q}:"]
            if pos in reloc_set:
                lines.append(f"\t.quad _{prefix}_image + {pe.pointer_target(pos):#x}")
                continue
            chunk = pe.image[pos:min(cut, len(pe.image))]
            for j in range(0, len(chunk), 32):
                row = chunk[j:j + 32]
                if not any(row) and lines[-1].startswith("\t.zero "):
                    lines[-1] = f"\t.zero {int(lines[-1][7:]) + len(row)}"
                elif not any(row):
                    lines.append(f"\t.zero {len(row)}")
                else:
                    lines.append("\t.byte " + ",".join(str(b) for b in row))
            if cut > max(pos, len(pe.image)):
                lines.append(f"\t.space {cut - max(pos, len(pe.image))}")
    with open(out, "w") as fh:
        fh.write("\n".join(lines) + "\n")

    flags = []
    for i, (_, _, exe) in enumerate(pe.groups()):
        prot = "rx" if exe else "rw"
        flags += [f"-Wl,-segprot,{segment_name(i)},{prot},{prot}"]
    with open(os.path.splitext(out)[0] + ".ldflags", "w") as fh:
        fh.write("\n".join(flags) + "\n")


def read_macho(path):
    """Segments {name: (vmaddr, vmsize, fileoff, filesize, initprot)} and
    defined external symbols {name: address} of a 64-bit Mach-O file."""
    with open(path, "rb") as fh:
        data = fh.read()
    magic, _, _, _, ncmds = struct.unpack_from("<IiiII", data, 0)
    if magic != MH_MAGIC_64:
        raise PEError(f"{path} is not a 64-bit Mach-O file")
    segments, symbols, pos = {}, {}, 32
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", data, pos)
        if cmd == LC_SEGMENT_64:
            name = data[pos + 8:pos + 24].rstrip(b"\0").decode()
            vmaddr, vmsize, fileoff, filesize, _, initprot = struct.unpack_from("<QQQQii", data, pos + 24)
            segments[name] = (vmaddr, vmsize, fileoff, filesize, initprot)
        elif cmd == LC_SYMTAB:
            symoff, nsyms, stroff, _ = struct.unpack_from("<IIII", data, pos + 8)
            for i in range(nsyms):
                strx, ntype, _, _, value = struct.unpack_from("<IBBHQ", data, symoff + 16 * i)
                if ntype & N_TYPE == N_SECT and ntype & N_EXT:
                    end = data.index(b"\0", stroff + strx)
                    symbols[data[stroff + strx:end].decode()] = value
        pos += size
    return data, segments, symbols


def check(pe, prefix, dylib):
    """Errors in the linked dylib: segments not at their RVAs, wrong
    protections, bytes that differ from the image, missing exports."""
    data, segments, symbols = read_macho(dylib)
    errors = []
    base = symbols.get(f"_{prefix}_image")
    if base is None:
        return [f"no symbol _{prefix}_image"]
    relocs = set(pe.rebased())
    for i, (start, end, exe) in enumerate(pe.groups()):
        name = segment_name(i)
        if name not in segments:
            errors.append(f"segment {name} is missing")
            continue
        vmaddr, vmsize, fileoff, filesize, initprot = segments[name]
        if vmaddr != base + start:
            errors.append(f"segment {name} is at image + {vmaddr - base:#x}, expected RVA {start:#x}")
        if vmsize < end - start:
            errors.append(f"segment {name} is {vmsize:#x} bytes, expected {end - start:#x}")
        want = VM_PROT_READ | (VM_PROT_EXECUTE if exe else VM_PROT_WRITE)
        if initprot != want:
            errors.append(f"segment {name} has protection {initprot}, expected {want}")
        # The file holds the bytes as linked; relocated slots hold dyld's fixup encoding.
        stored = bytearray(data[fileoff:fileoff + min(filesize, end - start)])
        expected = bytearray(pe.image[start:start + len(stored)])
        for r in relocs:
            if start <= r < start + len(stored):
                stored[r - start:r - start + 8] = expected[r - start:r - start + 8] = bytes(8)
        if stored != expected:
            diff = [start + j for j in range(len(stored)) if stored[j] != expected[j]]
            errors.append(f"segment {name}: {len(diff)} bytes differ from the image, first at RVA {diff[0]:#x}")
    for name, rva in pe.exports().items():
        sym = f"_{prefix}_export_{name}"
        if symbols.get(sym) != base + rva:
            errors.append(f"export {name}: symbol {sym} missing or not at RVA {rva:#x}")
    if pe.teb_slot_rva is not None and symbols.get(f"_{prefix}_teb_slot") != base + pe.teb_slot_rva:
        errors.append(f"symbol _{prefix}_teb_slot missing or not at RVA {pe.teb_slot_rva:#x}")
    # No x18 read may be left in the code as linked, other than the ones the
    # rewrite had to skip (it says which).
    skipped = {rva for rva, _ in pe.x18_skipped}
    for s in pe.sections:
        if not s.executable:
            continue
        group = next(g for g in range(len(pe.groups())) if pe.groups()[g][0] <= s.rva < pe.groups()[g][1])
        seg = segments.get(segment_name(group))
        if not seg:
            continue
        off = seg[2] + s.rva - pe.groups()[group][0]
        code = data[off:off + min(s.vsize, pe.size_of_image - s.rva)]
        literal = x18.literal_words(code)
        for i in range(0, len(code) - 3, 4):
            (insn,) = struct.unpack_from("<I", code, i)
            if i not in literal and s.rva + i not in skipped and x18.classify(insn)[0]:
                errors.append(f"x18 read left at RVA {s.rva + i:#x} ({insn:#010x})")
                break
    return errors


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--prefix")
    ap.add_argument("--check", action="store_true", help="verify a linked dylib against the DLL")
    ap.add_argument("--no-x18", action="store_true", help="keep the code's x18 (TEB) reads as they are")
    ap.add_argument("--relocs", action="store_true",
                    help="write the rebased pointers to OUT, one 'RVA TARGET_RVA' line each (hex)")
    ap.add_argument("dll")
    ap.add_argument("out", help="OUT.s, the dylib with --check, or the list with --relocs")
    args = ap.parse_args()
    prefix = args.prefix or default_prefix(args.dll)
    with open(args.dll, "rb") as fh:
        try:
            pe = PE(fh.read())
            if not args.no_x18:
                pe.rewrite_x18()
            for rva, insn in pe.x18_skipped:
                print(f"{args.dll}: x18 read at RVA {rva:#x} ({insn:#010x}) left as is: "
                      "it addresses through sp or has no free scratch register", file=sys.stderr)
            if args.check:
                errors = check(pe, prefix, args.out)
                for e in errors:
                    print(f"{args.out}: {e}", file=sys.stderr)
                if errors:
                    return 1
                print(f"{args.out}: {len(pe.groups())} segments at their RVAs, "
                      f"{len(pe.rebased())} rebased pointers, {len(pe.exports())} exports, "
                      f"{pe.x18_patched} x18 reads rewritten")
                return 0
            if args.relocs:
                with open(args.out, "w") as out:
                    for rva in pe.rebased():
                        out.write(f"{rva:x} {pe.pointer_target(rva):x}\n")
                return 0
            write_asm(pe, prefix, args.out)
        except PEError as e:
            print(f"{args.dll}: {e}", file=sys.stderr)
            return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
