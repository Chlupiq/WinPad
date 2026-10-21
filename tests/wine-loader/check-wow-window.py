#!/usr/bin/env python3
"""Guest-window placement on an iPad whose address map is short; no Wine runs.

Usage: check-wow-window.py MADEIRA_DIR
MADEIRA_DIR is a Madeira checkout (build/ and tests/host/) with patches/madeira
applied. This runs Madeira's own harness for the guest-window code
(tests/host/check-lazy-windows.py: the production code compiled against a fake
address map) on the map of an iPad on iPadOS 27 without the extended virtual
addressing entitlement: TASK_VM_INFO.max_address = 0x7180000000. There the map
ends inside the guest-window band, below the end of its first 4 GB slot
(0x7100000000..0x7200000000), and a 32-bit process could not start
(patches/madeira/0003).
"""
from pathlib import Path
import re, subprocess, sys, tempfile

madeira = Path(sys.argv[1]).resolve()
script = madeira / "tests/host/check-lazy-windows.py"
src = script.read_text()
# Madeira's harness and run(), without its own scenarios
ns = {"__file__": str(script), "__name__": "harness"}
exec(compile(src[:src.index("BIG, TABLET, SMALL =")], str(script), "exec"), ns)
harness, run = ns["harness"], ns["run"]

# The app runs FEX without a JIT pool on a device (FEX_NOJIT), so nothing need
# be at 0x7000000000; NO_JIT_ALIAS=1 leaves the pool's RW alias out of the map.
jit = "    add_region( 0x7000000000ULL, 0x7038000000ULL, 1 );        /* JIT pool RW alias */\n"
assert jit in harness
harness = harness.replace(jit, "    if (!getenv( \"NO_JIT_ALIAS\" ))\n" + jit)

IPAD, BIG = "0x7180000000", "0x8000000000"
with tempfile.TemporaryDirectory() as t:
    c = Path(t) / "lazy.c"; c.write_text(harness)
    exe = Path(t) / "lazy"
    subprocess.run(["cc", "-std=gnu11", "-Wall", "-Wno-unused-function", "-Wno-unused-variable",
                    "-Wno-unused-but-set-variable", "-pthread", "-fsanitize=address,undefined",
                    str(c), "-o", str(exe)], check=True)

    out, err = run(exe, "main-i386", IPAD, env={"NO_JIT_ALIAS": "1"})
    assert "start armed=1" in out and "placeholders=1" in out, out + err
    assert "main status=0 base=7000000000 new_mappings=0" in out, out + err
    assert "short address map: it ends at 0x7180000000" in err, err
    assert "B=0x7000000000: reserved 4GB + own guard page" in err, err
    assert not re.search(r"B=0x7[1-9a-f]00000000", err), err
    print("PASS: map ending at 0x7180000000: the window is the highest slot below the end of the map, "
          "with its own guard page")

    out, err = run(exe, "main-i386", IPAD)
    # 0x7000000000 is taken; the guard page of 0x6f00000000 would be the alias
    assert "main status=0 base=6e00000000 new_mappings=0" in out, out + err
    assert "adopted placeholder B=0x6e00000000" in out + err and "B=0x7000000000" not in err.split("adopted")[1], err
    print("PASS: the same with that slot taken: the next slot down whose guard page is free")

    out, err = run(exe, "procs", IPAD, "2", env={"NO_JIT_ALIAS": "1"})
    assert "proc0 status=0 base=7000000000 new_mappings=1" in out, out + err
    assert "proc1 status=0 base=6f00000000 new_mappings=1" in out, out + err
    print("PASS: two 32-bit processes at once on that map")

    out, err = run(exe, "main-i386", "0x7200000000")
    assert "main status=0 base=7100000000 new_mappings=0" in out, out + err
    assert "B=0x7100000000: reserved exactly 4GB; the end of the address map at 0x7200000000 is its guard" in err, err
    print("PASS: a window that ends exactly at the end of the map has the end of the map as its guard")

    # MADEIRA_WOW_MAP_END, as the simulator runs set it: only ever narrows the map
    out, err = run(exe, "main-i386", BIG, env={"NO_JIT_ALIAS": "1", "MADEIRA_WOW_MAP_END": IPAD})
    assert "main status=0 base=7000000000 new_mappings=0" in out, out + err
    assert "MADEIRA_WOW_MAP_END: the map is taken to end at 0x7180000000" in err, err
    out, err = run(exe, "main-i386", BIG, env={"MADEIRA_WOW_MAP_END": "0x9000000000"})
    assert "main status=0 base=7100000000 new_mappings=0" in out, out + err
    assert "MADEIRA_WOW_MAP_END" not in err, err
    print("PASS: MADEIRA_WOW_MAP_END narrows the map to the iPad's and never widens it")
