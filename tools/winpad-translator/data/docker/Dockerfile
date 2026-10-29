# Wine for arm64 Linux, which runs FEX's offline compiler (an aarch64 Windows
# program) for WinPad Translator's docker backend. On an x86-64 computer Docker
# runs this arm64 image emulated (Docker Desktop, or QEMU's binfmt handlers).
FROM ubuntu:24.04
RUN apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends wine \
    && rm -rf /var/lib/apt/lists/*
# wineboot is done when it returns; the services it started (explorer, plugplay...) would keep
# wineserver -w waiting for ever, so they are stopped, which also writes the registry out.
RUN WINEDEBUG=-all WINEDLLOVERRIDES=mscoree,mshtml= wineboot -i && wineserver -k && sleep 2
