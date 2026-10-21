# WinPad Wine: Xcode projekt

Testovací aplikace pro iPad. Spustí ve Wine malý 32bitový x86 program pro
Windows (`hello.exe`) přes WoW64 a FEX, bez JITu: x86 kód běží jen
z předpřeloženého obrazu (`fexaot.dylib`) a každý modul Wine ze svého dylibu.
Wine, jeho moduly i obraz jsou už přeložené, zvlášť pro iPad (`iphoneos`)
a pro simulátor (`iphonesimulator`). Xcode překládá jen `main.m`.

Blok x86 kódu, který v obrazu chybí, spustí interpret FEXu (nic nemapuje
jako spustitelné) a zapíše ho do kódové mapy v `fexcache/codemap/new`
v Dokumentech aplikace, takže ho další obraz může mít.

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
dokud ji neukončíš. `dinput8.dll` ze složky hry (ASI Loader) má přednost
před Wine (`WINEDLLOVERRIDES=dinput8=n,b`).

Projekt vzniká v CI (`tests/wine-app/build-xcode.sh` v repu Chlupiq/WinPad).
Nic v něm neupravuj ručně, při další verzi se přegeneruje.
