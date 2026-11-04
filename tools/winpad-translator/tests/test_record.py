"""Tests of "Play and record" (record.py): DynamoRIO's download and command, drcov logs of the game
and its own DLLs into code maps, and the Mac's recording in an iPad simulator with stand-ins for
xcodebuild and simctl."""
import io
import json
import os
import plistlib
import struct
import sys
import tempfile
import threading
import unittest
import zipfile
from unittest import mock

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(here, ".."))
from winpad_translator import codemaps, project, record  # noqa: E402

try:
    import capstone  # noqa: F401
    import pefile  # noqa: F401
    import xxhash  # noqa: F401
    HAVE_PE_TOOLS = True
except ImportError:
    HAVE_PE_TOOLS = False


def x86_pe(path, code, base=0x400000, stamp=0x5A5A5A5A):
    """A 32-bit x86 PE with CODE in its one section, .text at 0x1000."""
    opt = struct.pack("<HBBIIIIIIIIIHHHHHHIIIIHHIIIIII", 0x10B, 14, 0, 0x200, 0, 0, 0x1000, 0x1000, 0x2000, base,
                      0x1000, 0x200, 6, 0, 0, 0, 6, 0, 0, 0x2000, 0x200, 0, 3, 0, 0x100000, 0x1000, 0x100000,
                      0x1000, 0, 16) + bytes(16 * 8)
    assert len(opt) == 0xE0
    head = bytearray(0x200)
    head[:2] = b"MZ"
    struct.pack_into("<I", head, 0x3C, 0x40)
    hdr = b"PE\0\0" + struct.pack("<HHIIIHH", 0x14C, 1, stamp, 0, 0, len(opt), 0x102) + opt
    sec = struct.pack("<8sIIIIIIHHI", b".text", len(code), 0x1000, 0x200, 0x200, 0, 0, 0, 0, 0x60000020)
    head[0x40:0x40 + len(hdr) + len(sec)] = hdr + sec
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "wb") as f:
        f.write(bytes(head) + code.ljust(0x200, b"\xcc"))
    return path


# call +3 (to 0x1008); ret; int3 x2; ret
CODE = bytes.fromhex("e803000000c3cccc" "c3")


def drcov_log(path, modules, blocks):
    """A drcov log as -dump_text writes it. modules: [(path, base, end)], blocks: [(module, offset, size)]."""
    lines = ["DRCOV VERSION: 2", "DRCOV FLAVOR: drcov", f"Module Table: version 2, count {len(modules)}",
             "Columns: id, base, end, entry, checksum, timestamp, path"]
    lines += [f" {i}, {base:#010x}, {end:#010x}, 0x00000000, 0x00000000, 0x00000000, {p}"
              for i, (p, base, end) in enumerate(modules)]
    lines += [f"BB Table: {len(blocks)} bbs", "module id, start, size:"]
    lines += [f"module[{m:3}]: {off:#010x}, {size:3}" for m, off, size in blocks]
    with open(path, "w", newline="\n") as f:
        f.write("\n".join(lines) + "\n")
    return path


class Backend:
    @staticmethod
    def image_name(local):
        return "\\??\\Z:" + local.replace("/", "\\")


class DynamoRioTest(unittest.TestCase):
    def test_download_takes_the_windows_zip(self):
        buf = io.BytesIO()
        with zipfile.ZipFile(buf, "w") as z:
            z.writestr("DynamoRIO-Windows-11.3.0/bin32/drrun.exe", b"MZ")
            z.writestr("DynamoRIO-Windows-11.3.0/bin64/drrun.exe", b"MZ")
        releases = [{"tag_name": "cronbuild-11.90", "prerelease": True, "assets": []},
                    {"tag_name": "release_11.3.0", "assets": [
                        {"name": "DynamoRIO-Linux-11.3.0.tar.gz", "browser_download_url": "https://x/linux"},
                        {"name": "DynamoRIO-Windows-11.3.0.zip", "browser_download_url": "https://x/win"}]}]
        asked = []

        def urlopen(req, timeout=None):
            asked.append(req.full_url)
            return io.BytesIO(json.dumps(releases).encode() if "api.github.com" in req.full_url else buf.getvalue())

        with tempfile.TemporaryDirectory() as t:
            root = record.download_dynamorio(log=lambda *_: None, urlopen=urlopen, into=t)
            self.assertEqual(asked[-1], "https://x/win")
            self.assertEqual(root, os.path.join(t, "DynamoRIO-Windows-11.3.0"))
            self.assertEqual(record.dynamorio_root(root), root)
            self.assertFalse(os.path.exists(os.path.join(t, "DynamoRIO-Windows-11.3.0.zip")))

    def test_bits_follow_the_game(self):
        with tempfile.TemporaryDirectory() as t:
            exe = x86_pe(os.path.join(t, "GAME.EXE"), CODE)
            cmd = record.drrun_command("D", exe, "L", ["-window"])
            self.assertEqual(cmd, [os.path.join("D", "bin32", "drrun.exe"), "-t", "drcov", "-logdir", "L", "--", exe,
                                   "-window"])
            self.assertEqual(record.pe_machine(exe), 0x14C)

    def test_stop_closes_then_kills(self):
        class Proc:
            def __init__(self):
                self.killed = False

            def poll(self):
                return None

            def wait(self, timeout=None):
                if not self.killed:
                    raise record.subprocess.TimeoutExpired("game", timeout)

            def kill(self):
                self.killed = True

        proc, stop, closed = Proc(), threading.Event(), []
        stop.set()
        record.wait(proc, stop, lambda: closed.append(1), lambda *_: None, grace=0)
        self.assertEqual(closed, [1])
        self.assertTrue(proc.killed)


