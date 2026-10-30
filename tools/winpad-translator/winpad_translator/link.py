"""Links code caches and FEX's dispatcher into the AOT image (a dylib for an iPad).

tools/cache2macho writes each cache as an arm64 Mach-O object and the index as
assembly (tests/fex-wow64/build-aot-image.sh). On a Mac, Xcode's clang
assembles and links them; anywhere else LLVM does (clang or llvm-mc, and lld's
Mach-O linker ld64.lld), with a stub of libSystem in place of the iOS SDK, so
no Mac is needed for this step.
"""
import glob
import os
import re
import shutil
import subprocess
import sys

from . import paths  # noqa: F401
import aotindex  # noqa: E402
import cache2macho  # noqa: E402
import fxcc_inspect  # noqa: E402

MIN_IOS = "17.4"
SDKS = ("iphoneos", "iphonesimulator")
CACHE_NAME = re.compile(r"-[0-9a-f]{16}-[0-9a-f]{16}$")
LLVM_DIRS = [
    r"C:\Program Files\LLVM\bin",
    "/opt/homebrew/opt/llvm/bin", "/opt/homebrew/opt/lld/bin",
    "/usr/local/opt/llvm/bin", "/usr/local/opt/lld/bin",
]


class LinkError(Exception):
    pass


def _which(names, extra_dirs):
    for d in extra_dirs:
        for n in names:
            for cand in (os.path.join(d, n), os.path.join(d, n + ".exe")):
                if os.path.isfile(cand):
                    return cand
    for n in names:
        hit = shutil.which(n)
        if hit:
            return hit
    return None


def _versioned(base, dirs):
    """BASE, else the newest BASE-NN on the PATH or in DIRS (Debian/Ubuntu name LLVM's tools so)."""
    hit = _which([base], dirs)
    if hit:
        return hit
    found = []
    for d in dirs + os.environ.get("PATH", "").split(os.pathsep):
        found += glob.glob(os.path.join(d, base + "-[0-9]*"))
    found = [f for f in found if re.search(r"-\d+(\.exe)?$", f)]
    return sorted(found, key=lambda f: int(re.search(r"-(\d+)(\.exe)?$", f).group(1)))[-1] if found else None


class Toolchain:
    def __init__(self, kind, assembler=None, linker=None):
        self.kind = kind  # "xcode" or "llvm"
        self.assembler = assembler
        self.linker = linker

    def __str__(self):
        if self.kind == "xcode":
            return "Xcode (xcrun clang)"
        return f"LLVM ({self.assembler[1]}, {' '.join(self.linker)})"


def find_toolchain(prefer=None, llvm_dir=None):
    """Xcode on a Mac, else LLVM (also on a Mac when PREFER is "llvm")."""
    if prefer != "llvm" and sys.platform == "darwin" and shutil.which("xcrun"):
        return Toolchain("xcode")
    dirs = ([llvm_dir] if llvm_dir else []) + ([os.environ["WINPAD_LLVM"]] if os.environ.get("WINPAD_LLVM") else []) + LLVM_DIRS
    clang = _versioned("clang", dirs)
    mc = None if clang else _versioned("llvm-mc", dirs)
    ld64 = _versioned("ld64.lld", dirs)
    linker = [ld64] if ld64 else None
    if not linker:
        lld = _versioned("lld", dirs)
        linker = [lld, "-flavor", "darwin"] if lld else None
    if not (clang or mc) or not linker:
        raise LinkError("LLVM was not found: install it (Windows: winget install LLVM.LLVM, or llvm.org; "
                        "Linux: clang and lld) or give its bin folder")
    return Toolchain("llvm", ("clang", clang) if clang else ("llvm-mc", mc), linker)


def _run(cmd, log):
    proc = subprocess.run(cmd, capture_output=True, text=True, errors="replace")
    if proc.returncode != 0:
        raise LinkError(f"{' '.join(cmd)} failed:\n{proc.stdout}{proc.stderr}")
    return proc


def _assemble(tc, sdk, src, obj, log):
    triple = f"arm64-apple-ios{MIN_IOS}" + ("-simulator" if sdk == "iphonesimulator" else "")
    if tc.kind == "xcode":
        _run(["xcrun", "-sdk", sdk, "clang", "-target", triple, "-c", src, "-o", obj], log)
    elif tc.assembler[0] == "clang":
        _run([tc.assembler[1], "--target=" + triple, "-c", src, "-o", obj], log)
    else:
        _run([tc.assembler[1], "-triple", triple, "-filetype=obj", src, "-o", obj], log)


