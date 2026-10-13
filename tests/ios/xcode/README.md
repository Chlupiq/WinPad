# WinPad Probe: Xcode projekt

Testovací aplikace pro iPad. Spustí malý x86-64 program přes FEXCore jen
z předpřeloženého obrazu (`probe-aot.dylib`), bez JITu. FEXCore a sonda jsou
už přeložené v `lib/`, zvlášť pro iPad (`iphoneos`) a pro simulátor
(`iphonesimulator`). Xcode překládá jen `main.mm`.

## Na simulátoru (Mac s Apple Silicon)

1. Otevři `WinPadProbe.xcodeproj`.
2. Nahoře vyber jako cíl simulátor iPadu (iOS 17.4 nebo novější).
3. Dej Run (⌘R). Podpis není potřeba.

Simulátor běží jako proces na Macu, ne pod pravidly iPadu. Ukáže, že aplikace
funguje, ale skutečný test „bez JITu“ je jen na iPadu.

## Na iPadu

1. Target WinPadProbe → Signing & Capabilities → Team: vyber svůj účet.
   Když Xcode hlásí, že bundle ID je obsazené, změň ho (např. přidej `.test`).
2. Připoj iPad, vyber ho nahoře jako cíl a dej Run (⌘R).
   Na iPadu musí být zapnutý Režim vývojáře (Nastavení → Soukromí a zabezpečení).

Aplikace ukáže OK nebo FAILED a log. Ten samý log vypíše i do konzole Xcode.
Pod Xcode běží s debuggerem; sonda paměť jako spustitelnou nikdy nepoužívá,
ale pro jistotu ji pak spusť ještě jednou přímo z plochy iPadu.
Log z posledního běhu je v aplikaci Soubory → Na mém iPadu → WinPad Probe.

Projekt vzniká v CI (`tests/ios/build-xcode.sh` v repu Chlupiq/WinPad).
Nic v něm neupravuj ručně, při další verzi se přegeneruje.
