# Patche

Každý patch má v hlavičce podrobný popis (proč a jak), tady je jen přehled. Patche se aplikují v pořadí čísel a stavějí na sobě. Mezery v číslování vznikly při slévání souběžných větví.

## `patches/fex-wow64/` (FEX fork Madeiry `3bec2ac`)

Z tohoto stromu se staví `xtajit.dll` (FEX pro WoW64) i `FEXOfflineCompiler.exe`.

| # | Co dělá |
|---|---|
| 0001 | Konstruktory se spouští v kopii modulu v poolu |
| 0002, 0003 | Code mapa se zapíše při ukončení procesu, v binárním režimu |
| 0004 | Offline kompilátor se sestaví pro iOS hosta (stuby symbolů jen pro iOS) |
| 0005 | Offline kompilátor si vyhradí 4GiB okno hosta a i386 obrazy mapuje ručně |
| 0006 | WoW64 modul načítá code cache |
| 0007 | AOT: adresy hosta z datových slotů, exit linker přes stav vlákna |
| 0008 | AOT: propojování bloků jen přes data |
| 0009 | AOT: konce bloků v datech, kód beze změn |
| 0010 | Cache slinkované do obrazu se spouští na místě (index obrazu) |
| 0011 | Dispatcher stejný v každém procesu, spouštěný z obrazu |
| 0012 | **NoJIT**: spouští se jen kód z obrazu |
| 0013 | Systémová volání WoW64 přes BOP v kódu 32bitové ntdll |
| 0014 | Báze okna hosta se čte z vlákna, ne z kódu |
| 0015 | Offline kompilátor překládá syscally pro generické ABI |
| 0016 | Code mapa se zapíše až při skutečném konci procesu |
| 0017 | NoJIT bez JIT poolu |
| 0018 | Proč se blok překládá za běhu, i když jsou cache načtené |
| 0019 | **IR interpret** pro bloky, které v obrazu chybí |
| 0020 | Offline kompilátor publikuje každý přeložený blok |
| 0021 | Která relokace dělá blok necacheovatelným (diagnostika) |
| 0023 | Ponechá loady hosta, jejichž hodnota se nepoužije (`_chkstk` sondy) |
| 0024 | Halda FEXu mezi oknem hosta a koncem mapy adres iPadu |
| 0026 | Interpret: MMX/SSE posuny, packy, konverze |
| 0027 | Cache zůstanou v provozu po změně DEP |
| 0028 | Offline kompilátor dělá nejvýš N cache v jednom procesu |
| 0029 | Bloky z cache se vrátí po `VirtualProtect`, který kód nezměnil |
| 0030 | Bloky s nezarovnanými atomickými přístupy se zapíšou a přeloží s half barrier |
| 0031 | Interpret říká, proč se blok naučil |
| 0032 | Offline kompilátor odmítne cache, jejíž kód přetekl buffer |
| 0033 | rpmalloc nechává pár volných stránek commitnutých |
| 0034 | Interpret si pamatuje IR každého bloku |
| 0035 | Interpret recykluje pole SSA hodnot |
| 0036 | Code cache pro kód, který si program vyrobí za běhu (podle bajtů) |
| 0037 | Offline kompilátor běží bez JIT poolu (Windows on ARM, Wine) |

## `patches/fex/` (upstream FEX `14c9268`, etapa M2)

| # | Co dělá |
|---|---|
| 0001 | Relokace code cache relativně ke kódovému bufferu (oprava chyby upstreamu) |
| 0002–0004 | AOT cache: datové sloty, propojení přes data, kód jen pro čtení |
| 0005 | Načtení cache slinkovaných do obrazu |
| 0006 | Statický dispatcher |
| 0007 | FEXCore pro iOS |
| 0008 | NoJIT |
| 0009 | Hook pro minimální frontend `tests/probe` |
| 0010 | FEXCore na macOS, generování cache s NoJIT |
| 0011 | `__clear_cache` v iOS aplikaci |

Patche 0002–0008 jsou předobrazem `fex-wow64/0007–0012`.

## `patches/madeira/` (unixová strana ntdll Madeiry)

| # | Co dělá |
|---|---|
| 0001 | **Převezme PE obraz z podepsaného dylibu** místo kopie do JIT poolu |
| 0002 | Řádek logu `[xp]` s veřejným iOS SDK |
| 0003 | Okno hosta na iPadu, jehož mapa adres končí pod prvním slotem |
| 0004 | Stránku 0 mapuje debugger jen na požádání |
| 0005 | Hledání jména souboru v jiné velikosti písmen (DLL her na iPadu) |
| 0007 | 32bitový zásobník vlákna WoW64 podle adres hosta (guard stránky) |
| 0008 | Breakpointy nechá debuggeru, který je drží |

## `patches/wine/` (Wine Madeiry)

| # | Co dělá |
|---|---|
| 0001 | aarch64 syscall stuby načítají dispatcher přes `adrp`/`ldr` (bez relokací v kódu) |
| 0002 | win32u bere okno vytvořené wineserverem jako plochu (první vykreslení) |
| 0003 | Exportovaná funkce i386 ntdll s BOP instrukcemi pro WoW64 |

## `patches/dxmt/`

| # | Co dělá |
|---|---|
| 0001 | Pipeline bez rasterizace dostane v simulátoru attachment |
| 0002 | `air_tessellation.metal` se přeloží i Metal kompilátorem z Xcode 27 |
| 0003 | Chyby vracené unixovou stranou winemetal se retainují (use-after-free) |