@unittest.skipUnless(HAVE_PE_TOOLS, "needs pefile, capstone and xxhash")
class DrcovTest(unittest.TestCase):
    def test_exe_and_game_dlls(self):
        # pefile keeps the images mapped until it is collected, which Windows does not let go of.
        with tempfile.TemporaryDirectory(ignore_cleanup_errors=True) as t:
            game = os.path.join(t, "My Game")
            exe = x86_pe(os.path.join(game, "GAME.EXE"), CODE)
            dll = x86_pe(os.path.join(game, "bin", "engine.dll"), CODE, base=0x10000000, stamp=0x1234)
            launcher = x86_pe(os.path.join(game, "launch.exe"), CODE, stamp=0x99)
            logs = os.path.join(t, "logs")
            os.makedirs(logs)
            # The launcher's own process first: it never ran GAME.EXE.
            drcov_log(os.path.join(logs, "drcov.launch.exe.1.log"), [(launcher, 0x400000, 0x402000)], [(0, 0x1000, 5)])
            drcov_log(os.path.join(logs, "drcov.GAME.EXE.2.log"),
                      [(exe, 0x400000, 0x402000), ("C:\\Windows\\SysWOW64\\kernel32.dll", 0x76000000, 0x76100000),
                       (dll, 0x10000000, 0x10002000)],
                      [(0, 0x1000, 5), (0, 0x1005, 1), (0, 0x1008, 1), (1, 0x2000, 3), (2, 0x1000, 5), (2, 0x1008, 1)])
            all_logs = sorted(os.path.join(logs, n) for n in os.listdir(logs))
            self.assertEqual(record.logs_with(all_logs, "game.exe"), [os.path.join(logs, "drcov.GAME.EXE.2.log")])
            new = os.path.join(t, "work", "codemap", "new")
            os.makedirs(new)
            seed = project._seed_map(new, exe, Backend, [])
            made = record.drcov_to_maps(all_logs, exe, game, new, Backend.image_name, seed, log=lambda *_: None)
            self.assertEqual(len(made), 3)  # GAME.EXE, engine.dll, launch.exe
            maps = {}
            for path in made:
                with open(path, "rb") as f:
                    names, blocks, main, _ = codemaps.parse(f.read())
                maps[os.path.basename(path)] = (names, blocks, main)
            exe_id, dll_id = codemaps.pe_file_id(exe), codemaps.pe_file_id(dll)
            exe_map = next(v for k, v in maps.items() if not k.startswith("drcov-engine") and
                           not k.startswith("drcov-launch"))
            self.assertEqual(exe_map[2], exe_id)
            self.assertEqual(sorted(exe_map[1][exe_id]), [0x1000, 0x1005, 0x1008])
            dll_map = next(v for k, v in maps.items() if k.startswith("drcov-engine"))
            # Named with the game's main program, as the iPad's maps are; only the DLL's blocks.
            self.assertEqual(dll_map[2], exe_id)
            self.assertEqual(dll_map[0][dll_id], Backend.image_name(dll))
            self.assertEqual(sorted(dll_map[1][dll_id]), [0x1000, 0x1005, 0x1008])
            self.assertNotIn(exe_id, dll_map[1])
            self.assertFalse([n for n in os.listdir(new) if n.endswith(".tmp")])


