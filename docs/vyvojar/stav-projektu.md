# Stav projektu

Stav k 30. 10. 2026.

## Milníky

| Datum | Co se povedlo |
|---|---|
| 2026-10-11 | Plán (M0), audit relokací a analýza FEX cache (M1) |
| 2026-10-13 | **M2**: x86 testovací program běží na skutečném iPadu čistě z AOT obrazu, bez JITu i bez debuggeru |
| 2026-10-14 | **M3**: Wine na simulátoru iPadu: clock.exe přes GDI, písma, klávesnice a dotyk (notepad), Minesweeper, podprocesy |
| 2026-10-14 | 32bitový `hello.exe` ve Wine přes WoW64 a FEX |
| 2026-10-15 – 19 | Code mapy, offline cache, AOT obraz s dispatcherem, `xtajit.dll` z dylibu, NoJIT bez JIT poolu |
| 2026-10-20 | Volba první hry: **Need for Speed Underground 2** (32bit, Direct3D 9); okenní program NoJIT, IR interpret |
| 2026-10-21 | `hello.exe` a `window.exe` na skutečném iPadu bez JITu; D3D9 přes DXMT; hra v simulátoru načítá data |
| 2026-10-22 | Hra NoJIT na iPadu z obrazu postaveného na Macu; opravy DEP, hooků, nezarovnaných přístupů |
| 2026-10-23 | Herní ovladač, knihovna her, IPA. Obraz ze záznamu DynamoRIO z PC: **NFSU2 na iPadu bez JITu, okno za 1,1 s, ~120 FPS v intru** |
| 2026-10-25 | Intro a menu viditelné hned po startu, obraz přes celou obrazovku, dotykový ovladač Xbox, uložené hry zůstávají |
| 2026-10-28 | Interpret zrychlený: **menu 60 FPS** (dřív 11), závod ~44 FPS; zvuk; kód z běhu (zvukový systém EA) v obrazu |
| 2026-10-29 | Se zvukem ~50 FPS ze Xcode; z plochy pomaleji, viz otevřené problémy |
| 2026-10-30 | **WinPad Translator** pro libovolnou hru na Macu i PC (cache shodné na všech platformách), Word návod, víc her v jedné aplikaci, knihovna ve stylu konzole |

## Řetěz pull requestů

Na `main` není nic sloučeno. Každý PR stojí na předchozím, takže se dají číst jako kapitoly. Vrchol řetězu (#98) obsahuje všechno níže, s výjimkou několika slepých větví.

| PR | Téma |
|---|---|
| #1–#2 | Plán, analýza (M0, M1) |
| #3–#11 | FEX AOT na Linuxu: syscall stuby, cache, datové sloty, propojení přes data, kód jen pro čtení, `cache2macho`, statický dispatcher |
| #12–#21 | FEXCore pro iOS, NoJIT, probe na macOS a iPadu (IPA, Xcode), plán Mac aplikace (#18), testy SSE/x87/výjimek/vláken |
| #22–#39 | M3: `pe2macho`, Wine moduly jako dyliby, x18, převzetí obrazu, ntdll/wineserver/win32u pro iOS, Wine host, GDI, písma, vstup, Minesweeper, rychlejší CI |
| #40–#55 | x86: i386 moduly Wine, FEX pro WoW64 ze zdrojáků, code mapa, offline cache, AOT obraz, dispatcher, NoJIT, aplikace WinPadWine pro iPad |
| #56–#66 | Okenní program, D3D9 (#57), interpret (#59), importy hry, DirectSound, naučené bloky zpět do obrazu, aplikace s interpretem a oknem |
| #67–#77 | Zásobník a guard stránky, složka programu, hra v aplikaci, hra NoJIT z obrazu z Macu, SIMD v interpretu, DEP, dávky kompilátoru, hooky, obraz hry na obrazovce, half barrier |
| #78–#84 | Herní ovladač, knihovna her, přemapování tlačítek, IPA, jméno obrazu podle hry, x87 v interpretu, statické hledání kódu a DynamoRIO |
| #85–#96 | Zvukové zařízení a hodiny v logu, Metal vrstva na hlavním vlákně, celá obrazovka, popředí okna, dotykový ovladač, trvalý prefix, FPS, rychlejší interpret, zvuková relace, kód z běhu |
| #97 | WinPad Translator (Mac, Windows, Linux) |
| #98 | Víc her v jedné aplikaci, knihovna ve stylu konzole, iPhone |

Slepé nebo nahrazené větve: #41 (podprocesy Wine, mimo hlavní řetěz), #66 a #68 (rpmalloc a IR cache interpretu, nahrazené `0033`/`0034` v #94), #42 (draft, převzatý do #43).

## NFSU2 v číslech

| Měření | Hodnota |
|---|---|
| Obraz hry (kolo 8) | 59 cache, ~38 MB pro iPad, SPEED2 ~41 000 bloků |
| Start do prvního snímku | ~1 s |
| Menu, 1024×768 | 60 FPS |
| Závod bez zvuku | ~44 FPS průměr |
| Závod se zvukem | ~50 FPS ze Xcode, 10–20 FPS z plochy (viz níže) |
| Bloky v interpretu po konvergenci | jednotky až desítky |

Měřeno na iPadu Air 13" M2, iPadOS 27.0.1.

## Otevřené problémy a další kroky

1. **Kód z běhu závisí na adrese.** Id kódu, který si hra nahraje za běhu (`0036`), obsahuje adresu. Zvukové moduly NFSU2 leží při spuštění z plochy jinde než pod Xcode, takže se obraz netrefí. Řešení: id nezávislé na adrese (bajty jsou relokované, je potřeba je „odrelokovat“).
2. **Ověření na iPadu**: knihovna ve stylu konzole (#98), obraz podepsaný do složky hry, instalace IPA přes AltStore/SideStore (podpis volných knihoven).
3. **Další hra.** Překladač je obecný, ale celý cyklus zatím prošlo jen NFSU2.
4. **Nativní D3D9** (ARM64 DXMT místo x86 frontendu přes FEX) by ušetřil překlad; zatím padá po prvním snímku.
5. **Interpret**: chybějící operace (AES, SHA, CRC32, SSE4.2, AVX), výpadky paměti uvnitř interpretu, single-step. Viz [M4-interpreter.md](../M4-interpreter.md).
6. **64bitové hry** (x86-64 přes ARM64EC) zatím nejsou.
7. **Mac aplikace** podle plánu M6 (#18): přetáhnout instalátor hry a dostat hotovou aplikaci. Překladač je její základ.
8. **Sloučení řetězu PR** do `main`.
