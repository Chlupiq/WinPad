# Sestavení a CI

Všechno se staví v GitHub Actions (`.github/workflows/checks.yml`), na každý push a PR. Repozitář je veřejný kvůli bezplatným macOS runnerům. Lokálně se staví hlavně na Macu se hrou, protože herní soubory do CI nesmí.

## Joby

| Job | Runner | Co ověřuje / vyrábí |
|---|---|---|
| `syscall-stubs` | ubuntu-24.04 | Syscall stuby Wine bez relokací v kódu |
| `wow-window` | ubuntu-24.04 | Umístění okna hosta na mapě adres skutečného iPadu (končí na `0x7180000000`) |
| `fxcc-inspect` | ubuntu-24.04 | Testy nástroje `fxcc-inspect` |
| `fex-cache` | ubuntu-24.04-arm | Upstream FEX: code mapa, offline cache, probe z AOT obrazu |
| `fex-wow64` | ubuntu-24.04-arm | `xtajit.dll` a `FEXOfflineCompiler.exe` z FEX forku Madeiry s `patches/fex-wow64` |
| `probe-macos` | macos-15 | Probe z Mach-O AOT obrazu; aplikace WinPadProbe (IPA, Xcode projekt) |
| `pe2macho` | macos-15 | Zabalené Windows DLL běží na Macu; všechny Wine moduly Madeiry se načtou přes `dlopen` |
| `wine-loader` | macos-15 | **Hlavní job.** Celé Wine pro iOS a simulátor, testovací programy v simulátoru iPadu (clock, notepad, Minesweeper, x86 hello/window), code mapy → cache → obraz → NoJIT běh s konvergencí, testy interpretu (SIMD, DEP, hook, rtcode, unaligned), statické hledání kódu, importy hry, zásobník, složka programu, DXMT a D3D9 kostka, aplikace v simulátoru se snímkem knihovny, Xcode projekt a IPA, toolkit překladače |
| `winpad-translator` | ubuntu, windows, macos | Unit testy překladače (mapy z iPadu, IPA, linkování LLVM bez Xcode, celý běh) |
| `winpad-translator-app` | windows, macos | Zabalený překladač (PyInstaller) se spustí, najde toolkit a slinkuje obraz |
| `translator-compile` | ubuntu-24.04-arm, windows-11-arm, ubuntu-24.04 | Offline kompilátor mimo Mac (Docker nativně, Windows on ARM nativně, Docker pod QEMU); cache se musí bajt po bajtu shodovat se simulátorem |
| `fexcore-ios` | macos-15 | FEXCore pro iOS (etapa M2) |

Běhy jsou dlouhé (hlavní job desítky minut), proto se mezivýsledky ukládají do cache Actions (Wine strom, sestavené knihovny, LLVM, FEX).

## Artefakty

| Artefakt | Obsah | Pro koho |
|---|---|---|
| `WinPadWine-ipa` | Nepodepsaná IPA aplikace s testovacími programy | Instalace přes Sideloadly/AltStore/SideStore; vstup překladače |
| `WinPadWine-xcode` | Xcode projekt aplikace (předpřeložené knihovny pro `iphoneos` i `iphonesimulator`, `make-ipa.sh`, `game-aot.sh`) | Instalace z Xcode, práce na Macu |
| `WinPadTranslator-windows`, `WinPadTranslator-macos` | Zabalený překladač s toolkitem | Uživatelé |
| `WinPadTranslator-toolkit` | `FEXOfflineCompiler.exe` a `dispatcher.bin` tohoto buildu | Překladač spouštěný ze zdrojáků |
| `xtajit` | FEX WoW64 modul | Ladění |
| `wine-app-window`, `wine-window-*` | Snímky oken a logy z běhů v simulátoru | Kontrola výsledků |
| `fex-cache-hello`, `fex-cache-window` | Code mapy a cache testovacích programů | Ladění AOT |
| `translator-compile-*` | Výstupy kompilátoru z jiných počítačů | Porovnání cache |

