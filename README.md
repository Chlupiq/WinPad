# WinPad

Windows games on iPad and iPhone **without JIT**: no debugger, StikDebug, VPN or pairing.

WinPad builds on [Madeira](https://github.com/willfaust/Madeira) (Wine ARM64EC + FEX + DXMT) and adds an ahead-of-time mode. The game's x86 code and Wine's PE modules are translated or packaged in advance into signed Mach-O libraries, so nothing has to be generated at runtime. Code missing from the translation runs in FEX's IR interpreter and is recorded, so the next translation has it.

Status: 32-bit Direct3D 9 games run on a real iPad without JIT (Need for Speed Underground 2: menu at 60 FPS). WinPad Translator turns any game's recorded code into its image on a Mac or a PC.

**Documentation (Czech): [docs/README.md](docs/README.md)**, for users (installing the app, adding and translating games) and for developers (architecture, AOT pipeline, build and CI, patches, project status). The original plan is in [PLAN.md](PLAN.md).

## License
GPL-3.0-or-later (a derivative work of Madeira, including the Madeira Converter Exception).
