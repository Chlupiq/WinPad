"""Plays a game on this computer and records the x86 code it runs: code maps without the iPad.

The translator turns code maps into the AOT image. They used to come from elsewhere: from the
iPad (its interpreter, slowly), from a Windows PC under DynamoRIO run by hand, or from
tests/wine-app/game-aot.sh on a Mac. "Play and record" (--record) does it here and hands the
result straight to the translation:

  Windows  the game runs natively under DynamoRIO's drcov (drrun -t drcov -- GAME.EXE); its
           logs become code maps (drcov2codemap.py) of the .exe and of the game's own DLLs.
           DynamoRIO is downloaded from its GitHub releases the first time (or --dynamorio).
           Windows' own DLLs are not Wine's, so their code is not taken.
  macOS    the WinPadWine-xcode project is built for an iPad simulator, the game is copied into
           the simulator app's Documents and started there with FEX's JIT and code maps on
           (main.m's -recordGame): the same Wine, DLLs and game settings as on the iPad, so the
           maps cover Wine's code as well. They are taken as maps from the iPad are.

Either way the game is played in a window here; the recording ends when the game ends (or
the stop button, which closes it first, so that its maps are written).
"""
import datetime
import glob
import json
import os
import plistlib
import re
import shutil
import struct
import subprocess
import sys
import time
import urllib.request
import zipfile

from . import codemaps, profiles

DYNAMORIO_RELEASES = "https://api.github.com/repos/DynamoRIO/dynamorio/releases"
DYNAMORIO_ASSET = re.compile(r"^DynamoRIO-Windows-[\d.]+\.zip$")
# main.m writes it into Documents/wine.log when the program has ended.
FINISHED = "== finished"
BUNDLE = "WinPadWine.app"


class RecordError(Exception):
    pass


def tools_dir():
    return os.path.join(os.path.expanduser("~"), "WinPadTranslator", "tools")


def stamp():
    return datetime.datetime.now().strftime("%Y%m%d-%H%M%S")


def pe_machine(path):
    """The Machine field of a PE file's header (0x14c: 32-bit x86, 0x8664: x86-64), or None."""
    try:
        with open(path, "rb") as f:
            head = f.read(4096)
    except OSError:
        return None
    if head[:2] != b"MZ" or len(head) < 64:
        return None
    pe = struct.unpack_from("<I", head, 60)[0]
    if pe + 6 > len(head) or head[pe:pe + 4] != b"PE\0\0":
        return None
    return struct.unpack_from("<H", head, pe + 4)[0]


def game_args(game_dir):
    """The game's arguments from its winpad.json (its profile's, or the user's own)."""
    try:
        args = profiles.effective(profiles.read_winpad_json(game_dir)).get("args") or []
    except (OSError, profiles.ProfileError):
        return []
    return [str(a) for a in args] if isinstance(args, list) else []


# ---------------------------------------------------------------- Windows: DynamoRIO


def dynamorio_root(folder):
    """FOLDER if it is a DynamoRIO (bin32/drrun.exe in it), else None."""
    return folder if folder and os.path.isfile(os.path.join(folder, "bin32", "drrun.exe")) else None


def find_dynamorio(given=""):
    """DynamoRIO here: GIVEN, DYNAMORIO_HOME, the toolkit's, one downloaded before, C:\\DynamoRIO."""
    from . import project
    candidates = [given, os.environ.get("DYNAMORIO_HOME", "")]
    candidates += [os.path.join(d, "DynamoRIO") for d in project.toolkit_dirs()]
    candidates += sorted(glob.glob(os.path.join(tools_dir(), "DynamoRIO-Windows-*")), reverse=True)
    candidates += [r"C:\DynamoRIO", r"C:\Program Files\DynamoRIO"]
    for c in candidates:
        root = dynamorio_root(c)
        if root:
            return root
    if given:
        raise RecordError(f"no DynamoRIO in {given} (it has no bin32\\drrun.exe)")
    return None


