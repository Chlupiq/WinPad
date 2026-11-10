#!/bin/sh
# Downloads Microsoft's DirectX End-User Runtimes (June 2010) installer, the one the app
# downloads (Redist.h), and takes its 32-bit DLLs out with Redist.c (redist-test.c).
# Usage: sh tests/wine-app/redist-test.sh WORKDIR
set -eu
here=$(cd "$(dirname "$0")" && pwd)
work=${1:?usage: redist-test.sh WORKDIR}
mkdir -p "$work"
sh "$here/fetch-mspack.sh" "$work/mspack"
for c in "$work"/mspack/*.c; do
    cc -O1 -w -I"$work/mspack" -c "$c" -o "${c%.c}.o"
done
cc -O1 -Wall -Werror -I"$here" -I"$work/mspack" "$here/redist-test.c" "$here/Redist.c" "$work"/mspack/*.o \
    -o "$work/redist-test"
url=$("$work/redist-test" --url)
echo "Downloading $url"
curl -fsSL --retry 3 -o "$work/directx_redist.exe" "$url"
ls -l "$work/directx_redist.exe"
rm -rf "$work/dlls"
mkdir -p "$work/dlls"
"$work/redist-test" "$work/directx_redist.exe" "$work/dlls"
ls "$work/dlls" | head -100
