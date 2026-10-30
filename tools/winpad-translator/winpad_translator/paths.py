"""Where the WinPad scripts this tool builds on are: in the repository, or bundled by PyInstaller."""
import os
import sys


def _root():
    bundled = getattr(sys, "_MEIPASS", None)
    if bundled:
        return bundled
    return os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", ".."))


ROOT = _root()
# In the repository the scripts live in their own folders; the packaged app has them
# under the same relative paths (see winpad-translator.spec).
FEX_WOW64 = os.path.join(ROOT, "tests", "fex-wow64")
CACHE2MACHO = os.path.join(ROOT, "tools", "cache2macho")
FXCC_INSPECT = os.path.join(ROOT, "tools", "fxcc-inspect")
WINE_LOADER = os.path.join(ROOT, "tests", "wine-loader")
DATA = os.path.join(ROOT, "tools", "winpad-translator", "data")

for p in (FEX_WOW64, CACHE2MACHO, FXCC_INSPECT):
    if p not in sys.path:
        sys.path.insert(0, p)
