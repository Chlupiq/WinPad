#!/usr/bin/env python3
"""Turns umu-protonfixes' game fixes into WinPad game profiles (data/protonfixes.json).

umu-protonfixes (https://github.com/Open-Wine-Components/umu-protonfixes, BSD 2-Clause)
is the set of per-game fixes Proton and umu run before a game: one Python file per game,
named by its Steam app id (gamefixes-steam/<id>.py) or its umu id (gamefixes-gog/umu-<id>.py
and the others). Most are a few calls of its util module. This reads them without running
them (ast) and keeps what WinPad Wine can do the same way:

  util.winedll_override(dll, OverrideOrder.X)   -> dllOverrides
  util.set_environment(name, value)             -> env (not Proton's, DXVK's, VKD3D's ...)
  util.append_argument(arg)                     -> args
  util.regedit_add(key, name, type, value)      -> registry
  util.replace_command(launcher, game.exe)      -> exe (the game, not its launcher)
  util.protontricks('d3dx9_43' ...)             -> nativeDirectX (Microsoft's DLLs, which the
                                                   app downloads), 'win7' ... -> windowsVersion

Everything else (fonts, Visual C++, .NET, PhysX, ini edits, code with ifs) is left out and
named in the profile's notes. A fix with nothing WinPad can use gives no profile.

The profiles match a game by its Steam app id (steam_appid.txt, a steamapps manifest) or its
GOG id (goggame-<id>.info, mapped to the umu id by umu-database.csv). The app and this tool's
profiles.py read data/protonfixes.json after data/profiles, whose own profiles win.

  import-protonfixes.py UMU_PROTONFIXES_DIR UMU_DATABASE_CSV [OUT]
"""
import ast
import csv
import json
import os
import re
import shlex
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, "data", "protonfixes.json")

ORDERS = {"DISABLED": "", "NATIVE": "n", "BUILTIN": "b", "NATIVE_BUILTIN": "n,b", "BUILTIN_NATIVE": "b,n"}
# Environment of Proton, its graphics layers and Linux: nothing in WinPad Wine reads them.
ENV_SKIP = re.compile(r"^(PROTON_|DXVK_|VKD3D_|WINE|STAGING_|__GL|MESA|RADV|VK_|LD_|PULSE|STEAM|SteamGameId|"
                      r"SDL_VIDEODRIVER|DISPLAY|ENABLE_VKBASALT|MANGOHUD|DXIL|WINEDLL|FEX_|DYLD_)")
WINVER = {"winxp": "winxp", "winxp64": "winxp", "win2k": "win2k", "win98": "win98", "win95": "win95",
          "vista": "vista", "win7": "win7", "win8": "win8", "win81": "win81", "win10": "win10", "win11": "win11"}
# winetricks verbs that are Microsoft's DirectX DLLs from the June 2010 redist (the app's download).
DX_VERB = re.compile(r"^(d3dx9(_\d+)?|d3dx10(_\d+)?|d3dx11_4[23]|d3dcompiler_(3\d|4[0-3])|xinput|xact|xact_x64|"
                     r"x3daudio(1_\d+)?|xaudio2_\d|xapofx1_\d)$")
REG_ROOTS = {"HKEY_LOCAL_MACHINE": "HKLM", "HKEY_CURRENT_USER": "HKCU", "HKLM": "HKLM", "HKCU": "HKCU"}


def _literal(node):
    try:
        return ast.literal_eval(node)
    except (ValueError, TypeError, SyntaxError, MemoryError, RecursionError):
        return None


def _order(node):
    # util.OverrideOrder.NATIVE, OverrideOrder.NATIVE, or a plain text ('n,b').
    if isinstance(node, ast.Attribute) and node.attr in ORDERS:
        return ORDERS[node.attr]
    value = _literal(node)
    return value if isinstance(value, str) and re.fullmatch(r"[nbd, ]*", value) else None


