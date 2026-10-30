"""Packs WinPad Translator with PyInstaller: WinPadTranslator.exe on Windows (one file),
WinPad Translator.app on a Mac (zipped, so that the app keeps its permissions).

Usage: package.py OUT_DIR [TOOLKIT_DIR]
TOOLKIT_DIR (FEXOfflineCompiler.exe and dispatcher.bin of the WinPad Wine build the
IPA comes from, CI's WinPadTranslator-toolkit) is put inside the app.
"""
import os
import shutil
import subprocess
import sys

here = os.path.dirname(os.path.abspath(__file__))
root = os.path.normpath(os.path.join(here, "..", ".."))


def main(argv):
    out = os.path.abspath(argv[0])
    toolkit = os.path.abspath(argv[1]) if len(argv) > 1 else None
    build = os.path.join(out, "build")
    sep = os.pathsep
    args = [sys.executable, "-m", "PyInstaller", "--noconfirm", "--clean", "--name", "WinPad Translator"
            if sys.platform == "darwin" else "WinPadTranslator", "--distpath", out, "--workpath", build,
            "--specpath", build]
    # The scripts the package imports from the repository (paths.py puts their folders on sys.path).
    for folder in ("tests/fex-wow64", "tools/cache2macho", "tools/fxcc-inspect"):
        args += ["--paths", os.path.join(root, folder)]
    for module in ("codemap", "discover", "drcov2codemap", "cache2macho", "aotindex", "fxcc_inspect",
                   "xxhash", "pefile", "capstone"):
        args += ["--hidden-import", module]
    args += ["--collect-all", "capstone"]
    args += ["--add-data", f"{os.path.join(here, 'data')}{sep}tools/winpad-translator/data"]
    if toolkit:
        args += ["--add-data", f"{toolkit}{sep}toolkit"]
    if sys.platform == "darwin":
        args += ["--windowed", "--osx-bundle-identifier", "io.github.chlupiq.winpad.translator"]
    else:
        args += ["--onefile", "--console"]
    args.append(os.path.join(here, "winpad-translator.py"))
    subprocess.run(args, check=True, cwd=here)
    shutil.rmtree(build, ignore_errors=True)
    if sys.platform == "darwin":
        app = os.path.join(out, "WinPad Translator.app")
        subprocess.run(["ditto", "-c", "-k", "--keepParent", app, os.path.join(out, "WinPadTranslator-macos.zip")],
                       check=True)
        shutil.rmtree(os.path.join(out, "WinPad Translator"), ignore_errors=True)
        print(f"{app} and WinPadTranslator-macos.zip in {out}")
    else:
        print(f"{os.path.join(out, 'WinPadTranslator.exe')}")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
