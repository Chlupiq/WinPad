# Wine for arm64 Linux, which runs FEX's offline compiler (an aarch64 Windows
# program) for WinPad Translator's docker backend. On an x86-64 computer Docker
# runs this arm64 image emulated (Docker Desktop, or QEMU's binfmt handlers); on
# an arm64 one natively. The translator picks the distribution (compile.py,
# docker_wine_base): Debian's Wine 10 natively, as Ubuntu 24.04's Wine 9 hangs
# making its prefix on arm64 CPUs with pointer authentication (its unwinder does
# not know DW_CFA_AARCH64_negate_ra_state and loops for ever on wineboot's first
# fault); Ubuntu's Wine 9 under QEMU, where Wine 10's wineboot never returns.
ARG WINE_BASE=debian:trixie
FROM ${WINE_BASE}
RUN apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends wine64 wine \
    && rm -rf /var/lib/apt/lists/*
# wineboot is done when it returns; the services it started (explorer, plugplay...) would keep
# wineserver -w waiting for ever, so they are stopped, which also writes the registry out.
RUN WINEDEBUG=-all WINEDLLOVERRIDES=mscoree,mshtml= timeout 900 wineboot -i && wineserver -k && sleep 2
