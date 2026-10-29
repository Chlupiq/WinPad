"""One game's translation: its settings and the steps from code maps to the AOT image."""
import dataclasses
import json
import os
import shutil
import sys

from . import codemaps, compile as fexcompile, ipa as ipamod, link, paths

SETTINGS = "winpad-translator.json"


@dataclasses.dataclass
class Project:
    game_dir: str = ""
    # Where code maps, caches and images of this game are kept from one image to the next.
    work_dir: str = ""
    # Folders copied off the iPad: the app's Documents/fexcache/codemap/new (with runtime/).
    ipad_maps: list = dataclasses.field(default_factory=list)
    # DynamoRIO drcov logs of the game run natively on a PC (drrun -t drcov -- GAME.EXE).
    drcov_logs: list = dataclasses.field(default_factory=list)
    # Also walk the game's .exe statically for code no run reached (tests/fex-wow64/discover.py).
    discover: bool = False
    # The program; empty: the main executable the code maps name, else winpad.json's "exe".
    exe: str = ""
    # The game folder's name on the iPad, if it differs from game_dir's.
    ipad_folder: str = ""
    # The WinPad Wine IPA the iPad runs: its i386 DLLs, and the IPA the image goes into.
    ipa: str = ""
    # Or the i386 DLLs as a folder (the app's i386-windows).
    system_dir: str = ""
    # FEXOfflineCompiler.exe and dispatcher.bin of the same build (the toolkit next to this app).
    compiler: str = ""
    dispatcher: str = ""
    backend: str = ""
    wine: str = ""
    sim_work_dir: str = ""
    # A WinPad checkout, for the simulator backend's scripts (the packaged app has none).
    winpad_repo: str = ""
    caches_per_run: int = 8
    compile_timeout: int = 0
    half_barrier: bool = True
    rebuild: bool = False
    simulator_image: bool = False
    # False: stop after compiling (to link the caches on another computer).
    link: bool = True
    # Where the image goes: a folder, an IPA copy with it, an Xcode project (WinPadWine-xcode).
    output_dir: str = ""
    output_ipa: str = ""
    xcode_project: str = ""

    def folder_name(self):
        return os.path.basename(os.path.normpath(self.game_dir))

    def slug(self):
        return codemaps.slug(self.folder_name())

    def image_name(self):
        return f"fexaot-{self.slug()}.dylib"

    def save(self, path=None):
        path = path or os.path.join(self.work_dir, SETTINGS)
        os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
        with open(path, "w") as f:
            json.dump(dataclasses.asdict(self), f, indent=2)

    @classmethod
    def load(cls, path):
        with open(path) as f:
            data = json.load(f)
        known = {f.name for f in dataclasses.fields(cls)}
        return cls(**{k: v for k, v in data.items() if k in known})


def toolkit_dirs():
    """Where the toolkit (FEXOfflineCompiler.exe, dispatcher.bin) may be: bundled with the
    app, next to it, or in the repository's build output."""
    here = os.path.dirname(os.path.abspath(sys.executable if getattr(sys, "frozen", False) else __file__))
    # Bundled, next to the program, next to WinPad Translator.app (here is its Contents/MacOS).
    return [os.path.join(paths.ROOT, "toolkit"), os.path.join(here, "toolkit"), here,
            os.path.join(here, "..", "..", "..", "toolkit")]


def find_in_toolkit(name):
    for d in toolkit_dirs():
        p = os.path.join(d, name)
        if os.path.isfile(p):
            return p
    return ""


def default_work_dir(game_dir):
    return os.path.join(os.path.expanduser("~"), "WinPadTranslator", codemaps.slug(os.path.basename(os.path.normpath(game_dir))))


def program_from_settings(game_dir):
    """winpad.json's "exe" in the game folder (the app's game library reads it too)."""
    try:
        with open(os.path.join(game_dir, "winpad.json")) as f:
            exe = json.load(f).get("exe")
    except (OSError, ValueError, AttributeError):
        return None
    return codemaps.find_ci(game_dir, exe) if exe else None


class TranslateError(Exception):
    pass


# What goes wrong for a reason the message says (no traceback needed).
KNOWN_ERRORS = (TranslateError, fexcompile.CompileError, link.LinkError, ipamod.IpaError, OSError)


