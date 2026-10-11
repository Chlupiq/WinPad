#!/usr/bin/env python3
"""Audit PE modules for the PE-in-Mach-O plan (PLAN.md, section 2A).

For each PE file it reports:
  - machine and section alignment (iOS pages are 16 KB),
  - sections that are executable, writable, or both,
  - base relocations whose target lies in an executable section
    (these would have to be written into signed, read-only code pages),
  - the x64 code ranges of ARM64EC modules (CHPE metadata), which FEX would
    have to translate ahead of time as well.

Usage: pe_reloc_audit.py [--json out.json] FILE_OR_DIR...
"""
import argparse
import json
import os
import struct
import sys

import pefile

IOS_PAGE = 0x4000
MACHINES = {0x14C: "i386", 0x8664: "x64", 0xAA64: "arm64", 0xA641: "arm64ec", 0xA64E: "arm64x"}
SCN_EXEC = 0x20000000
SCN_WRITE = 0x80000000


def section_for(pe, rva):
    for s in pe.sections:
        size = max(s.Misc_VirtualSize, s.SizeOfRawData)
        if s.VirtualAddress <= rva < s.VirtualAddress + size:
            return s
    return None


def chpe_x64_ranges(pe):
    """Return [(start_rva, length)] of x64 code ranges from the ARM64EC CHPE metadata."""
    lc = getattr(pe, "DIRECTORY_ENTRY_LOAD_CONFIG", None)
    if lc is None:
        return None
    chpe_va = getattr(lc.struct, "CHPEMetadataPointer", 0)
    if not chpe_va:
        return None
    base = pe.OPTIONAL_HEADER.ImageBase
    off = pe.get_offset_from_rva(chpe_va - base)
    data = pe.__data__
    # IMAGE_ARM64EC_METADATA: Version, CodeMap (RVA), CodeMapCount
    _version, code_map, count = struct.unpack_from("<III", data, off)
    ranges = []
    cm_off = pe.get_offset_from_rva(code_map)
    for i in range(count):
        start_and_kind, length = struct.unpack_from("<II", data, cm_off + 8 * i)
        kind = start_and_kind & 3  # 0 = ARM64, 1 = ARM64EC, 2 = AMD64
        if kind == 2:
            ranges.append((start_and_kind & ~3, length))
    return ranges


def audit(path):
    pe = pefile.PE(path, fast_load=True)
    pe.parse_data_directories(directories=[
        pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_BASERELOC"],
        pefile.DIRECTORY_ENTRY["IMAGE_DIRECTORY_ENTRY_LOAD_CONFIG"],
    ])
    machine = MACHINES.get(pe.FILE_HEADER.Machine, hex(pe.FILE_HEADER.Machine))
    sections = []
    for s in pe.sections:
        sections.append({
            "name": s.Name.rstrip(b"\0").decode(errors="replace"),
            "rva": s.VirtualAddress,
            "size": s.Misc_VirtualSize,
            "exec": bool(s.Characteristics & SCN_EXEC),
            "write": bool(s.Characteristics & SCN_WRITE),
        })
    total = 0
    in_exec = {}
    for block in getattr(pe, "DIRECTORY_ENTRY_BASERELOC", []):
        for entry in block.entries:
            if entry.type == 0:  # IMAGE_REL_BASED_ABSOLUTE is padding
                continue
            total += 1
            s = section_for(pe, entry.rva)
            if s is not None and s.Characteristics & SCN_EXEC:
                name = s.Name.rstrip(b"\0").decode(errors="replace")
                in_exec[name] = in_exec.get(name, 0) + 1
    x64 = chpe_x64_ranges(pe)
    return {
        "file": os.path.basename(path),
        "machine": machine,
        "section_alignment": pe.OPTIONAL_HEADER.SectionAlignment,
        "aligned_16k": pe.OPTIONAL_HEADER.SectionAlignment % IOS_PAGE == 0,
        "image_size": pe.OPTIONAL_HEADER.SizeOfImage,
        "exec_and_write_sections": [s["name"] for s in sections if s["exec"] and s["write"]],
        "relocs_total": total,
        "relocs_in_exec": sum(in_exec.values()),
        "relocs_in_exec_by_section": in_exec,
        "x64_code_ranges": None if x64 is None else len(x64),
        "x64_code_bytes": None if x64 is None else sum(l for _, l in x64),
    }


def iter_files(paths):
    for p in paths:
        if os.path.isdir(p):
            for root, _, files in os.walk(p):
                for f in sorted(files):
                    if f.lower().endswith((".dll", ".exe", ".drv", ".sys", ".cpl", ".ocx", ".acm", ".ax")):
                        yield os.path.join(root, f)
        else:
            yield p


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    ap.add_argument("paths", nargs="+")
    ap.add_argument("--json", help="write full results to this file")
    args = ap.parse_args()
    results = []
    for f in iter_files(args.paths):
        try:
            results.append(audit(f))
        except pefile.PEFormatError as e:
            print(f"skip {f}: {e}", file=sys.stderr)
    print(f"{'file':32} {'machine':8} {'align':>6} {'relocs':>7} {'in code':>7} {'x64 rng':>7}")
    for r in results:
        x = "-" if r["x64_code_ranges"] is None else r["x64_code_ranges"]
        print(f"{r['file'][:32]:32} {r['machine']:8} {r['section_alignment']:>6x} "
              f"{r['relocs_total']:>7} {r['relocs_in_exec']:>7} {x:>7}")
    n = len(results)
    print(f"\nmodules: {n}")
    print(f"16 KB aligned: {sum(r['aligned_16k'] for r in results)}/{n}")
    print(f"with relocations in executable sections: {sum(r['relocs_in_exec'] > 0 for r in results)}/{n}")
    print(f"with writable+executable sections: {sum(bool(r['exec_and_write_sections']) for r in results)}/{n}")
    if args.json:
        with open(args.json, "w") as fh:
            json.dump(results, fh, indent=1)


if __name__ == "__main__":
    main()
