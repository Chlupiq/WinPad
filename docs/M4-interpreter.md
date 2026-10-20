# M4: Interpret pro bloky mimo AOT obraz

Kódová mapa není deterministická: běh s `FEX_NOJIT=1` občas narazí na blok, který nahrávací běhy nezaznamenaly, a v AOT obrazu tedy chybí. FEX se dřív na takovém bloku zastavil. Teď ho spustí interpret (patch `patches/fex-wow64/0018-nojit-ir-interpreter.patch`) a nic nemapuje jako spustitelné.

## Jak to funguje

- Interpretuje se IR FEXu, ne x86. Dekodér a OpcodeDispatcher běží jako při JITu (vyrábějí jen data), vynechá se jen alokátor registrů (`PassManager::SkipRA`). V IR před alokací `LoadRegister`/`StoreRegister` pořád říkají, který registr hosta čtou a zapisují.
- `CompileBlock` IR zkopíruje z OpDispatcheru vlákna. Syscall v interpretovaném bloku může spustit vnořený kód hosta, který by sdílený buffer přepsal.
- Dispatcher volá `CompileBlock` se statickými registry uloženými ve `Frame->State`. Interpret tedy pracuje přímo nad `State`. Na konci bloku nastaví `State.rip` a vrátí vrchol smyčky dispatcheru. `Break` vrací stub signálu se `SynchronousFaultData` stejně jako JIT.
- `ExitFunctionLink` bez JITu nic nelinkuje, když cíl v obrazu chybí. Pošle běh zpátky do smyčky dispatcheru, která cíl při každé návštěvě znovu interpretuje.
- Sémantika každé operace kopíruje arm64 JIT (`Core/JIT/*Ops.cpp`): šířky pod 32 bitů, které příznaky operace zapisuje, 32bitové zalomení adres v okně hosta.
- Před spuštěním se ověří, že interpret zná každou operaci bloku. Když nějakou nezná, zaloguje `[interp] guest block X needs IR op Y, which the interpreter does not implement` pro každou z nich a skončí s `NoJIT: ... has no implementation of IR op Y`.
- Každý interpretovaný blok se poprvé zaloguje jako `[interp] learned block X` (prvních 64) a zapíše do kódové mapy, pokud se nějaká píše. Další `process-all` ho tak přidá do obrazu. Při `NtTerminateProcess` běh zaloguje `[interp] fallback ran N blocks (M distinct)`.
- `FEX_INTERP_SURVEY=1` (v CI `WINEHOST_FEX_INTERP_SURVEY`) v offline kompilátoru spočítá, kolik bloků kódové mapy by interpret zvládl a které operace chybějí ostatním (`[interp-survey] ...`).

CI z kódové mapy hello.exe vyhodí každý čtvrtý blok (`codemap.py drop --every 4`), postaví z ní cache a obraz a spustí hello.exe s NoJIT. Běh musí vypsat `Hello from x86`, skončit s 0, zalogovat interpretované bloky a zapsat je do nové kódové mapy.

## Co zbývá

1. Operace, které interpret nezná: x87/F80 (zásobník i fallbacky), AES, SHA, CRC32, PCLMUL, `Thunk`, `CallbackReturn`, `ValidateCode`, `RDRAND`, maskované a gather loady a širší SSE/AVX operace (saturační zúžení, `VFCADD`, FMA, převody s `RoundMode`). Seznam pro konkrétní program dá survey. Fallbacky z `Interpreter/Fallbacks` jdou volat přímo.
2. Výpadky paměti uvnitř interpretu. Přístup hosta na neplatnou adresu teď spadne v C++ kódu interpretu a obsluha výjimek WoW64 ho nepozná jako kód FEXu. Je potřeba buď ověřovat přístupy, nebo PC interpretu přeložit na adresu hosta a doručit SEH jako z JITu.
3. Cache IR. Blok se teď dekóduje při každé návštěvě znovu, takže smyčka v chybějícím bloku je pomalá. Stačí mapa adresa → kopie IR, zneplatňovaná spolu s lookup cache (SMC a uvolnění kódu).
4. Vlákna a SMC. Interpretované bloky se neregistrují pro detekci samomodifikujícího kódu. S cache IR je to nutné.
5. Zpětná vazba do buildu. Naučené bloky jsou v `codemap/new`, ale aplikace je do obrazu dostane až při dalším buildu. Je potřeba je z iPadu sbírat (např. s logem) a přidat do kódové mapy, ze které se obraz staví.
6. Single-step (příznak TF) bez JITu: `CompileSingleStep` pořád překládá.