def _libsystem_stub(sdk, folder):
    """A text stub of libSystem, which every dylib Xcode links names, for lld without an SDK."""
    target = "arm64-ios-simulator" if sdk == "iphonesimulator" else "arm64-ios"
    path = os.path.join(folder, "libSystem.tbd")
    with open(path, "w") as f:
        f.write("--- !tapi-tbd\ntbd-version: 4\n"
                f"targets: [ {target} ]\n"
                "install-name: '/usr/lib/libSystem.B.dylib'\n"
                "current-version: 1351\n"
                "exports:\n"
                f"  - targets: [ {target} ]\n"
                "    symbols: [ dyld_stub_binder ]\n...\n")
    return path


def caches_in(cache_dir):
    folder = os.path.join(cache_dir, "cache")
    if not os.path.isdir(folder):
        return []
    return sorted(os.path.join(folder, n) for n in os.listdir(folder)
                  if CACHE_NAME.search(n) and os.path.getsize(os.path.join(folder, n)) > 0)


def link_image(cache_dir, out, sdk="iphoneos", dispatcher=None, toolchain=None, log=print):
    """Links CACHE_DIR/cache/* and DISPATCHER (dispatcher.bin) into OUT. Returns the
    number of caches linked."""
    if sdk not in SDKS:
        raise LinkError(f"unknown SDK {sdk}")
    tc = toolchain or find_toolchain()
    objs = os.path.join(os.path.dirname(os.path.abspath(out)), f"aot-objs-{sdk}")
    shutil.rmtree(objs, ignore_errors=True)
    os.makedirs(objs)
    fxcc_inspect.RELOC_TYPES = fxcc_inspect.RELOC_TYPES_WOW64
    platform = cache2macho.PLATFORM_IOSSIMULATOR if sdk == "iphonesimulator" else cache2macho.PLATFORM_IOS
    kept = []
    for c in caches_in(cache_dir):
        with open(c, "rb") as f:
            data = f.read()
        try:
            obj, _ = cache2macho.convert(data, cache2macho.default_prefix(c), MIN_IOS, platform)
        except (cache2macho.ConvertError, fxcc_inspect.FormatError) as e:
            # A cache without blocks (its map held only blocks the compiler did not
            # keep) stays out; FEX treats that module as one without a cache.
            if str(e) == "empty cache":
                continue
            raise LinkError(f"{c}: {e}")
        with open(os.path.join(objs, os.path.basename(c) + ".o"), "wb") as f:
            f.write(obj)
        kept.append(c)
    if not kept:
        raise LinkError(f"no code caches with blocks in {cache_dir}/cache")
    has_dispatcher = bool(dispatcher and os.path.isfile(dispatcher) and os.path.getsize(dispatcher))
    if has_dispatcher:
        with open(dispatcher, "rb") as f:
            asm = cache2macho.convert_dispatcher_asm(f.read(), False)
        with open(os.path.join(objs, "dispatcher.s"), "w") as f:
            f.write(asm)
        _assemble(tc, sdk, os.path.join(objs, "dispatcher.s"), os.path.join(objs, "dispatcher.o"), log)
    entries = [aotindex.entry(c) for c in kept]
    with open(os.path.join(objs, "index.s"), "w") as f:
        f.write(aotindex.index_asm(entries, has_dispatcher))
    _assemble(tc, sdk, os.path.join(objs, "index.s"), os.path.join(objs, "index.o"), log)
    obj_files = sorted(glob.glob(os.path.join(objs, "*.o")))
    os.makedirs(os.path.dirname(os.path.abspath(out)), exist_ok=True)
    if tc.kind == "xcode":
        triple = f"arm64-apple-ios{MIN_IOS}" + ("-simulator" if sdk == "iphonesimulator" else "")
        _run(["xcrun", "-sdk", sdk, "clang", "-target", triple, "-dynamiclib", "-install_name",
              "@rpath/fexaot.dylib", "-o", out] + obj_files, log)
    else:
        plat = "ios-simulator" if sdk == "iphonesimulator" else "ios"
        _run(tc.linker + ["-arch", "arm64", "-platform_version", plat, MIN_IOS, MIN_IOS, "-dylib",
                          "-install_name", "@rpath/fexaot.dylib", "-adhoc_codesign", "-o", out]
             + obj_files + [_libsystem_stub(sdk, objs)], log)
    log(f"Linked {out}: {os.path.getsize(out)} bytes, {len(kept)} caches"
        + (" and the dispatcher" if has_dispatcher else " (no dispatcher: the iPad can't run it without a JIT)"))
    return len(kept)
