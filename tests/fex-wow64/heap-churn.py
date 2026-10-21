"""Counts how often a run decommitted and committed again pages of FEX's host heap.

FEX's host heap (rpmalloc) lives in the band BTCpuProcessInit reports as
"[va-profile] ml787 FEX host arena = [LO, HI]". Madeira's ntdll logs each
VirtualFree there ("[vfree] ml842 ... type=0x4000" is MEM_DECOMMIT, the
first 3000 frees of a process) and each commit, as
"err:virtual:mprotect_exec mprotect_exec(BASE, SIZE, rw-)" (every one, or
after patches/madeira/0006 the first 32 and then every power of two, with
the running count as "(#N)").

Usage: heap-churn.py RUN_LOG [--max-decommits N]
Prints the counts. With --max-decommits it exits with 1 if more than N
decommits fell in the host arena, or if the log names no host arena.
"""
import re
import sys

ARENA = re.compile(r"\[va-profile\] ml787 FEX host arena = \[(0x[0-9a-fA-F]+), (0x[0-9a-fA-F]+)\]")
VFREE = re.compile(r"\[vfree\] ml842 \S+ base=(0x[0-9a-fA-F]+) size=(0x[0-9a-fA-F]+) type=(0x[0-9a-fA-F]+)")
COMMIT = re.compile(r"err:virtual:mprotect_exec .*?mprotect_exec\((0x[0-9a-fA-F]+), 0x[0-9a-fA-F]+, (...)\)(?: \(#(\d+)\))?")
MEM_DECOMMIT = 0x4000


def main(argv):
    path = argv[1]
    limit = None
    if len(argv) == 4 and argv[2] == "--max-decommits":
        limit = int(argv[3])
    elif len(argv) != 2:
        sys.exit(__doc__)
    arena = None
    decommits = 0
    commits = 0
    commit_total = 0
    with open(path, errors="replace") as f:
        lines = f.readlines()
    for line in lines:
        m = ARENA.search(line)
        if m and arena is None:
            arena = (int(m.group(1), 16), int(m.group(2), 16))
    if arena is None:
        print(f"{path}: no \"FEX host arena\" line")
        return 1 if limit is not None else 0
    lo, hi = arena
    for line in lines:
        m = VFREE.search(line)
        if m:
            if int(m.group(3), 16) & MEM_DECOMMIT and lo <= int(m.group(1), 16) <= hi:
                decommits += 1
            continue
        m = COMMIT.search(line)
        if m and m.group(2) == "rw-" and lo <= int(m.group(1), 16) <= hi:
            commits += 1
            if m.group(3):
                commit_total = max(commit_total, int(m.group(3)))
    print(f"FEX host arena [{lo:#x}, {hi:#x}]")
    print(f"MEM_DECOMMIT of host heap pages: {decommits}")
    print(f"rw- commits (mprotect_exec) of host heap pages logged: {commits}"
          + (f", the last one #{commit_total} of all mprotect_exec calls" if commit_total else ""))
    if limit is not None and decommits > limit:
        print(f"more than {limit} decommits: the host heap gives its free pages back and takes them again")
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
