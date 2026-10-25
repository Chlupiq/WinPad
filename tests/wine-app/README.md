# WinPad Wine: Xcode projekt

Testovací aplikace pro iPad. Spustí ve Wine malý 32bitový x86 program pro
Windows (`hello.exe`) přes WoW64 a FEX, bez JITu: x86 kód běží jen
z předpřeloženého obrazu (`fexaot.dylib`) a každý modul Wine ze svého dylibu.
Wine, jeho moduly i obraz jsou už přeložené, zvlášť pro iPad (`iphoneos`)
a pro simulátor (`iphonesimulator`). Xcode překládá jen `main.m` a `Library.m`.

Blok x86 kódu, který v obrazu chybí, spustí interpret FEXu (nic nemapuje
jako spustitelné) a zapíše ho do kódové mapy v `fexcache/codemap/new`
v Dokumentech aplikace, takže ho další obraz může mít.

## Herní knihovna

Aplikace se otevře na knihovně her, podobné úvodní obrazovce herní konzole.
Ukáže každou hru, kterou jsi do aplikace nakopíroval (Finder → iPad →
Soubory → WinPad Wine), každou ve vlastní složce. Hru vybereš herním
ovladačem (křížový ovladač nebo levá páčka, A spustí, Y otevře nastavení,
B ho zavře), šipkami a Enterem na klávesnici, nebo ťuknutím (druhé ťuknutí
spustí). Ve složce hry může být:

- `winpad.json` s názvem hry a jejím programem, např.
  `{"title": "Need for Speed Underground 2", "exe": "SPEED2.EXE"}`. Bez něj
  je názvem jméno složky a programem největší `.exe`, který není instalátor
  ani pomocný program.
- `cover.png` nebo `cover.jpg`, obal hry.

Přeložený obraz hry je v projektu `Frameworks/<sdk>/fexaot-SLOŽKA.dylib`
(jméno složky malými písmeny, ostatní znaky jako `-`), jinak
`fexaot-game.dylib` z `game-aot.sh`. Knihovna u hry ukáže, jestli ho má.
Wine jde v aplikaci spustit jen jednou, takže po skončení hry aplikaci
spusť znovu. V nastavení knihovny je dotykové ovládání, poslední log
a testovací programy (`hello.exe`, `window.exe`). Nastavení → WinPad Wine →
Program nebo schémata v Xcode knihovnu přeskočí.

## Na simulátoru (Mac s Apple Silicon)

1. Otevři `WinPadWine.xcodeproj`.
2. Nahoře vyber jako cíl simulátor iPadu (iOS 17.4 nebo novější).
3. Dej Run (⌘R). Podpis není potřeba.

## Na iPadu

1. Target WinPadWine → Signing & Capabilities → Team: vyber svůj účet.
   Když Xcode hlásí, že bundle ID je obsazené, změň ho (např. přidej `.test`).
2. Připoj iPad, vyber ho nahoře jako cíl a dej Run (⌘R).
   Na iPadu musí být zapnutý Režim vývojáře (Nastavení → Soukromí a zabezpečení).

Aplikace průběžně ukazuje log a na konci OK nebo FAILED. Ten samý log vypíše
i do konzole Xcode. Pod Xcode běží s debuggerem; aplikace paměť jako
spustitelnou nikdy nepoužívá, ale pro jistotu ji pak spusť ještě jednou
přímo z plochy iPadu. Log z posledního běhu je v aplikaci Soubory →
Na mém iPadu → WinPad Wine (`wine.log`). Když běh aplikaci shodí, ukáže
log toho běhu při dalším spuštění.

## Jako IPA (AltStore, SideStore, Sideloadly)

Bez Xcode jde aplikace nainstalovat z IPA, které si podepíše instalátor tvým
Apple ID. CI dává IPA s testovacími programy jako artefakt `WinPadWine-ipa`.
IPA s hrou si uděláš na Macu, až `game-aot.sh` dá do projektu obraz hry:

    sh WinPadWine-xcode/make-ipa.sh WinPadWine-xcode ~/Desktop/WinPadWine.ipa

Skript projekt postaví pro iPad bez podpisu a zabalí ho. IPA s obrazem hry
nikam nenahrávej, je v něm přeložený kód hry.

