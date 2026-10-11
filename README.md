# WinPad

Windows games on iPad and iPhone **without JIT**: no debugger, StikDebug, VPN or pairing.

WinPad builds on [Madeira](https://github.com/willfaust/Madeira) (Wine ARM64EC + FEX + DXMT) and adds an ahead-of-time mode. The game's x86 code and Wine's PE modules are translated or packaged in advance into signed Mach-O libraries, so nothing has to be generated at runtime.

Status: **M0, plan**. See [PLAN.md](PLAN.md).

## License
GPL-3.0-or-later (a derivative work of Madeira, including the Madeira Converter Exception).
