"""Downloads rcodesign (apple-codesign, github.com/indygreg/apple-platform-rs) for this
computer into a folder: CI puts it into WinPad Translator's toolkit, so the packaged app
signs an IPA without a Mac (winpad_translator/signipa.py).

Usage: fetch-rcodesign.py FOLDER
"""
import io
import os
import platform
import shutil
import sys
import tarfile
import urllib.request
import zipfile

VERSION = "0.29.0"
BASE = f"https://github.com/indygreg/apple-platform-rs/releases/download/apple-codesign%2F{VERSION}/"


def asset():
    machine = platform.machine().lower()
    arm = machine in ("arm64", "aarch64")
    if sys.platform == "win32":
        # No arm64 build for Windows: Windows on ARM runs the x86-64 one.
        return f"apple-codesign-{VERSION}-x86_64-pc-windows-msvc.zip"
    if sys.platform == "darwin":
        return f"apple-codesign-{VERSION}-macos-universal.tar.gz"
    return f"apple-codesign-{VERSION}-{'aarch64' if arm else 'x86_64'}-unknown-linux-musl.tar.gz"


def main(argv):
    folder = os.path.abspath(argv[0])
    os.makedirs(folder, exist_ok=True)
    name = asset()
    with urllib.request.urlopen(BASE + name, timeout=300) as r:
        data = r.read()
    exe = "rcodesign.exe" if sys.platform == "win32" else "rcodesign"
    out = os.path.join(folder, exe)
    if name.endswith(".zip"):
        with zipfile.ZipFile(io.BytesIO(data)) as z:
            member = next(n for n in z.namelist() if n.rsplit("/", 1)[-1] == exe)
            with z.open(member) as src, open(out, "wb") as dst:
                shutil.copyfileobj(src, dst)
    else:
        with tarfile.open(fileobj=io.BytesIO(data)) as t:
            member = next(m for m in t.getmembers() if m.name.rsplit("/", 1)[-1] == exe)
            with t.extractfile(member) as src, open(out, "wb") as dst:
                shutil.copyfileobj(src, dst)
    os.chmod(out, 0o755)
    print(f"{out} ({name})")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
