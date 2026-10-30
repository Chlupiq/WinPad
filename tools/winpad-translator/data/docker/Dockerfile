# Wine for arm64 Linux, which runs FEX's offline compiler (an aarch64 Windows
# program) for WinPad Translator's docker backend. On an x86-64 computer Docker
# runs this arm64 image emulated (Docker Desktop, or QEMU's binfmt handlers); on
# an arm64 one natively. Debian's Wine 10: Ubuntu 24.04's Wine 9 hangs making its
# prefix on arm64 CPUs with pointer authentication (its unwinder does not know
# DW_CFA_AARCH64_negate_ra_state and loops for ever on wineboot's first fault),
# and under QEMU it faults where FEX creates its JIT core.
FROM debian:trixie
RUN apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends wine64 wine \
    && rm -rf /var/lib/apt/lists/*
# Under QEMU the CPU it emulates (EMULATED_CPU; the translator passes the same as QEMU_CPU when
# it runs the compiler): with QEMU's default one wineboot never returns.
ARG EMULATED_CPU=
# wineboot is done when it returns; the services it started (explorer, plugplay...) would keep
# wineserver -w waiting for ever, so they are stopped, which also writes the registry out.
RUN if [ -n "$EMULATED_CPU" ]; then export QEMU_CPU=$EMULATED_CPU; fi; \
    WINEDEBUG=-all WINEDLLOVERRIDES=mscoree,mshtml= timeout 900 wineboot -i && wineserver -k && sleep 2
