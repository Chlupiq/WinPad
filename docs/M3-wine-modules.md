# M3: Wine moduly jako podepsané dyliby

Stav k 2026-10-14. Madeira `48f9764`, moduly z `app/Madeira/aarch64-windows`.

## Převod

`tools/pe2macho` převede 125 ze 135 ARM64 modulů (DLL i EXE). CI je načte přes `dlopen` a ověří hlavičky, ukazatele z relokací a ochranu stránek (`tests/pe2macho/wine-modules.sh`).

- `ntdll` a `win32u` nejdřív projdou `fix_syscall_stubs.py`. Ten přepíše syscall stuby na `adrp`/`ldr`, stejně jako `patches/wine/0001` ve zdrojácích.
- Zbylých 10 modulů je mimo strom Wine (DXMT, `xtajit`, testovací EXE). Mají 4 KB zarovnání a potřebují `/ALIGN:16384` při sestavení.

## Kód, který Madeira přepisuje při načtení

Madeira kopíruje každý PE modul do JIT poolu a kód přitom upravuje (`build/ntdll-unix/virtual_ios.c`). Do podepsaného dylibu se zapisovat nedá, takže každou takovou úpravu musí udělat `pe2macho` už při sestavení.

1. **x18 → TEB** (`ios_jit_patch_x18`). Windows drží TEB v registru x18, Darwin ho při přepnutí vlákna nuluje. Každá instrukce, která čte x18, se nahradí skokem do trampolíny. Ta načte TEB z TSD slotu (`TPIDRRO_EL0`).
   - Hotovo v `tools/pe2macho/x18.py`: 10 722 instrukcí ve 125 modulech, žádná vynechaná.
   - Rozdíl proti Madeiře: číslo TSD slotu se zjistí až za běhu (patří pthread klíči). Trampolíny ho proto čtou z datového slova `_PREFIX_teb_slot`, které loader zapíše po `dlopen`.
   - Chyba v Madeiře, kterou neopakujeme: klasifikátor bere i `LDP/STP` SIMD registrů (`q18`, `d18`, `s18`) jako x18 a přepisuje je. V převáděných modulech je 27 takových instrukcí v 8 modulech (např. gdi32, rpcrt4, wined3d, windowscodecs). Madeira v nich zamění `q18` za `q17` a uloží nebo načte špatný registr.
2. **TSD slot v ručně psaném kódu FEX** (`Module.S`, trojice `mrs`/`and`/`ldr` s pevným offsetem). Týká se `xtajit`, který je zatím mimo převod.
3. **`RtlPcToFileHeader` v ntdll** (`ios_patch_rtl_pc_to_file_header`). Patch existuje jen proto, že kód běží z kopie na jiné adrese než PE obraz. Když loader převezme obraz přímo z dylibu, kopie zmizí a s ní i důvod pro patch.

## Další krok

Wine loader převezme obraz z dylibu: view modulu bude ležet přímo na adrese `_PREFIX_image`, takže nevznikne kopie ani překlad adres mezi PE obrazem a JIT poolem.
