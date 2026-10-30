# AOT obraz a interpret

Jak se x86 kód hry dostane do podepsaného obrazu a co se stane s kódem, který v něm chybí. Návrh je v [M2-aot-design.md](../M2-aot-design.md), interpret podrobně v [M4-interpreter.md](../M4-interpreter.md). Tahle stránka popisuje celý řetěz tak, jak dnes funguje.

## Pojmy

| Pojem | Co to je |
|---|---|
| **Code mapa** | Binární seznam bloků (obraz + RVA), které FEX spustil. Zapisuje se při ukončení procesu (`FEX_ENABLECODECACHINGWIP=1`, patche `0002`, `0003`, `0016`). Čte ji `tests/fex-wow64/codemap.py`. |
| **Id souboru** | `XXH3_64(jméno malými písmeny) ^ (SizeOfImage << 32 | TimeDateStamp)`. Cache platí jen pro přesně ten soubor, ze kterého vznikla. |
| **Code cache (`.fxcc`)** | Výstup offline kompilátoru FEXu pro jeden modul: kód, datová oblast, relokace. |
| **AOT obraz** | `fexaot-<hra>.dylib`: všechny cache převedené `cache2macho` na Mach-O objekty, index (`aotindex.py`) a dispatcher, slinkované do jedné knihovny pro `iphoneos` (a `iphonesimulator`). |
| **NoJIT** | Režim FEXu, ve kterém se nikdy nic nepřekládá ani nemapuje jako spustitelné. |
| **Interpret** | Spouští IR FEXu pro bloky, které v obrazu chybí. |
| **Kolo** | Běh NoJIT → nové code mapy → nový obraz. |

## 1. Záznam: code mapy

Kód hry lze získat třemi způsoby a všechny končí jako code mapa:

1. **Běh s JITem** v simulátoru na Macu (`game-aot.sh`, `RUNS=3`; mapa není deterministická, proto sjednocení 3 běhů). Tak začínalo NFSU2.
2. **Běh NoJIT na iPadu**: interpret zapíše každý blok, který spustil, do `Documents/fexcache/codemap/new`. Tohle je hlavní cesta pro uživatele.
3. **Bez spuštění pod FEXem**:
   - `tests/fex-wow64/discover.py`: statické procházení `.exe` (capstone + pefile) od vstupního bodu, exportů, tabulek adres a známých bloků.
   - `tests/fex-wow64/drcov2codemap.py`: záznam DynamoRIO (`drrun -t drcov`) z běhu na Windows PC. Zapíše jen bloky, kterými FEX vstupuje (cíle volání, návratové adresy, nepřímé cíle); se všemi bloky by cache přetekla 128 MB kódový buffer kompilátoru (`0032` takovou cache odmítne).

Mapy z iPadu obsahují cesty z kontejneru aplikace (`.../Documents/NFSU2/SPEED2.EXE`). `codemap.py rehome` je přejmenuje na soubory na počítači; i386 DLL Wine se berou z IPA, ze které iPad běžel.

## 2. Offline kompilace

`FEXOfflineCompiler.exe` je aarch64 Windows program sestavený ze stejného stromu FEXu jako `xtajit.dll` (`tests/fex-wow64/build.sh`). Cache sedí jen k buildu FEXu, který ji vyrobil.

- `process-all` načte mapy, každý i386 obraz namapuje ručně do okna hosta (`0005`) a přeloží bloky s volbou AOT (`ENABLECODECACHINGWIP`, `AOTCODECACHEWIP`).
- Kód v AOT režimu nemá v instrukcích žádné adresy hosta. Adresy hosta jsou v datových slotech (`adrp`+`ldr`, `0007`), bloky se propojují jen přes data (`0008`), konce bloků jsou v datech (`0009`). Kód je tedy konečný, jak je uložený.
- Systémová volání se překládají pro generické ABI jako ve WoW64 modulu (`0015`), báze okna hosta se čte z vlákna (`0014`).
- Najednou se dělá nejvýš N cache v jednom procesu (`--max-caches`, `0028`, `process-all-batches.sh`), protože 48 modulů hry se do jednoho procesu nevejde.
- Kompilátor publikuje každý přeložený blok (`0020`), jinak by se kvůli heuristice zámku některé bloky neuložily.
- **Funkce CPU**: kód FEXu závisí na funkcích procesoru (FEAT_AFP, FlagM, LRCPC…). Aplikace zapisuje funkce iPadu do `codemap/new/hostprobe.txt` a kompiluje se pro ně (`WINEHOST_HOSTPROBE`), ne pro počítač, na kterém kompilátor běží.
- **Kde běží**: simulátor iPadu na Macu (Wine z `tests/wine-loader`), Windows on ARM nativně, arm64 Linux s Wine 10, nebo Docker (arm64 kontejner s Debian Wine 10, na x86-64 pod QEMU jako Neoverse N1). Bez winehostu není JIT pool, proto `0037` (kompilátor kód nikdy nespouští). Všechny backendy dávají bajt po bajtu stejné cache (CI job `translator-compile`).

## 3. Linkování obrazu

`tests/fex-wow64/build-aot-image.sh` (a `link.py` v překladači):

