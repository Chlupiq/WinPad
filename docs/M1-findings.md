# M1: analýza – výsledky

Zkoumané verze: Madeira `48f9764` (2026-10-07), upstream FEX `14c9268` (2026-10-07).

## Shrnutí

| Otázka z PLAN.md | Odpověď | Dopad |
|---|---|---|
| 1. Relokace v kódu Wine PE modulů | **Jen 2 z 303 modulů** (`ntdll.dll`, `win32u.dll` pro aarch64), vždy syscall stuby | PE-in-Mach-O je proveditelné. Stačí malý patch ve `winebuild`. |
| 2. Je FEX cache relokovatelná? | **Ano, při načtení**: FEX má relokace a offline kompilátor. Relokace ale zapisuje **do kódu** a za běhu patchuje i propojení bloků. | Potřeba „AOT/PIC režim" v ARM64 backendu FEX (viz B). |
| 3. 32bit guest window | Cache pracuje v guest adresách, báze `B` je v registru | Pravděpodobně bez problému, ověřit v M2. |
| 4. Limity velikosti | Neřešeno | M2 |

## A. PE moduly → podepsané Mach-O

Nástroj: [`tools/pe-reloc-audit`](../tools/pe-reloc-audit/pe_reloc_audit.py), spuštěný nad `app/Madeira/{arm64ec,aarch64,i386}-windows` (303 souborů, 243 MB obrazů).

- **Zarovnání:** 267/303 modulů má sekce zarovnané na 64 KB (Wine výchozí), což je násobek 16 KB stránky iOS. Zbylých 36 jsou moduly mimo Wine strom (DXMT `winemetal`/`d3d11`/`dxgi`, `xtajit`/`xtajit64` z FEX, D3D12, testovací exe) se 4 KB zarovnáním → přidat `-Wl,/ALIGN:65536` (nebo 16384) do jejich buildů.
- **W+X sekce:** žádné (0/303).
- **Relokace v kódových sekcích:** jen `ntdll.dll` (258×) a `win32u.dll` (1540×), obě aarch64 (WoW64 strana). Všechny jsou `IMAGE_REL_BASED_DIR64` uvnitř syscall stubů `Nt*/Zw*`: 64bit literál s adresou syscall dispatcheru přímo v `.text`.
  - **Řešení:** upravit generátor stubů ve `winebuild` (arm64 větev), aby adresu načítal přes `adrp+ldr` z `.data`/`.rdata` místo literálu v `.text`. Jedna funkce, změna se týká všech syscall stubů najednou.
- **x64 kód v ARM64EC modulech:** 148 ze 168 ARM64EC modulů má v CHPE code map jeden x64 rozsah (4–85 KB). Je to sekce `.hexpthk` (hybrid export thunky), malé x64 stuby, kterými x64 kód hry volá exporty. Jsou statické a předem známé, takže **je přeložíme AOT celé**, i bez nahrávání.

**Závěr A:** proveditelné. Pracovní kroky: patch `winebuild`, zarovnání 36 modulů a nástroj `pe2macho` + cesta „adopt pre-mapped image" ve `virtual_ios.c`.

## B. FEX cache → podepsaný kód

FEX už má většinu potřebné infrastruktury (`FEXCore/include/FEXCore/Core/CodeCache.h`, `Source/Tools/FEXOfflineCompiler`):

- **Code mapy:** za běhu zapisuje seznam vstupních bloků (`FileId` + offset bloku), včetně knihoven. Přesně to je naše „nahrávání".
- **Offline kompilátor:** z code mapy umí vygenerovat cache bez spuštění hry.
- **Relokace:** cache je nezávislá na adrese. Typy jsou v `JIT/Relocations.h`: `NAMED_SYMBOL_LITERAL`, `NAMED_THUNK_MOVE`, `GUEST_RIP_LITERAL/MOVE` a patchovatelné varianty.

Problém pro iOS bez JITu: FEX při načtení cache **zkopíruje kód do vlastního bufferu a relokace zapíše přímo do instrukcí** (`MappedCodeCacheFile::CodeBuffer`, „post-relocation"). Za běhu navíc **propojuje bloky přepisem instrukcí** (`Arm64JITCore::ExitFunctionLink` v `JIT.cpp`: `b`/`bl` přímo na cílový blok, nebo `ldr` přes thunk s `HostCode` uloženým uvnitř kódu). Do podepsaného kódu se zapisovat nesmí.

**Potřebné změny v ARM64 backendu FEX („AOT režim"):**
1. `NAMED_SYMBOL_LITERAL` / `NAMED_THUNK_MOVE` → `adrp+add` na symbol. AOT kód se slinkuje do stejného Mach-O jako FEX, takže vzdálenost je pevná a řeší ji linker.
2. `GUEST_RIP_*` → PE moduly nahrávat na jejich preferovanou `ImageBase` (Wine to umí, když je místo volné). Hodnota pak bude konstanta známá při buildu. Fallback: báze modulu v datové tabulce + `adrp`.
3. **Propojení bloků při buildu:** `cache2macho` zná všechny bloky, takže přímé skoky vyřeší jako `ARM64_RELOC_BRANCH26` (linker). Neznámé cíle půjdou přes dispatcher a lookup tabulku v `__DATA`. Data thunků (`HostCode`, `GuestRIP`, `CallerOffset`) se musí přesunout z kódu do `__DATA`.
4. Vypnout invalidaci a znovupropojování (`BlockDelinker`) v AOT režimu.
5. Dispatcher (`Dispatcher.cpp`) emitovat při buildu do statického objektu.

**Závěr B:** proveditelné, ale je to největší část práce. Jde o zásah do backendu FEX, ne o nový překladač. Doporučuji ho dělat proti upstream FEX (MIT) a zároveň proti forku Madeiry (`ios-port-2607`).

## Upravené pořadí pro M2

1. Patch `winebuild` (syscall stuby) a ověření auditem, že v `.text` nezbyly relokace. *(cloud)*
2. FEX AOT režim, body 1+4, ověřené na Linuxu ARM64 v CI: offline kompilace testovacího programu, načtení z read-only mapované paměti s `PROT_EXEC` bez zápisu. To simuluje iOS omezení i bez iPadu. *(CI)*
3. `cache2macho` + body 2, 3 a 5.
4. Teprve potom iOS build v CI a test na iPadu.

## Reprodukce

```sh
pip install pefile
git clone --depth 1 https://github.com/willfaust/Madeira
python3 tools/pe-reloc-audit/pe_reloc_audit.py --json audit.json \
  Madeira/app/Madeira/arm64ec-windows Madeira/app/Madeira/aarch64-windows Madeira/app/Madeira/i386-windows
```