def latest_dynamorio_asset(urlopen=urllib.request.urlopen):
    """(version, name, url) of the newest DynamoRIO release with a Windows zip."""
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "WinPad-Translator"}
    # GitHub answers 60 anonymous API requests an hour per address; a token raises that.
    if os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = "Bearer " + os.environ["GITHUB_TOKEN"]
    req = urllib.request.Request(DYNAMORIO_RELEASES + "?per_page=10", headers=headers)
    with urlopen(req, timeout=60) as r:
        releases = json.load(r)
    for rel in releases:
        if rel.get("draft") or rel.get("prerelease"):
            continue
        for a in rel.get("assets", []):
            if DYNAMORIO_ASSET.match(a.get("name", "")):
                return rel.get("tag_name", ""), a["name"], a["browser_download_url"]
    raise RecordError("no DynamoRIO release with a Windows zip on GitHub; download it from "
                      "https://dynamorio.org and give its folder (--dynamorio)")


def download_dynamorio(log=print, urlopen=urllib.request.urlopen, into=None):
    """Downloads and unpacks the newest DynamoRIO for Windows into ~/WinPadTranslator/tools."""
    into = into or tools_dir()
    tag, name, url = latest_dynamorio_asset(urlopen)
    log(f"=== downloading DynamoRIO {tag} ({name}), once")
    os.makedirs(into, exist_ok=True)
    archive = os.path.join(into, name)
    with urlopen(urllib.request.Request(url, headers={"User-Agent": "WinPad-Translator"}), timeout=600) as r, \
            open(archive + ".part", "wb") as f:
        shutil.copyfileobj(r, f)
    os.replace(archive + ".part", archive)
    dest = os.path.join(into, name[:-len(".zip")])
    tmp = dest + ".part"
    shutil.rmtree(tmp, ignore_errors=True)
    with zipfile.ZipFile(archive) as z:
        for member in z.namelist():
            target = os.path.realpath(os.path.join(tmp, member))
            if not target.startswith(os.path.realpath(tmp) + os.sep):
                raise RecordError(f"{name} has a file outside its folder: {member}")
        z.extractall(tmp)
    os.remove(archive)
    # The zip holds one top folder (DynamoRIO-Windows-x.y.z); take what has bin32 in it.
    inner = [os.path.join(tmp, d) for d in os.listdir(tmp)]
    root = next((d for d in [tmp] + inner if dynamorio_root(d)), None)
    if not root:
        shutil.rmtree(tmp, ignore_errors=True)
        raise RecordError(f"{name} has no bin32\\drrun.exe")
    shutil.rmtree(dest, ignore_errors=True)
    os.replace(root, dest)
    shutil.rmtree(tmp, ignore_errors=True)
    log(f"  -> {dest}")
    return dest


def drrun_command(dynamorio, exe, logdir, args=()):
    bits = "bin64" if pe_machine(exe) == 0x8664 else "bin32"
    return [os.path.join(dynamorio, bits, "drrun.exe"), "-t", "drcov", "-logdir", logdir, "--", exe] + list(args)


def drcov_modules(log_path):
    import drcov2codemap
    modules, _ = drcov2codemap.read_drcov(log_path)
    return [m["path"] for m in modules.values()]


def logs_with(logs, name):
    """The drcov logs that saw a module named NAME (the game's launcher may run first)."""
    name = name.lower()
    out = []
    for path in logs:
        try:
            if any(codemaps.basename(m.replace("/", "\\")).lower() == name for m in drcov_modules(path)):
                out.append(path)
        except (OSError, ValueError, SystemExit):
            continue
    return out


def game_modules(logs, game_dir):
    """The game's own DLLs and programs (in its folder) the logs saw: {local path: [logs]}."""
    root = os.path.normcase(os.path.realpath(game_dir))
    found = {}
    for path in logs:
        try:
            names = drcov_modules(path)
        except (OSError, ValueError, SystemExit):
            continue
        for m in names:
            local = os.path.normcase(os.path.realpath(m))
            if local.startswith(root + os.sep) and pe_machine(m) is not None:
                found.setdefault(m, []).append(path)
    return found


