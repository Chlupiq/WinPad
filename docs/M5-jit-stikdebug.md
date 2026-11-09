# JIT přes StikDebug

Bez JITu hra na iPadu běží z AOT obrazu (`fexaot-<hra>.dylib`) a kód, který v obrazu chybí, spouští interpret FEXu. Obraz se pro každou hru staví v několika kolech: hrát, exportovat kódové mapy, přeložit, nainstalovat znovu. S JITem tohle odpadá, protože FEX přeloží každý blok ve chvíli, kdy ho hra poprvé spustí, a dál ho spouští rychlostí JITu.

## Proč nestačí Xcode

Proces může spouštět kód, který sám vytvořil, jen když ho měl v rukou debugger (příznak `CS_DEBUGGED`). Na zařízeních s TXM (A15 a M2 a novější, iOS/iPadOS 26 a novější) ani to nestačí: každou 16KB stránku spustitelné paměti musí napřed jednou zapsat sám debugger. Debugger Xcode to nedělá, proto 2026-10-21 hra na iPadu pod Xcode padala na `KERN_CODESIGN_ERROR`.

StikDebug to umí skriptem `universal.js` (StikJIT, `INTEGRATION.md`). Aplikace o to požádá instrukcí `brk #0xf00d`, příkaz je v `x16`:

| x16 | Příkaz | Argumenty | Výsledek |
|-----|--------|-----------|----------|
| 1 | připravit oblast | `x0` = 0 (alokuje debugger), `x1` = velikost | `x0` = adresa spustitelné (RX) oblasti |
| 0 | odpojit debugger | | |

Skript posune PC za `brk`, alokuje oblast (`_M<size>,rx`), zapíše jeden bajt do každé její 16KB stránky a vrátí adresu. Stránky zůstanou spustitelné i po odpojení debuggeru.

## Co dělá aplikace

- `tests/wine-app/JITPool.c` (čisté C):
  - Pozná TXM. Hledá klíč `TXM` v `IODeviceTree:/chosen/memory-map` přes IOKit (funkce získá přes `dlsym`). Když se to nedá přečíst, bere každý systém od verze 26 jako TXM.
  - Pozná připojený debugger (`P_TRACED`), `CS_DEBUGGED` a spuštění z Xcode (proměnné prostředí, které Xcode nastavuje).
  - Požádá skript o 512MB oblast. Udělá k ní zapisovatelný alias (`vm_remap` a `vm_protect` na RW): přes něj FEX zapisuje kód (`DualMap::WriteOffset`) a z oblasti ho spouští.
  - Ověří, že kód zapsaný přes alias opravdu běží (`mov w0, #42; ret`), a odpojí debugger.
  - Nastaví `WINE_IOS_JIT_RX`, `WINE_IOS_JIT_RW` a `WINE_IOS_JIT_SIZE`. Pak `winehost.c` žádný vlastní pool nevyrábí.
- Kdyby ta kontrola aplikaci shodila, zůstane v `Documents/.jit-check` značka. Další spuštění pak poběží bez JITu a značku smaže, takže to následující spuštění zkusí znovu.
- `tests/wine-app/WinPadJIT.m`:
  - Hlídá nastavení: „Hrát s JITem, když je k dispozici“ a „Před hrou otevřít StikDebug“ (obojí výchozí zapnuté).
  - Otevírá URL `stikdebug://enable-jit?bundle-id=…&pid=…&script-name=universal.js`. Na zařízení bez TXM ji otevírá bez skriptu.
  - Stav ukazuje v Nastavení → JIT (StikDebug).
- Knihovna (`Library.m`): když JIT není zapnutý a StikDebug je nainstalovaný, otevře před hrou StikDebug. Pak čeká, než se debugger připojí, nejdéle 60 s, nebo dokud uživatel neklepne na „Spustit bez JITu“. Pool připraví hned po připojení, dokud na to skript čeká.
- Když StikDebug spustí aplikaci sám a už je připojený, pool se připraví hned při startu (`didFinishLaunching`).
- `main.m`: když je JIT připravený, hra běží s JITem a AOT obraz se nenačte. Bez JITu běží jako dřív: z AOT obrazu s interpretem.

| Situace | Co poběží |
|---------|-----------|
| Simulátor | jako dřív (obraz, nebo JIT, když obraz chybí) |
| Zařízení s TXM, StikDebug s universal.js | JIT |
| Zařízení bez TXM, StikDebug (stačí připojení) | JIT, pool vyrobí `winehost.c` |
| Zařízení s TXM pod Xcode | AOT obraz a interpret (Xcode JIT nedá) |
| Bez debuggeru | AOT obraz a interpret |

## Testy

CI (job `jit-protocol`, `tests/wine-app/jit-protocol-test.sh`) na Macu přehraje skript obsluhou signálu `SIGTRAP`:

- obsluha alokuje RX oblast a posune PC jako `universal.js`;
- test ověří jednu žádost o oblast zaokrouhlenou na 16KB stránky, jedno odpojení a alias, který vidí stejnou paměť;
- ověří proměnné pro Wine, smazanou značku a že skript bez oblasti vede k odpojení a běhu bez JITu.

Pak job přeloží `JITPool.c` a `WinPadJIT.m` pro iphoneos i simulátor. Celou aplikaci staví job `wine-loader` jako dřív.

## Neověřeno

- Na skutečném iPadu s iPadOS 27 a TXM tohle zatím nikdo nespustil. Protokol a skript odpovídají StikJIT z listopadu 2026 a hlášení UTM, Play! a Dolphinu pro iOS 26. Pro iPadOS 27 to nikdo nepotvrdil.
- Jestli StikDebug přepne zpátky do WinPad Wine sám. Jestli jeho skript běží dál, když je StikDebug na pozadí, než se uživatel vrátí. Pool se proto připravuje hned, jak se aplikace vrátí do popředí.
- Jak se 512MB pool připravuje dlouho. Je to 32 768 zápisů po 128 v dávce přes tunel StikDebugu.
- Jestli FEX JIT s Madeirou na zařízení dělá všechno ostatní správně (vyprázdnění cache instrukcí přes RX alias a podobně). V simulátoru to funguje.

## Pro uživatele v aplikaci

- V knihovně vedle tlačítka nastavení je štítek „JIT zapnutý“ nebo „JIT vypnutý“. Ťuknutím se otevře průvodce „Zapnout JIT“ se čtyřmi kroky. Hotové kroky mají fajfku: Režim pro vývojáře, StikDebug (ťuknutím se otevře stikdebug.org), párovací soubor a VPN, Zapnout JIT teď.
- Na zařízení bez JITu se průvodce při prvním spuštění ukáže sám, jednou.
- Štítek hry ukazuje „Poběží s JITem“, „Přeloženo“ nebo „Potřebuje JIT“.
- Hru bez přeloženého obrazu bez JITu aplikace nespustí, protože by spadla. Místo toho nabídne průvodce.
- Když se aplikace vrátí do popředí a StikDebug je mezitím připojený, pool se připraví hned.
