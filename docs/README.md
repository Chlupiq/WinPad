# Dokumentace WinPadu

WinPad spouští 32bitové Windows hry na iPadu a iPhonu **bez JITu**: bez debuggeru, StikDebugu, VPN a párování. Stačí normálně sideloadnutá aplikace. x86 kód hry se předem přeloží na počítači do podepsané knihovny (AOT obrazu) a na iPadu se už jen spouští. Co v obrazu chybí, spustí pomalejší interpret a zapíše, aby to příští překlad měl.

Dokumentace má dvě části. Uživatelská popisuje, jak aplikaci nainstalovat, přidat do ní hry a přeložit je. Vývojářská popisuje, jak to celé funguje uvnitř, co je v repozitáři a jak se to staví a testuje.

## Pro uživatele

| Dokument | Obsah |
|---|---|
| [Přehled](uzivatel/prehled.md) | Co WinPad umí, co k němu potřebuješ, co nepůjde |
| [Aplikace WinPad na iPadu](uzivatel/aplikace.md) | Instalace, přidání hry, knihovna her, nastavení, ovládání, logy a uložené hry |
| [Překlad her](uzivatel/preklad-her.md) | WinPad Translator: kola hraní a překladu, víc her v jedné aplikaci |
| [Návod k překladači (Word)](uzivatel/WinPad-Translator-navod.docx) | Krok za krokem s obrázky polí v okně překladače |
| [Když něco nejde](uzivatel/reseni-problemu.md) | Časté potíže a co s nimi |

## Pro vývojáře

| Dokument | Obsah |
|---|---|
| [Architektura](vyvojar/architektura.md) | Vrstvy (aplikace, Wine, WoW64, FEX, DXMT) a proč nic nepotřebuje JIT |
| [AOT obraz a interpret](vyvojar/aot-a-interpret.md) | Code mapa → offline kompilátor → cache → dylib → běh NoJIT; interpret a kola |
| [Repozitář](vyvojar/repozitar.md) | Co je ve kterém adresáři, nástroje a testy |
| [Sestavení a CI](vyvojar/sestaveni-a-ci.md) | Workflow `checks.yml`, artefakty, lokální práce na Macu |
| [Patche](vyvojar/patche.md) | Seznam patchů pro FEX, Madeiru, Wine a DXMT |
| [Stav projektu](vyvojar/stav-projektu.md) | Milníky, řetěz PR, NFSU2 v číslech, co zbývá |

## Deník návrhu

Starší dokumenty z jednotlivých etap. Popisují, jak se k řešení došlo, a zůstávají beze změny:

- [PLAN.md](../PLAN.md): původní plán (M0)
- [M1-findings.md](M1-findings.md): audit relokací v PE modulech a analýza FEX cache
- [M2-aot-design.md](M2-aot-design.md): návrh AOT režimu FEXu
- [M3-wine-modules.md](M3-wine-modules.md): Wine moduly jako podepsané dyliby
- [M4-interpreter.md](M4-interpreter.md): interpret pro bloky mimo AOT obraz (průběžně doplňovaný)
- [tools/winpad-translator/README.md](../tools/winpad-translator/README.md): překladač (anglicky, technicky)
- [tests/wine-app/README.md](../tests/wine-app/README.md): Xcode projekt aplikace