def _script(module, argv, log):
    """Runs one of tests/fex-wow64's scripts in this process; they report by printing and sys.exit."""
    import contextlib
    import io
    buf = io.StringIO()
    try:
        with contextlib.redirect_stdout(buf):
            code = module.main(argv)
    except SystemExit as e:
        code = e.code
    for line in buf.getvalue().splitlines():
        log("  " + line)
    if code not in (0, None):
        raise TranslateError(f"{module.__name__} failed: {code}")


def run(p, log=print):
    """All steps for project P. Returns the paths of the images made."""
    if not p.game_dir or not os.path.isdir(p.game_dir):
        raise TranslateError(f"no game folder: {p.game_dir}")
    p.work_dir = p.work_dir or default_work_dir(p.game_dir)
    p.backend = p.backend or fexcompile.default_backend()
    p.compiler = p.compiler or find_in_toolkit("FEXOfflineCompiler.exe")
    p.dispatcher = p.dispatcher or find_in_toolkit("dispatcher.bin")
    cache_dir = os.path.join(p.work_dir, "fexcache")
    new = os.path.join(cache_dir, "codemap", "new")
    os.makedirs(new, exist_ok=True)
    p.save()
    log(f"=== {p.folder_name()}: image {p.image_name()}, work folder {p.work_dir}, compiler backend {p.backend}")

    system_dir = p.system_dir
    if p.ipa and not system_dir:
        system_dir = os.path.join(p.work_dir, "i386-windows")
        shutil.rmtree(system_dir, ignore_errors=True)
        log(f"=== {ipamod.extract_system_dlls(p.ipa, system_dir)} i386 DLLs from {p.ipa}")
    if not system_dir and p.backend != "simulator":
        raise TranslateError("give the WinPad Wine IPA the iPad runs (or its i386-windows folder): "
                             "the compiler needs the same Wine DLLs as the iPad")

    for i, folder in enumerate(p.ipad_maps):
        tag = f"ipad{i}-{os.path.basename(os.path.normpath(folder))}"
        log(f"=== {codemaps.import_maps(folder, cache_dir, tag)} code maps from {folder}")

    backend = fexcompile.make_backend(
        p.backend, p.compiler, cache_dir, log=log, per_run=p.caches_per_run, timeout=p.compile_timeout or None,
        wine=p.wine, work_dir=p.sim_work_dir, repo=p.winpad_repo or None, mounts=[m for m in (p.game_dir, system_dir) if m])

    maps = codemaps.map_files(new)
    names, blocks, main_id = codemaps.summary(maps)
    folders = codemaps.ipad_folders(names.values())
    ipad_folder = p.ipad_folder
    if not ipad_folder and folders:
        same = [f for f in folders if codemaps.slug(f) == p.slug()]
        if same:
            ipad_folder = same[0]
        elif len(folders) == 1:
            ipad_folder = folders[0]
            log(f"  the maps come from the iPad folder {ipad_folder}, taken to be {p.game_dir}")
        else:
            raise TranslateError(f"the code maps come from several iPad game folders ({', '.join(folders)}); "
                                 "say which one is this game")
    resolver = codemaps.Resolver(p.game_dir, ipad_folder, system_dir)

    exe = codemaps.find_ci(p.game_dir, p.exe) if p.exe else None
    if not exe and main_id is not None and main_id in names:
        exe = resolver.resolve(names[main_id])[0]
    exe = exe or program_from_settings(p.game_dir)

    if maps:
        log(f"=== {len(maps)} new code maps, {sum(len(b) for b in blocks.values())} blocks in {len(blocks)} images; "
            "finding their images here")
        renamed, missing, mismatched = codemaps.rehome(maps, resolver, backend.image_name, backend.keep_name, log)
        if mismatched:
            log(f"  ! {len(mismatched)} files differ from the ones the iPad ran: their code would not be used. "
                "Use the IPA the iPad has and the game files as they are on the iPad.")
        if missing:
            log(f"  ! {len(missing)} images not found here; the compiler leaves their caches out")
        if exe:
            codemaps.name_main(maps, backend.image_name(exe))

    if (p.drcov_logs or p.discover) and not exe:
        raise TranslateError("which .exe is the game? (no code map names it; set exe or winpad.json)")
    if p.drcov_logs or p.discover:
        import drcov2codemap
        import discover
        seed = _seed_map(new, exe, backend, maps)
        if p.drcov_logs:
            log(f"=== blocks of {os.path.basename(exe)} from {len(p.drcov_logs)} drcov logs")
            _script(drcov2codemap, [exe, seed, os.path.join(new, "drcov.bin")] + list(p.drcov_logs), log)
        if p.discover:
            log(f"=== static code discovery in {os.path.basename(exe)}")
            _script(discover, [exe, seed, os.path.join(new, "discover.bin")], log)
        if os.path.basename(seed) == "seed.bin":
            os.remove(seed)

    maps = codemaps.map_files(new)
    if p.half_barrier and maps:
        log(f"=== {codemaps.mark_half_barrier(maps)} blocks marked for plain loads and stores with half barriers")
    if p.rebuild:
        shutil.rmtree(os.path.join(cache_dir, "cache"), ignore_errors=True)
        log("=== generating every code cache again")
    if maps or p.rebuild or not link.caches_in(cache_dir):
        log(f"=== compiling ({backend.name})")
        backend.compile()
    else:
        log("=== no new code maps: linking the code caches there are")

    if not p.link:
        log(f"=== code caches in {os.path.join(cache_dir, 'cache')}, not linked")
        return []
    dispatcher = p.dispatcher
    if os.path.isfile(os.path.join(cache_dir, "dispatcher.bin")):
        dispatcher = os.path.join(cache_dir, "dispatcher.bin")
    if not dispatcher:
        raise TranslateError("no dispatcher.bin (it comes with FEXOfflineCompiler.exe in the toolkit)")
    tc = link.find_toolchain()
    log(f"=== linking with {tc}")
    made = []
    for sdk in ("iphoneos",) + (("iphonesimulator",) if p.simulator_image else ()):
        out = os.path.join(p.work_dir, f"image-{sdk}", p.image_name())
        link.link_image(cache_dir, out, sdk, dispatcher, tc, log)
        made.append((sdk, out))
        if p.xcode_project:
            dest = os.path.join(p.xcode_project, "Frameworks", sdk)
            os.makedirs(dest, exist_ok=True)
            shutil.copyfile(out, os.path.join(dest, p.image_name()))
            log(f"  -> {dest}")
    device = made[0][1]
    if p.output_dir:
        os.makedirs(p.output_dir, exist_ok=True)
        shutil.copyfile(device, os.path.join(p.output_dir, p.image_name()))
        log(f"  -> {os.path.join(p.output_dir, p.image_name())}")
    if p.output_ipa:
        if not p.ipa:
            raise TranslateError("an IPA with the image needs the IPA it is made from")
        ipamod.add_images(p.ipa, p.output_ipa, [device])
        log(f"=== {p.output_ipa}: the app with {p.image_name()}, for AltStore, SideStore or Sideloadly")
    # The maps and logs are in the cache directory now; the next run takes only new ones.
    p.ipad_maps, p.drcov_logs, p.rebuild = [], [], False
    p.save()
    log(f"Done. Copy the game folder {p.folder_name()} into WinPad Wine's Documents on the iPad (Finder or Files) "
        "and install the app with the image.")
    return [m[1] for m in made]


def _seed_map(new, exe, backend, maps):
    """A code map that names EXE: one of MAPS that does, else a new one (from its file id)."""
    want = os.path.basename(exe).lower()
    for path in maps:
        with open(path, "rb") as f:
            n, _, _, _ = codemaps.parse(f.read())
        if any(codemaps.basename(v).lower() == want for v in n.values()):
            return path
    file_id = codemaps.pe_file_id(exe)
    if file_id is None:
        raise TranslateError("no code map names the game's .exe, and its file id needs the xxhash package")
    seed = os.path.join(new, "seed.bin")
    with open(seed, "wb") as f:
        f.write(codemaps.image_record(file_id, backend.image_name(exe)) +
                codemaps.ENTRY.pack(*codemaps.SET_MAIN) + codemaps.struct.pack("<Q", file_id))
    return seed
