# M2: AOT režim FEX – návrh

Cíl: kód z FEX cache musí jít spustit z paměti, která je jen `r-x` a do které se po načtení nikdy nezapisuje. Na iPadu bez JITu jinak spustit nejde. Návrh vychází z FEX `14c9268` a z měření v `docs/M1-findings.md` (24 zápisů do kódu u malého programu).

## Kam dnes FEX zapisuje do kódu

| Místo | Kód | Kdy |
|---|---|---|
| `EXITFUNCTION_LINKER` literál na konci každého bloku | `JIT.cpp` (`PlaceNamedSymbolLiteral(... EXITFUNCTION_LINKER)`), `Arm64Relocations.cpp` | při načtení cache (`ApplyCodeRelocations`) |
| `GUEST_RIP_LITERAL` v jump thunku (`GuestRIP`) | `JIT.cpp`, `InsertGuestRIPLiteral` | při načtení cache |
| `GUEST_RIP_MOVE` (`LoadConstant` adresy hosta) | `Arm64Relocations.cpp`, `InsertGuestRIPMove` | při načtení cache |
| `HostCode` v jump thunku + `b`/`bl` na místě volání | `JIT.cpp`, `ExitFunctionLink` | za běhu, při propojení bloků |
| vrácení `b`/`bl` a `b 0x8` | `DirectBlockDelinker`, `IndirectBlockDelinker` | za běhu, při invalidaci |
| relokace stránky při prvním spuštění | `CodeCache::FinalizeCodePages` (staging + `mremap`) | za běhu, líně po stránkách |

## Návrh: kód jen pro čtení, vše proměnné v datech

V AOT režimu (nová volba, např. `FEX_AOTCODE=1`) backend vydává kód tak, aby žádná z položek výše nebyla v kódu:

1. **Datová oblast vedle kódu.** Každý blok dostane sloty v samostatné datové oblasti (`rw-`, nikdy `x`). V cache souboru následuje za kódem jako nová sekce; na iOS z ní bude `__DATA` vedle `__TEXT` (krok `cache2macho`). Kód na sloty sahá přes `adrp` + `ldr` (±4 GB), takže stačí zachovat vzdálenost kód–data a nic se nepřepisuje.
2. **Pojmenované symboly (`EXITFUNCTION_LINKER`)** se načítají ze slotu v datech. Slot vyplní zavaděč, nebo na iOS dyld přes bind. *(bod 1 z M1)*
3. **Adresy hosta (`GUEST_RIP_*`)** se také čtou ze slotů. Zavaděč do nich zapíše `base + offset`, kód zůstane stejný pro libovolnou adresu načtení. Tím odpadá nutnost mapovat PE moduly vždy na preferovanou adresu (bod 2 z M1 se zjednoduší).
4. **Propojování bloků jen přes data.** Thunk má vždy tvar „načti `HostCode` ze slotu, je-li nenulový, skoč tam, jinak zavolej linker“. `ExitFunctionLink` zapíše jen do slotu `HostCode`; místo volání (`b`/`bl`) se nikdy nepřepisuje. Odpojení = zápis nuly do slotu. *(body 3 a 4 z M1 zároveň, za cenu jednoho nepřímého skoku na přechod mezi bloky)*
5. **Žádné líné relokace.** `FinalizeCodePages` v AOT režimu jen namapuje stránky cache `PROT_READ|PROT_EXEC` přímo ze souboru.

## Ověření bez iPadu

Na Linuxu ARM64 v CI: AOT cache se namapuje ze souboru jen `r-x` (bez staging bufferu) a datová oblast `rw-`. Testovací program musí doběhnout, `fxcc-inspect` musí v AOT cache ukázat 0 relokací v kódu a druhý běh musí blok načíst z cache (kontrola `Cache load:` v logu, zavedená v tomto kroku).

## Nálezy z ověření v CI

- **Chyba FEX: relokace v cache mířily do prvního bloku.** JIT ukládá offsety relokací vůči dočasnému bufferu bloku. Při generování cache se relokace sbírají přes všechny bloky a serializují vůči celému code bufferu, takže relokace každého dalšího bloku se zapsaly do kódu prvního bloku a běh z cache spadl na SIGILL. Oprava: `patches/fex/0001-codecache-rebase-relocations.patch`. Po ní test projde: 7 bloků se načte z cache a program vypíše `ok`.
- **Statický program musí mít kód od offsetu 0.** S výchozím rozložením lld mapují segment jen pro čtení i segment kódu offset 0 souboru. FEX za běhu pak počítá offsety bloků od jiné základní adresy (0x201000) než `FEXOfflineCompiler` (0x200000). Test proto linkuje s `--no-rosegment`. Pro Wine a PE moduly to neplatí, tam adresy hlídá `ImageTracker`.

