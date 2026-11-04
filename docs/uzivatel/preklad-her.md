# Překlad her (WinPad Translator)

Podrobný návod krok za krokem, s popisem každého pole v okně překladače, je ve Wordu: **[WinPad-Translator-navod.docx](WinPad-Translator-navod.docx)**. Tahle stránka shrnuje, jak překlad funguje, a doplňuje, co návod nepokrývá: knihovnu více her v jedné aplikaci a obraz podepsaný do složky hry.

## Jak to funguje

Na iPadu běží rychle jen ten kód hry, který je předem přeložený v obrazu `fexaot-<hra>.dylib`. Zbytek spouští interpret, pomalu, a zapisuje si, co spustil (code mapy). Překladač z code map udělá nový obraz a vloží ho do IPA. Hra se tak zrychluje po kolech:

```
 ┌──────────── iPad ────────────┐        ┌────────── počítač ──────────┐
 │ 1. hraj (nové části hry       │        │ 3. WinPad Translator:       │
 │    běží pomalu v interpretu)  │──────▶ │    code mapy + složka hry   │
 │ 2. code mapy se zapíšou do    │ kopie  │    + IPA → nová IPA s       │
 │    fexcache/codemap/new       │        │    obrazem                  │
 └──────────────▲───────────────┘        └──────────────┬──────────────┘
                └──────────── 4. nainstaluj novou IPA ──┘
```

Každé kolo přidá kód, který se v něm hrál. U NFSU2 stačilo pár kol (intro, menu, závod) a pak běžela rychle.

## Co překladač potřebuje

- **Složku hry** na počítači, se stejnými soubory jako na iPadu.
- **Code mapy z iPadu**: celou složku `fexcache/codemap/new` včetně `runtime/` a `hostprobe.txt`.
- **IPA WinPad Wine ze stejného buildu**, jaký běží na iPadu. Code mapy se odkazují na Wine DLL podle přesné verze souboru. Překladač proto bere DLL z IPA a ohlásí, když soubor nesedí („file id“).
- Na běžném Windows PC **Docker Desktop** a **LLVM** (`winget install LLVM.LLVM`). Na Macu Xcode, na Windows on ARM nic navíc.

Překladač stáhneš z GitHub Actions jako artefakt `WinPadTranslator-windows` nebo `WinPadTranslator-macos` (obsahuje i kompilátor). Na všech typech počítačů dává bajt po bajtu stejný výsledek.

## Další zdroje kódu (pro pokročilé)

Kromě map z iPadu umí překladač přidat kód i jinak, takže stačí méně kol:

- **Also find the game's code statically**: projde `.exe` hry a najde funkce předem. Obraz je větší.
- **PC drcov logs**: hra spuštěná na Windows PC pod DynamoRIO (`drrun -t drcov -- HRA.EXE`) zaznamená skoro všechen svůj kód najednou. U NFSU2 to byl hlavní skok rychlosti. Pokryje jen kód hry, ne Wine.

## Víc her v jedné aplikaci

Překladač si vede knihovnu her (záložka **Game library**, soubor `~/WinPadTranslator/library.json`). Výsledkem je jedna IPA s obrazy všech her, aplikace se pak jmenuje WinPad.

1. Přidej hry: v okně tlačítkem, nebo
   ```
   winpad-translator --library --add-game ~/Games/NFSU2 --add-game ~/Games/JinaHra
   ```
2. Po hraní zkopíruj z iPadu `codemap/new` jako obvykle. Mapy všech her jsou v jedné složce; překladač si je rozdělí podle toho, ze které složky hry na iPadu pocházejí.
3. Přelož:
   ```
   winpad-translator --library --build --ipad-maps ~/z-ipadu/new \
       --ipa WinPadWine.ipa --out-ipa WinPad.ipa
   ```
   Znovu se překládají jen hry, které mají nové mapy.
4. Nainstaluj `WinPad.ipa` přes starou aplikaci. Hry v Documents zůstanou.

Jako `--ipa` dávej vždycky IPA z CI, ne tu, kterou vyrobila knihovna. Hra odebraná ze seznamu (`--remove-game`) pak z další IPA zmizí. Hra, kterou jsi ještě nehrál, nemá mapy ani obraz a běží v interpretu.

## Bez nové instalace (Mac, experimentální)

Spustitelný kód na iPadu musí být podepsaný, proto nový obraz obvykle znamená novou IPA. Na Macu jde obraz podepsat rovnou do složky hry:

- V okně zaškrtni **Sign into game folder**, nebo v příkazové řádce `--sign-identity auto`.
- Překladač obraz podepíše vývojářskou identitou z klíčenky a uloží ho do složky hry jako `fexaot.dylib` s `fexaot.build` (pro který build aplikace je).
- Složku hry zkopíruj na iPad. Aplikace obraz načte ze složky, pokud sedí build aplikace i podpis (aplikace musí být nainstalovaná z Xcode stejným Apple ID). Jinak použije obraz z IPA.

Na skutečném iPadu to zatím ověřené není.

## Vlastní název aplikace

Pole **App name** (`--app-name "Moje Hra"`) změní název pod ikonou. Identita aplikace zůstává, nová IPA tedy dál nahrazuje WinPad Wine a hry zůstanou. Podrobně v kroku 5 Word návodu.

## Příkazová řádka

Bez argumentů se otevře okno. Všechny volby vypíše `winpad-translator --help`, nejčastější:

| Volba | Co dělá |
|---|---|
| `--game SLOŽKA` | složka hry |
| `--ipad-maps SLOŽKA` | code mapy z iPadu (lze opakovat) |
| `--drcov LOG`, `--discover` | další zdroje kódu |
| `--ipa`, `--out-ipa` | vstupní IPA z CI, výstupní IPA s obrazem |
| `--out SLOŽKA` | kam uložit samotný obraz |
| `--xcode-project SLOŽKA` | vložit obraz do Xcode projektu místo IPA |
| `--backend` | kde běží kompilátor: `simulator`, `native`, `wine`, `docker` |
| `--app-name` | název pod ikonou |
| `--sign-identity` | podepsat obraz do složky hry (Mac) |
| `--library`, `--add-game`, `--remove-game`, `--list-games`, `--build` | knihovna her |
| `--rebuild` | přeložit všechno znovu (po nové verzi FEXu) |

Technické detaily (backendy, CPU funkce iPadu) jsou v [tools/winpad-translator/README.md](../../tools/winpad-translator/README.md).

Dál: [Když něco nejde](reseni-problemu.md)
