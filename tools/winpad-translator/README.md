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
  `Documents/fexcache/<game folder>/codemap/new` (with `runtime/` for code the game builds at
  run time). In the app's library, **Exportovat pro převodník** (or the
  controller's X) shares them as one zip (AirDrop to the Mac, Files, Mail);
  add that zip (`--ipad-maps WinPad-mapy-<game>-<date>.zip`, or the **zip**
  button in the window). Copying the folder off the iPad (Finder or Files)
  works too. The app writes each block the moment the interpreter learns it,
  so maps survive iPadOS ending the app. The zip's `winpad-export.json` names
  the game folder, the app build and when it was exported; the library build
  says when an export is of no game it has. Each round of play → export →
  translate makes the game faster.
- **DynamoRIO logs from a Windows PC** (`drrun -t drcov -- GAME.EXE`, play for a
  while): one session covers most of the game's own code at once
  (`tests/fex-wow64/drcov2codemap.py`).
- **A static walk** of the game's .exe (`tests/fex-wow64/discover.py`).
- **Play and record** (`--record`, the **Play and record** button): the
  translator starts the game here, you play, and when you quit it the code it
  ran goes straight into the translation, with no other app (`record.py`):
  - **Windows** (an x86-64 PC): the game runs natively under DynamoRIO's
    drcov, which the translator downloads from DynamoRIO's GitHub releases the
    first time into `~/WinPadTranslator/tools` (or `--dynamorio FOLDER`). Code
    maps are made of the .exe and of the game's own DLLs (its folder); Windows'
    DLLs are not Wine's, so their code is left to the iPad. A game with copy
    protection or anti-cheat may refuse to run under DynamoRIO. DynamoRIO does
    not run on Windows on ARM.
  - **Mac**: the `WinPadWine-xcode` project (`--xcode-project`) is built for an
    iPad simulator, the game is cloned into the simulator app's Documents and
    started there (`-recordGame FOLDER`, main.m) with FEX's JIT and code maps
    on. You play in the Simulator window (keyboard, game controller); Wine, its
    DLLs and the game's settings are the iPad's, so these maps cover Wine's
    code too and are taken as maps from the iPad are. The simulator runs on the
    Mac's chip, so its `hostprobe.txt` is left out: the image is compiled for
    the iPad's features.

  Quitting the game in the game is best. **Stop the game** asks it to close on
  Windows (drcov writes its log as the game ends), and ends the app on a Mac
  (FEX has written all but the last few blocks by then). `--record-only` records without translating (the next run with
  `--settings` takes it).

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

`--game` also takes the game's .exe (`--game "D:\Games\My Game\GAME.EXE"`): the folder
it is in is the game, and the .exe its program (as `--exe`). In the window, **Game program
(.exe)** picks it and fills the game folder; in the game library, **+** adds a game by its
.exe and **dir** by its folder.

Then copy the game folder into WinPad Wine's Documents on the iPad and install
the new IPA. The settings of a game are kept in its work folder
(`winpad-translator.json`, `--settings`), so the next round only needs the new
code maps.

## Game profiles

Some games need settings of their own in WinPad Wine: a DLL from the game
folder before Wine's, a resolution that fits the iPad, an argument. A profile
(`data/profiles/<id>.json`, `profiles.py`) says how to recognise a game and
what it needs. Every translation looks for one (`--profile auto`, the
default; Game profile in the window) and puts it into the game folder's
`winpad.json`, which the app reads:

```json
{
  "title": "My own title",
  "profile": {
    "id": "nfsu2", "version": 1, "title": "Need for Speed Underground 2",
    "notes": ["..."],
    "settings": {
      "exe": "SPEED2.EXE", "title": "Need for Speed Underground 2",
      "dllOverrides": {"dinput8": "n,b"},
      "registry": {"HKLM\\Software\\EA Games\\Need for Speed Underground 2": {"g_RacingResolution": 2}}
    }
  }
}
```

The translator only writes `"profile"`. Every other key of `winpad.json` is
the user's, and it wins over the profile's: `title` and `exe` replace the
profile's, and `dllOverrides`, `env` and `registry` win entry by entry. The app
(`WinPadGameSettings` in tests/wine-app/Library.m) and `profiles.effective`
merge the same way. The settings:

| key | what the app does with it |
| --- | --- |
| `title`, `exe` | the library's title and the program, relative to the game folder |
| `args` | arguments for the program |
| `dllOverrides` | `WINEDLLOVERRIDES`, after the app's own `dinput8=n,b` |
| `env` | environment variables, except the ones the app sets (`WINE*`, `FEX_*`, `DYLD_*`...) |
| `registry` | values (text, a number = DWORD, `{"hex": "00ff"}` = binary) put into the prefix's `system.reg` (HKLM) or `user.reg` (HKCU) when the key does not have them yet, so a game that changes one keeps its own; a 32-bit game's `HKLM\Software` goes to `Wow6432Node` |

