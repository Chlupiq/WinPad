#!/usr/bin/env python3
"""Rewrites Wine's dlls/opengl32/unix_thunks.c for Madeira's WoW64.

A 32-bit program's memory is not at the same address on the host here: a
guest address A is the host address B + A (Madeira's guest window, see
ios_wow_host_ptr() in include/wine/unixlib.h of Madeira's Wine). Wine's
generated wow64 thunks turn every pointer of a 32-bit argument block into a
host pointer with ULongToPtr(), which assumes B = 0. This turns those into
ios_wow_host_ptr(), and the pointers the thunks write back for the guest
(PtrToUlong) into ios_wow_guest_ptr32().

HGLRC, HPBUFFERARB and GLsync are not handles at this boundary: opengl32.dll
passes the address of its client object (struct opengl_client_context...),
which the unix side writes its own handle into, so they are converted too,
and the client object a create call hands back is returned as a guest address.

Left as they are: HDCs, debug callbacks with their user parameter and OpenCL
objects (values the guest only hands back), and the GLintptr / GLsizeiptr
casts (offsets and sizes).

Usage: wow64-ptrs.py IN OUT
"""
import re
import sys

KEEP = {
    'hdc', 'hDC', 'hDc', 'hDrawDC', 'hReadDC', 'handle', 'dc', 'context', 'event',
    'external_sync', 'callback', 'userParam', 'vdpDevice', 'vdpSurface', 'getProcAddress',
}

src = open(sys.argv[1]).read()
counts = {'host': 0, 'kept': 0, 'guest': 0}


def to_host(m):
    cast, name = m.group(1), m.group(2)
    if cast or name in KEEP:
        counts['kept'] += 1
        return m.group(0)
    counts['host'] += 1
    return 'ios_wow_host_ptr(params->%s)' % name


src = re.sub(r'(\((?:GLintptr|GLsizeiptr|GLint64|GLuint64|GLintptrARB|GLsizeiptrARB)\))?'
             r'U[Ll]ongToPtr\(\s*params->(\w+)\s*\)',
             lambda m: (m.group(1) or '') + to_host(m) if not m.group(1) else m.group(0), src)


def to_guest(m):
    counts['guest'] += 1
    return 'ios_wow_guest_ptr32( %s )' % m.group(1)


# *(PTR32 *)ios_wow_host_ptr(params->x) = PtrToUlong( y ); and params->ret = PtrToUlong( ... );
src = re.sub(r'PtrToUlong\(\s*(\w+)\s*\)', to_guest, src)

# glMapBuffer*: the copy Wine makes for a 32-bit caller (wow64_map_buffer in
# unix_wgl.c) is allocated in the guest's memory; the guest gets its guest address.
def map_ret(m):
    counts['guest'] += 1
    return 'params->ret = ios_wow_guest_ptr32( %s );' % m.group(1)


src = re.sub(r'params->ret = \(UINT_PTR\)(wow64_glMap\w*\(.*\));', map_ret, src)

# Arrays of strings (glShaderSource, glTransformFeedbackVaryings, glGetUniformIndices,
# glCompileShaderIncludeARB, glCreateShaderProgramv): their elements are guest pointers too.
# copy_wow64_str32s is added to unix_private.h by build.sh.
STRINGS = {'string', 'strings', 'path', 'uniformNames', 'varyings'}


def str_arrays(m):
    if m.group(2) not in STRINGS:
        return m.group(0)
    counts['strs'] = counts.get('strs', 0) + 1
    return '%s = copy_wow64_str32s( params->%s' % (m.group(1), m.group(2))


src = re.sub(r'(\w+) = copy_wow64_ptr32s\( params->(\w+)', str_arrays, src)
if counts.get('strs', 0) < 5:
    sys.exit('wow64-ptrs: expected the string arrays (glShaderSource...) in unix_thunks.c, found %d'
             % counts.get('strs', 0))

# Create calls get the client object to fill in: UlongToHandle( params->ret ),
# and return it; the guest gets its own address back.
def create_ret(m):
    counts['host'] += 1
    counts['guest'] += 1
    return 'params->ret = ios_wow_guest_ptr32( %sios_wow_host_ptr(params->ret) ) );' % m.group(1)


src, n = re.subn(r'params->ret = \(UINT_PTR\)([^;]*?)UlongToHandle\( params->ret \) \);', create_ret, src)
assert n >= 6, 'expected the create calls of contexts, pbuffers and syncs, found %d' % n
assert 'UlongToHandle( params->ret )' not in src

left = re.findall(r'U[Ll]ongToPtr\(params->(\w+)\)', src)
unexpected = sorted(set(n for n in left if n not in KEEP))
open(sys.argv[2], 'w').write(src)
print('wow64-ptrs: %(host)d pointers converted to host, %(kept)d handles/offsets kept, '
      '%(guest)d pointers written back as guest addresses, %(strs)d string arrays' % counts)
