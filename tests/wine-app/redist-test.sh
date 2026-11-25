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
# The import scan the app runs before a game starts (winpad_pe_imports): D3DX9 imports kernel32 (D3D9 it loads itself).
"$work/redist-test" --imports "$work/dlls/d3dx9_30.dll" | tee "$work/imports.txt"
grep -qix "kernel32.dll" "$work/imports.txt" || { echo "d3dx9_30.dll's imports lack kernel32.dll" >&2; exit 1; }

# Any Microsoft installer (winpad_redist_extract_dlls), as the app takes DLLs out of a game's own
# installers and out of the Visual C++ runtimes it downloads: 2010 (vc_red.cab inside the
# program) and 2022 (a WiX bundle with cabinets in cabinets) must give their DLLs; the older
# ones are only reported.
vc() {
    year=$1
    shift
    set -- $("$work/redist-test" --vc-url "$year") "$@"
    url=$1 sha=$2
    shift 2
    echo "Visual C++ $year: $url"
    curl -fsSL --retry 3 -o "$work/vc$year.exe" "$url"
    if [ "$sha" != - ]; then
        echo "$sha  $work/vc$year.exe" | sha256sum -c -
    fi
    rm -rf "$work/vc$year"
    mkdir -p "$work/vc$year"
    "$work/redist-test" --dlls "$work/vc$year.exe" "$work/vc$year" "$@"
    ls "$work/vc$year"
}
vc 2010 msvcr100.dll msvcp100.dll mfc100.dll mfc100u.dll
vc 2022 vcruntime140.dll msvcp140.dll mfc140.dll mfc140u.dll
for year in 2005 2008 2012 2013; do
    vc "$year" || echo "Visual C++ $year: no DLLs out of it (reported only)"
done
# The game's own DirectX folder: its *_x86.cab files, as DXSETUP has them next to it.
mkdir -p "$work/dxgame"
"$work/redist-test" --dlls "$work/directx_redist.exe" "$work/dxgame" d3dx9_43.dll xinput1_3.dll
