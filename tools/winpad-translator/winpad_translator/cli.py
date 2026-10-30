"""Command line of WinPad Translator; without arguments it opens the window (gui.py)."""
import argparse
import os
import sys

from . import __version__, compile as fexcompile, library, project


def parser():
    ap = argparse.ArgumentParser(
        prog="winpad-translator",
        description="Turns a game's FEX code maps (from the iPad, PC drcov logs or a static walk) into the "
                    "AOT image fexaot-<game>.dylib the WinPad Wine iPad app runs.")
    ap.add_argument("--version", action="version", version=__version__)
    ap.add_argument("--settings", help=f"read the settings from this file ({project.SETTINGS} in a work folder)")
    ap.add_argument("--game", dest="game_dir", help="the game's folder, as it is on the iPad")
    ap.add_argument("--work", dest="work_dir", help="where maps, caches and images are kept (default ~/WinPadTranslator/<game>)")
    ap.add_argument("--ipad-maps", action="append", default=[], metavar="FOLDER",
                    help="Documents/fexcache/codemap/new copied off the iPad (may be repeated)")
    ap.add_argument("--drcov", dest="drcov_logs", action="append", default=[], metavar="LOG",
                    help="DynamoRIO drcov log of the game run on a PC (may be repeated)")
    ap.add_argument("--discover", action="store_true", help="also find the .exe's code statically")
    ap.add_argument("--exe", help="the game's program, relative to its folder (default: from the maps or winpad.json)")
    ap.add_argument("--ipad-folder", help="the game folder's name on the iPad, if it differs")
    ap.add_argument("--ipa", help="the WinPad Wine IPA the iPad runs")
    ap.add_argument("--system-dir", help="or its i386-windows folder")
    ap.add_argument("--compiler", help="FEXOfflineCompiler.exe (default: from the toolkit)")
    ap.add_argument("--dispatcher", help="dispatcher.bin (default: from the toolkit)")
    ap.add_argument("--backend", choices=fexcompile.BACKENDS,
                    help=f"how the compiler runs (default here: {fexcompile.default_backend()})")
    ap.add_argument("--wine", help="the Wine command for --backend wine")
    ap.add_argument("--sim-work-dir", help="tests/wine-loader's work directory, for --backend simulator")
    ap.add_argument("--winpad-repo", help="a WinPad checkout, for --backend simulator")
    ap.add_argument("--compile-only", dest="link", action="store_false", default=None,
                    help="stop after compiling the code caches")
    ap.add_argument("--host-features", help="the iPad's CPU features as FEX_MADEIRA_HOSTPROBE "
                    "(default: hostprobe.txt next to the iPad's code maps)")
    ap.add_argument("--caches-per-run", type=int, help="caches one compiler process makes (default 8)")
    ap.add_argument("--compile-timeout", type=int, help="seconds one compiler process may take")
    ap.add_argument("--no-half-barrier", dest="half_barrier", action="store_false", default=None,
                    help="compile new blocks with ordered atomics (an iPad faults on unaligned ones)")
    ap.add_argument("--rebuild", action="store_true", default=None, help="generate every cache again")
    ap.add_argument("--simulator-image", action="store_true", default=None, help="also link an image for the iPad simulator")
    ap.add_argument("--out", dest="output_dir", help="folder to put the image in")
    ap.add_argument("--out-ipa", dest="output_ipa", help="write a copy of --ipa with the image in it")
    ap.add_argument("--app-name", help="the name under the app's icon on the iPad, e.g. the game's (default: WinPad Wine)")
    ap.add_argument("--xcode-project", help="put the image into this WinPadWine-xcode project's Frameworks")
    ap.add_argument("--sign-identity", help="Mac: also sign the image with this identity (auto: your Apple Development "
                    "one) into the game folder as fexaot.dylib, which the app loads without a new install")
    lib = ap.add_argument_group("a library of games: several games in one app")
    lib.add_argument("--library", nargs="?", const=library.default_path(), metavar="FILE",
                     help=f"work on the library in FILE (default {library.default_path()}); --ipa, --out-ipa, "
                     "--xcode-project, --app-name and the compiler settings are kept in it")
    lib.add_argument("--add-game", action="append", default=[], metavar="FOLDER",
                     help="add a game folder (--exe, --ipad-folder apply to it)")
    lib.add_argument("--remove-game", action="append", default=[], metavar="NAME", help="take a game off the list")
    lib.add_argument("--list-games", action="store_true", help="list the games")
    lib.add_argument("--build", action="store_true",
                     help="translate the games with new code maps in --ipad-maps and write the app with all of them")
    return ap


PATH_KEYS = ("winpad_repo", "ipa", "compiler", "dispatcher", "output_ipa", "xcode_project")


def library_main(args):
    path = os.path.abspath(args.library)
    lib = library.Library.load(path)
    for key in ("ipa", "output_ipa", "xcode_project", "app_name"):
        if getattr(args, key) is not None:
            setattr(lib, key, getattr(args, key))
    for key in library.SHARED:
        value = getattr(args, key, None)
        if value is not None:
            lib.settings[key] = value
    for folder in args.add_game:
        p = lib.add(folder, exe=args.exe or "", ipad_folder=args.ipad_folder or "")
        print(f"added {p.folder_name()} (image {p.image_name()}, work folder {p.work_dir})")
    for name in args.remove_game:
        print(f"removed {lib.remove(name).folder_name()}")
    lib.save(path)
    if args.list_games or not (args.add_game or args.remove_game or args.build):
        for p in lib.projects():
            state = "image ready" if os.path.isfile(library.image_of(p)) else "no image yet"
            print(f"{p.folder_name()}: {p.game_dir} ({p.image_name()}, {state})")
    if args.build:
        library.build(lib, args.ipad_maps, rebuild=bool(args.rebuild))
        lib.save(path)


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if not argv:
        from . import gui
        return gui.main()
    args = parser().parse_args(argv)
    for key, value in vars(args).items():
        if key in ("remove_game", "library") or value in (None, []):
            continue
        if isinstance(value, list):
            setattr(args, key, [os.path.abspath(v) for v in value])
        elif key.endswith("_dir") or key in PATH_KEYS:
            setattr(args, key, os.path.abspath(value))
    if args.library:
        try:
            library_main(args)
        except Exception as e:  # noqa: BLE001 - one line for the user, not a traceback
            print(f"error: {e}", file=sys.stderr)
            return 1
        return 0
    p = project.Project.load(args.settings) if args.settings else project.Project()
    for key, value in vars(args).items():
        if key in ("settings", "library", "add_game", "remove_game", "list_games", "build") or value in (None, []):
            continue
        setattr(p, key, value)
    try:
        project.run(p)
    except Exception as e:  # noqa: BLE001 - one line for the user, not a traceback
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0
