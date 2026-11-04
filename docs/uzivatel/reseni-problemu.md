# Když něco nejde

Při každém problému se hodí `wine.log` (Soubory → WinPad Wine), případně `wine.log.crashed`. V aplikaci ho najdeš i v Nastavení → Diagnostika → Poslední log.

| Příznak | Pravděpodobná příčina | Co s tím |
|---|---|---|
| Aplikace spadne hned po instalaci | Instalátor nepodepsal všechny knihovny v aplikaci | Zkus jiný instalátor (Sideloadly ↔ AltStore), nebo instalaci z Xcode |
| Aplikace po týdnu nejde spustit | Vypršel 7denní podpis bezplatného Apple ID | Obnov v AltStore/SideStore, nebo nainstaluj znovu |
| Hra je hodně pomalá | Její kód ještě není přeložený a běží v interpretu | Normální v prvním kole. Zkopíruj `codemap/new` a přelož ([Překlad her](preklad-her.md)) |
| Hra je pomalá i po překladu, jen v nových částech | Do těch částí jsi v minulém kole nedošel | Další kolo |
| Hra je pomalá jen při spuštění z plochy, z Xcode ne (nebo naopak) | Kód, který si hra vyrábí za běhu, leží pokaždé jinde | Odehraj kolo právě tím způsobem, jakým budeš hrát, a přelož |
| Start trvá minuty | Spouštíš z Xcode s debuggerem | Spouštěj z plochy iPadu |
| Překladač hlásí nesouhlasící „file id“ | Jiná verze hry na počítači než na iPadu, nebo IPA z jiného buildu | Použij stejnou složku hry a IPA, která na iPadu běží |
| Hra nenajde svá data | Složka hry není celá, nebo je program jinde | Zkopíruj celou složku; v `winpad.json` uveď správné `exe` |
| Po hře nejde spustit další | Wine běží jednou za spuštění aplikace | Zavři aplikaci v přepínači a spusť ji znovu |
| Hra hlásí chybějící disk nebo ochranu | DRM (SecuROM a podobně) | Použij verzi bez DRM (např. GOG) |
| Černá obrazovka, ale zvuk hraje | Dřív chyba zobrazení (opraveno v aktuální verzi) | Nainstaluj aktuální IPA; když přetrvá, pošli `wine.log` |
| Ovladač na obrazovce chybí | Je připojený herní ovladač, nebo je dotykové ovládání vypnuté | Nastavení → Ovládání → Dotykové ovládání |
| Žádný zvuk | Starší verze aplikace (tichý režim) | Aktuální verze hraje i v tichém režimu |

## Hlášení chyby

Do issue nebo do vlákna pošli:

1. co jsi dělal a co se stalo,
2. `wine.log` (případně `wine.log.crashed`),
3. model iPadu a verzi iPadOS,
4. odkud aplikace je (artefakt a běh CI, nebo verze z překladače).

Nikdy neposílej soubory hry, obraz hry ani IPA s obrazem.