def _util_call(stmt):
    """(name, args) of a statement that is only util.NAME(...) (or NAME(...)), else None."""
    if not (isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Call)):
        return None
    f = stmt.value.func
    name = f.attr if isinstance(f, ast.Attribute) else f.id if isinstance(f, ast.Name) else None
    return (name, stmt.value.args, {k.arg: k.value for k in stmt.value.keywords}) if name else None


def _reg_value(typ, value):
    typ = (typ or "REG_SZ").upper()
    if typ in ("REG_SZ", "REG_EXPAND_SZ") and isinstance(value, str):
        return value
    if typ == "REG_DWORD":
        try:
            n = int(value, 0) if isinstance(value, str) else int(value)
        except (TypeError, ValueError):
            return None
        return n if 0 <= n <= 0xFFFFFFFF else None
    if typ == "REG_BINARY" and isinstance(value, str):
        hexes = re.sub(r"[^0-9a-fA-F]", "", value)
        return {"hex": hexes.lower()} if len(hexes) % 2 == 0 else None
    return None


def convert(source):
    """(settings, notes) from one fix's source: what WinPad can do, and what it left out."""
    try:
        tree = ast.parse(source)
    except SyntaxError:
        return {}, ["not read: not valid Python"]
    main = next((n for n in tree.body if isinstance(n, ast.FunctionDef) and n.name == "main"), None)
    if not main:
        return {}, []
    s, left = {}, []
    for stmt in main.body:
        if isinstance(stmt, ast.Expr) and isinstance(stmt.value, ast.Constant):
            continue  # its docstring
        call = _util_call(stmt)
        if not call:
            left.append("code that depends on the game's files or the system")
            continue
        name, args, kw = call
        vals = [_literal(a) for a in args]
        if name == "winedll_override" and len(args) == 2 and isinstance(vals[0], str):
            order = _order(args[1])
            if order is not None and re.fullmatch(r"[A-Za-z0-9_.\-]+", vals[0]):
                s.setdefault("dllOverrides", {})[vals[0].lower()] = order
                continue
        elif name == "set_environment" and len(args) == 2 and all(isinstance(v, str) for v in vals):
            if ENV_SKIP.match(vals[0]):
                continue  # Proton's own: nothing to carry over, and nothing left out
            if re.fullmatch(r"[A-Za-z_][A-Za-z0-9_]*", vals[0]):
                s.setdefault("env", {})[vals[0]] = vals[1]
                continue
        elif name == "append_argument" and len(args) == 1 and isinstance(vals[0], str):
            try:
                s.setdefault("args", []).extend(shlex.split(vals[0]))
                continue
            except ValueError:
                pass
        elif name == "regedit_add" and args and isinstance(vals[0], str):
            key = vals[0].replace("/", "\\")
            root, _, rest = key.partition("\\")
            name_, typ, value = (vals + [None, None, None])[1:4]
            name_ = kw.get("name") and _literal(kw["name"]) or name_
            typ = kw.get("typ") and _literal(kw["typ"]) or typ
            value = kw.get("value") and _literal(kw["value"]) or value
            if root.upper() in REG_ROOTS and rest:
                if name_ is None:
                    continue  # only makes the key: the app makes it with its first value
                v = _reg_value(typ, value)
                if isinstance(name_, str) and v is not None:
                    s.setdefault("registry", {}).setdefault(f"{REG_ROOTS[root.upper()]}\\{rest}", {})[name_] = v
                    continue
        elif name == "replace_command" and len(args) >= 2 and all(isinstance(v, str) for v in vals[:2]):
            repl = vals[1].replace("\\", "/")
            if repl.lower().endswith(".exe") and ".." not in repl.split("/") and not repl.startswith("/") \
                    and not re.search(r"[\\^$*+?()\[\]{}|]", repl):
                s["exe"] = repl
                continue
        elif name == "protontricks" and len(args) == 1 and isinstance(vals[0], str):
            verb = vals[0]
            if verb in WINVER:
                s["windowsVersion"] = WINVER[verb]
                continue
            if DX_VERB.match(verb):
                s.setdefault("nativeDirectX", [])
                if verb not in s["nativeDirectX"]:
                    s["nativeDirectX"].append(verb)
                continue
            left.append(f"winetricks {verb}")
            continue
        elif name in ("disable_esync", "disable_fsync", "disable_ntsync", "disable_nvapi", "set_cpu_topology_nosmt",
                      "set_dxvk_option", "install_battleye_runtime", "install_eac_runtime"):
            continue  # Linux and Proton only
        left.append(f"util.{name}")
    return s, left


