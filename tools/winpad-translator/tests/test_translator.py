"""Unit tests of WinPad Translator: code map renaming, image naming, the IPA, linking with
LLVM (when it is installed) and a whole run with a stand-in for FEX's offline compiler."""
import importlib.util
import os
import plistlib
import struct
import sys
import tempfile
import unittest
import zipfile

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(here, ".."))
from winpad_translator import codemaps, ipa, link, project  # noqa: E402
from winpad_translator import compile as fexcompile  # noqa: E402

sys.path.insert(0, os.path.join(here, "..", "..", "fxcc-inspect"))
from test_fxcc_inspect import build_cache  # noqa: E402

IPAD = "\\??\\Z:\\private\\var\\mobile\\Containers\\Data\\Application\\0A1B-UUID\\Documents\\{}\\{}"
DATA_SLOT, LINK_RECORD, BLOCK_TAIL = 4, 5, 6  # FEX 3bec2ac (fxcc_inspect.RELOC_TYPES_WOW64)


def pe(path, stamp=0x12345678, size_of_image=0x20000):
    """A file with just enough PE header for FEX's file id."""
    head = bytearray(0x200)
    head[:2] = b"MZ"
    struct.pack_into("<I", head, 0x3C, 0x80)
    head[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<I", head, 0x80 + 8, stamp)
    struct.pack_into("<I", head, 0x80 + 24 + 56, size_of_image)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(head)
    return path


def file_id(path):
    fid = codemaps.pe_file_id(path)
    return fid if fid is not None else hash(os.path.basename(path)) & 0xFFFFFFFFFFFF


def write_map(path, images, main=None):
    """images: [(file id, name, [offsets])]"""
    out = bytearray()
    for fid, name, offsets in images:
        out += codemaps.image_record(fid, name)
        if fid == main:
            out += codemaps.ENTRY.pack(*codemaps.SET_MAIN) + struct.pack("<Q", fid)
        for o in offsets:
            out += codemaps.ENTRY.pack(fid, o)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(out)


def read(path):
    with open(path, "rb") as f:
        return f.read()


def write(path, data):
    with open(path, "wb") as f:
        f.write(data)


def names_in(path):
    with open(path, "rb") as f:
        return codemaps.parse(f.read())[0]


def aot_code():
    code = bytearray(b"\x1f\x20\x03\xd5" * 32)  # nop
    struct.pack_into("<I", code, 0, 0x60)  # block header: OffsetToBlockTail
    struct.pack_into("<II", code, 0x10, 0x90000000 | (1 << 5), 0xF9400000 | (1 << 10))  # adrp; ldr
    struct.pack_into("<II", code, 0x20, 0x90000000, 0x91000000 | (8 << 10))  # adrp; add
    return bytes(code)


def write_cache(cache_dir, name, fid):
    tail = struct.pack("<IQI", 16, 0x1000, 0x60)
    data = build_cache(blocks=[(0x1000, 4, [0x1000])],
                       relocs=[(0x10, DATA_SLOT, b""), (0x20, LINK_RECORD, b""), (0x60, BLOCK_TAIL, tail)],
                       code=aot_code())
    os.makedirs(os.path.join(cache_dir, "cache"), exist_ok=True)
    with open(os.path.join(cache_dir, "cache", f"{name}-{fid:016x}-{0:016x}"), "wb") as f:
        f.write(data)


def toolchain():
    try:
        return link.find_toolchain("llvm")
    except link.LinkError:
        # CI has LLVM on every system it runs these on; there a missing one is a failure.
        if os.environ.get("WINPAD_REQUIRE_LLVM"):
            raise
        return None


class SlugTest(unittest.TestCase):
    def test_like_the_app_library(self):
        self.assertEqual(codemaps.slug("NFSU2"), "nfsu2")
        self.assertEqual(codemaps.slug("Need for Speed: Underground 2"), "need-for-speed-underground-2")
        self.assertEqual(codemaps.slug("  Test Game!"), "test-game")
        self.assertEqual(project.Project(game_dir="/g/Half-Life").image_name(), "fexaot-half-life.dylib")


class RehomeTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        t = self.tmp.name
        self.game = os.path.join(t, "My Game")
        self.system = os.path.join(t, "i386-windows")
        self.exe = pe(os.path.join(self.game, "Bin", "GAME.EXE"))
        self.dll = pe(os.path.join(self.game, "Bin", "engine.dll"), stamp=7)
        self.ntdll = pe(os.path.join(self.system, "ntdll.dll"), stamp=9)
        self.map = os.path.join(t, "new", "a.bin")
        write_map(self.map, [
            (file_id(self.exe), IPAD.format("My Game", "Bin\\GAME.EXE"), [0x1000, 0x1010]),
            (file_id(self.dll), IPAD.format("My Game", "bin\\ENGINE.DLL"), [0x2000]),
            (file_id(self.ntdll), "\\??\\C:\\windows\\syswow64\\ntdll.dll", [0x3000]),
            (0x1111, "\\??\\C:\\windows\\syswow64\\missing.dll", [0x10]),
            (0x2222, "rtcode-00401000-0123456789abcdef.fexrc", [0x0]),
        ], main=file_id(self.exe))

    def tearDown(self):
        self.tmp.cleanup()

    def test_images_point_here(self):
        resolver = codemaps.Resolver(self.game, None, self.system)
        to_name = fexcompile.Wine("c.exe", self.tmp.name).image_name
        renamed, missing, mismatched = codemaps.rehome([self.map], resolver, to_name, log=lambda _: None)
        names = names_in(self.map)
        self.assertEqual(renamed, 3)
        self.assertEqual(missing, {"\\??\\C:\\windows\\syswow64\\missing.dll"})
        self.assertEqual(mismatched, set())
        self.assertEqual(names[file_id(self.dll)], to_name(self.dll))  # case differs on the iPad
        self.assertEqual(names[file_id(self.ntdll)], to_name(self.ntdll))
        self.assertEqual(names[0x2222], "rtcode-00401000-0123456789abcdef.fexrc")
        if os.name != "nt":
            self.assertTrue(to_name(self.exe).startswith("\\??\\Z:\\"))
        # Blocks and the main executable record stay.
        _, blocks, main, left = codemaps.parse(read(self.map))
        self.assertEqual(blocks[file_id(self.exe)], {0x1000, 0x1010})
        self.assertEqual(main, file_id(self.exe))
        self.assertEqual(left, 0)

    @unittest.skipUnless(importlib.util.find_spec("xxhash"), "needs xxhash")
    def test_other_file_is_reported(self):
        pe(self.dll, stamp=8)  # a patched DLL: other link time
        resolver = codemaps.Resolver(self.game, None, self.system)
        _, _, mismatched = codemaps.rehome([self.map], resolver, lambda p: p, log=lambda _: None)
        self.assertEqual(len(mismatched), 1)

    def test_simulator_keeps_system_names(self):
        sim = fexcompile.Simulator("c.exe", self.tmp.name, work_dir="w")
        codemaps.rehome([self.map], codemaps.Resolver(self.game, None, None), sim.image_name, sim.keep_name,
                        log=lambda _: None)
        self.assertEqual(names_in(self.map)[file_id(self.ntdll)], "\\??\\C:\\windows\\syswow64\\ntdll.dll")

    def test_half_barrier_and_main_name(self):
        self.assertEqual(codemaps.mark_half_barrier([self.map]), 6)
        _, blocks, _, _ = codemaps.parse(read(self.map))
        self.assertTrue(all(o & codemaps.HALF_BARRIER for b in blocks.values() for o in b))
        unnamed = os.path.join(self.tmp.name, "new", "b.bin")
        with open(unnamed, "wb") as f:
            f.write(codemaps.ENTRY.pack(*codemaps.SET_MAIN) + struct.pack("<Q", 0x77))
        self.assertEqual(codemaps.name_main([self.map, unnamed], "\\??\\Z:\\g\\GAME.EXE"), 1)
        self.assertEqual(names_in(unnamed)[0x77], "\\??\\Z:\\g\\GAME.EXE")

    def test_ipad_folders(self):
        self.assertEqual(codemaps.ipad_folders(names_in(self.map).values()), ["My Game"])


class IpaTest(unittest.TestCase):
    def test_dlls_out_image_in(self):
        with tempfile.TemporaryDirectory() as t:
            src = os.path.join(t, "WinPadWine.ipa")
            with zipfile.ZipFile(src, "w") as z:
                z.writestr("Payload/WinPadWine.app/WinPadWine", b"app")
                z.writestr("Payload/WinPadWine.app/i386-windows/ntdll.dll", b"MZ")
                z.writestr("Payload/WinPadWine.app/i386-windows/hello.exe", b"MZ")
                z.writestr("Payload/WinPadWine.app/Frameworks/fexaot-game.dylib", b"old")
            self.assertEqual(ipa.extract_system_dlls(src, os.path.join(t, "sys")), 2)
            image = os.path.join(t, "fexaot-game.dylib")
            with open(image, "wb") as f:
                f.write(b"new")
            out = os.path.join(t, "out.ipa")
            ipa.add_images(src, out, [image])
            with zipfile.ZipFile(out) as z:
                self.assertEqual(z.read("Payload/WinPadWine.app/Frameworks/fexaot-game.dylib"), b"new")
                self.assertEqual(z.read("Payload/WinPadWine.app/WinPadWine"), b"app")
                self.assertEqual(len(z.namelist()), 4)

    def test_app_name(self):
        with tempfile.TemporaryDirectory() as t:
            src = os.path.join(t, "WinPadWine.ipa")
            info = {"CFBundleDisplayName": "WinPad Wine", "CFBundleIdentifier": "com.example.winpad"}
            with zipfile.ZipFile(src, "w") as z:
                z.writestr("Payload/WinPadWine.app/Info.plist", plistlib.dumps(info, fmt=plistlib.FMT_BINARY))
            out = os.path.join(t, "out.ipa")
            ipa.add_images(src, out, [], app_name="Moje hra")
            with zipfile.ZipFile(out) as z:
                data = z.read("Payload/WinPadWine.app/Info.plist")
            # Still binary, as the installer got it; only the name under the icon changed.
            self.assertTrue(data.startswith(b"bplist"))
            self.assertEqual(plistlib.loads(data), dict(info, CFBundleDisplayName="Moje hra"))
            project_plist = os.path.join(t, "Info.plist")
            write(project_plist, plistlib.dumps({"CFBundleDisplayName": "WinPad Wine",
                                                 "CFBundleExecutable": "$(EXECUTABLE_NAME)"}))
            ipa.rename_app(project_plist, "Moje hra")
            with open(project_plist, "rb") as f:
                self.assertEqual(plistlib.load(f), {"CFBundleDisplayName": "Moje hra",
                                                    "CFBundleExecutable": "$(EXECUTABLE_NAME)"})


@unittest.skipUnless(toolchain(), "needs LLVM (clang or llvm-mc, and lld)")
class LinkTest(unittest.TestCase):
    def test_dylib_for_both_sdks(self):
        self.check_link(toolchain())

    @unittest.skipUnless(sys.platform == "darwin", "Xcode is on a Mac only")
    def test_dylib_with_xcode(self):
        self.check_link(link.find_toolchain())

    def check_link(self, tc):
        with tempfile.TemporaryDirectory() as t:
            write_cache(t, "game.exe", 0x0123456789ABCDEF)
            write_cache(t, "ntdll.dll", 0x1111)
            dispatcher = os.path.join(t, "dispatcher.bin")
            with open(dispatcher, "wb") as f:
                f.write(b"\x1f\x20\x03\xd5" * 8)
            for sdk, platform in (("iphoneos", 2), ("iphonesimulator", 7)):
                out = os.path.join(t, sdk, "fexaot-game.dylib")
                self.assertEqual(link.link_image(t, out, sdk, dispatcher, tc, log=lambda _: None), 2)
                data = read(out)
                magic, cputype, _, filetype = struct.unpack_from("<IiII", data)
                self.assertEqual((magic, cputype, filetype), (0xFEEDFACF, 0x0100000C, 6))  # arm64 MH_DYLIB
                cmd = data.index(struct.pack("<I", 0x32))  # LC_BUILD_VERSION
                self.assertEqual(struct.unpack_from("<I", data, cmd + 8)[0], platform)
                self.assertIn(b"_fexaot_index", data)
                self.assertIn(b"@rpath/fexaot.dylib", data)


FAKE_COMPILER = r'''#!/usr/bin/env python3
# Stands in for FEXOfflineCompiler.exe: one cache per image the ready maps name.
import os, struct, sys
sys.path.insert(0, {tests!r})
import test_translator as t
loc = os.environ["FEX_APP_CACHE_LOCATION"]
cache = "/" + loc[3:].replace("\\", "/") if loc[1] == ":" and os.name != "nt" else loc
new, ready = os.path.join(cache, "codemap", "new"), os.path.join(cache, "codemap", "ready")
with open(os.path.join(cache, "hostprobe-seen.txt"), "w") as f:
    f.write(os.environ.get("FEX_MADEIRA_HOSTPROBE", ""))
os.makedirs(ready, exist_ok=True)
for n in os.listdir(new):
    if n.endswith(".bin"):
        os.replace(os.path.join(new, n), os.path.join(ready, n))
for n in os.listdir(ready):
    names, _, _, _ = t.codemaps.parse(open(os.path.join(ready, n), "rb").read())
    for fid, name in names.items():
        assert name.startswith("\\??\\"), name
        t.write_cache(cache, t.codemaps.basename(name).lower(), fid)
print("[process-all] 2 caches generated (0 failed), 0 left for the next process-all")
'''


@unittest.skipIf(os.name == "nt" or not toolchain(), "needs a POSIX shell for the fake compiler and LLVM")
class RunTest(unittest.TestCase):
    def test_ipad_maps_to_ipa(self):
        with tempfile.TemporaryDirectory() as t:
            game = os.path.join(t, "Some Game")
            exe = pe(os.path.join(game, "game.exe"))
            maps = os.path.join(t, "from-ipad", "new")
            write_map(os.path.join(maps, "x.bin"), [(file_id(exe), IPAD.format("Some Game", "game.exe"), [0x1000])],
                      main=file_id(exe))
            os.makedirs(os.path.join(maps, "runtime"))
            write(os.path.join(maps, "hostprobe.txt"), b"AFP=1,FLAGM=1,FLAGM2=1\n")
            write(os.path.join(maps, "runtime", "rtcode-1.fexrc"), b"x")
            src = os.path.join(t, "WinPadWine.ipa")
            with zipfile.ZipFile(src, "w") as z:
                z.writestr("Payload/WinPadWine.app/i386-windows/ntdll.dll", b"MZ")
            compiler = os.path.join(t, "fake-compiler")
            with open(compiler, "w") as f:
                f.write(FAKE_COMPILER.format(tests=here))
            os.chmod(compiler, 0o755)
            dispatcher = os.path.join(t, "dispatcher.bin")
            write(dispatcher, b"\x1f\x20\x03\xd5" * 8)
            p = project.Project(game_dir=game, work_dir=os.path.join(t, "work"), ipad_maps=[maps], ipa=src,
                                compiler=compiler, dispatcher=dispatcher, backend="native",
                                output_ipa=os.path.join(t, "out.ipa"), simulator_image=True)
            lines = []
            made = project.run(p, log=lines.append)
            self.assertEqual([os.path.basename(m) for m in made], ["fexaot-some-game.dylib"] * 2)
            with zipfile.ZipFile(os.path.join(t, "out.ipa")) as z:
                self.assertIn("Payload/WinPadWine.app/Frameworks/fexaot-some-game.dylib", z.namelist())
            self.assertTrue(os.path.isfile(os.path.join(t, "work", "fexcache", "codemap", "new", "runtime",
                                                        "rtcode-1.fexrc")))
            # The settings are kept for the next round, without the maps already taken.
            again = project.Project.load(os.path.join(t, "work", project.SETTINGS))
            self.assertEqual((again.game_dir, again.ipad_maps), (game, []))
            # The compiler compiled for the iPad's CPU features, which the app wrote next to its maps.
            self.assertEqual(again.host_features, "AFP=1,FLAGM=1,FLAGM2=1")
            with open(os.path.join(t, "work", "fexcache", "hostprobe-seen.txt")) as f:
                self.assertEqual(f.read(), "AFP=1,FLAGM=1,FLAGM2=1")


if __name__ == "__main__":
    unittest.main()
