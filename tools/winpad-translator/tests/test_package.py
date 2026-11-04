"""WinPad packages (.winpad): the translator writes them (package.py), the iPad app reads them
(tests/wine-app/Package.c, built here with the C compiler and zlib where there are)."""
import json
import os
import shutil
import struct
import subprocess
import sys
import tempfile
import unittest
import zipfile

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(here, ".."))
from winpad_translator import cli, package, project  # noqa: E402

REPO = os.path.normpath(os.path.join(here, "..", "..", ".."))
APP = os.path.join(REPO, "tests", "wine-app")


def macho(path, signed):
    """A 64-bit Mach-O header with one load command: LC_CODE_SIGNATURE or LC_UUID."""
    cmd = struct.pack("<IIII", package.LC_CODE_SIGNATURE, 16, 0, 0) if signed else struct.pack("<II16s", 0x1B, 24, b"u" * 16)
    head = struct.pack("<IiiIIIII", 0xFEEDFACF, 0x0100000C, 0, 6, 1, len(cmd), 0, 0)
    with open(path, "wb") as f:
        f.write(head + cmd + b"\0" * 64)


def game(root, name="My Game", signed=True):
    d = os.path.join(root, name)
    os.makedirs(os.path.join(d, "DATA", "LEVELS"))
    with open(os.path.join(d, "GAME.EXE"), "wb") as f:
        f.write(b"MZ" + bytes(range(256)) * 40)
    with open(os.path.join(d, "DATA", "LEVELS", "one.bin"), "wb") as f:
        f.write(os.urandom(200000))
    with open(os.path.join(d, "DATA", "readme.txt"), "w") as f:
        f.write("hello " * 1000)
    with open(os.path.join(d, ".DS_Store"), "w") as f:
        f.write("x")
    with open(os.path.join(d, "winpad.json"), "w") as f:
        json.dump({"title": "Moje hra", "dlloverrides": "d3d8=n,b"}, f)
    with open(os.path.join(d, "cover.png"), "wb") as f:
        f.write(b"\x89PNG....")
    macho(os.path.join(d, "fexaot.dylib"), signed)
    with open(os.path.join(d, "fexaot.build"), "w") as f:
        f.write("abc123\n")
    return d


def package_tool(tmp):
    """Package.c built with package-tool.c, or None without a C compiler and zlib."""
    cc = shutil.which("cc") or shutil.which("gcc") or shutil.which("clang")
    if not cc or os.name == "nt":
        return None
    exe = os.path.join(tmp, "package-tool")
    r = subprocess.run([cc, "-O1", "-Wall", "-Werror", "-o", exe, os.path.join(APP, "package-tool.c"),
                        os.path.join(APP, "Package.c"), "-lz"], capture_output=True, text=True)
    if r.returncode:
        if os.environ.get("CI"):
            raise AssertionError(r.stderr)
        return None
    return exe


def tree(d):
    out = {}
    for dirpath, _, files in os.walk(d):
        for name in files:
            p = os.path.join(dirpath, name)
            with open(p, "rb") as f:
                out[os.path.relpath(p, d).replace(os.sep, "/")] = f.read()
    return out


class PackageTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, self.tmp, ignore_errors=True)

    def test_whole_game(self):
        d = game(self.tmp)
        out = package.write(d, os.path.join(self.tmp, "out") + os.sep, folder="MYGAME", exe="GAME.EXE", log=lambda _: None)
        self.assertEqual(os.path.basename(out), "MYGAME.winpad")
        with zipfile.ZipFile(out) as z:
            names = sorted(z.namelist())
            settings = json.loads(z.read("winpad.json"))
            self.assertEqual(z.getinfo("DATA/LEVELS/one.bin").compress_type, zipfile.ZIP_STORED)
            self.assertEqual(z.getinfo("DATA/readme.txt").compress_type, zipfile.ZIP_DEFLATED)
        self.assertEqual(names, ["DATA/LEVELS/one.bin", "DATA/readme.txt", "GAME.EXE", "cover.png", "fexaot.build",
                                 "fexaot.dylib", "winpad.json"])
        self.assertEqual(settings["title"], "Moje hra")
        self.assertEqual(settings["dlloverrides"], "d3d8=n,b")
        self.assertEqual(settings["exe"], "GAME.EXE")
        self.assertEqual(settings["package"]["folder"], "MYGAME")
        self.assertEqual(settings["package"]["image"], "fexaot.dylib")
        self.assertEqual(settings["package"]["app_build"], "abc123")
        self.assertTrue(settings["package"]["game_files"])

    def test_unsigned_image_left_out(self):
        d = game(self.tmp, signed=False)
        lines = []
        out = package.write(d, os.path.join(self.tmp, "g.winpad"), with_game=False, log=lines.append)
        with zipfile.ZipFile(out) as z:
            self.assertEqual(sorted(z.namelist()), ["cover.png", "winpad.json"])
            self.assertIsNone(json.loads(z.read("winpad.json"))["package"]["image"])
        self.assertTrue(any("not signed" in line for line in lines), lines)

    def test_refused(self):
        d = game(self.tmp)
        with self.assertRaises(package.PackageError):
            package.write(d, os.path.join(d, "x.winpad"), log=lambda _: None)
        with self.assertRaises(package.PackageError):
            package.write(d, os.path.join(self.tmp, "x.winpad"), folder="fexcache", log=lambda _: None)

    def test_cli_package_only(self):
        d = game(self.tmp)
        out = os.path.join(self.tmp, "cli.winpad")
        self.assertEqual(cli.main(["--game", d, "--work", os.path.join(self.tmp, "w"), "--package", out,
                                   "--package-no-game", "--package-only"]), 0)
        self.assertEqual(package.read_settings(out)["package"]["game_files"], False)

    def test_project_writes_package(self):
        d = game(self.tmp)
        p = project.Project(game_dir=d, exe="game.exe", package=os.path.join(self.tmp, "p") + os.sep)
        out = project.write_package(p, log=lambda _: None)
        self.assertEqual(package.read_settings(out)["exe"], "GAME.EXE")

    def test_ipad_reader(self):
        tool = package_tool(self.tmp)
        if not tool:
            self.skipTest("no C compiler with zlib")
        d = game(self.tmp)
        out = package.write(d, os.path.join(self.tmp, "g.winpad"), log=lambda _: None)
        settings = subprocess.run([tool, "read", out, "winpad.json"], capture_output=True, check=True).stdout
        self.assertEqual(json.loads(settings)["package"]["folder"], "My Game")
        dest = os.path.join(self.tmp, "ipad", "My Game")
        subprocess.run([tool, "extract", out, dest], check=True)
        want = tree(d)
        del want[".DS_Store"]
        got = tree(dest)
        self.assertEqual(json.loads(got.pop("winpad.json"))["title"], "Moje hra")
        del want["winpad.json"]
        self.assertEqual(got, want)

        # ZIP64 (as for a game over 4 GB), and folders as entries.
        z64 = os.path.join(self.tmp, "z64.winpad")
        with zipfile.ZipFile(z64, "w", allowZip64=True) as z:
            z.writestr("winpad.json", "{}")
            z.writestr(zipfile.ZipInfo("Saves/"), b"")
            with z.open("big.bin", "w", force_zip64=True) as f:
                f.write(b"abc" * 100000)
            info = zipfile.ZipInfo("packed.bin")
            info.compress_type = zipfile.ZIP_DEFLATED
            with z.open(info, "w", force_zip64=True) as f:
                f.write(b"xyz" * 300000)
        dest = os.path.join(self.tmp, "z64")
        subprocess.run([tool, "extract", z64, dest], check=True)
        self.assertEqual(tree(dest), {"winpad.json": b"{}", "big.bin": b"abc" * 100000, "packed.bin": b"xyz" * 300000})
        self.assertTrue(os.path.isdir(os.path.join(dest, "Saves")))

        # Names that would leave the folder, and a damaged file.
        for bad in ("../evil.txt", "/abs.txt", "a/../../b.txt", "win\\path.txt", "./x"):
            evil = os.path.join(self.tmp, "evil.winpad")
            with zipfile.ZipFile(evil, "w") as z:
                z.writestr("winpad.json", "{}")
                z.writestr(zipfile.ZipInfo(bad), b"x")
            r = subprocess.run([tool, "extract", evil, os.path.join(self.tmp, "evil")], capture_output=True, text=True)
            self.assertNotEqual(r.returncode, 0, bad)
            self.assertIn("outside its folder", r.stderr)
            self.assertFalse(os.path.exists(os.path.join(self.tmp, "evil.txt")))
        with open(out, "r+b") as f:
            data = f.read()
            at = data.index(b"hello hello") if b"hello hello" in data else data.index(bytes(range(256)))
            f.seek(at + 10)
            f.write(b"\xff\xfe")
        r = subprocess.run([tool, "extract", out, os.path.join(self.tmp, "bad")], capture_output=True, text=True)
        self.assertNotEqual(r.returncode, 0)
        self.assertIn("damaged", r.stderr)


if __name__ == "__main__":
    unittest.main()
