# Wine for arm64 Linux, which runs FEX's offline compiler (an aarch64 Windows
# program) for WinPad Translator's docker backend. On an x86-64 computer Docker
# runs this arm64 image emulated (Docker Desktop, or QEMU's binfmt handlers).
FROM ubuntu:24.04
RUN apt-get update -q && DEBIAN_FRONTEND=noninteractive apt-get install -y -q --no-install-recommends wine \
    && rm -rf /var/lib/apt/lists/*
RUN WINEDEBUG=-all wineboot -i && wineserver -w