def record_windows(game_dir, exe, work_dir, log=print, stop=None, dynamorio="", popen=subprocess.Popen):
    """Runs EXE under drcov until it ends. Returns the drcov logs written."""
    if os.name != "nt":
        raise RecordError("recording with DynamoRIO runs on Windows; on a Mac the game is recorded in the "
                          "iPad simulator (it needs the WinPadWine-xcode project)")
    machine = os.environ.get("PROCESSOR_ARCHITEW6432") or os.environ.get("PROCESSOR_ARCHITECTURE", "")
    if machine.upper() == "ARM64":
        raise RecordError("DynamoRIO does not run on Windows on ARM: record on an x86-64 PC, or on a Mac")
    root = find_dynamorio(dynamorio) or download_dynamorio(log)
    logdir = os.path.join(work_dir, "drcov", stamp())
    os.makedirs(logdir, exist_ok=True)
    cmd = drrun_command(root, exe, logdir, game_args(game_dir))
    log("=== play the game; the recording ends when you quit it")
    log("$ " + " ".join(cmd))
    proc = popen(cmd, cwd=os.path.dirname(exe))
    wait(proc, stop, lambda: close_windows(proc), log)
    logs = sorted(glob.glob(os.path.join(logdir, "*.log")))
    log(f"=== {len(logs)} drcov logs in {logdir}")
    if not logs:
        raise RecordError("DynamoRIO wrote no log: did the game start? (a game with copy protection or "
                          "anti-cheat may refuse to run under it)")
    return logs


def close_windows(proc):
    """Asks the game (drrun's child) to close, as its window's close button does."""
    subprocess.run(["taskkill", "/T", "/PID", str(proc.pid)], capture_output=True)


def wait(proc, stop, close, log, grace=30):
    """Waits for PROC; when STOP is set, CLOSE asks it to end, then after GRACE s it is killed."""
    while proc.poll() is None:
        if stop is not None and stop.wait(1):
            log("=== stopping: closing the game, so that what it ran is written")
            close()
            try:
                proc.wait(timeout=grace)
            except subprocess.TimeoutExpired:
                log(f"  ! it did not end in {grace} s: killed; the end of its recording may be lost")
                proc.kill()
                proc.wait()
            return
        if stop is None:
            proc.wait()


def drcov_to_maps(logs, exe, game_dir, new, image_name, seed, log=print):
    """Code maps in NEW from drcov LOGS: one of EXE, and one of each of the game's own DLLs the
    logs saw (SEED: a map that names EXE as the main program, project._seed_map)."""
    import drcov2codemap
    from .project import _script
    made = []
    with_exe = logs_with(logs, os.path.basename(exe))
    if with_exe:
        out = os.path.join(new, f"drcov-{stamp()}.bin")
        log(f"=== blocks of {os.path.basename(exe)} from {len(with_exe)} drcov logs")
        _script(drcov2codemap, [exe, seed, out] + with_exe, log)
        made.append(out)
    else:
        log(f"  ! no drcov log saw {os.path.basename(exe)}")
    with open(seed, "rb") as f:
        names, _, main_id, _ = codemaps.parse(f.read())
    for dll, dll_logs in sorted(game_modules(logs, game_dir).items()):
        if os.path.normcase(os.path.realpath(dll)) == os.path.normcase(os.path.realpath(exe)):
            continue
        file_id = codemaps.pe_file_id(dll)
        if file_id is None:
            log(f"  ! {os.path.basename(dll)}: its file id needs the xxhash package")
            continue
        base = re.sub(r"[^A-Za-z0-9]+", "-", os.path.basename(dll))
        dll_seed = os.path.join(new, f"seed-{base}.tmp")
        with open(dll_seed, "wb") as f:
            f.write(codemaps.image_record(file_id, image_name(dll)))
        out = os.path.join(new, f"drcov-{base}-{stamp()}.bin")
        log(f"=== blocks of {os.path.basename(dll)} from {len(dll_logs)} drcov logs")
        try:
            _script(drcov2codemap, [dll, dll_seed, out] + dll_logs, log)
        except Exception as e:  # noqa: BLE001 - one DLL less, the rest stands
            log(f"  ! {os.path.basename(dll)} left out: {e}")
            continue
        finally:
            os.remove(dll_seed)
        # As every map the iPad writes: the main program named too.
        if main_id is not None and main_id in names:
            with open(out, "rb") as f:
                data = f.read()
            with open(out, "wb") as f:
                f.write(codemaps.image_record(main_id, names[main_id]) +
                        codemaps.ENTRY.pack(*codemaps.SET_MAIN) + struct.pack("<Q", main_id) + data)
        made.append(out)
    return made


# ---------------------------------------------------------------- macOS: the iPad simulator


def simctl(*args, run=subprocess.run, check=True):
    r = run(["xcrun", "simctl"] + list(args), capture_output=True, text=True)
    if check and r.returncode:
        raise RecordError(f"simctl {' '.join(args)}: {(r.stderr or r.stdout).strip()}")
    return r.stdout


