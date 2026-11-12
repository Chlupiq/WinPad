"""Game profiles: settings a known game needs in WinPad Wine, put into its winpad.json.

A profile (data/profiles/<id>.json) says how to recognise the game and what it needs:

    {"id": "mafia", "version": 1, "title": "Mafia",
     "match": [{"steamAppId": 40990}, {"exe": "GameV12.exe"}, {"exe": "Game.exe", "files": ["LS3DF.dll"]}],
     "settings": {"dllOverrides": {"d3d8": "n,b"}},
     "notes": ["..."], "sources": ["https://..."]}

A game matches when any of its "match" rules does: "exe" is a file of the game folder
(any case, may have a folder in it), every one of "files" is there too, and "steamAppId"
is the folder's Steam app (steam_appid.txt in it, or the steamapps/appmanifest_<id>.acf
whose installdir it is). The rule's exe becomes the game's program.

The profile goes into winpad.json under the one key "profile", which this tool alone
writes: {"id", "version", "title", "notes", "settings"}. Everything else in winpad.json is
the user's and stays as it is. The app (tests/wine-app/Library.m) takes profile.settings
and lays the top-level keys over them (dictionaries key by key), so a user's own
"title", "exe", "args", "dllOverrides", "env" or "registry" wins over the profile's.

Settings keys (the app's):
  title, exe          the library's title and the game's program, relative to its folder
  args                list of arguments for the program
  dllOverrides        {"dll": "n,b" ...}: WINEDLLOVERRIDES (the app's default is dinput8=n,b)
  env                 {"NAME": "value"}: environment variables (not the app's own: WINE*, FEX_*, ...)
  registry            {"HKLM\\Software\\...": {"name": "text" | 123 | {"hex": "00ff"}}}: values
                      the registry gets when it does not have them yet (the game may change them)
  folders             ["Maps", ...]: folders, relative to the game's, the app makes before the
                      game starts: empty ones a game writes into (Mafia saves a mission's
                      progress in Maps), which copying the game often leaves out
"""
import json
import os
import re

from . import paths

PROFILES_DIR = os.path.join(paths.DATA, "profiles")
WINPAD_JSON = "winpad.json"
SETTINGS_KEYS = ("title", "exe", "args", "dllOverrides", "env", "registry", "folders")
DICT_KEYS = ("dllOverrides", "env", "registry")
REGISTRY_ROOTS = ("HKLM", "HKEY_LOCAL_MACHINE", "HKCU", "HKEY_CURRENT_USER")


class ProfileError(Exception):
    pass


def load_all(folder=PROFILES_DIR):
    """The profiles, by id."""
    profiles = {}
    for name in sorted(os.listdir(folder)) if os.path.isdir(folder) else []:
        if not name.endswith(".json"):
            continue
        with open(os.path.join(folder, name), encoding="utf-8") as f:
            prof = json.load(f)
        problems = check(prof)
        if problems:
            raise ProfileError(f"{name}: " + "; ".join(problems))
        profiles[prof["id"]] = prof
    return profiles


def check(prof):
    """What is wrong with profile PROF (a list of messages; empty if nothing)."""
    out = []
    if not isinstance(prof.get("id"), str) or not re.fullmatch(r"[a-z0-9][a-z0-9-]*", prof.get("id", "")):
        out.append("id must be lower-case letters, digits and -")
    if not isinstance(prof.get("version"), int):
        out.append("version must be a number")
    rules = prof.get("match")
    if not isinstance(rules, list) or not rules:
        out.append("match must be a list of rules")
    else:
        for rule in rules:
            if not isinstance(rule, dict) or not ({"exe", "steamAppId"} & set(rule)):
                out.append(f"match rule {rule!r} needs exe or steamAppId")
            elif set(rule) - {"exe", "files", "steamAppId"}:
                out.append(f"match rule {rule!r} has unknown keys")
    out += check_settings(prof.get("settings", {}))
    return out


