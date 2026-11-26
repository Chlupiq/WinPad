"""Unit tests of the game profiles (profiles.py) and the profiles shipped in data/profiles."""
import json
import os
import sys
import tempfile
import unittest

here = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, os.path.join(here, ".."))
from winpad_translator import cli, profiles, project  # noqa: E402


def touch(root, *names):
    for name in names:
        path = os.path.join(root, *name.split("/"))
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "wb") as f:
            f.write(b"MZ")


def read(game):
    with open(os.path.join(game, "winpad.json"), encoding="utf-8") as f:
        return json.load(f)


class ShippedProfilesTest(unittest.TestCase):
    def test_all_valid(self):
        shipped = profiles.load_all()
        self.assertIn("nfsu2", shipped)
        self.assertIn("mafia", shipped)
        self.assertIn("cod4", shipped)
        for prof in shipped.values():
            self.assertEqual(profiles.check(prof), [], prof["id"])
            self.assertTrue(prof.get("sources"), f"{prof['id']} names no sources")


class OnlineProfilesTest(unittest.TestCase):
    """data/online/profiles.json, which the iPad app downloads, is made from the profiles as they are."""

    def test_online_file_current(self):
        import subprocess
        tool = os.path.join(here, "..", "make-online-profiles.py")
        run = subprocess.run([sys.executable, tool, "--check"], capture_output=True, text=True)
        self.assertEqual(run.returncode, 0, run.stderr)
        with open(os.path.join(here, "..", "data", "online", "profiles.json"), encoding="utf-8") as f:
            data = json.load(f)
        self.assertEqual(data["format"], 1)
        ids = [p["id"] for p in data["profiles"]]
        self.assertEqual(ids[:3], ["cod4", "mafia", "nfsu2"])
        self.assertEqual(len(ids), len(set(ids)))


class DetectTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)

    def game(self, *files, name="Game"):
        d = os.path.join(self.tmp.name, name)
        os.makedirs(d, exist_ok=True)
        touch(d, *files)
        return d

    def test_nfsu2_any_case(self):
        g = self.game("speed2.exe", "Global/globala.bun", "scripts/x.asi")
        prof, exe = profiles.detect(g)
        self.assertEqual(prof["id"], "nfsu2")
        self.assertEqual(exe, "speed2.exe")

    def test_cod4_campaign(self):
        g = self.game("iw3sp.exe", "iw3mp.exe", "Main/IW_00.IWD", name="CoD4")
        prof, exe = profiles.detect(g)
        self.assertEqual(prof["id"], "cod4")
        self.assertEqual(exe, "iw3sp.exe")
        s = prof["settings"]
        self.assertEqual((s["padMouse"], s["touchMouse"], s["padKeys"]["r2"]), ("right", "trackpad", 1))
        self.assertIsNone(profiles.detect(self.game("iw3sp.exe", name="NoData"))[0])

    def test_mouse_settings_checked(self):
        bad = {"padKeys": {"a": 0, "trigger": 32}, "padMouse": "middle", "touchMouse": "swipe", "mouseSpeed": 0}
        problems = profiles.check_settings(bad)
        for key in ("padKeys", "padMouse", "touchMouse", "mouseSpeed"):
            self.assertTrue(any(p.startswith(key) for p in problems), key)
        self.assertEqual(profiles.check_settings({"padKeys": {"r2": 1}, "padMouse": "left", "mouseSpeed": 1.5}), [])

    def test_nfsu2_needs_its_data(self):
        self.assertEqual(profiles.detect(self.game("SPEED2.EXE"))[0], None)

    def test_mafia_patched_and_original(self):
        self.assertEqual(profiles.detect(self.game("GameV12.exe", "Setup.exe", name="M12")),
                         (profiles.load_all()["mafia"], "GameV12.exe"))
        self.assertEqual(profiles.detect(self.game("Game.exe", "Setup.exe", "LS3DF.dll", name="M10"))[1], "Game.exe")
        self.assertIsNone(profiles.detect(self.game("Game.exe", "Setup.exe", name="Other"))[0])

    def test_mafia_by_steam_manifest(self):
        steamapps = os.path.join(self.tmp.name, "steamapps")
        g = os.path.join(steamapps, "common", "Mafia")
        os.makedirs(g)
        touch(g, "Game.exe")
        with open(os.path.join(steamapps, "appmanifest_40990.acf"), "w") as f:
            f.write('"AppState"\n{\n\t"appid"\t\t"40990"\n\t"installdir"\t\t"Mafia"\n}\n')
        self.assertEqual(profiles.steam_app_ids(g), {40990})
        prof, exe = profiles.detect(g)
        self.assertEqual((prof["id"], exe), ("mafia", "Game.exe"))

    def test_steam_appid_txt(self):
        g = self.game("whatever.exe")
        with open(os.path.join(g, "steam_appid.txt"), "w") as f:
            f.write("40990\n")
        self.assertEqual(profiles.detect(g)[0]["id"], "mafia")

    def test_protonfixes_by_gog_id(self):
        # Kingdoms of Amalur: Re-Reckoning, Steam 1041720, GOG 1077045575 (umu-database).
        g = self.game("Amalur.exe")
        with open(os.path.join(g, "goggame-1077045575.info"), "w") as f:
            json.dump({"gameId": "1077045575"}, f)
        prof = profiles.detect(g)[0]
        self.assertEqual(prof["id"], "pf-1041720")
        self.assertIn("d3dcompiler_43", prof["settings"]["nativeDirectX"])

    def test_own_profile_wins_over_protonfixes(self):
        g = self.game("whatever.exe")
        with open(os.path.join(g, "steam_appid.txt"), "w") as f:
            f.write("40990\n")
        self.assertEqual(profiles.detect(g)[0]["id"], "mafia")


