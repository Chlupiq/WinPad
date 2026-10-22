# M4: Interpret pro bloky mimo AOT obraz

Kódová mapa není deterministická: běh s `FEX_NOJIT=1` občas narazí na blok, který nahrávací běhy nezaznamenaly, a v AOT obrazu tedy chybí. FEX se dřív na takovém bloku zastavil. Teď ho spustí interpret (patch `patches/fex-wow64/0019-nojit-ir-interpreter.patch`) a nic nemapuje jako spustitelné.

## Jak to funguje

- Interpretuje se IR FEXu, ne x86. Dekodér a OpcodeDispatcher běží jako při JITu (vyrábějí jen data), vynechá se jen alokátor registrů (`PassManager::SkipRA`). V IR před alokací `LoadRegister`/`StoreRegister` pořád říkají, který registr hosta čtou a zapisují.
- `CompileBlock` IR zkopíruje z OpDispatcheru vlákna. Syscall v interpretovaném bloku může spustit vnořený kód hosta, který by sdílený buffer přepsal.
- Dispatcher volá `CompileBlock` se statickými registry uloženými ve `Frame->State`. Interpret tedy pracuje přímo nad `State`. Na konci bloku nastaví `State.rip` a vrátí vrchol smyčky dispatcheru. `Break` vrací stub signálu se `SynchronousFaultData` stejně jako JIT.
- `ExitFunctionLink` bez JITu nic nelinkuje, když cíl v obrazu chybí. Pošle běh zpátky do smyčky dispatcheru, která cíl při každé návštěvě předá `CompileBlock`.
- IR každého interpretovaného bloku zůstává v cache podle adresy hosta (`ContextImpl::InterpCache`, patch `0023-interpreter-ir-cache.patch`), takže blok, který běží znovu, se už nedekóduje. Kopie IR si pamatuje stránky hosta, ze kterých blok vznikl; `InvalidateCodeBuffersCodeRange`, přes který jde každé zneplatnění (zápis do stránky s kódem, změna ochrany, uvolnění, odmapování), zahodí každý blok se stránkou v rozsahu, stejně jako přeložené bloky. Stránky bloku v cache se registrují pro detekci SMC (`MarkGuestExecutableRange`) jako u přeloženého bloku.
- Sémantika každé operace kopíruje arm64 JIT (`Core/JIT/*Ops.cpp`): šířky pod 32 bitů, které příznaky operace zapisuje, 32bitové zalomení adres v okně hosta.
- Před spuštěním se ověří, že interpret zná každou operaci bloku. Když nějakou nezná, zaloguje `[interp] guest block X needs IR op Y, which the interpreter does not implement` pro každou z nich a skončí s `NoJIT: ... has no implementation of IR op Y`.
- Každý interpretovaný blok se poprvé zaloguje jako `[interp] learned block X` (prvních 64) a zapíše do kódové mapy, pokud se nějaká píše. Další `process-all` ho tak přidá do obrazu. Při `NtTerminateProcess` běh zaloguje `[interp] fallback ran N blocks (M distinct) that are not in the AOT image, H of them from the IR cache (B IR builds, D dropped by invalidation)`.
- `FEX_INTERP_SURVEY=1` (v CI `WINEHOST_FEX_INTERP_SURVEY`) v offline kompilátoru spočítá, kolik bloků kódové mapy by interpret zvládl a které operace chybějí ostatním (`[interp-survey] ...`).

Okenní program v CI s NoJIT narazí na bloky, které žádný běh s JITem nevzal (v kernelbase, user32 kolem x87, a od nich bloky začínající uvnitř kódu, který obraz přeložil jako část delšího bloku), a interpret je spustí. `tests/wine-loader/converge-nojit.sh` jejich kódové mapy přidá do cache, ze kterých se obraz staví, offline kompilátor je přeloží, obraz se slinkuje znovu a program běží znovu, dokud poslední běh nevezme všechno z obrazu (nejvýš 4 kola). CI také z kódové mapy hello.exe vyhodí každý čtvrtý blok (`codemap.py drop --every 4`), postaví z ní cache a obraz a spustí hello.exe s NoJIT. Běh musí vypsat `Hello from x86`, skončit s 0, zalogovat interpretované bloky a zapsat je do nové kódové mapy.

## Co zbývá

1. Operace, které interpret nezná: AES, SHA, CRC32, PCLMUL, `Thunk`, `CallbackReturn`, `ValidateCode`, `RDRAND`, maskované a gather loady a širší SSE/AVX operace (saturační zúžení, `VFCADD`, FMA, převody s `RoundMode`). Seznam pro konkrétní program dá survey. x87 už interpret umí: operace F80 a F64 volá přímo softfloat fallbacky z `Interpreter/Fallbacks` s FCW ze stavu, stejně jako JIT.
2. Výpadky paměti uvnitř interpretu. Přístup hosta na neplatnou adresu teď spadne v C++ kódu interpretu a obsluha výjimek WoW64 ho nepozná jako kód FEXu. Je potřeba buď ověřovat přístupy, nebo PC interpretu přeložit na adresu hosta a doručit SEH jako z JITu.
3. Zpětná vazba z iPadu. V CI se naučené bloky vracejí do buildu (`converge-nojit.sh`), aplikace na iPadu je ale zapíše jen do svého `codemap/new`. Je potřeba je odtud sbírat (např. s logem) a přidat do kódové mapy, ze které se obraz staví.
4. Single-step (příznak TF) bez JITu: `CompileSingleStep` pořád překládá.