def check_settings(s):
    out = []
    if not isinstance(s, dict):
        return ["settings must be an object"]
    for key in set(s) - set(SETTINGS_KEYS):
        out.append(f"unknown setting {key}")
    for key in ("title", "exe"):
        if key in s and not isinstance(s[key], str):
            out.append(f"{key} must be text")
    if "args" in s and not (isinstance(s["args"], list) and all(isinstance(a, str) for a in s["args"])):
        out.append("args must be a list of texts")
    if "folders" in s and not (isinstance(s["folders"], list) and all(
            isinstance(f, str) and f and not f.startswith(("/", "\\")) and ".." not in re.split(r"[/\\]", f)
            for f in s["folders"])):
        out.append("folders must be a list of folder names inside the game's")
    for key in ("dllOverrides", "env"):
        if key in s and not (isinstance(s[key], dict) and all(isinstance(v, str) for v in s[key].values())):
            out.append(f"{key} must map names to texts")
    for key, values in s.get("registry", {}).items():
        if key.split("\\", 1)[0].upper() not in REGISTRY_ROOTS or "\\" not in key:
            out.append(f"registry key {key} must start with HKLM\\ or HKCU\\")
        if not isinstance(values, dict):
            out.append(f"registry key {key} must map value names to values")
            continue
        for name, v in values.items():
            ok = (isinstance(v, str) or (isinstance(v, int) and not isinstance(v, bool) and 0 <= v <= 0xFFFFFFFF)
                  or (isinstance(v, dict) and set(v) == {"hex"} and re.fullmatch(r"([0-9a-fA-F]{2})*", v["hex"])))
            if not ok:
                out.append(f"registry value {key}\\{name}: text, a number up to 0xFFFFFFFF or {{\"hex\": \"..\"}}")
    return out


def _files_ci(game_dir):
    """Every file of GAME_DIR, by its lower-case path relative to it (with /)."""
    found = {}
    for top, dirs, files in os.walk(game_dir):
        rel = os.path.relpath(top, game_dir)
        depth = 0 if rel == "." else rel.count(os.sep) + 1
        if depth >= 3:
            dirs[:] = []
        for f in files:
            path = f if rel == "." else os.path.join(rel, f)
            found.setdefault(path.replace(os.sep, "/").lower(), path.replace(os.sep, "/"))
    return found


def steam_app_ids(game_dir):
    """The Steam app ids GAME_DIR is: steam_appid.txt in it, or the appmanifest of the
    steamapps folder it is in (steamapps/common/<installdir>)."""
    ids = set()
    try:
        with open(os.path.join(game_dir, "steam_appid.txt")) as f:
            ids.add(int(f.read().split()[0]))
    except (OSError, ValueError, IndexError):
        pass
    game_dir = os.path.normpath(os.path.abspath(game_dir))
    common = os.path.dirname(game_dir)
    if os.path.basename(common).lower() == "common":
        steamapps = os.path.dirname(common)
        for name in os.listdir(steamapps) if os.path.isdir(steamapps) else []:
            m = re.fullmatch(r"appmanifest_(\d+)\.acf", name)
            if not m:
                continue
            try:
                with open(os.path.join(steamapps, name), encoding="utf-8", errors="replace") as f:
                    text = f.read()
            except OSError:
                continue
            d = re.search(r'"installdir"\s+"([^"]*)"', text)
            if d and d.group(1).lower() == os.path.basename(game_dir).lower():
                ids.add(int(m.group(1)))
    return ids


def match(prof, game_dir, files=None, steam_ids=None):
    """(True, program relative to GAME_DIR or None) when PROF is the game in GAME_DIR."""
    files = _files_ci(game_dir) if files is None else files
    steam_ids = steam_app_ids(game_dir) if steam_ids is None else steam_ids
    for rule in prof["match"]:
        if "steamAppId" in rule and rule["steamAppId"] not in steam_ids:
            continue
        exe = None
        if "exe" in rule:
            exe = files.get(rule["exe"].replace("\\", "/").lower())
            if not exe:
                continue
        if not all(f.replace("\\", "/").lower() in files for f in rule.get("files", [])):
            continue
        return True, exe
    return False, None


def rule_exe(prof, files):
    """The first of PROF's rules' programs that FILES (_files_ci) has, or None: the program
    of a game matched by its Steam app alone, or given its profile by name."""
    for rule in prof["match"]:
        exe = files.get(rule.get("exe", "").replace("\\", "/").lower())
        if exe:
            return exe
    return None


