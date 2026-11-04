# Repozitář

Repozitář neobsahuje kopii Madeiry, Wine ani FEXu. Skripty si je stáhnou na pevných commitech a aplikují patche z `patches/`. Kód WinPadu je hlavně v `tools/` (Python), `tests/` (build skripty, testovací programy, aplikace) a `patches/`.

## Kořen

| Soubor | Co to je |
|---|---|
| `README.md` | Krátký úvod |
| `PLAN.md` | Původní plán a etapy (M0–M7) |
| `docs/` | Tahle dokumentace a deník návrhu (M1–M4) |
| `.github/workflows/checks.yml` | Jediný workflow CI, viz [Sestavení a CI](sestaveni-a-ci.md) |

## `patches/`

Úpravy cizích projektů, aplikované skripty při sestavení. Seznam s popisem je v [Patche](patche.md).

| Adresář | Pro co |
|---|---|
| `fex/` | upstream FEX `14c9268` (etapa M2: Linux, minimální iOS frontend) |
| `fex-wow64/` | FEX fork Madeiry `3bec2ac`, ze kterého je `xtajit.dll` a `FEXOfflineCompiler.exe` |
| `madeira/` | unixová strana ntdll Madeiry (`loader_ios.c`, `virtual_ios.c`) |
| `wine/` | Wine Madeiry |
| `dxmt/` | DXMT Madeiry |

Čísla patchů nejsou souvislá (chybí 0022 a 0025 ve `fex-wow64`, 0006 v `madeira`): čísla se srovnávala, když se větve slévaly.

## `tools/`: nástroje

| Nástroj | Co dělá |
|---|---|
| `pe2macho/` | Zabalí ARM64 PE modul do Mach-O dylibu se stejným RVA rozložením. `x18.py` přepisuje čtení x18 (TEB) na trampolíny, `fix_syscall_stubs.py` syscall stuby na `adrp`/`ldr`, `pe_adopt.h` obraz po `dlopen` najde a ověří. |
| `cache2macho/` | FEX AOT cache → Mach-O objekt (`cache2macho.py`), index cache pro WoW64 (`aotindex.py`), kontrola slinkovaného obrazu (`check_linked.py`). |
| `fxcc-inspect/` | Výpis FEX cache: bloky, velikost kódu, relokace podle typu, porovnání dvou cache. |
| `pe-reloc-audit/` | Audit relokací v kódových sekcích PE modulů (etapa M1). |
| `winpad-translator/` | WinPad Translator: okno (Tk) i příkazová řádka, balení přes PyInstaller (`package.py`), Docker kontejner pro kompilátor (`data/docker`). Moduly: `codemaps.py` (import a rozdělení map), `compile.py` (backendy kompilátoru), `link.py` (obraz), `ipa.py` (IPA, název aplikace), `library.py` (víc her), `project.py` (nastavení hry), `gui.py`, `cli.py`. |

Testy nástrojů: `python3 -m unittest` v adresáři nástroje (`test_*.py`, u překladače `tests/`).

## `tests/`: build skripty, testy a aplikace

### Etapa M2 (FEX bez JITu na Linuxu a v iOS testovací aplikaci)

| Adresář | Obsah |
|---|---|
| `syscall-stubs/` | Syscall stuby Wine bez relokací (`patches/wine/0001`) |
| `fex-cache/` | Upstream FEX na arm64 Linuxu: code mapa → offline cache → druhý běh z cache; malý x86-64 host `guest.S` |
| `probe/` | Minimální frontend FEXCore (bez Wine): x86-64 program z AOT obrazu s NoJIT na Linuxu a macOS; pokrývá SSE2, x87, výjimky, vlákna |
| `ios/` | Testovací aplikace WinPadProbe (IPA a Xcode projekt), FEXCore pro iOS |
| `pe2macho/` | Načtení zabalených Wine modulů přes `dlopen`, testovací DLL |

### Etapa M3 a dál (Wine na iOS)

| Adresář | Obsah |
|---|---|
| `wine-loader/` | Stažení Madeiry a Wine (`build.sh`), unixová strana ntdll/win32u/wineserver pro iOS (`build-*.sh`), zabalení modulů (`wrap-modules.sh`), linkování hostu (`link-host.sh`), běh na simulátoru (`run-host.sh`), konvergence cache (`converge-cache.sh`, `converge-nojit.sh`), kontrola okna hosta proti mapě adres iPadu (`check-wow-window.*`), výchozí `prefix/system.reg`. Host sám je v `host/winehost.c` a `host/metal-display.m`. |
| `wine-i386/` | 32bitová strana: i386 moduly Wine (`build.sh`), DXMT pro i386 a jeho unixová strana (`build-d3d9.sh`, `build-dxmt-unix.sh`, `build-llvm.sh`), testovací programy |
| `fex-wow64/` | `xtajit.dll` a `FEXOfflineCompiler.exe` ze zdrojáků (`build.sh`), linkování obrazu (`build-aot-image.sh`), kompilace po dávkách (`process-all-batches.sh`), práce s code mapami (`codemap.py`), statické hledání kódu (`discover.py`), převod DynamoRIO (`drcov2codemap.py`), kontrola interpretu (`interp-cache.sh`) |
| `wine-app/` | **Aplikace WinPad Wine**: `main.m`, `Library.m`, `Settings.bundle`, `project.yml.in` (XcodeGen), `build-xcode.sh` (Xcode projekt), `make-ipa.sh` (IPA), `game-aot.sh` (obraz hry na Macu, předchůdce překladače) |

### Testovací programy (`tests/wine-i386`)

Každý ověřuje jednu věc, kterou potřebovala skutečná hra:

| Program | Co ověřuje |
|---|---|
| `hello.c` | Konzolový program, jen kernel32 |
| `window.c` | Okno přes GDI, menu, klávesy, ťuknutí |
| `imports.c` + `casetest.c` | DLL, které hra importuje; názvy DLL v jiné velikosti písmen |
| `d3d9-cube.c` | Direct3D 9 přes DXMT a Metal |
| `cwd.c` | Program startuje ve své složce |
| `guard.c` | Růst zásobníku a guard stránky |
| `simd.c` | MMX, SSE a x87 v interpretu proti JITu (hash výsledků) |
| `hook.c` | Kód přepsaný hookem po `VirtualProtect` |
| `unaligned.c` | Nezarovnané atomické přístupy (half barrier) |
| `rtcode.c` | Kód vyrobený za běhu |
| `nodep.exe` | `hello.c` bez NX_COMPAT (změna DEP) |

## Větve

Na `main` je zatím jen počáteční commit. Veškerá práce je v řetězu navazujících PR (#1 → … → #98), každý postavený na předchozím. Nejnovější stav je vždy na vrcholu řetězu. Podrobnosti v [Stav projektu](stav-projektu.md).