1. `tools/cache2macho/cache2macho.py`: každá cache → objekt (kód v `__TEXT`, datová oblast v `__DATA`, odkazy mezi nimi jako relokace linkeru).
2. `tools/cache2macho/aotindex.py`: index, podle kterého WoW64 modul FEXu cache najde (`0010`).
3. Dispatcher vypsaný jedním během (`dispatcher.bin`, `0011`). Je stejný pro každý proces daného buildu, takže jeden z CI stačí pro každou hru.
4. Link Xcodem, nebo bez Xcode: `clang`/`llvm-mc` + `ld64.lld` se stubem libSystem.

Obraz pro iPad podepisuje Xcode nebo instalátor IPA spolu s aplikací. Mac může obraz podepsat i zvlášť do složky hry (`fexaot.dylib` + `fexaot.build`); aplikace ho vezme jen pro stejný build (`winpad-build.txt`) a při odmítnutí podpisu se vrátí k obrazu z balíčku.

## 4. Běh NoJIT

- `xtajit.dll` je převzatý z dylibu (`#52`), obraz se načte `dlopen` a cache se registrují na místě (`0010`), bez JIT poolu (`0017`).
- Systémová volání 32bitové strany jdou přes BOP instrukce v exportované funkci i386 ntdll (`patches/wine/0003`, `0013`), ne přes vlastní stránku kódu.
- Po změně DEP (hra bez NX_COMPAT) FEX zahodí přeložené bloky; `0027` znovu zaregistruje bloky z cache.
- Po `VirtualProtect` na kódu (instalátory hooků, ASI loader) `0029` porovná hash 64bajtových kusů kódu a vrátí bloky, jejichž bajty se nezměnily.
- **Nezarovnané atomické přístupy**: FEX překládá x86 přístupy jako `LDAPR`/`STLR`, které na iPadu spadnou při překročení 16 bajtů. JIT místo přepíše, AOT kód ne. `0030` takové bloky zapíše do mapy se značkou `HalfBarrierTSOBlock` a kompilátor je přeloží s `LDUR+DMB`. Simulátor nepadá, proto překladač značí všechny nové bloky preventivně (`codemap.py halfbarrier`).
- **Kód z běhu** (`0036`): kód, který si program nahraje do haldy a přepne na spustitelný (zvukový systém EA v NFSU2), dostane id z bajtů a adresy (`rtcode-<adresa>-<id>.fexrc`), jeho bajty se uloží do `codemap/new/runtime/` a offline kompilátor ho přeloží na stejné adrese. Id zatím obsahuje adresu, a ta se u NFSU2 liší mezi během z Xcode a z plochy.

## 5. Interpret

Interpretuje se IR FEXu (dekodér a OpcodeDispatcher běží jako při JITu, vynechá se alokace registrů), přímo nad stavem vlákna. Sémantika operací kopíruje arm64 JIT.

- Umí běžné celočíselné operace, x87 (softfloat fallbacky), MMX a SSE do SSE4.1 (`0026`).
- IR každého bloku zůstává v cache (`0034`), pole hodnot se recyklují (`0035`), rpmalloc nechává volné stránky commitnuté (`0033`). Před tím menu NFSU2 běželo 11 FPS kvůli ~40 000 commitům za sekundu, po tom 60 FPS.
- Každý interpretovaný blok se zaloguje (`[interp] learned block X: důvod`, `0031`) a zapíše do code mapy.
- Neumí: AES, SHA, CRC32, PCLMUL, SSE4.2 řetězce, AVX, RDRAND, single-step. Seznam pro konkrétní program dá `FEX_INTERP_SURVEY=1`.

## 6. Kola a konvergence

CI ověřuje celý cyklus na testovacích programech: `tests/wine-loader/converge-nojit.sh` spouští program NoJIT, přidá mapy interpretu do cache, přeloží, slinkuje a spustí znovu, dokud interpret nemá co dělat (nejvýš 4 kola). Pro uživatele je totéž WinPad Translator: každé kolo hraní na iPadu přidá mapy, překladač přeloží jen moduly s novými bloky.

## Užitečné logy

| Řádek ve `wine.log` | Význam |
|---|---|
| `[aot-image] index at …: N caches` | Obraz se načetl a kolik modulů má |
| `[aot-image] loaded linked cache for X: code N bytes …` | Velikost kódu modulu v obrazu (podle toho poznáš, který obraz na iPadu opravdu je) |
| `[aot-image] no linked cache for X` | Modul v obrazu chybí, celý poběží v interpretu |
| `[interp] learned block X: …` | Blok mimo obraz, s důvodem |
| `[interp] fallback ran N blocks (M distinct)…` | Souhrn interpretu při ukončení procesu |
| `[code-inval] …` | FEX zahodil bloky (DEP, VirtualProtect, zápis do kódu) |
| `[aot-cache] … registered again …` | Bloky z cache vrácené po změně DEP nebo ochrany stránek |
| `[aot-unaligned]` | Blok s nezarovnaným atomickým přístupem zapsaný pro half barrier |
| `[rt-code] … code cache from the AOT image` | Kód z běhu nalezený v obrazu |
| `[clock] N s, F frames` | Čas od startu a počet snímků (každou sekundu) |