def detect(game_dir, profiles=None):
    """The profile of the game in GAME_DIR and its program: (profile, exe) or (None, None)."""
    profiles = load_all() if profiles is None else profiles
    files, steam_ids = _files_ci(game_dir), steam_app_ids(game_dir)
    for prof in profiles.values():
        ok, exe = match(prof, game_dir, files, steam_ids)
        if ok:
            return prof, exe or rule_exe(prof, files)
    return None, None


def read_winpad_json(game_dir):
    """The game folder's winpad.json ({} if there is none). A file that is not a JSON object
    is an error: it is the user's, and is not written over."""
    path = os.path.join(game_dir, WINPAD_JSON)
    if not os.path.exists(path):
        return {}
    try:
        with open(path, encoding="utf-8-sig") as f:
            data = json.load(f)
    except ValueError as e:
        raise ProfileError(f"{path} is not valid JSON ({e}); fix it or remove it") from e
    if not isinstance(data, dict):
        raise ProfileError(f"{path} is not a JSON object")
    return data


def effective(data):
    """The settings the app uses for winpad.json DATA: the profile's, with the user's top-level
    keys over them (the same as Library.m's WinPadGameSettings)."""
    prof = data.get("profile")
    out = dict(prof.get("settings", {})) if isinstance(prof, dict) else {}
    for key, value in data.items():
        if key == "profile":
            continue
        if key in DICT_KEYS and isinstance(value, dict) and isinstance(out.get(key), dict):
            merged = dict(out[key])
            for k, v in value.items():
                if key == "registry" and isinstance(v, dict) and isinstance(merged.get(k), dict):
                    merged[k] = {**merged[k], **v}
                else:
                    merged[k] = v
            out[key] = merged
        else:
            out[key] = value
    return out


def apply(game_dir, choice="auto", profiles=None, log=print):
    """Puts the profile CHOICE ("auto": the one detect finds, "none": take it out, or an id)
    into GAME_DIR's winpad.json. Returns the profile, or None."""
    profiles = load_all() if profiles is None else profiles
    data = read_winpad_json(game_dir)
    if choice == "none":
        prof, exe = None, None
    elif choice in ("auto", "", None):
        prof, exe = detect(game_dir, profiles)
    else:
        if choice not in profiles:
            raise ProfileError(f"no profile {choice} (there are: {', '.join(profiles) or 'none'})")
        prof = profiles[choice]
        files = _files_ci(game_dir)
        exe = match(prof, game_dir, files)[1] or rule_exe(prof, files)
    if prof is None:
        if "profile" in data:
            del data["profile"]
            _write(game_dir, data)
            log(f"=== profile taken out of {WINPAD_JSON}")
        elif choice in ("auto", "", None):
            log("=== no profile for this game (it runs with the defaults)")
        return None
    settings = dict(prof.get("settings", {}))
    if exe:
        settings["exe"] = exe
    settings.setdefault("title", prof.get("title", ""))
    block = {"id": prof["id"], "version": prof["version"], "title": prof.get("title", ""),
             "notes": prof.get("notes", []), "settings": settings}
    if data.get("profile") != block:
        data["profile"] = block
        _write(game_dir, data)
        log(f"=== profile {prof['id']} v{prof['version']} ({prof.get('title', '')}) in {WINPAD_JSON}"
            + (f", program {exe}" if exe else ""))
    else:
        log(f"=== profile {prof['id']} v{prof['version']} ({prof.get('title', '')}) already in {WINPAD_JSON}")
    for note in prof.get("notes", []):
        log(f"  {note}")
    mine = {k for k in data if k != "profile" and k in settings and data[k] != settings[k]}
    if mine:
        log(f"  your own {', '.join(sorted(mine))} in {WINPAD_JSON} win over the profile's")
    return prof


def _write(game_dir, data):
    path = os.path.join(game_dir, WINPAD_JSON)
    tmp = path + ".tmp"
    with open(tmp, "w", encoding="utf-8", newline="\n") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, path)
