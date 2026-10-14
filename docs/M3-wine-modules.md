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

## Převzetí obrazu loaderem Wine

Po `dlopen` je obraz v dylibu už ve stavu, do kterého ho jinak dostává loader: každý bajt na svém RVA od `_PREFIX_image`, relokace provedl dyld. `pe2macho` k tomu přidává dvě věci v hlavičce:

- Pole `ImageBase` je také ukazatel, který dyld přepíše na skutečnou adresu obrazu. Wine z něj bere základ modulu (`fill_builtin_image_info`), takže nevidí důvod k relokaci.
- `SizeOfImage` pokrývá i trampolíny pro x18 a TEB slot, takže patří do view modulu (a unwind přes trampolínu najde modul).

`tools/pe2macho/pe_adopt.h` obraz v dylibu najde a ověří (hlavičky, ARM64, `ImageBase` = adresa obrazu, zarovnání na stránku). CI ho pustí na všech 125 modulů a projde exporty přes PE export directory stejně jako `GetProcAddress` ve Wine. Každý musí vyjít na stejnou adresu, jakou dyld dá symbolu exportu.

Ve Wine na to stačí existující cesta pro builtin `.so` moduly (`dlopen_dll` → `virtual_create_builtin_view` v `loader_ios.c` a `virtual_ios.c`). Na aarch64 je vypnutá (`SO_DLLS_SUPPORTED` jen pro x86), ale `virtual_create_builtin_view` se kompiluje vždy. Plán patche:

1. `open_builtin_pe_file` nejdřív zkusí `NAME.dylib` vedle `NAME`. Když existuje: `dlopen`, `pe_adopt`, zápis TSD slotu do `teb_slot`, `fill_builtin_image_info` a `virtual_create_builtin_view`. Nevolá se `map_image_into_view`, takže nevznikne kopie v JIT poolu ani `ios_jit_add_mapping`.
2. `mprotect_exec` musí rozsahy převzatých modulů nechat být: kód už je r-x a podepsaný, data rw-. Změna ochrany od Windows kódu (`VirtualProtect` na IAT apod.) se tam má promítnout jen do evidence Wine, ne do kopie.
3. `ios_patch_rtl_pc_to_file_header` se pro převzaté moduly nevolá, protože kód běží přímo z obrazu.

Patch: `patches/madeira/0001-adopt-pe-dylib.patch` (body 1 a 2; bod 3 plyne z toho, že kód neprojde `mprotect_exec`). CI (`tests/wine-loader/build.sh`) přeloží `loader_ios.c` a `virtual_ios.c` pro iOS s příznaky Madeiry, nejdřív bez patche a pak s ním.

## Další krok

Sestavit celou Madeiru s patchem a spustit Wine proces s moduly z dylibů.
