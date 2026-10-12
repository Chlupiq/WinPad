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
4. Mapování cache `r-x` bez relokací a test, který ověří, že do kódu nikdo nezapsal.
