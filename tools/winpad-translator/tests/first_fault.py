"""Runs a Windows program under a minimal debugger and reports where it faults.

Usage: first_fault.py PROGRAM [ARGS...]   (Windows only)

Prints, for each exception other than the loader's breakpoint, its code, the
module and offset it happened at, the nearest COFF symbol (mingw images keep
their symbol table) and the instruction words there, so a crash on a CI
runner without a debugger (windows-11-arm) can be read from its log.
"""
import ctypes
import ctypes.wintypes as w
import os
import struct
import subprocess
import sys

DEBUG_ONLY_THIS_PROCESS = 0x2
EXCEPTION_DEBUG_EVENT, CREATE_PROCESS_DEBUG_EVENT, EXIT_PROCESS_DEBUG_EVENT, LOAD_DLL_DEBUG_EVENT = 1, 3, 5, 6
OUTPUT_DEBUG_STRING_EVENT = 8
DBG_CONTINUE, DBG_EXCEPTION_NOT_HANDLED = 0x00010002, 0x80010001
# The loader's breakpoint (also as a WoW64 one) and C++ exceptions and debug strings the
# runtime raises on purpose.
BREAKPOINTS = {0x80000003, 0x4000001F, 0x40010006, 0x4001000A}


class EXCEPTION_RECORD(ctypes.Structure):
    _fields_ = [("code", w.DWORD), ("flags", w.DWORD), ("record", ctypes.c_void_p), ("address", ctypes.c_void_p),
                ("nparams", w.DWORD), ("info", ctypes.c_size_t * 15)]


class EXCEPTION_DEBUG_INFO(ctypes.Structure):
    _fields_ = [("record", EXCEPTION_RECORD), ("first_chance", w.DWORD)]


class CREATE_PROCESS_DEBUG_INFO(ctypes.Structure):
    _fields_ = [("file", w.HANDLE), ("process", w.HANDLE), ("thread", w.HANDLE), ("base", ctypes.c_void_p)]


class LOAD_DLL_DEBUG_INFO(ctypes.Structure):
    _fields_ = [("file", w.HANDLE), ("base", ctypes.c_void_p), ("debug_offset", w.DWORD), ("debug_size", w.DWORD),
                ("name", ctypes.c_void_p), ("unicode", w.WORD)]


class OUTPUT_DEBUG_STRING_INFO(ctypes.Structure):
    _fields_ = [("data", ctypes.c_void_p), ("unicode", w.WORD), ("length", w.WORD)]


class U(ctypes.Union):
    _fields_ = [("exception", EXCEPTION_DEBUG_INFO), ("create", CREATE_PROCESS_DEBUG_INFO),
                ("load", LOAD_DLL_DEBUG_INFO), ("string", OUTPUT_DEBUG_STRING_INFO), ("pad", ctypes.c_byte * 176)]


class DEBUG_EVENT(ctypes.Structure):
    _fields_ = [("code", w.DWORD), ("pid", w.DWORD), ("tid", w.DWORD), ("u", U)]


def module_path(handle):
    buf = ctypes.create_unicode_buffer(1024)
    n = ctypes.windll.kernel32.GetFinalPathNameByHandleW(handle, buf, 1024, 0)
    return buf.value[4:] if n and buf.value.startswith("\\\\?\\") else (buf.value if n else "?")


def nearest_symbol(path, rva):
    """The COFF symbol at or below RVA in the PE file PATH, or None."""
    try:
        with open(path, "rb") as f:
            data = f.read()
    except OSError:
        return None
    nt = struct.unpack_from("<I", data, 0x3C)[0]
    nsect, _, symtab, nsyms, opt_size = struct.unpack_from("<HIIIH", data, nt + 6)
    if not symtab or not nsyms:
        return None
    sections = []
    for i in range(nsect):
        off = nt + 24 + opt_size + 40 * i
        sections.append(struct.unpack_from("<I", data, off + 12)[0])
    strings = symtab + 18 * nsyms
    best = None
    i = 0
    while i < nsyms:
        off = symtab + 18 * i
        name, value, section, _, storage, aux = struct.unpack_from("<8sIhHBB", data, off)
        if 1 <= section <= nsect and storage in (2, 3):
            sym_rva = sections[section - 1] + value
            if sym_rva <= rva and (best is None or sym_rva > best[0]):
                if name[:4] == b"\0\0\0\0":
                    s = struct.unpack_from("<I", name, 4)[0]
                    end = data.index(b"\0", strings + s)
                    text = data[strings + s:end].decode("ascii", "replace")
                else:
                    text = name.rstrip(b"\0").decode("ascii", "replace")
                best = (sym_rva, text)
        i += 1 + aux
    return f"{best[1]}+{rva - best[0]:#x}" if best else None


def main(argv):
    k32 = ctypes.windll.kernel32
    si = subprocess.STARTUPINFO()
    proc = subprocess.Popen(argv, creationflags=DEBUG_ONLY_THIS_PROCESS, startupinfo=si)
    modules = {}
    event = DEBUG_EVENT()
    process = None
    while True:
        if not k32.WaitForDebugEvent(ctypes.byref(event), 600_000):
            print("first_fault: no debug event for 10 minutes")
            return 2
        status = DBG_CONTINUE
        if event.code == CREATE_PROCESS_DEBUG_EVENT:
            process = event.u.create.process
            modules[event.u.create.base] = module_path(event.u.create.file)
        elif event.code == LOAD_DLL_DEBUG_EVENT:
            modules[event.u.load.base] = module_path(event.u.load.file)
        elif event.code == OUTPUT_DEBUG_STRING_EVENT:
            info = event.u.string
            size = info.length * (2 if info.unicode else 1)
            buf = (ctypes.c_char * size)()
            got = ctypes.c_size_t()
            k32.ReadProcessMemory(process, ctypes.c_void_p(info.data), buf, size, ctypes.byref(got))
            text = bytes(buf).decode("utf-16-le" if info.unicode else "mbcs", "replace").rstrip("\0\r\n")
            print(f"debug: {text}")
        elif event.code == EXCEPTION_DEBUG_EVENT:
            rec = event.u.exception.record
            if rec.code not in BREAKPOINTS:
                addr = rec.address or 0
                base = max((b for b in modules if b and b <= addr), default=0)
                path = modules.get(base, "?")
                rva = addr - base
                words = (ctypes.c_uint32 * 8)()
                got = ctypes.c_size_t()
                k32.ReadProcessMemory(process, ctypes.c_void_p(addr - 16), words, 32, ctypes.byref(got))
                print(f"first_fault: exception {rec.code:#010x} ({'first' if event.u.exception.first_chance else 'second'}"
                      f" chance) at {addr:#x} = {os.path.basename(path)}+{rva:#x} [{nearest_symbol(path, rva)}]")
                print("first_fault: words from pc-16: " + " ".join(f"{x:08x}" for x in words))
                status = DBG_EXCEPTION_NOT_HANDLED
        elif event.code == EXIT_PROCESS_DEBUG_EVENT:
            k32.ContinueDebugEvent(event.pid, event.tid, DBG_CONTINUE)
            print(f"first_fault: exit {proc.wait() & 0xFFFFFFFF:#x}")
            return 0
        k32.ContinueDebugEvent(event.pid, event.tid, status)


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