class ImportProtonfixesTest(unittest.TestCase):
    def test_converts_what_winpad_can_do(self):
        spec = __import__("importlib.util").util.spec_from_file_location(
            "import_protonfixes", os.path.join(here, "..", "import-protonfixes.py"))
        mod = __import__("importlib.util").util.module_from_spec(spec)
        spec.loader.exec_module(mod)
        s, left = mod.convert(r'''
from protonfixes import util
def main() -> None:
    """A game."""
    util.protontricks('d3dx9_43')
    util.protontricks('win7')
    util.protontricks('vcrun2019')
    util.winedll_override('xaudio2_7', util.OverrideOrder.NATIVE_BUILTIN)
    util.set_environment('DXVK_ASYNC', '1')
    util.set_environment('GAME_MODE', 'x')
    util.append_argument('-nointro -windowed')
    util.replace_command('Launcher.exe', 'Bin/Game.exe')
    util.regedit_add('HKCU\\Software\\Game', 'Res', 'REG_DWORD', '0x10')
    util.disable_esync()
    if util.get_game_install_path():
        util.append_argument('-x')
''')
        self.assertEqual(s, {"nativeDirectX": ["d3dx9_43"], "windowsVersion": "win7",
                             "dllOverrides": {"xaudio2_7": "n,b"}, "env": {"GAME_MODE": "x"},
                             "args": ["-nointro", "-windowed"], "exe": "Bin/Game.exe",
                             "registry": {"HKCU\\Software\\Game": {"Res": 16}}})
        self.assertIn("winetricks vcrun2019", left)
        self.assertEqual(profiles.check({"id": "pf-1", "version": 1, "match": [{"steamAppId": 1}], "settings": s}), [])


class ApplyTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.g = os.path.join(self.tmp.name, "NFSU2")
        touch(self.g, "SPEED2.EXE", "GLOBAL/GLOBALA.BUN")
        self.log = []

    def test_writes_profile_and_keeps_users_keys(self):
        with open(os.path.join(self.g, "winpad.json"), "w") as f:
            json.dump({"title": "Moje NFS", "dllOverrides": {"dsound": "n"}}, f)
        prof = profiles.apply(self.g, log=self.log.append)
        self.assertEqual(prof["id"], "nfsu2")
        data = read(self.g)
        self.assertEqual(data["title"], "Moje NFS")
        self.assertEqual(data["profile"]["id"], "nfsu2")
        self.assertEqual(data["profile"]["settings"]["exe"], "SPEED2.EXE")
        eff = profiles.effective(data)
        self.assertEqual(eff["title"], "Moje NFS")
        self.assertEqual(eff["dllOverrides"], {"dinput8": "n,b", "dsound": "n"})
        self.assertEqual(eff["registry"]["HKLM\\Software\\EA Games\\Need for Speed Underground 2"],
                         {"g_RacingResolution": 2})
        self.assertEqual(project.program_from_settings(self.g), os.path.join(self.g, "SPEED2.EXE"))

    def test_again_changes_nothing_and_none_removes(self):
        profiles.apply(self.g, log=self.log.append)
        before = os.path.getmtime(os.path.join(self.g, "winpad.json"))
        profiles.apply(self.g, log=self.log.append)
        self.assertEqual(os.path.getmtime(os.path.join(self.g, "winpad.json")), before)
        self.assertIn("already", self.log[-1 - len(profiles.load_all()["nfsu2"]["notes"])])
        profiles.apply(self.g, "none", log=self.log.append)
        self.assertNotIn("profile", read(self.g))

    def test_forced_profile_and_unknown(self):
        other = os.path.join(self.tmp.name, "Mafia")
        touch(other, "Game.exe")
        profiles.apply(other, "mafia", log=self.log.append)
        self.assertEqual(read(other)["profile"]["settings"]["exe"], "Game.exe")
        with self.assertRaises(profiles.ProfileError):
            profiles.apply(other, "nope", log=self.log.append)

    def test_users_broken_json_is_not_overwritten(self):
        path = os.path.join(self.g, "winpad.json")
        with open(path, "w") as f:
            f.write("{title: oops")
        with self.assertRaises(profiles.ProfileError):
            profiles.apply(self.g, log=self.log.append)
        with open(path) as f:
            self.assertEqual(f.read(), "{title: oops")

    def test_cli_profile_only(self):
        self.assertEqual(cli.main(["--game", self.g, "--profile-only"]), 0)
        self.assertEqual(read(self.g)["profile"]["id"], "nfsu2")
        self.assertEqual(cli.main(["--list-profiles"]), 0)

    def test_check_rejects_bad_settings(self):
        bad = {"id": "x", "version": 1, "match": [{"exe": "a.exe"}],
               "settings": {"registry": {"HKXX\\a": {"v": 1}, "HKCU\\b": {"v": True}}, "env": {"A": 1}, "foo": 1}}
        self.assertEqual(len(profiles.check(bad)), 4)


if __name__ == "__main__":
    unittest.main()
