"""Command line of WinPad Translator; without arguments it opens the window (gui.py)."""
import argparse
import os
import sys

from . import __version__, compile as fexcompile, project


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
    ap.add_argument("--caches-per-run", type=int, help="caches one compiler process makes (default 8)")
    ap.add_argument("--compile-timeout", type=int, help="seconds one compiler process may take")
    ap.add_argument("--no-half-barrier", dest="half_barrier", action="store_false", default=None,
                    help="compile new blocks with ordered atomics (an iPad faults on unaligned ones)")
    ap.add_argument("--rebuild", action="store_true", default=None, help="generate every cache again")
    ap.add_argument("--simulator-image", action="store_true", default=None, help="also link an image for the iPad simulator")
    ap.add_argument("--out", dest="output_dir", help="folder to put the image in")
    ap.add_argument("--out-ipa", dest="output_ipa", help="write a copy of --ipa with the image in it")
    ap.add_argument("--xcode-project", help="put the image into this WinPadWine-xcode project's Frameworks")
    return ap


def main(argv=None):
    argv = sys.argv[1:] if argv is None else argv
    if not argv:
        from . import gui
        return gui.main()
    args = parser().parse_args(argv)
    p = project.Project.load(args.settings) if args.settings else project.Project()
    for key, value in vars(args).items():
        if key == "settings" or value in (None, []):
            continue
        if isinstance(value, list):
            value = [os.path.abspath(v) for v in value]
        elif key.endswith("_dir") or key in ("winpad_repo", "ipa", "compiler", "dispatcher", "output_ipa", "xcode_project"):
            value = os.path.abspath(value)
        setattr(p, key, value)
    try:
        project.run(p)
    except Exception as e:  # noqa: BLE001 - one line for the user, not a traceback
        print(f"error: {e}", file=sys.stderr)
        return 1
    return 0
