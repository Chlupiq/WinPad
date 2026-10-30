# WinPad Translator

Turns a Windows game's x86 code into the AOT image the WinPad Wine iPad app
runs without a JIT (`Frameworks/fexaot-<game>.dylib`), for any game, on a Mac
or a Windows PC. It does what `tests/wine-app/game-aot.sh` and the manual
steps around it did for NFS Underground 2, with nothing game-specific in it.

Distribution stays "ROM style": each user translates the games they own on
their own computer and installs the app with the image under their own Apple
ID. Game files, code maps, caches and images never go to the repository or CI.

## What it takes and what it makes

Inputs, any combination:

- **Code maps from the iPad.** Code missing from the image runs in FEX's
  interpreter on the iPad, slowly, and is recorded in the app's
  `Documents/fexcache/codemap/new` (with `runtime/` for code the game builds at
  run time). Copy that folder off the iPad (Finder or Files) and add it. Each
  round of play → copy → translate makes the game faster.
- **DynamoRIO logs from a Windows PC** (`drrun -t drcov -- GAME.EXE`, play for a
  while): one session covers most of the game's own code at once
  (`tests/fex-wow64/drcov2codemap.py`).
- **A static walk** of the game's .exe (`tests/fex-wow64/discover.py`).

Plus:

- the **game folder**, the same files as in WinPad Wine's Documents on the iPad;
- the **WinPad Wine IPA** the iPad runs: the code maps name Wine's i386 DLLs,
  and FEX only uses a cache for the very file it was made from (its file id
  hashes the name, size and link time), so the DLLs come from that IPA;
- the **toolkit** of the same build: `FEXOfflineCompiler.exe` and
  `dispatcher.bin` (CI artifact `WinPadTranslator-toolkit`, bundled into the
  packaged apps).

Output: `fexaot-<game>.dylib` (`<game>` is the folder name in lower case,
other characters as `-`, as the app's game library looks for it), optionally
a copy of the IPA with the image in `Frameworks/` for AltStore, SideStore or
Sideloadly, or the image copied into a `WinPadWine-xcode` project.

## Steps

1. Code maps are copied into the work folder (`~/WinPadTranslator/<game>`,
   kept from one round to the next).
2. Each image name in them is pointed at the file here: the iPad's
   `Documents/FOLDER/...` paths at the game folder (matched without regard to
   case), Wine's `C:\windows\syswow64` DLLs at the IPA's `i386-windows`. A file
   whose file id differs from the one the iPad ran is reported.
3. New blocks are marked for half barriers (patches/fex-wow64/0030): an iPad
   faults on unaligned atomics in read-only AOT code.
4. FEX's offline compiler compiles the maps into code caches, a few caches per
   process (patches/fex-wow64/0028).
5. tools/cache2macho turns the caches into Mach-O objects; with the index and
   the dispatcher they are linked into the dylib, by Xcode on a Mac or by LLVM
   (`clang`/`llvm-mc` + `ld64.lld`, a libSystem stub in place of the SDK)
   anywhere else.

## The iPad's CPU features

FEX's code depends on the CPU features it may use (FEAT_AFP, FlagM, LRCPC...).
The app writes the iPad's features (`FEX_MADEIRA_HOSTPROBE`) as `hostprobe.txt`
next to its code maps, and the translator compiles for those, not for the
computer it runs on: the simulator on a Mac would otherwise compile for that
Mac's chip (an M1 has no FEAT_AFP, an M2 iPad has). Without the file it
compiles for FEX's assumption, the newest Apple cores (`--host-features` sets
them by hand). When they change, every cache is made again.

## Where the offline compiler runs

`FEXOfflineCompiler.exe` is an **aarch64 Windows** program. It only generates
arm64 code and never runs it, and its host features are fixed for Apple's
cores (FEX_IOS_HOST), so what it makes should not depend on the computer.
Backends (`--backend`):

| Backend | Where | Status |
|---|---|---|
| `simulator` | Mac with Xcode: Wine in an iPad simulator, as `game-aot.sh` | what NFSU2's images were made with; needs a WinPad checkout and its `tests/wine-loader` build (`--sim-work-dir`, `--winpad-repo`) |
| `native` | Windows on ARM (Snapdragon) | CI job `translator-compile` on `windows-11-arm`: caches byte for byte the simulator's |
| `wine` | arm64 Linux with Wine 10 or newer (Debian 13, Fedora...; also a Raspberry Pi 5, an Ampere box) | Ubuntu 24.04's Wine 9 hangs on CPUs with pointer authentication (Neoverse N2, Graviton 4...), as on CI's `ubuntu-24.04-arm`: use `docker` there |
| `docker` on arm64 Linux | the same Debian container, run natively (also Docker on an Apple Silicon Mac) | CI on `ubuntu-24.04-arm`: caches byte for byte the simulator's |
| `docker` | any x86-64 PC or Mac with Docker (Desktop): Debian's Wine 10 in an arm64 container, emulated by QEMU as a Neoverse N1 (with QEMU's default CPU `wineboot` never returns) | CI on `ubuntu-24.04`: caches byte for byte the simulator's; slower (emulated), but needs nothing else |

An x86-64 Windows PC therefore compiles through Docker Desktop (the default
there); the linking step runs natively with LLVM (`winget install LLVM.LLVM`).
A native x86-64 build of the offline compiler would need FEX's arm64 code
emitter ported to an x86-64 host: possible in principle, not done.

## Use

The packaged apps (CI artifacts `WinPadTranslator-windows`,
`WinPadTranslator-macos`) open a window without arguments. From the
repository: `python3 tools/winpad-translator/winpad-translator.py` (needs
Python 3.10+ with Tk; `pip install xxhash pefile capstone`).

```
winpad-translator --game "D:\Games\My Game" --ipad-maps "D:\from-ipad\new" \
    --ipa WinPadWine.ipa --out-ipa WinPadWine-mygame.ipa --app-name "My Game"
```

`--app-name` (App name in the window) sets the name under the app's icon
(CFBundleDisplayName) in the IPA written, or in the Info.plist of
`--xcode-project`. The bundle identifier stays, so the renamed app replaces
WinPad Wine on the iPad and keeps its Documents.

Then copy the game folder into WinPad Wine's Documents on the iPad and install
the new IPA. The settings of a game are kept in its work folder
(`winpad-translator.json`, `--settings`), so the next round only needs the new
code maps.

Tests: `python3 -m unittest discover -s tools/winpad-translator/tests`.
