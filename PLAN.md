# WinPad: plán (M0)

**Cíl:** spouštět Windows hry na iPadu (a iPhonu) **bez JITu**, tedy bez StikDebugu, bez debuggeru, bez VPN a bez párování. Stačí normálně sideloadnutá aplikace.

**Základ:** [Madeira](https://github.com/willfaust/Madeira) (GPL-3.0-or-later + Madeira Converter Exception). Madeira už spouští Windows hry na iOS: Wine ARM64EC, FEX (x86/x86-64 → ARM64), DXMT (D3D9–11 → Metal) a vlastní D3D12. Potřebuje ale JIT od připojeného debuggeru. WinPad tedy bude fork Madeiry s novým režimem **Ahead-of-Time (AOT)**.

## 1. Proč Madeira potřebuje JIT (zjištěno z kódu)

Ze `docs/WOW64.md`: *„Everything that executes comes from the one dual-mapped RX/RW JIT pool."* JIT pool je tedy potřeba na dvě věci:

| Co se spouští z JIT poolu | Příklad | Proč je to problém bez JITu |
|---|---|---|
| **A. Wine PE moduly (ARM64EC)** | `ntdll.dll`, `kernel32.dll`, `wow64.dll`, `d3d11.dll` (DXMT), `xtajit64.dll` (FEX) | iOS spustí jen kód z podepsaného Mach-O, který načte dyld. PE soubory načítá Wine vlastním loaderem do JIT poolu (`build/ntdll-unix/virtual_ios.c`, `ios_jit_mappings`). |
| **B. Přeložený kód hry** | x86 → ARM64 z FEX | FEX ho generuje za běhu. |
| **C. Pomocný kód FEX** | dispatcher, thunky, signal handlery | FEX ho generuje při startu. |

Unix strana (Wine unix libs, wineserver, DXMT unix) už je staticky linkovaná do aplikace (`.a`), takže ta JIT nepotřebuje.

## 2. Návrh režimu bez JITu

### A. PE moduly jako podepsané Mach-O („PE-in-Mach-O")
- Wine, DXMT a FEX PE moduly se sestaví s **16 KB zarovnáním sekcí** (lld-link `/ALIGN:16384`), aby PE sekce seděly na iOS stránky.
- Nástroj `pe2macho` zabalí každý PE obraz do dylibu: PE `.text` jako `__TEXT` (RX) a `.data`/`.rdata` jako `__DATA` (RW), se stejnými relativními offsety (RVA).
- Dyld dylib načte a podepíše jako běžný kód. Wine loader (`virtual_ios.c`) dostane cestu **„adopt pre-mapped image"**: místo kopírování do JIT poolu najde už načtený obraz a aplikuje PE relokace jen na RW stránky.
- **Riziko:** relokace v kódových stránkách. U ARM64 je kód převážně PC-relativní, ale musí se to ověřit nástrojem nad skutečnými DLL (M1).

### B. AOT cache přeloženého kódu hry
- **FEX 2609 přidal disk cache** (`FEX_DISKCACHE=1`), která ukládá výstup JITu do FOZ databáze ([FEX-2609](https://fex-emu.com/FEX-2609/)). To je přirozený základ.
- **Nahrávání:** hra běží v Madeiře s JITem (iPad s StikJIT) nebo ve FEX na ARM64 Linuxu / Windows on ARM a cache se plní.
- **Build:** nástroj `cache2macho` převede FOZ cache na objektový soubor s relokacemi, který se slinkuje do podepsaného dylibu hry.
- **Běh na iPadu:** FEX v AOT režimu nic negeneruje. Při vstupu do bloku hledá v tabulce (module hash + guest RVA → host adresa).
- **Riziko:** přeložený kód FEX obsahuje absolutní adresy (dispatcher, guest base, konstanty). Je potřeba zjistit, co FEX při ukládání do cache relokuje, a doplnit relokační záznamy.

### C. Pomocný kód FEX
- Dispatcher a thunky vygenerovat při buildu (na Macu, v CI) a slinkovat jako statický kód.

### D. Co když blok v cache chybí
1. **Varianta 1 (M2):** zalogovat adresu a ukončit hru se srozumitelnou chybou. Log se pošle zpátky do nahrávání. Je to jednoduché a pro staré hry s deterministickým kódem to může stačit.
2. **Varianta 2 (později):** interpret x86 jako záloha. FEX vlastní interpret už nemá, takže by šlo o nový kód. Kandidáti: interpret nad FEX IR nebo převzatý interpret (např. z Box64/Bochs, ověřit licence).

### E. Co bez JITu nepůjde
- .NET/Mono/XNA, Java, hry se skriptovacím JITem (LuaJIT apod.), protože kód generují za běhu.
- DRM a anti-cheat.
- Samomodifikující se kód a packery (UPX apod.); předem rozbalit, nebo nepodporováno.

## 3. Etapy

| Etapa | Výstup | Kde běží |
|---|---|---|
| **M0** | Tento plán | – |
| **M1: analýza** | Madeira jako submodul. Nástroj `pe-reloc-audit`, který u všech PE modulů Madeiry vypíše relokace v kódových sekcích. Analýza formátu FEX disk cache (FOZ) a relokací v ní. | Cloud (Linux), CI |
| **M2: hello world bez JITu** | Konzolový x86 test (aritmetika, x87/SSE, výjimky, vlákna), plně nahraný → AOT dylib → běží v iOS aplikaci bez debuggeru. Režim D1. | CI macOS + tvůj iPad |
| **M3: Wine bez JITu** | PE-in-Mach-O pro `ntdll`/`kernel32`/`user32`; Win32 okno s GDI na iPadu. | CI + iPad |
| **M4: grafika** | DXMT D3D9 vzorek (kostka) bez JITu. | CI + iPad |
| **M5: první hry** | HoMM3 (GOG, 32bit DirectDraw), pak FlatOut 2 (GOG, DX9). Měření FPS s JITem a bez něj. | iPad |
| **M6: Nahrávací workflow** | Nahrávání cache přímo v Madeiře s JITem + export, build IPA v CI z cache. | iPad + CI |
| **M7: Interpret jako záloha** | Varianta D2. | – |

## 4. Infrastruktura
- **Licence:** WinPad je odvozené dílo Madeiry → **GPL-3.0-or-later** se zachovanou Madeira Converter Exception. FEX (MIT), Wine (LGPL-2.1+), DXMT (MIT).
- **CI:** GitHub Actions. Linux runnery pro nástroje a testy, macOS runnery (M-čipy) pro iOS build. Build Madeiry dnes závisí na ručně připravených toolchainech (llvm-mingw 20260421, LLVM pro iOS), takže první úkol M1 je zautomatizovat jejich stažení a sestavení s cache.
- **Podepisování v CI:** v CI vznikne nepodepsané IPA. Podepisuje se při sideloadu (Sideloadly/AltStore/SideStore) tvým Apple ID.
- **Testy na zařízení:** iOS Simulator v CI ověří jen část (simulátor vynucuje podpis kódu jinak). Rozhodující test je vždy na skutečném iPadu.

## 5. Otevřené otázky
1. Kolik relokací je v kódových sekcích Wine ARM64EC DLL? (M1)
2. Jsou položky FEX disk cache relokovatelné, nebo obsahují absolutní host adresy? (M1)
3. Jak se FEX chová k 32bit „guest window" (`B + zext32(EA)`) v cache? Báze `B` se liší mezi běhy. (M1/M2)
4. Limity velikosti podepsaného kódu a jetsam paměti pro velkou AOT cache (desítky až stovky MB). (M2)
