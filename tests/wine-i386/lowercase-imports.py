#!/usr/bin/env python3
# Rewrites, in place, the DLL names a PE file imports in lower case
# (USER32.dll -> user32.dll), the way Wine's own import libraries name them.
# In the WoW64 runs on the iPad simulator, Wine finds an imported user32.dll
# or gdi32.dll only by its lower-case name (c0000135 for USER32.dll and
# GDI32.dll, which MinGW's import libraries name, although the volume is
# case-insensitive), so build-d3d9.sh passes DXMT's DLLs and the cube
# through this.
#
# Usage: lowercase-imports.py FILE...
import struct
import sys


def lowercase_imports(path):
    with open(path, 'r+b') as f:
        data = bytearray(f.read())
        pe = struct.unpack_from('<I', data, 0x3c)[0]
        nsec, = struct.unpack_from('<H', data, pe + 6)
        optsize, = struct.unpack_from('<H', data, pe + 20)
        opt = pe + 24
        magic, = struct.unpack_from('<H', data, opt)
        dirs = opt + (96 if magic == 0x10b else 112)
        imp_rva, = struct.unpack_from('<I', data, dirs + 8)
        sections = []
        for i in range(nsec):
            s = opt + optsize + 40 * i
            vsize, va, rawsize, raw = struct.unpack_from('<IIII', data, s + 8)
            sections.append((va, max(vsize, rawsize), raw))

        def offset(rva):
            for va, size, raw in sections:
                if va <= rva < va + size:
                    return rva - va + raw
            raise ValueError(f'{path}: RVA {rva:#x} is in no section')

        names = []
        d = offset(imp_rva) if imp_rva else None
        while d is not None:
            name_rva = struct.unpack_from('<I', data, d + 12)[0]
            if not name_rva:
                break
            o = offset(name_rva)
            end = data.index(0, o)
            old = data[o:end].decode('ascii')
            data[o:end] = old.lower().encode('ascii')
            names.append(old)
            d += 20
        f.seek(0)
        f.write(data)
    print(f'{path}: ' + ' '.join(names))


for p in sys.argv[1:]:
    lowercase_imports(p)