A profile matches a game by any of its `match` rules: an `exe` in the folder
(any case) with all of the rule's `files`, or the folder's Steam app
(`steamAppId`: `steam_appid.txt` in the folder, or the `appmanifest_<id>.acf`
of the `steamapps` folder it is in). `--profile ID` forces one, `--profile
none` takes it out of `winpad.json`, `--list-profiles` lists them, and
`--profile-only --game FOLDER` only writes `winpad.json`.

| profile | recognised by | settings |
| --- | --- | --- |
| `nfsu2` Need for Speed Underground 2 | `SPEED2.EXE` + `GLOBAL/GLOBALA.BUN` | `dinput8=n,b` (Ultimate ASI Loader), race resolution 1024×768 (`g_RacingResolution` 2) |
| `mafia` Mafia (2002) | Steam 40990, `GameV12.exe`, or `Game.exe` + `Setup.exe` + `LS3DF.dll` | `d3d8=n,b`: a `d3d8.dll` in the game folder (Mafia Widescreen Fix's d3d8to9) first, else the app's d3d8to9 |

Each profile names its sources (PCGamingWiki, forums). Proton's game fixes
(umu-protonfixes) have nothing for either game; take settings from them when a
game has one. A new profile is one JSON file; `tests/test_profiles.py` checks
the shipped ones.

## Several games in one app

The app's game library (tests/wine-app/Library.m) starts each game folder in
its Documents with that game's own image, `Frameworks/fexaot-<folder>.dylib`,
so one app holds any number of games. The translator keeps a library of them
(`~/WinPadTranslator/library.json`, the "Game library" tab in the window):

```
winpad-translator --library --add-game ~/Games/NFSU2 --add-game ~/Games/OtherGame
winpad-translator --library --build --ipad-maps ~/from-ipad/fexcache \
    --ipa WinPadWine.ipa --out-ipa WinPad.ipa
```

The app keeps each game's code maps in its own folder,
`Documents/fexcache/<game folder>` (older builds: all in `fexcache/codemap/new`).
Give the whole `fexcache` folder copied off the iPad; each game takes its own
maps from it (the maps naming files in its folder on the iPad), and FEX's
caches in it are left alone. Only games
with new maps are compiled again; the others keep their image. The IPA written
has every game's image and is called WinPad (`--app-name`). Install it over the
old app (same bundle identifier, so its Documents and games stay). `--ipa` is
the IPA from CI, never one the library wrote, so a game taken off the list
(`--remove-game`) is gone from the next one. A game that was not played yet
has no maps and no image: it runs in FEX's interpreter until then.

### Without a new install (Mac, experimental)

Executable code on an iPad must be signed. With `--sign-identity auto` (or an
identity's name; "Sign into game folder" in the window) the translator signs
each image on the Mac with the Apple Development identity of the keychain and
puts it into the game folder as `fexaot.dylib`, with `fexaot.build` naming the
app build it was made for (the IPA's `winpad-build.txt`, which
tests/wine-app/build-xcode.sh writes). Copy the folder to the iPad and the app
loads the image from there, no new install. It takes the image only for the
same build of the app, and falls back to the one in its Frameworks if iOS
refuses it (a signature from another team than the app's: install the app from
Xcode with the same Apple ID). Code maps themselves cannot be turned into code
on the iPad: that would take a JIT.

## One file for the iPad: the .winpad package

`--package FILE` (or a folder, for `<game folder>.winpad` in it; "Write .winpad
package" in the window) also writes the game as one file: a ZIP archive of the
game folder as the app keeps it, with its `winpad.json`, cover and, when it was
signed with `--sign-identity`, the image `fexaot.dylib` with `fexaot.build`.
AirDrop it to the iPad or open it in Files (or copy it into WinPad Wine's
Documents): the app unpacks it into `Documents/<folder>` and the game shows in
its library. Files the game wrote there itself (saves) stay.

- `--package-no-game`: only the settings, cover and signed image, for a game
  the iPad has already (an update after a new translation round).
- `--package-only`: package the game folder as it is, translate nothing.
- `--library ... --build --package-dir FOLDER`: a package of each game
  translated.

An image that is not signed is left out, because iOS would not run it: the game
then runs from the image in the app's IPA. The code maps are not packaged: the
iPad writes its own, and the translator's copies name this computer's files.

`winpad.json` in the package is the game folder's own (the library reads
`title` and `exe`; other keys are game settings), plus a `package` object:

```json
{"title": "Need for Speed Underground 2", "exe": "SPEED2.EXE",
 "package": {"format": 1, "folder": "NFSU2", "game_files": true, "image": "fexaot.dylib",
             "app_build": "…", "made": "2026-11-04T13:00:00+00:00", "translator": "0.1.0"}}
```

The app reads packages with `tests/wine-app/Package.c` (zlib; stored and
deflated entries, ZIP64 for games over 4 GB; names that would leave the folder
are refused); `tests/test_package.py` builds it with the C compiler here and
unpacks the translator's packages with it.


## Sign and install in one step

Translated code is executable code, and an iPad runs only code signed for it, so the
image runs from an app signed with your Apple certificate. With `--install` ("Sign and
install on the iPad" in the window, both tabs) the translator signs the app with the new
image and installs it on the iPad, connected by cable or on the same Wi-Fi, right after
translating (winpad_translator/install.py). Installed over the old app (same bundle
identifier), it keeps its Documents and games.

| Computer | What signs | What it needs |
|---|---|---|
| Mac with the `WinPadWine-xcode` project (`--xcode-project`) | `xcodebuild` builds the app for your team; Xcode makes the certificate and profile itself and registers a new iPad (`-allowProvisioningUpdates`) | your Apple ID in Xcode (Settings › Accounts), free or paid; the team is your Apple Development identity's (`--team` otherwise) |
| Mac with only the IPA | `codesign` with your Apple Development identity and the profile Xcode made for the app | one Run of WinPadWine from Xcode with your team (that makes the profile), or `--provisioning-profile` |
| Windows PC, Linux | `rcodesign` (apple-codesign; the packaged app brings it) | your certificate as a `.p12` (`--p12`, `--p12-password` or `WINPAD_P12_PASSWORD`) and a profile (`--provisioning-profile`): paid Apple Developer account |
| Windows PC, nothing installed | a GitHub Actions job in your own private repository (`--cloud-sign OWNER/REPO`) | the same `.p12` and profile, once stored in that repository |

The app goes onto the iPad with Xcode's `devicectl` on a Mac and with `ideviceinstaller`
(libimobiledevice) elsewhere when it is installed; otherwise the translator writes
`…-signed.ipa`, which installs as it is (Sideloadly with Signing mode "Normal install",
Apple Configurator). `--device` picks the iPad when several are connected; `--sign-only`
only writes the signed IPA; `--bundle-id` sets another bundle identifier (with a free
Apple ID it must be one nobody else registered). The first app from a new certificate
needs Settings › General › VPN & Device Management › trust, and iOS 16+ Developer Mode.

```
# Mac: translate, build for your team, install
winpad-translator --game ~/Games/NFSU2 --ipad-maps ~/from-ipad/fexcache \
    --xcode-project ~/Developer/wine-app/WinPadWine-xcode --install
# a library of games, the same way
winpad-translator --library --build --ipad-maps ~/from-ipad/fexcache --install
```

### A certificate without a Mac

developer.apple.com takes a certificate signing request; the translator makes one and
turns Apple's certificate into the `.p12` (winpad_translator/applecert.py):

```
winpad-translator --cert-request you@example.com
#   upload ~/WinPadTranslator/certificate/winpad.certSigningRequest at developer.apple.com ›
#   Certificates › + › Apple Development, download the .cer
winpad-translator --cert-p12 development.cer --p12-password SECRET
#   then Profiles › + › iOS App Development: the app's identifier
#   (com.chlupiq.winpad.wine or your own), this certificate, your iPad › download
```

### Signing in the cloud

For a Windows PC with nothing to sign with. Once:

```
winpad-translator --cloud-setup you/winpad-sign --github-token TOKEN \
    --p12 winpad.p12 --p12-password SECRET --provisioning-profile WinPad.mobileprovision
```

makes the private repository `you/winpad-sign` (or takes yours), puts the signing job
(data/cloud-sign/winpad-sign.yml) and `signipa.py` into it and stores the certificate,
its password and the profile as its Actions secrets, encrypted for the repository
(PyNaCl). The token (a fine-grained one for that repository with Contents, Actions,
Secrets and Administration, or a classic one with `repo` and `workflow`) is kept in
`~/WinPadTranslator/github-token`. Then `--cloud-sign you/winpad-sign` uploads the IPA to a
draft release of the repository, starts the job, downloads the signed IPA and deletes the
release. The IPA holds your games' translated code, so a public repository is refused.
On GitHub's free plan a private repository has 2,000 Actions minutes a month; one
signing takes about a minute.

Tests: `python3 -m unittest discover -s tools/winpad-translator/tests` (signing needs
rcodesign: `python3 tools/winpad-translator/fetch-rcodesign.py FOLDER`).