Toolkit, IPA a překladač musí být ze **stejného běhu CI**: cache sedí jen k buildu FEXu, který je vyrobil, a code mapy jmenují i386 DLL přesně té IPA.

## Lokálně na Macu

Potřeba: Mac s Apple Silicon, Xcode (Wine Madeiry potřebuje iOS 26 SDK nebo novější), Homebrew (`llvm`, `lld`, `bison`, `flex`, `meson`, `ninja`, `xcodegen`), Python 3.10+.

Nejjednodušší je stáhnout artefakt `WinPadWine-xcode` a pracovat s ním. Pro změny v kódu se dá zopakovat to, co dělá job `wine-loader`, se stejnými skripty a pracovním adresářem `WORK`:

```sh
sh tests/wine-loader/build.sh WORK              # Madeira, Wine, loader ntdll s patchi
sh tests/wine-loader/build-ntdll.sh WORK iphonesimulator       # unixová strana ntdll
sh tests/wine-loader/build-win32u.sh WORK iphonesimulator
sh tests/wine-loader/build-wineserver.sh WORK iphonesimulator
sh tests/wine-loader/wrap-modules.sh WORK iphonesimulator
sh tests/wine-i386/build.sh WORK                # i386 moduly a testovací programy
sh tests/fex-wow64/build.sh WORK                # xtajit.dll + FEXOfflineCompiler.exe
sh tests/wine-loader/run-host.sh WORK Z:/…/hello.exe   # běh v simulátoru
sh tests/wine-app/build-xcode.sh WORK fexaot.dylib …  # Xcode projekt (argumenty v checks.yml)
```

Přesné argumenty a proměnné prostředí jsou v hlavičce každého skriptu a v odpovídajícím kroku `checks.yml`. Po `build-d3d9.sh` je potřeba znovu spustit celé `wine-i386/build.sh` (D3D9 build přepisuje `i386-windows`).

### Obraz hry na Macu

Dnes to dělá WinPad Translator ([Překlad her](../uzivatel/preklad-her.md)). Starší skript `tests/wine-app/game-aot.sh` zůstává pro ladění:

```sh
sh tests/wine-app/game-aot.sh WORK ~/Games/NFSU2/SPEED2.EXE \
    FEXOfflineCompiler.exe ~/Developer/nfsu2-fexcache WinPadWine-xcode [MAPY_Z_IPADU]
```

Proměnné: `RUNS` (běhy s JITem, `0` = jen z map), `REBUILD_CACHES=1` (po změně generování kódu FEXu), `GAME_AOT_CACHES_PER_RUN` (výchozí 8; při zaseknutí 1), `GAME_AOT_COMPILE_SECONDS` (velké moduly potřebují až 1800), `GAME_AOT_IMAGE=folder` (obraz podle složky hry), `WINPAD_AOT_TRACE=1` (stopa po blocích).

### Simulátor vs. iPad

Simulátor je rychlý na ověření Wine a AOT, ale ne všechno se v něm projeví:

- Nemá Metal 3, takže D3D9/DXMT nekreslí (hra skončí na `0x80000101` při CPU dekódování DXTn).
- Nepadá na nezarovnaných atomických přístupech.
- Má jinou mapu adres (CI ji napodobuje přes `WINEHOST_VA_HOLES` a `MADEIRA_WOW_MAP_END`).
- Na macOS 27 potřebuje `MADEIRA_WOW_MIN_FREE_GB=2`.

Rozhodující test je vždy na skutečném iPadu.

## Úpravy FEX patchů

Patch se upravuje ve zdrojácích FEXu (pracovní strom s aplikovanými patchi) a pak se z něj patch vygeneruje znovu. Patche na sobě stavějí v pořadí čísel. Nové číslo vždy navazuje na nejvyšší v řetězu; když dvě souběžné větve použijí stejné číslo, při slévání se jedno přečísluje.