## Pořadí implementace

1. Druhý běh testu načte cache a ověří, že se použila. *(PR #5, hotovo)*
2. Volba AOT + datová oblast + sloty pro `EXITFUNCTION_LINKER` a `GUEST_RIP_*`, nový formát cache (FXCC v3) a podpora v `fxcc-inspect`.
   *(PR #6, první část: volba `AOTCodeCacheWIP`, `GUEST_RIP_MOVE` → slot v datech přes `adrp`+`ldr`, linker se v thuncích čte ze stavu vlákna `Pointers.ExitFunctionLinker`, takže `EXITFUNCTION_LINKER` zmizí úplně. Formát hlavičky zůstal, počet slotů plyne z relokací. `GUEST_RIP_LITERAL` zůstává v záznamu thunku a odejde s bodem 3.)*
   *Výsledek v CI (ARM64): AOT cache testovacího programu má 7 bloků, 0 `NAMED_SYMBOL_LITERAL`, 0 `GUEST_RIP_MOVE`, 10 slotů v datech (`AOT data area: 10 slots at code+0x4000`), program z ní doběhne. Zápisů do kódu při načtení zbývá 9 z 24, všechny `GUEST_RIP_LITERAL` v thuncích.*
3. Propojování přes data (thunky, `ExitFunctionLink`, delinkery).
   *(PR #7: záznam `ExitFunctionLinkData` je v datové oblasti, thunk na něj míří přes `adrp`+`add` a skáče přes `HostCode`, je-li nenulový. Linker u takového záznamu jen zapíše `HostCode`, delinker ho vynuluje; místo volání ani thunk se nikdy nepřepisují. Lokálně: `GUEST_RIP_LITERAL` v thuncích zmizely, v kódu zbývá jeden `GUEST_RIP_LITERAL` na blok, a to `RIP` v `JITCodeTail` za kódem.)*
   *Výsledek v CI (ARM64): 4 záznamy propojení v datech (`AOT data area: 22 slots (4 link records)`), program z AOT cache doběhne. Zápisů do kódu při načtení zbývá 5 z 24, všechny jsou `RIP` v `JITCodeTail`.*
4. Mapování cache `r-x` bez relokací a test, který ověří, že do kódu nikdo nezapsal. Předtím vyřešit `JITCodeTail` (pole `RIP` a `SpinLockFutex` jsou ve stejném mapování jako kód).
   *(PR #8: konec bloku (`JITCodeTail` s tabulkou RIP) se kopíruje do datové oblasti a hlavička bloku na kopii ukazuje (`RELOC_AOT_BLOCK_TAIL`). Když všechny relokace plní jen data, zavaděč kód hned zkopíruje a nastaví `PROT_READ|PROT_EXEC`, bez líného načítání po stránkách. Zápis do takového kódu skončí chybou, obsluha SIGSEGV ho už nepovažuje za líné načtení. Test v CI vyžaduje 0 zápisů do kódu při načtení a hlášku `AOT code mapped read+execute`.)*
   *Výsledek v CI (ARM64): 0 zápisů do kódu z 24 původních, 59 slotů v datech (10 hodnot, 4 záznamy propojení, 5 konců bloků), kód namapovaný jen `r-x` a program z něj doběhne.*
   *Zbývá pro iOS: na Linuxu se kód kopíruje z cache souboru do anonymní paměti, na iOS ho namapuje dyld z `__TEXT` (krok `cache2macho`). Nezarovnaný přístup s pořadím TSO (`ldapur`, `stlr`, …) FEX normálně opraví přepsáním instrukce; v AOT kódu ho obsluha SIGBUS místo toho provede sama, atomicky a bez zápisu do kódu (stejná cesta jako pro kód mimo JIT). Test na to narazil hned: tabulka v testovacím programu není zarovnaná. Novější čipy Apple by měly mít LSE2, kde nezarovnaný `ldapur` uvnitř 16 bajtů nechybuje (neověřeno na iPadu); každý chybující přístup ale stojí signál. Ověření cache (`EnableCodeCacheValidation`) s AOT cache nepočítá.*

## cache2macho (M2, bod 3 pořadí z M1)

`tools/cache2macho/cache2macho.py` převede AOT cache na objekt Mach-O pro arm64 (iOS), který se slinkuje přímo do aplikace:

- `__TEXT,__fexaot_text`: kód z cache. Dvojice `adrp`+`ldr`/`add` do datové oblasti dostanou `ARM64_RELOC_PAGE21`/`PAGEOFF12` (s `ARM64_RELOC_ADDEND`), 32bitový odkaz z hlavičky bloku na kopii konce bloku dvojici `SUBTRACTOR`/`UNSIGNED`. Vzdálenost kód–data tak řeší linker a kód po podepsání nepotřebuje žádnou opravu.
- `__DATA,__fexaot_data`: datová oblast (nulová, `S_ZEROFILL`) ve stejném rozložení, jaké používá zavaděč FEX. Vyplní ji běhové prostředí.
- `__TEXT,__fexaot_meta`: hlavička `FXAM` a zbytek cache souboru bez kódu (seznam bloků, relokace, stránky kódu) pro zavaděč.

Ověření bez iPadu: `tests/fex-cache/run.sh` převede AOT cache z CI, slinkuje ji `ld64.lld` jako iOS dylib a `check_linked.py` ve výsledku dekóduje každý odkaz do datové oblasti a porovná ho s offsetem, který by použil zavaděč FEX. Ostatní bajty kódu musí zůstat stejné a segment s kódem musí být `r-x`.

Symboly se jmenují `fexaot_<file id>_<config id>_text`/`_data`/`_meta` podle jména cache souboru, takže FEX najde kód pro konkrétní binárku a do jedné aplikace jde slinkovat víc cache.

## Zavaděč z nalinkovaného obrazu (patch 0005)

`CodeCache::LoadLinkedCache` vezme tři symboly obrazu: z `_meta` přečte bloky a relokace, vyplní datovou oblast v `_data` a kód v `_text` použije na místě. Nic nekopíruje, nevolá `mprotect` a do kódu nezapisuje; všechny stránky jsou rovnou načtené a kód je `ReadOnlyCode`. `ExternalCode` zabrání tomu, aby FEX paměť obrazu uvolnil.

Na Linuxu volba `AOTImage` (`FEX_AOTIMAGE`) ukazuje na sdílenou knihovnu z `cache2macho.py --elf-asm` (stejný obraz jako AArch64 assembler; odkazy do dat řeší assembler a `ld.lld`). FEX ji načte přes `dlopen` a symboly najde přes `dlsym`; když pro binárku nic nemá, použije se cache soubor jako dřív. CI tak spouští host s kódem, který FEX nikdy nekopíroval ani neupravoval: cache soubory se před během přesunou pryč a log musí obsahovat `AOT image linked:`.

Na iOS bude zavaděč stejný, jen symboly hledá v aplikaci (`dlsym(RTLD_DEFAULT, …)`) místo v `.so`.

## Statický dispatcher (patch 0006, bod 5 z M1)

Dispatcher FEX (smyčka hledání bloků, obsluha signálů, volání kompilátoru, pomocné funkce pro x87) se generuje při startu. Jeho kód byl nezávislý na adrese až na čtyři 64bitové literály: ukazatel na kontext a adresy `SleepThread`, `CompileBlock` a `CompileSingleStep`. Ty se teď čtou ze stavu vlákna (`JITPointers`), takže kód dispatcheru je ve všech procesech stejného buildu a konfigurace bajt po bajtu stejný.

- Volba `DumpDispatcher` zapíše vygenerovaný kód do souboru, `cache2macho.py --dispatcher` z něj udělá assembler (Mach-O, nebo ELF s `--elf-asm`) se symboly `fexaot_dispatcher_text`/`_meta`.
- S `AOTImage` FEX dispatcher dál vygeneruje, ale do paměti bez práva spouštění. Když se kopie v obrazu shoduje, přesune všechny vstupní body do ní. Jinak (jiný build nebo konfigurace) použije vlastní kopii jako dřív a zaloguje to.
- CI ověřuje, že dva procesy vygenerují stejné bajty, a spouští hosta s dispatcherem ze `.so`. Pro iOS se dispatcher sestaví a slinkuje s `ld64.lld`.

Na iOS tak FEX nepotřebuje spustitelnou paměť pro dispatcher ani pro bloky v AOT cache. Bloky, které v cache nejsou, ale pořád překládá JIT. Bez JITu je musí obsloužit interpret, nebo musí být v cache všechny.

## Režim bez JITu (patch 0008)

Volba `NoJIT` zaručí, že FEX nikdy nežádá o spustitelnou paměť, což je na iOS bez debuggeru podmínka:

- Paměť pro JIT kód se alokuje jen pro čtení a zápis.
- Když blok hosta není v lookup cache (tedy ani v AOT obrazu), `CompileBlock` FEX zastaví s chybou s adresou bloku. Nic nepřekládá.
- Dispatcher musí být z obrazu. Když tam žádný odpovídající není, FEX skončí, místo aby udělal spustitelný vlastní.

CI spouští běh z `.so` s `FEX_NOJIT=1`, takže ověřuje, že testovací program proběhne celý jen z AOT kódu. Pro skutečné hry zůstává otázka bloků, které při nahrávání neproběhly: interpret, nebo opakované nahrávání, dokud cache nepokryje vše.

Zbývá: iOS build a test na iPadu.