def read_fix(path):
    with open(path, encoding="utf-8", errors="replace") as f:
        return f.read()


def main(argv):
    if len(argv) < 3:
        print(__doc__)
        return 2
    root, csv_path = argv[1], argv[2]
    out_path = argv[3] if len(argv) > 3 else OUT
    # GOG id -> (umu id, title); umu id -> title.
    gog, titles = {}, {}
    with open(csv_path, encoding="utf-8") as f:
        for row in csv.DictReader(f):
            umu = row.get("UMU_ID", "")
            if umu and row.get("TITLE"):
                titles.setdefault(umu, row["TITLE"])
            if row.get("STORE") == "gog" and row.get("CODENAME", "").isdigit() and umu:
                gog.setdefault(umu, []).append(int(row["CODENAME"]))
    profiles = {}
    steam_dir = os.path.join(root, "gamefixes-steam")
    for name in sorted(os.listdir(steam_dir)):
        m = re.fullmatch(r"(\d+)\.py", name)
        if not m:
            continue
        appid = int(m.group(1))
        settings, left = convert(read_fix(os.path.join(steam_dir, name)))
        if not settings:
            continue
        umu = f"umu-{appid}"
        match = [{"steamAppId": appid}] + [{"gogId": g} for g in sorted(gog.get(umu, []))]
        profiles[f"pf-{appid}"] = (umu, match, settings, left)
    # GOG's own fixes (umu-<id>.py that are not a link to a Steam one).
    gog_dir = os.path.join(root, "gamefixes-gog")
    for name in sorted(os.listdir(gog_dir)) if os.path.isdir(gog_dir) else []:
        m = re.fullmatch(r"(umu-[0-9a-z]+)\.py", name)
        path = os.path.join(gog_dir, name)
        if not m or os.path.islink(path) or not gog.get(m.group(1)):
            continue
        settings, left = convert(read_fix(path))
        if not settings:
            continue
        umu = m.group(1)
        pid = "pf-" + umu[4:]
        match = [{"gogId": g} for g in sorted(gog[umu])]
        if pid in profiles:
            # The Steam game's fix comes first; GOG's adds its own.
            old = profiles[pid]
            merged = dict(old[2])
            for k, v in settings.items():
                merged[k] = {**merged[k], **v} if isinstance(v, dict) and isinstance(merged.get(k), dict) else v
            profiles[pid] = (umu, old[1] + [r for r in match if r not in old[1]], merged, old[3] + left)
        else:
            profiles[pid] = (umu, match, settings, left)
    out = []
    for pid, (umu, match, settings, left) in sorted(profiles.items(), key=lambda kv: kv[0]):
        title = titles.get(umu, "")
        notes = ["Z umu-protonfixes (Proton): " + ", ".join(sorted(settings))]
        if left:
            notes.append("Vynecháno (WinPad to neumí stejně): " + ", ".join(sorted(set(left))))
        prof = {"id": pid, "version": 1, "match": match, "settings": settings, "notes": notes,
                "sources": [f"umu-protonfixes {umu}"]}
        if title:
            prof["title"] = title
        out.append(prof)
    header = {"source": "https://github.com/Open-Wine-Components/umu-protonfixes",
              "license": "BSD-2-Clause, Copyright (c) 2018, Chris Simons",
              "made by": "tools/winpad-translator/import-protonfixes.py"}
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump({"about": header, "profiles": out}, f, ensure_ascii=False, indent=1, sort_keys=True)
        f.write("\n")
    print(f"{len(out)} profiles -> {out_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
