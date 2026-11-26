#!/usr/bin/env python3
"""Mach-O has no symbol aliases (__attribute__((alias))): gl4es's AliasDecl
lines in IN become functions that call the aliased one. Writes OUT.

Usage: no-aliases.py IN OUT
"""
import re
import sys

src = open(sys.argv[1]).read()


def call(m):
    ret, name, params, target = m.group(1), m.group(2), m.group(3), m.group(4)
    args = ', '.join(p.split()[-1].lstrip('*') for p in params.split(',') if p.strip() != 'void')
    body = ('return ' if ret != 'void' else '') + '%s(%s);' % (target, args)
    return '%s APIENTRY_GL4ES %s(%s) { %s }' % (ret, name, params, body)


src, n = re.subn(r'AliasDecl\(\s*(\w+)\s*,\s*(\w+)\s*,\s*\(([^)]*)\)\s*,\s*(\w+)\s*\);', call, src)
assert 'AliasDecl(' not in src, 'an AliasDecl this script does not understand'
open(sys.argv[2], 'w').write(src)
print('no-aliases: %d aliases in %s' % (n, sys.argv[1]))
