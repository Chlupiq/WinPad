# Přehled

## Co je WinPad

WinPad je aplikace pro iPad (a iPhone), která spouští Windows hry. Skládá se ze dvou částí:

- **WinPad Wine** na iPadu. Má knihovnu her ve stylu herní konzole, spouští hry přes Wine a překládá jejich x86 kód na ARM.
- **WinPad Translator** na počítači (Mac nebo Windows PC). Z toho, co hra na iPadu spustila, udělá přeložený kód (AOT obraz) a vloží ho do aplikace.

Hra se tak rozjíždí v kolech. Napoprvé běží pomalu, protože všechno jde přes interpret. Po každém kole „hrát, zkopírovat code mapy, přeložit, nainstalovat“ je přeložené víc a hra běží rychleji. Need for Speed Underground 2 takhle došlo na plynulé menu (60 FPS) a závod kolem 44–50 FPS na iPadu Air M2.

## Proč bez JITu

iPadOS nedovolí běžné aplikaci vyrábět spustitelný kód za běhu (JIT). Emulátory to obcházejí připojeným debuggerem (StikDebug a podobně), což je křehké a od iPadOS 26 s TXM to nejde ani pod Xcode. WinPad proto všechen kód, který se spouští, dodá předem a podepsaný:

- moduly Wine jsou zabalené jako podepsané knihovny (dyliby),
- x86 kód hry je přeložený na Macu nebo PC do knihovny `fexaot-<hra>.dylib`,
- co v ní chybí, provede interpret, který žádný kód nevyrábí, jen ho „čte a dělá“.

## Co potřebuješ

| Co | Proč |
|---|---|
| iPad nebo iPhone s Apple Silicon (ověřeno na iPadu Air 13" M2, iPadOS 27) | Hry běží na šířku, iPhone má menší knihovnu |
| Počítač: Mac, běžné Windows PC (s Docker Desktop) nebo Windows on ARM | Na něm běží WinPad Translator |
| Apple ID | Podpis aplikace při instalaci. Zdarma stačí, podpis se pak obnovuje každých 7 dní |
| Instalátor: Sideloadly, AltStore, SideStore, nebo Xcode na Macu | Nahraje aplikaci na iPad |
| Hra, kterou vlastníš | 32bitová Windows hra bez DRM (např. z GOG) |

Aplikace není v App Store a nebude. App Store nedovoluje spouštět kód, který není součástí schválené aplikace, a překlad je pro každou hru jiný. Proto „ROM styl“: každý si přeloží své hry na svém počítači a aplikaci si podepíše vlastním Apple ID.

## Pravidla

- Hru, code mapy, přeložené obrazy ani IPA s obrazem hry nikam nenahrávej (GitHub, CI, sdílení). Obsahují kód hry.
- Hry s ochranou proti kopírování (SecuROM, StarForce apod.) nepoběží a WinPad je obcházet nebude. Použij verzi bez DRM.

## Co (zatím) nepůjde

- **64bitové hry.** WinPad zatím umí jen 32bitové x86 hry (přes WoW64).
- **Hry, které si kód vyrábí za běhu ve velkém**: .NET/XNA/Mono, Java, LuaJIT a jiné skriptovací JITy. Malé kusy kódu vyrobené za běhu (např. zvukový systém EA v NFSU2) WinPad umí zachytit a přeložit podle obsahu.
- **Anti-cheat a online DRM.**
- **Direct3D 10/11/12.** Ověřený je Direct3D 9 (přes DXMT a Metal). DXMT umí i D3D10/11, ale ve WinPadu to zatím nikdo nezkoušel.
- **Jiné hry než NFSU2** zatím nikdo neprošel celé. Překladač je obecný a v CI ověřený, ale u nové hry se může ukázat něco nového.

Dál: [Aplikace WinPad na iPadu](aplikace.md) · [Překlad her](preklad-her.md)