S bezplatným Apple ID vyprší podpis po 7 dnech; AltStore a SideStore ho umí
obnovit samy. Aplikace má kromě hlavního programu desítky volných knihoven
(`Frameworks/`, `aarch64-windows/`) a instalátor musí podepsat i ty. Jestli
to každý z nich udělá, ještě není ověřené na iPadu: když aplikace po instalaci
spadne hned při startu, je to nejspíš tohle.

## Program s oknem (`window.exe`)

Aplikace umí spustit místo `hello.exe` i 32bitový x86 program s oknem
(`window.exe`): okno nakreslené přes GDI se ukáže nahoře v aplikaci, log
pod ním. Taky bez JITu, ze svého AOT obrazu (`fexaot-window.dylib`).
Za 2 s po ukázání okna do něj aplikace sama ťukne (jako v CI), okno změní
barvu a program skončí; poslední snímek okna zůstane na obrazovce a je
i v Soubory → WinPad Wine → `frames`.

Jak ho vybrat, bez nového překladu:

- Na iPadu: Nastavení → WinPad Wine → Program → `window.exe`, pak aplikaci
  spusť znovu (z plochy nebo z Xcode). Zpátky: `hello.exe`.
- Nebo v Xcode schéma `WinPadWine Window` (nahoře vedle cíle) a Run (⌘R).


## Direct3D 9 kostka (schéma „WinPadWine D3D9“)

Když CI přeložilo i DXMT, má projekt i schéma `WinPadWine D3D9`.
Vyber ho nahoře vedle cíle a dej Run (⌘R). Aplikace pak místo `hello.exe`
spustí 32bitový Direct3D 9 program (`d3d9-cube.exe`, kostka z Madeiry):
přes DXMT a Metal kreslí do okna v aplikaci, 8 sekund, a na konci ukáže OK,
když všechny snímky předal Metalu. Běží s JITem FEXu, ne z AOT obrazu,
takže potřebuje připojený debugger: spouštěj ho z Xcode, ne z plochy.
Na simulátoru kostka nedoběhne: jeho Metal nemá argument buffery tier 2
(Metal 3), na kterých DXMT kreslí.

## Hra (schéma „WinPadWine Game“)

S DXMT má projekt i schéma `WinPadWine Game` pro hru, kterou si do
aplikace nakopíruješ sám (herní soubory nikdy nejdou do repa ani do CI):

1. iPad připoj k Macu, ve Finderu ho vyber → Soubory → přetáhni složku
   hry (např. `NFSU2`) na „WinPad Wine“. Je pak v Soubory → WinPad Wine.
2. V Xcode vyber schéma `WinPadWine Game` a dej Run (⌘R).

Aplikace spustí `NFSU2/SPEED2.EXE` z Dokumentů aplikace, s pracovní
složkou ve složce hry. Jinou hru vybereš v Nastavení → WinPad Wine → Game
(cesta v Dokumentech, např. `NFSU2/SPEED2.EXE`). Hra běží s JITem FEXu
jako kostka, takže jen z Xcode s debuggerem; okno hry se ukáže v aplikaci,
dokud ji neukončíš. Ovládá se hardwarovou klávesnicí (Magic Keyboard, Bluetooth
nebo USB): šipky, Enter, Esc a další klávesy jdou přímo do hry. Funguje i herní
ovladač (Bluetooth/MFi: Xbox, PlayStation, …) a aplikace na obrazovku nakreslí
dotykový ovladač s rozložením Xboxu: dvě páčky, šipkový kříž, A B X Y, LB/RB,
LT/RT, View a Menu (Nastavení → WinPad Wine → Touch controls). Tlačítka se mění
na klávesy (`WinPadPadKeys` v `Library.m`): levá páčka a křížový ovladač jsou
šipky, RT plyn (šipka nahoru), LT brzda (šipka dolů), A Enter, B Esc, X mezerník
(ruční brzda), Y `C` (kamera), LB/RB `Z`/`A` (řazení), Menu Esc, View Enter;
pravá páčka nemá výchozí klávesu. Každé tlačítko přeřadíš v nastavení knihovny (Y) →
Mapování tlačítek.
`dinput8.dll` ze složky hry (ASI Loader) má přednost
před Wine (`WINEDLLOVERRIDES=dinput8=n,b`).

