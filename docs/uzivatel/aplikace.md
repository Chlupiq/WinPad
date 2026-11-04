# Aplikace WinPad na iPadu

Aplikace se jmenuje **WinPad Wine** (po překladu knihovny her **WinPad**, nebo jak si ji pojmenuješ polem App name v překladači). Identita aplikace (bundle ID) zůstává pořád stejná, takže nová verze vždycky přepíše starou a tvoje hry, uložené pozice a nastavení zůstanou.

## Instalace

Jsou dvě cesty. Obě potřebují tvoje Apple ID.

### A. IPA přes Sideloadly, AltStore nebo SideStore

1. Na [github.com/Chlupiq/WinPad](https://github.com/Chlupiq/WinPad) otevři **Actions**, vyber poslední zelený běh workflow **checks** a dole v **Artifacts** stáhni `WinPadWine-ipa`.
   IPA s přeloženými hrami ti místo toho vyrobí [WinPad Translator](preklad-her.md).
2. IPA nainstaluj instalátorem, který ji podepíše tvým Apple ID.
3. S bezplatným Apple ID vyprší podpis po 7 dnech. AltStore a SideStore ho umí obnovit samy, se Sideloadly IPA nainstaluj znovu.

Aplikace má kromě hlavního programu desítky dalších knihoven (`Frameworks/`, `aarch64-windows/`) a instalátor musí podepsat i ty. Kdyby aplikace po instalaci hned spadla, je to nejspíš tohle (zatím ověřené jen s Xcode).

### B. Z Xcode na Macu

1. Stáhni artefakt `WinPadWine-xcode`, rozbal ho a otevři `WinPadWine.xcodeproj`.
2. Target **WinPadWine → Signing & Capabilities → Team**: vyber svůj účet. Když Xcode hlásí obsazené bundle ID, přidej k němu např. `.test`.
3. Připoj iPad, vyber ho nahoře jako cíl a dej **Run (⌘R)**. Na iPadu musí být zapnutý Režim vývojáře (Nastavení → Soukromí a zabezpečení).
4. Hru pak spouštěj z plochy iPadu, ne z Xcode. Pod debuggerem Xcode se při startu zastavuje na každé ze stovky knihoven a start trvá minuty. Hra debugger nepotřebuje.

Podrobnosti k Xcode projektu (schémata, testovací programy) jsou v [tests/wine-app/README.md](../../tests/wine-app/README.md).

## Přidání hry

1. Připoj iPad k počítači.
   - Mac: **Finder → iPad → Soubory → WinPad Wine**.
   - Windows: aplikace Apple Devices (dřív iTunes) → **Sdílení souborů → WinPad Wine**.
2. Přetáhni tam **celou složku hry** (např. `NFSU2`). Každá hra má svou složku.
3. Volitelně do složky přidej:
   - `cover.png` nebo `cover.jpg`: obal, který knihovna ukáže na dlaždici.
   - `winpad.json`: název hry a její program, např.
     ```json
     { "title": "Need for Speed Underground 2", "exe": "SPEED2.EXE" }
     ```
     Bez něj je názvem jméno složky a programem největší `.exe`, který nevypadá jako instalátor nebo pomocný program.

Jméno složky na iPadu je zároveň jméno obrazu: složka `Moje Hra` → `fexaot-moje-hra.dylib`. Složku proto po prvním překladu nepřejmenovávej.

Hra, která ještě nemá přeložený obraz, se spustí taky. Poběží ale celá v interpretu, tedy velmi pomalu. To je první kolo; jak z něj udělat rychlou hru, popisuje [Překlad her](preklad-her.md).

## Knihovna her

Aplikace se otevře na knihovně podobné úvodní obrazovce herní konzole: řada čtvercových dlaždic, vybraná hra je větší, s bílým rámečkem, názvem, štítky, tlačítkem **Spustit** a informací, jestli má přeložený obraz. Vpravo nahoře jsou hodiny. Poslední dlaždice **Přidat hru** připomene, kam hry kopírovat.

| Akce | Herní ovladač | Klávesnice | Dotyk |
|---|---|---|---|
| Vybrat hru | křížový ovladač nebo levá páčka | šipky | ťuknutí |
| Spustit | A | Enter | druhé ťuknutí nebo Spustit |
| Nastavení | Y | | ikona nastavení |
| Zpět z nastavení | B | Esc | Zpět |

Wine jde v jednom spuštění aplikace pustit jen jednou. Po skončení hry proto aplikaci zavři (přejetím nahoru v přepínači aplikací) a spusť znovu, pak můžeš vybrat další hru.

Na iPhonu běží knihovna na šířku, s menšími dlaždicemi, bez nápovědy tlačítek a bez informační karty.

## Nastavení

Otevře se tlačítkem Y nebo ikonou v knihovně.

| Sekce | Co v ní je |
|---|---|
| **Vzhled** | Pozadí knihovny i nastavení: Modrá vlna, Půlnoc, Fialový soumrak, Smaragd, Obal vybrané hry (rozmazaný), nebo Vlastní obrázek z Fotek (případně nahraný jako `background.jpg` do Soubory → WinPad Wine). Přepínač **Vlny na pozadí**. |
| **Ovládání** | **Dotykové ovládání** (ovladač na obrazovce; ukáže se jen bez připojeného herního ovladače) a stav připojeného ovladače. |
| **Mapování tlačítek** | Jakou klávesu hra dostane za které tlačítko. Platí pro všechny hry. **Obnovit výchozí mapování** vrátí výchozí stav. |
| **Diagnostika** | **Ukazatel FPS**, **Poslední log**, testovací programy `hello.exe` a `window.exe`. |
| **O aplikaci** | Verze aplikace a počet nalezených her. |

V systémovém Nastavení iPadu (Nastavení → WinPad Wine) jsou ještě volby pro vývoj (Program, Game, Touch controls, FPS overlay). Při běžném hraní je nepotřebuješ.

## Ovládání ve hře

Hra dostává klávesy. Ovladač se na ně převádí podle mapování:

| Tlačítko | Výchozí klávesa | (NFSU2) |
|---|---|---|
| Levá páčka, křížový ovladač | šipky | řízení, menu |
| RT / LT | šipka nahoru / dolů | plyn / brzda |
| A | Enter | potvrdit |
| B | Esc | zpět |
| X | mezerník | ruční brzda |
| Y | C | kamera |
| LB / RB | Z / A | řazení |
| Menu | Esc | pauza |
| View | Enter | |
| Pravá páčka | nic (dá se namapovat) | |

Funguje:

- **herní ovladač** přes Bluetooth nebo MFi (Xbox, PlayStation a další),
- **dotykový ovladač** s rozložením Xboxu (dvě páčky, kříž, A B X Y, LB/RB, LT/RT, View a Menu nahoře uprostřed),
- **hardwarová klávesnice** (Magic Keyboard, Bluetooth, USB): klávesy jdou rovnou do hry.

Obraz hry vyplní obrazovku v poměru 4:3. **Ukazatel FPS** (Nastavení → Diagnostika) ukáže vlevo nahoře snímky za poslední sekundu, nejdelší snímek (zásek) a rozlišení, ve kterém hra kreslí.

Zvuk hraje i v tichém režimu iPadu (aplikace používá zvukovou relaci pro přehrávání).

## Uložené hry a nastavení her

Hry si ukládají pozice a nastavení do Wine prefixu v `Documents/prefix` (Soubory → WinPad Wine → prefix). Ten zůstává mezi spuštěními i mezi verzemi aplikace. Smaže ho jen odinstalování aplikace. Když chceš uložené hry zálohovat, zkopíruj si složku `prefix` do počítače.

## Co aplikace zapisuje

V Soubory → WinPad Wine najdeš:

| Soubor / složka | Co to je |
|---|---|
| `wine.log` | Log posledního běhu (Wine, FEX, aplikace). Hodí se při hlášení chyby. |
| `wine.log.crashed` | Log běhu, který aplikaci shodil. Aplikace ho ukáže při dalším spuštění. |
| `fexcache/codemap/new/` | **Code mapy**: kód, který běžel v interpretu, protože v obrazu chyběl. Včetně podsložky `runtime/` (kód, který si hra vyrobila za běhu) a `hostprobe.txt` (funkce procesoru iPadu). Tohle se kopíruje do překladače. |
| `prefix/` | Wine prefix: uložené hry, nastavení her, registry. |
| `background.jpg` | Vlastní pozadí knihovny. |
| `frames/` | Snímky okna testovacích programů. |

Dál: [Překlad her](preklad-her.md) · [Když něco nejde](reseni-problemu.md)
