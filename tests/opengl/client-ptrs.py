#!/usr/bin/env python3
"""Writes WinPad's copy of Wine's include/wine/opengl_driver.h.

Wine's opengl32 hands its unix side (and win32u) a context or pbuffer handle
that is the address of the client's object (struct opengl_client_context...),
which the unix side reads and writes. A 32-bit program's opengl32.dll made
that object in the guest's memory, so its address is a guest address A, the
host address B + A in Madeira's guest window (ios_wow_host_ptr). The handles
themselves stay guest values (the 32-bit program compares them, hands them
back); only reading the object goes through ios_wow_host_ptr. A 64-bit caller
(no guest window, base 0) and a host pointer (above 4 GB) are unchanged.

Usage: client-ptrs.py WINE_TREE OUT_DIR  (writes OUT_DIR/wine/opengl_driver.h;
a source file in OUT_DIR that includes "wine/opengl_driver.h" takes this one)
"""
import os
import sys

wine, out = sys.argv[1], sys.argv[2]
src = open(os.path.join(wine, 'include/wine/opengl_driver.h')).read()

helper = '''
#if defined(WINE_UNIX_LIB) && defined(WINE_IOS)
#include "wine/unixlib.h"
/* WinPad: a client object of a 32-bit program is at a guest address (client-ptrs.py). */
static inline void *winpad_gl_client_ptr( const void *client )
{
    ULONG_PTR addr = (ULONG_PTR)client;
    return addr && addr <= 0xffffffff ? ios_wow_host_ptr( (ULONG)addr ) : (void *)client;
}
#else
#define winpad_gl_client_ptr( client ) ((void *)(client))
#endif
'''
anchor = 'struct opengl_client_context\n{'
assert anchor in src, 'opengl_driver.h: struct opengl_client_context moved'
src = src.replace(anchor, helper + '\n' + anchor, 1)

for kind, handle in (('context', 'HGLRC client_context'), ('pbuffer', 'HPBUFFERARB client_pbuffer')):
    arg = handle.split()[1]
    old = ('static inline struct opengl_client_%s *opengl_client_%s_from_client( %s )\n{\n'
           '    return CONTAINING_RECORD( %s, struct opengl_client_%s, obj );\n}' % (kind, kind, handle, arg, kind))
    new = ('static inline struct opengl_client_%s *opengl_client_%s_from_client( %s )\n{\n'
           '    return CONTAINING_RECORD( (%s)winpad_gl_client_ptr( %s ), struct opengl_client_%s, obj );\n}'
           % (kind, kind, handle, handle.split()[0], arg, kind))
    assert old in src, 'opengl_driver.h: opengl_client_%s_from_client changed upstream' % kind
    src = src.replace(old, new, 1)

os.makedirs(os.path.join(out, 'wine'), exist_ok=True)
open(os.path.join(out, 'wine', 'opengl_driver.h'), 'w').write(src)
print('client-ptrs: %s' % os.path.join(out, 'wine', 'opengl_driver.h'))
