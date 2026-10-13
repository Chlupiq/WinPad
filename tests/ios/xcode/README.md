# WinPad Probe: Xcode projekt

Testovací aplikace pro iPad. Spustí malý x86-64 program přes FEXCore jen
z předpřeloženého obrazu (`Frameworks/probe-aot.dylib`), bez JITu.
FEXCore a sonda jsou už přeložené v `lib/`. Xcode překládá jen `main.mm`.

1. Otevři `WinPadProbe.xcodeproj`.
2. Target WinPadProbe → Signing & Capabilities → Team: vyber svůj účet.
   Když Xcode hlásí, že bundle ID je obsazené, změň ho (např. přidej `.test`).
3. Připoj iPad, vyber ho nahoře jako cíl a dej Run (⌘R).
   Na iPadu musí být zapnutý Developer Mode (Nastavení → Soukromí a zabezpečení).
4. Aplikace ukáže OK nebo FAILED a log. Ten samý log vypíše i do konzole Xcode.

Pod Xcode běží aplikace s debuggerem. Sonda paměť jako spustitelnou nikdy
nepoužívá, ale pro jistotu ji pak spusť ještě jednou přímo z plochy iPadu.
Log z posledního běhu je v aplikaci Soubory → Na mém iPadu → WinPad Probe.

Projekt vzniká v CI (`tests/ios/build-xcode.sh` v repu Chlupiq/WinPad).
Nic v něm neupravuj ručně, při další verzi se přegeneruje.