def runtime_version(runtime):
    m = re.search(r"iOS-(\d+)-(\d+)(?:-(\d+))?$", runtime)
    return tuple(int(x or 0) for x in m.groups()) if m else None


def pick_ipad(listing, minimum=(17, 0)):
    """The UDID of an available iPad simulator in `simctl list devices available -j`: a booted
    one, else one of the newest iOS."""
    best = None
    for runtime, devices in json.loads(listing).get("devices", {}).items():
        version = runtime_version(runtime)
        if not version or version < minimum:
            continue
        for d in devices:
            if not d.get("isAvailable", True) or "iPad" not in d.get("name", ""):
                continue
            key = (d.get("state") == "Booted", version, "Pro" in d["name"], d["name"])
            if best is None or key > best[0]:
                best = (key, d["udid"], d["name"])
    if not best:
        raise RecordError("no iPad simulator with iOS 17 or newer: add one in Xcode (Window > Devices and "
                          "Simulators, or Settings > Components)")
    return best[1], best[2]


def build_for_simulator(xcode_project, derived, log=print, run=subprocess.run):
    proj = os.path.join(xcode_project, "WinPadWine.xcodeproj")
    if not os.path.isdir(proj):
        raise RecordError(f"{xcode_project} has no WinPadWine.xcodeproj (the CI artifact WinPadWine-xcode)")
    os.makedirs(derived, exist_ok=True)
    cmd = ["xcodebuild", "-project", proj, "-scheme", "WinPadWine", "-configuration", "Debug",
           "-destination", "generic/platform=iOS Simulator", "-derivedDataPath", derived,
           "CODE_SIGNING_ALLOWED=NO", "build"]
    log("=== building the app for the iPad simulator (xcodebuild)")
    logfile = os.path.join(derived, "xcodebuild.log")
    with open(logfile, "w") as f:
        r = run(cmd, stdout=f, stderr=subprocess.STDOUT)
    if r.returncode:
        with open(logfile, errors="replace") as f:
            tail = "\n".join(f.read().splitlines()[-25:])
        raise RecordError(f"xcodebuild failed (whole log: {logfile}):\n{tail}")
    app = os.path.join(derived, "Build", "Products", "Debug-iphonesimulator", BUNDLE)
    if not os.path.isdir(app):
        raise RecordError(f"xcodebuild made no {app}")
    return app


def copy_game(game_dir, dest, log=print, run=subprocess.run):
    """The game folder into the simulator app's Documents: cloned on APFS (no space taken),
    else copied; files that are already there with the same size and time stay."""
    if not os.path.isdir(dest):
        os.makedirs(os.path.dirname(dest), exist_ok=True)
        if sys.platform == "darwin" and run(["cp", "-cR", game_dir, dest], capture_output=True).returncode == 0:
            log(f"  game cloned into {dest}")
            return
        shutil.rmtree(dest, ignore_errors=True)
    copied = 0
    for dirpath, _, files in os.walk(game_dir):
        rel = os.path.relpath(dirpath, game_dir)
        os.makedirs(os.path.join(dest, rel), exist_ok=True)
        for n in files:
            src, dst = os.path.join(dirpath, n), os.path.join(dest, rel, n)
            s = os.stat(src)
            try:
                d = os.stat(dst)
                if d.st_size == s.st_size and int(d.st_mtime) == int(s.st_mtime):
                    continue
            except OSError:
                pass
            shutil.copy2(src, dst)
            copied += 1
    log(f"  game in {dest} ({copied} files copied)")


def wait_finished(log_path, stop, done, poll=2.0, timeout=None):
    """Waits until the app's wine.log says the program has ended, STOP is set or DONE()
    says the app is gone. Returns how it ended: "finished", "stopped" or "gone"."""
    start = time.monotonic()
    while True:
        try:
            with open(log_path, errors="replace") as f:
                if FINISHED in f.read():
                    return "finished"
        except OSError:
            pass
        if done():
            return "gone"
        if timeout and time.monotonic() - start > timeout:
            return "stopped"
        if stop is not None and stop.wait(poll):
            return "stopped"
        if stop is None:
            time.sleep(poll)