class SimulatorTest(unittest.TestCase):
    LISTING = json.dumps({"devices": {
        "com.apple.CoreSimulator.SimRuntime.iOS-16-4": [{"udid": "OLD", "name": "iPad Pro", "isAvailable": True}],
        "com.apple.CoreSimulator.SimRuntime.iOS-18-2": [
            {"udid": "PHONE", "name": "iPhone 16", "isAvailable": True},
            {"udid": "AIR", "name": "iPad Air 13-inch (M2)", "isAvailable": True}],
        "com.apple.CoreSimulator.SimRuntime.iOS-26-0": [
            {"udid": "PRO", "name": "iPad Pro 13-inch (M4)", "isAvailable": True},
            {"udid": "GONE", "name": "iPad Pro 11-inch (M4)", "isAvailable": False}]}})

    def test_pick_ipad(self):
        self.assertEqual(record.pick_ipad(self.LISTING), ("PRO", "iPad Pro 13-inch (M4)"))
        booted = json.loads(self.LISTING)
        booted["devices"]["com.apple.CoreSimulator.SimRuntime.iOS-18-2"][1]["state"] = "Booted"
        self.assertEqual(record.pick_ipad(json.dumps(booted))[0], "AIR")
        with self.assertRaises(record.RecordError):
            record.pick_ipad(json.dumps({"devices": {"com.apple.CoreSimulator.SimRuntime.iOS-16-4": []}}))

    def test_record_in_the_simulator(self):
        with tempfile.TemporaryDirectory() as t:
            game = os.path.join(t, "games", "My Game")
            os.makedirs(os.path.join(game, "DATA"))
            with open(os.path.join(game, "GAME.EXE"), "wb") as f:
                f.write(b"MZ game")
            with open(os.path.join(game, "DATA", "a.bin"), "wb") as f:
                f.write(b"data")
            xcode = os.path.join(t, "WinPadWine-xcode")
            os.makedirs(os.path.join(xcode, "WinPadWine.xcodeproj"))
            work = os.path.join(t, "work")
            data = os.path.join(t, "CoreSimulator", "Devices", "PRO", "data", "Containers", "Data", "Application",
                                "UUID")
            docs = os.path.join(data, "Documents")
            calls = []

            def run(cmd, **kw):
                calls.append(cmd)
                out = ""
                if cmd[0] == "xcodebuild":
                    derived = cmd[cmd.index("-derivedDataPath") + 1]
                    app = os.path.join(derived, "Build", "Products", "Debug-iphonesimulator", "WinPadWine.app")
                    os.makedirs(app)
                    with open(os.path.join(app, "Info.plist"), "wb") as f:
                        plistlib.dump({"CFBundleIdentifier": "com.chlupiq.winpad.wine"}, f)
                elif cmd[:3] == ["xcrun", "simctl", "list"]:
                    out = self.LISTING
                elif cmd[:3] == ["xcrun", "simctl", "get_app_container"]:
                    out = data + "\n"
                elif cmd[:3] == ["xcrun", "simctl", "launch"]:
                    self.assertEqual(cmd[-2:], ["-recordGame", "My Game"])
                    # The app: the game ran with the JIT and FEX wrote its code map.
                    self.assertTrue(os.path.isfile(os.path.join(docs, "My Game", "DATA", "a.bin")))
                    maps = os.path.join(docs, "fexcache", "My Game", "codemap", "new")
                    os.makedirs(maps)
                    # As Wine on the Mac names it (Z: is the Mac's root), whatever this computer is.
                    name = ("\\??\\Z:\\Users\\me\\Library\\Developer\\CoreSimulator\\Devices\\PRO\\data\\"
                            "Containers\\Data\\Application\\UUID\\Documents\\My Game\\GAME.EXE")
                    with open(os.path.join(maps, "1234.1.bin"), "wb") as f:
                        f.write(codemaps.image_record(0x1234, name) + codemaps.ENTRY.pack(*codemaps.SET_MAIN) +
                                struct.pack("<Q", 0x1234) + codemaps.ENTRY.pack(0x1234, 0x1000))
                    with open(os.path.join(maps, "hostprobe.txt"), "w") as f:
                        f.write("AFP=0\n")
                    with open(os.path.join(docs, "wine.log"), "w") as f:
                        f.write("winehost: starting\n== finished, exit 0\n")
                elif cmd[:2] == ["cp", "-cR"]:
                    return mock.Mock(returncode=1, stdout="", stderr="no clones here")
                return mock.Mock(returncode=0, stdout=out, stderr="")

            lines = []
            with mock.patch.object(record.sys, "platform", "darwin"):
                out = record.record_simulator(game, "My Game", xcode, work, log=lines.append, run=run, poll=0.01)
            self.assertTrue(any(c[0] == "xcodebuild" and "CODE_SIGNING_ALLOWED=NO" in c for c in calls))
            self.assertIn(["xcrun", "simctl", "terminate", "PRO", "com.chlupiq.winpad.wine"], calls)
            new = os.path.join(out, "codemap", "new")
            self.assertEqual(os.listdir(new), ["1234.1.bin"])  # the Mac's CPU features left out
            # Taken as the iPad's maps: the simulator's Documents path is the game folder.
            names, _, _ = codemaps.summary(codemaps.map_files(new))
            self.assertEqual(codemaps.ipad_folders(names.values()), ["My Game"])
            resolver = codemaps.Resolver(game, "My Game")
            self.assertEqual(resolver.resolve(names[0x1234])[0], os.path.join(game, "GAME.EXE"))

    def test_record_puts_maps_into_the_project(self):
        p = project.Project(game_dir=tempfile.mkdtemp(), xcode_project="X")
        with mock.patch.object(record.sys, "platform", "darwin"), \
                mock.patch.object(record, "record_simulator", return_value="/rec/fexcache/g") as sim:
            record.record(p)
        self.assertEqual(p.ipad_maps, ["/rec/fexcache/g"])
        self.assertEqual(sim.call_args.args[1], os.path.basename(p.game_dir))
        os.rmdir(p.game_dir)


if __name__ == "__main__":
    unittest.main()