### Hra bez JITu (AOT obraz z Macu)

iPad s TXM (iPadOS 26 a novější) JIT kód nespustí ani pod debuggerem Xcode
(chyba podpisu kódu, `kr=50`). Hra proto běží bez JITu z obrazu
`Frameworks/fexaot-game.dylib`, pokud ho projekt má. Ten se staví jen na
Macu se hrou, nikdy v CI (je to přeložený kód hry):

    sh tests/wine-app/game-aot.sh WORK_DIR ~/Games/NFSU2/SPEED2.EXE \
        FEXOfflineCompiler.exe ~/Developer/nfsu2-fexcache WinPadWine-xcode

Hra třikrát proběhne v simulátoru s JITem a zapíše mapu kódu, offline
kompilátor FEXu z ní udělá cache a ty se slinkují do `fexaot-game.dylib`
pro simulátor i iPad. Pak stačí v Xcode dát Run; hra na iPadu poběží i bez
debuggeru (spuštěná z plochy). Bloky, které v obrazu chybí, spustí
interpretr FEXu a zapíše je do Soubory → WinPad Wine → `fexcache/codemap/new`.
Tu složku zkopíruj na Mac a dej ji skriptu jako šestý argument: další obraz
je už bude mít.

Kompilátor dělá nejvýš 8 cache v jednom procesu (`GAME_AOT_CACHES_PER_RUN`)
a spouští se znovu, dokud nějaká chybí, protože 48 modulů hry by se do JIT
poolu jednoho procesu nevešlo. `RUNS=0` hru s JITem nespouští a obraz postaví
z map a cache, které už v adresáři jsou. `REBUILD_CACHES=1` vygeneruje všechny
cache znovu, což je potřeba po změně v generování kódu FEXu.

Víc her v jedné aplikaci: s `GAME_AOT_IMAGE=folder` se obraz jmenuje podle
složky hry (`NFSU2` → `fexaot-nfsu2.dylib`) a knihovna ho najde u té hry.
Bez toho je to `fexaot-game.dylib`, který knihovna použije pro hru bez
vlastního obrazu.

Projekt vzniká v CI (`tests/wine-app/build-xcode.sh` v repu Chlupiq/WinPad).
Nic v něm neupravuj ručně, při další verzi se přegeneruje.

## Víc kódu hry najednou

Bez JITu běží rychle jen kód, který je v překladu (`fexaot-game.dylib`). Kód, ke kterému se hra dostane poprvé, iPad interpretuje (pomalu) a zapíše do `Documents/fexcache/codemap/new`; další kolo překladu na Macu ho přidá. Dvě cesty, jak získat víc kódu v jednom kole (potřebují `python3 -m pip install capstone pefile`):

- **Statické hledání v EXE:** `python3 tests/fex-wow64/discover.py ~/Games/NFSU2/SPEED2.EXE MAPA static.bin --check` projde kód hry od vstupního bodu, exportů, nahraných bloků a tabulek adres v datech a zapíše začátky bloků jako code mapu. `MAPA` je kterákoli nahraná mapa (nebo složka map), která hru jmenuje; z ní se vezme záznam souboru. `--check` vypíše, kolik nahraných bloků by hledání našlo samo.
- **Záznam z Windows PC:** hra na PC pod DynamoRIO (`C:\DynamoRIO\bin32\drrun.exe -t drcov -- SPEED2.EXE`) zapíše každý spuštěný blok do `drcov.SPEED2.EXE.*.log`. `python3 tests/fex-wow64/drcov2codemap.py ~/Games/NFSU2/SPEED2.EXE MAPA pc.bin drcov....log [další logy]` z nich udělá jednu code mapu. Zapíše jen bloky, kterými FEX vstupuje (cíle volání, návratové adresy, nepřímé cíle); se všemi bloky (`--all-blocks`) by překlad přetekl 128 MB kódový buffer offline kompilátoru. Pokryje jen kód samotné hry, ne Wine a DXMT.

Výslednou mapu dej (po `codemap.py halfbarrier`) do `codemap/new` jako mapy z iPadu a spusť `game-aot.sh` jako obvykle. Mapy, záznamy i obraz hry zůstávají jen na Macu.