def record_simulator(game_dir, folder, xcode_project, work_dir, log=print, stop=None, run=subprocess.run,
                     poll=2.0, timeout=None):
    """Plays the game in the WinPad Wine app on an iPad simulator with FEX's JIT and code maps
    on. Returns the folder with the maps it wrote (as Documents/fexcache/<game> on the iPad)."""
    if sys.platform != "darwin":
        raise RecordError("recording in the iPad simulator needs a Mac with Xcode")
    if not xcode_project:
        raise RecordError("recording on a Mac needs the WinPadWine-xcode project (Advanced > Xcode project, "
                          "--xcode-project): it is built for the simulator")
    app = build_for_simulator(xcode_project, os.path.join(work_dir, "simulator-build"), log, run)
    with open(os.path.join(app, "Info.plist"), "rb") as f:
        bundle = plistlib.load(f)["CFBundleIdentifier"]
    udid, name = pick_ipad(simctl("list", "devices", "available", "-j", run=run))
    log(f"=== {name} simulator ({udid})")
    simctl("boot", udid, run=run, check=False)
    simctl("bootstatus", udid, "-b", run=run)
    run(["open", "-a", "Simulator", "--args", "-CurrentDeviceUDID", udid], capture_output=True)
    simctl("install", udid, app, run=run)
    data = simctl("get_app_container", udid, bundle, "data", run=run).strip()
    docs = os.path.join(data, "Documents")
    copy_game(game_dir, os.path.join(docs, folder), log, run)
    # Only this session's maps, and no CPU features of this Mac (hostprobe.txt): the image is
    # compiled for the iPad's.
    maps = os.path.join(docs, "fexcache", folder, "codemap", "new")
    shutil.rmtree(maps, ignore_errors=True)
    wine_log = os.path.join(docs, "wine.log")
    if os.path.exists(wine_log):
        os.remove(wine_log)
    log("=== play the game in the Simulator window (the Mac's keyboard and a game controller work); "
        "the recording ends when you quit it")
    simctl("launch", "--terminate-running-process", udid, bundle, "-recordGame", folder, run=run)
    ended = wait_finished(wine_log, stop, lambda: False, poll=poll, timeout=timeout)
    if ended == "stopped":
        log("=== stopping: the app is ended; FEX has written all but the last few blocks it compiled")
    time.sleep(min(poll, 1))
    simctl("terminate", udid, bundle, run=run, check=False)
    out = os.path.join(work_dir, "recorded", f"simulator-{stamp()}")
    found = sorted(p for p in glob.glob(os.path.join(maps, "*.bin")) if os.path.getsize(p))
    if not found:
        tail = ""
        try:
            with open(wine_log, errors="replace") as f:
                tail = "\n".join(f.read().splitlines()[-15:])
        except OSError:
            pass
        raise RecordError("the game wrote no code map in the simulator (did it start? the app's log ends:\n"
                          f"{tail})")
    dest = os.path.join(out, "fexcache", folder, "codemap", "new")
    shutil.copytree(maps, dest, ignore=shutil.ignore_patterns("hostprobe.txt"))
    try:
        shutil.copyfile(wine_log, os.path.join(out, "wine.log"))
    except OSError:
        pass
    log(f"=== {len(found)} code maps recorded -> {dest}")
    return os.path.join(out, "fexcache", folder)


def record(p, log=print, stop=None, exe=None):
    """Plays project P's game here and records it. Puts what it recorded into P (drcov logs on
    Windows, a maps folder on a Mac) for project.run to translate."""
    from . import project
    if not p.game_dir or not os.path.isdir(p.game_dir):
        raise RecordError(f"no game folder: {p.game_dir}")
    p.work_dir = p.work_dir or project.default_work_dir(p.game_dir)
    exe = exe or (codemaps.find_ci(p.game_dir, p.exe) if p.exe else None) or project.program_from_settings(p.game_dir)
    if sys.platform == "darwin":
        folder = p.ipad_folder or p.folder_name()
        maps = record_simulator(p.game_dir, folder, p.xcode_project, p.work_dir, log, stop)
        p.ipad_maps = list(p.ipad_maps) + [maps]
        return maps
    if not exe:
        raise RecordError("which .exe is the game? (set the program, --exe, or winpad.json's \"exe\")")
    logs = record_windows(p.game_dir, exe, p.work_dir, log, stop, p.dynamorio)
    p.drcov_logs = list(p.drcov_logs) + logs
    if not p.exe:
        p.exe = os.path.relpath(exe, p.game_dir)
    return logs
