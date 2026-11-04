"""A WinPad package (.winpad): a translated game in one file for the iPad.

It is a ZIP archive of the game folder as the app keeps it in its Documents:
the game's files, its cover, winpad.json and, when it was signed on a Mac, the
AOT image fexaot.dylib with fexaot.build. The iPad app (tests/wine-app,
Library.m and Package.c) opens it from AirDrop, Files or a share sheet and
unpacks it into Documents/<folder>; files the game wrote there itself (saves,
settings) stay unless the package has a file of the same name.

winpad.json is the game folder's own (the app's game library reads "title" and
"exe" from it, other keys are game settings), with a "package" object about
the package itself:

    {"title": "...", "exe": "SPEED2.EXE", ...,
     "package": {"format": 1, "folder": "NFSU2", "game_files": true,
                 "image": "fexaot.dylib", "app_build": "...", "made": "...", "translator": "0.1.0"}}

Only a signed image goes in: iOS runs no code that is not signed, and the app
loads an image from its Documents only when it is signed by the team the app
itself is signed for (project.into_game_folder, Mac only). Without one the game
runs from the image in the app's IPA (or, missing there, in the interpreter).
The code maps are not in it: the iPad makes its own, and the translator's copies
name files by this computer's paths.
"""
import datetime
import json
import os
import struct
import zipfile

from . import __version__

FORMAT = 1
EXTENSION = ".winpad"
SETTINGS = "winpad.json"
IMAGE, BUILD = "fexaot.dylib", "fexaot.build"
COVERS = ("cover.png", "cover.jpg", "cover.jpeg")
# Folder names the app keeps for itself in its Documents (Library.m, WinPadFindGames).
RESERVED = {"prefix", "fexcache", "frames", "inbox"}
# Files that are worth deflating; the rest (game data, mostly packed already) is stored, which
# the iPad unpacks at the speed of its flash.
DEFLATE = {".json", ".txt", ".ini", ".cfg", ".xml", ".log", ".build"}

LC_CODE_SIGNATURE = 0x1D


class PackageError(Exception):
    pass


def is_signed(path):
    """Whether the Mach-O file at PATH has a code signature (LC_CODE_SIGNATURE)."""
    try:
        with open(path, "rb") as f:
            head = f.read(32)
            if len(head) < 32 or struct.unpack_from("<I", head)[0] != 0xFEEDFACF:
                return False
            ncmds, sizeofcmds = struct.unpack_from("<II", head, 16)
            cmds = f.read(sizeofcmds)
    except OSError:
        return False
    at = 0
    for _ in range(ncmds):
        if at + 8 > len(cmds):
            return False
        cmd, size = struct.unpack_from("<II", cmds, at)
        if cmd == LC_CODE_SIGNATURE:
            return True
        if size < 8:
            return False
        at += size
    return False


def folder_ok(name):
    return bool(name) and "/" not in name and "\\" not in name and name not in (".", "..") \
        and not name.startswith(".") and name.lower() not in RESERVED


def game_settings(game_dir):
    """The game folder's winpad.json as a dict ({} if it has none or it is broken)."""
    try:
        with open(os.path.join(game_dir, SETTINGS), encoding="utf-8") as f:
            data = json.load(f)
    except (OSError, ValueError):
        return {}
    return data if isinstance(data, dict) else {}


def _files(game_dir, with_game):
    """(relative name with "/", path) of the files that go in, without winpad.json."""
    if not with_game:
        names = {n.lower(): n for n in os.listdir(game_dir)}
        for want in (IMAGE, BUILD) + COVERS:
            if want in names and os.path.isfile(os.path.join(game_dir, names[want])):
                yield names[want], os.path.join(game_dir, names[want])
        return
    for dirpath, dirnames, filenames in os.walk(game_dir):
        dirnames[:] = sorted(d for d in dirnames if not d.startswith("."))
        for name in sorted(filenames):
            path = os.path.join(dirpath, name)
            rel = os.path.relpath(path, game_dir).replace(os.sep, "/")
            if name.startswith(".") or rel.lower() == SETTINGS or not os.path.isfile(path):
                continue
            yield rel, path


def write(game_dir, out, folder="", exe="", with_game=True, log=print):
    """Writes the package of the game in GAME_DIR to OUT (a file, or a folder for
    <folder>.winpad in it). FOLDER: the game folder's name on the iPad (default
    GAME_DIR's); EXE: its program relative to it (default winpad.json's). Returns the
    package's path."""
    game_dir = os.path.abspath(game_dir)
    if not os.path.isdir(game_dir):
        raise PackageError(f"no game folder {game_dir}")
    folder = folder or os.path.basename(os.path.normpath(game_dir))
    if not folder_ok(folder):
        raise PackageError(f"the app cannot have a game folder named {folder!r}")
    if os.path.isdir(out) or out.endswith(("/", os.sep)):
        out = os.path.join(out, folder + EXTENSION)
    out = os.path.abspath(out)
    if os.path.commonpath([out, game_dir]) == game_dir:
        raise PackageError("write the package outside the game folder")

    files = list(_files(game_dir, with_game))
    image = next((path for rel, path in files if rel.lower() == IMAGE), None)
    if image and not is_signed(image):
        log(f"  {IMAGE} in the game folder is not signed: left out (iOS would not load it); "
            "the app takes the image in its IPA")
        files = [(rel, path) for rel, path in files if rel.lower() not in (IMAGE, BUILD)]
        image = None
    build = None
    if image:
        try:
            with open(os.path.join(game_dir, BUILD), encoding="utf-8") as f:
                build = f.read().strip() or None
        except OSError:
            pass

    settings = game_settings(game_dir)
    if exe:
        settings["exe"] = exe.replace("\\", "/")
    settings["package"] = {
        "format": FORMAT,
        "folder": folder,
        "game_files": with_game,
        "image": IMAGE if image else None,
        "app_build": build,
        "made": datetime.datetime.now(datetime.timezone.utc).replace(microsecond=0).isoformat(),
        "translator": __version__,
    }

    os.makedirs(os.path.dirname(out), exist_ok=True)
    tmp = out + ".tmp"
    total = 0
    with zipfile.ZipFile(tmp, "w", allowZip64=True) as z:
        z.writestr(zipfile.ZipInfo(SETTINGS, date_time=_now()), json.dumps(settings, indent=2, ensure_ascii=False),
                   compress_type=zipfile.ZIP_DEFLATED)
        for rel, path in files:
            kind = zipfile.ZIP_DEFLATED if os.path.splitext(rel)[1].lower() in DEFLATE else zipfile.ZIP_STORED
            z.write(path, rel, compress_type=kind)
            total += os.path.getsize(path)
    os.replace(tmp, out)
    what = f"{len(files)} files ({total / 1e6:.1f} MB)" if with_game else "settings" + (", image" if image else "")
    log(f"=== {out}: {folder}, {what}" + (", signed image" if image and with_game else "")
        + ("" if image else ", no image (the app uses the one in its IPA)"))
    log("  send it to the iPad (AirDrop, or Files › WinPad Wine) and open it: the app puts the game into its library")
    return out


def _now():
    return datetime.datetime.now().timetuple()[:6]


def read_settings(package):
    """The winpad.json in PACKAGE."""
    try:
        with zipfile.ZipFile(package) as z:
            return json.loads(z.read(SETTINGS))
    except (OSError, KeyError, ValueError, zipfile.BadZipFile) as e:
        raise PackageError(f"{package} is not a WinPad package: {e}") from e
