# Architektura

WinPad je fork [Madeiry](https://github.com/willfaust/Madeira) (Wine ARM64EC + FEX + DXMT na iOS). Madeira spouští všechno, co se vykonává, z jednoho dvojitě mapovaného JIT poolu, a proto potřebuje JIT od připojeného debuggeru. WinPad každou část, která se spouští, nahradí podepsaným kódem připraveným předem. Odvození je popsané v [PLAN.md](../../PLAN.md) a [M1-findings.md](../M1-findings.md).

Verze, na kterých stavíme: Madeira `48f9764`, její Wine `257f271`, její FEX fork `3bec2ac` (FEX-2607). Patche pro upstream FEX `14c9268` v `patches/fex/` jsou z etapy M2 (Linux a minimální iOS frontend).

## Vrstvy v jednom procesu

```
┌──────────────────────────── WinPadWine.app (jeden iOS proces) ───────────────────────────┐
│ main.m + Library.m      UIKit: knihovna her, nastavení, ovladače, obraz hry, FPS, log     │
│        │ winehost_main(), winehost_post_key(), winehost_metal_frames()                    │
│ winehost.c              Wine host: wineserver ve vlákně + jeden Wine proces v témže       │
│        │                procesu; okna → snímky / CAMetalLayer (metal-display.m)           │
│ Wine unix strana        libntdll_unix.a, libwin32u_unix.a, libwineserver.a (statické)     │
│ ─────────────── PE svět ───────────────────────────────────────────────────────────────── │
│ aarch64-windows/*.dll   ARM64 moduly Wine (ntdll, wow64, user32…) → každý jako NAME.dylib │
│                         zabalený pe2macho, převzatý loaderem (patches/madeira/0001)       │
│ xtajit.dll (.dylib)     FEX pro WoW64: překladač x86 → ARM64                              │
│   ├─ fexaot-<hra>.dylib AOT obraz: předpřeložené bloky + index + statický dispatcher      │
│   └─ IR interpret       bloky, které v obrazu chybí (nic nemapuje jako spustitelné)       │
│ i386-windows/*.dll      32bitové x86 moduly Wine a hra: pro FEX jen data (guest kód)       │
│ d3d9.dll → d3d9-emulated.dll (x86, DXMT) → winemetal → libdxmt_combined.a → Metal         │
└───────────────────────────────────────────────────────────────────────────────────────────┘
```

### Aplikace (`tests/wine-app`)

- `main.m` připraví prostředí (Wine prefix v `Documents/prefix`, který zůstává mezi spuštěními; `system.reg` z balíčku kvůli zvukovému zařízení), přesměruje stdout do `Documents/wine.log`, nastaví proměnné (`WINEPREFIX`, `WINEDLLOVERRIDES`, FEX přepínače) a zavolá `winehost_main`. Obraz hry ukazuje přes Metal vrstvu DXMT, dokud ji hra nemá, pak GDI snímky prvního okna. Klávesnici, herní ovladač a dotykový ovladač převádí na virtuální klávesy (`winehost_post_key`).
- `Library.m` je knihovna her: hledá složky v Documents, čte `winpad.json` a obal, vybírá obraz hry, kreslí konzolový vzhled a nastavení.
- Wine jde v jednom procesu spustit jen jednou, proto hra startuje místo knihovny a další hra potřebuje nové spuštění aplikace.

### Wine host (`tests/wine-loader/host/winehost.c`)

Příkazový host, který stejně běží v CI na simulátoru (`run-host.sh`) i v aplikaci. Spouští wineserver jako vlákno a v témže procesu jeden Wine proces. Okna Wine bez skutečného display driveru (null driver) kreslí do bitmap, které host posílá aplikaci (`winehost_frame_hook`) nebo ukládá jako PNG. Drží hlavní okno programu v popředí (NFSU2 jinak při neaktivním okně stojí). Nastaví programu pracovní složku podle složky `.exe`. Co by jinak dodala Madeira kolem Wine (Swift mosty, gamepad), je nahrazeno stuby (`link-host.sh`).

### Wine moduly bez JIT poolu

- `tools/pe2macho` zabalí každý ARM64 PE modul do Mach-O dylibu se stejným rozložením (RVA), převede base relokace na Mach-O relokace a přepíše čtení registru x18 (TEB) na trampolíny. Syscall stuby ntdll/win32u přepíše na `adrp`/`ldr` (`patches/wine/0001`), aby kód neměl relokace.
- `patches/madeira/0001-adopt-pe-dylib.patch`: loader Wine nejdřív hledá `NAME.dylib`, načte ho `dlopen` a převezme obraz místo kopírování do JIT poolu.
- Podrobně v [M3-wine-modules.md](../M3-wine-modules.md).

### x86 přes WoW64 a FEX

32bitový proces běží jako WoW64: 64bitové ARM ntdll a `wow64.dll` hostí 32bitovou stranu, jejíž kód (i386 moduly Wine a hra) překládá FEX v `xtajit.dll`. iOS nemá nic mapovatelného pod 4 GiB, takže 32bitový adresní prostor hosta je okno o velikosti 4 GiB na bázi `B` (adresa hosta = `B + zext32(EA)`). Na skutečném iPadu končí mapa adres na `0x7180000000`, okno a halda FEXu se proto hledají jinak než v simulátoru (`patches/madeira/0003`, `patches/fex-wow64/0024`).

Bez JITu FEX nic nepřekládá za běhu (`NoJIT`, `patches/fex-wow64/0012`, `0017`):

1. Blok x86 kódu se hledá v AOT obrazu `fexaot-<hra>.dylib` (index podle id souboru a RVA). Bloky jsou propojené jen přes data, kód obrazu se nikdy nepřepisuje.
2. Když tam není, spustí ho IR interpret (`0019` a další) a zapíše do code mapy v `Documents/fexcache/codemap/new`.
3. Dispatcher FEXu je pro daný build ve všech procesech stejný, takže je také předpřeložený v obrazu (`0011`).

Celý řetěz od code mapy po obraz popisuje [AOT obraz a interpret](aot-a-interpret.md).

### Grafika

DXMT z Madeiry: 32bitová `d3d9.dll` je shim, který předává volání `d3d9-emulated.dll` (frontend DXMT, x86 kód běžící přes FEX). Ten přes `winemetal.dll` volá unixovou stranu DXMT (`libdxmt_combined.a`, nativní ARM64), která kreslí přes Metal do `CAMetalLayer` z `host/metal-display.m`. Vrstva se vytváří a umisťuje na hlavním vlákně, jinak ji iOS nezobrazí, dokud aplikace nepřejde do pozadí (`#86`). Simulátor nemá Metal 3 (argument buffery tier 2), takže D3D9 ověřuje až iPad. Nativní ARM64 D3D9 Madeiry je experimentální a zatím padá.

### Zvuk a vstup

- DirectSound → mmdevapi → zvukový driver Madeiry. Zvukové zařízení potřebuje `system.reg` v prefixu. Aplikace používá relaci `AVAudioSessionCategoryPlayback` (hraje i v tichém režimu).
- DirectInput hra dostává z klávesnice Wine. Herní ovladač (`GameController`) i dotykový ovladač (`WinPadTouchPad`) se převádí na klávesy podle mapování (`padKeys`).

## Tok dat mezi iPadem a počítačem

```
iPad: hra běží NoJIT ──▶ chybějící blok ──▶ interpret ──▶ Documents/fexcache/codemap/new/*.bin
                                                         (+ runtime/ bajty kódu z běhu, hostprobe.txt)
                                       │ kopie (Finder / Soubory)
počítač: WinPad Translator ──▶ přejmenování cest na soubory počítače (codemap.py rehome)
         ──▶ half-barrier značky ──▶ FEXOfflineCompiler.exe (pod Wine/simulátorem/Dockerem)
         ──▶ cache *.fxcc ──▶ cache2macho ──▶ link (Xcode nebo LLVM) ──▶ fexaot-<hra>.dylib
         ──▶ do IPA / Xcode projektu / podepsaný do složky hry
```

Herní soubory, code mapy, cache a obrazy her nikdy nejdou do repozitáře ani do CI. CI pracuje jen s testovacími programy z `tests/wine-i386`.

## Licence

WinPad je odvozené dílo Madeiry, tedy **GPL-3.0-or-later** s Madeira Converter Exception. FEX je MIT, Wine LGPL-2.1+, DXMT MIT. Projekt FEX nepřijímá příspěvky generované AI, proto naše FEX patche zůstávají v tomto repozitáři a upstream se neposílají.
