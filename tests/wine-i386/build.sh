#!/bin/sh
# Builds Wine's 32-bit x86 (i386) PE modules, the ones a WoW64 process loads
# from i386-windows, the way Madeira's build/wine-i386/build.sh does: a separate
# build-i386 tree of Madeira's Wine, configured with --enable-archs=i386, and
# make of each module's i386-windows target. The PE side needs no MinGW: Wine
# compiles it with LLVM clang for i686-windows and links it with lld.
# Also builds tests/wine-i386/hello.c, a 32-bit console program that only
# imports kernel32, tests/wine-i386/window.c, one with a window (user32,
# gdi32), tests/wine-i386/imports.c, which imports what a game imports, and
# tests/wine-i386/guard.c, stack growth and guard pages.
#
# Usage: build.sh WORK_DIR [MODULE...]
# (default: ntdll kernelbase kernel32, what a program with a window needs and
# the import closure of tests/wine-i386/imports.c, then every other i386 DLL
# Wine has that can work here (WINE_I386_EXTRA=all; =common: only what games of
# the 2000s usually need, D3DX9, XInput, XAudio2/XACT, the Visual C++ runtimes,
# DirectMusic, DirectPlay...; =0: none), so a game finds them without a build
# of its own. Whatever any built module imports is built too, until nothing is
# missing.)
# WORK_DIR must hold the Wine tree tests/wine-loader/build.sh fetched.
# Needs LLVM clang, llvm-dlltool and lld (Homebrew llvm, lld), bison and flex.
# Output: WORK_DIR/i386-windows/*.dll, hello.exe, nodep.exe, hook.exe, rtcode.exe, unaligned.exe, guard.exe, simd.exe, cwd.exe, window.exe, imports.exe and
# casetest.dll (imports.exe's own DLL).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
work=$1
shift
# The default set is what a program with a window needs, then what the DLLs a
# game imports (DirectInput, DirectSound, DirectDraw, winmm, Winsock, TAPI,
# netapi32, shell32 and shfolder) import in turn: their whole import closure,
# or the loader stops at the first missing one (c0000135). d3d9 is not here.
# mmdevapi is no import but the COM class dsound creates for its device;
# cryptbase and cryptsp are where advapi32 forwards its SystemFunction* exports
# (RtlGenRandom, which mmdevapi reaches; an unresolved forward aborts the call).
# dpnhpast (DirectPlay NAT helper) is no import either: Mafia loads it at start and
# stops with "Init error #4214 Unsupported" without it.
[ $# -gt 0 ] || set -- ntdll kernelbase kernel32 win32u gdi32 user32 advapi32 sechost msvcrt ucrtbase imm32 \
    dinput8 dinput dsound ddraw winmm ws2_32 tapi32 netapi32 shfolder shell32 \
    comctl32 ole32 combase coml2 oleaut32 rpcrt4 hid setupapi cfgmgr32 wined3d opengl32 \
    msacm32 iphlpapi dnsapi nsi netutils shlwapi shcore version mmdevapi \
    cryptbase cryptsp dpnhpast
wine="$work/madeira/wine"
b="$wine/build-i386"
out="$work/i386-windows"
jobs=$(sysctl -n hw.ncpu 2>/dev/null || nproc)

if [ ! -f "$b/config.status" ]; then
    mkdir -p "$b"
    (cd "$b" && ../configure -q --enable-archs=i386 --without-x --without-freetype \
        --without-gnutls --without-vulkan --without-opencl --without-gstreamer --without-sdl \
        --without-cups --without-sane --without-krb5 --without-netapi --without-pcap \
        --without-usb --without-v4l2 --without-pulse --without-alsa --without-oss \
        --without-coreaudio --without-capi --without-gphoto --without-inotify \
        --without-dbus --without-udev --without-unwind --disable-tests \
        >"$work/configure-i386.log" 2>&1) || {
        tail -40 "$work/configure-i386.log" >&2
        exit 1
    }
fi

# Only with the default set. Names Wine does not have are left out. Their
# debug information is stripped (the app would carry it for every game); the
# default set stays as it is, so the AOT images made for those files still match.
extra=
if [ "${WINE_I386_EXTRA:-all}" != 0 ] && [ "$*" = "$(echo ntdll kernelbase kernel32 win32u gdi32 user32 advapi32 sechost msvcrt ucrtbase imm32 \
    dinput8 dinput dsound ddraw winmm ws2_32 tapi32 netapi32 shfolder shell32 \
    comctl32 ole32 combase coml2 oleaut32 rpcrt4 hid setupapi cfgmgr32 wined3d opengl32 \
    msacm32 iphlpapi dnsapi nsi netutils shlwapi shcore version mmdevapi \
    cryptbase cryptsp dpnhpast)" ]; then
    # WINE_I386_EXTRA=all (the default): every i386 DLL Wine builds, but not what cannot work
    # here: Direct3D 8/9 (DXMT's, build-d3d9.sh), Direct3D 10-12, DXGI, Vulkan and OpenCL
    # (Wine draws those through OpenGL/Vulkan), Wine's own audio, display and device drivers
    # (the app's unix side has its own) and 16-bit modules. WINE_I386_EXTRA=common: the list below.
    if [ "${WINE_I386_EXTRA:-all}" = all ]; then
        for t in $(grep -oE "^dlls/[^/ :]+/i386-windows/[^/ :]+\.(dll|drv|acm|ax|ocx|cpl)" "$b/Makefile" | sort -u); do
            m=${t#dlls/}
            m=${m%%/*}
            case $m in
            d3d8 | d3d9 | d3d10* | d3d11 | d3d12* | dxgi | vulkan-1 | winevulkan | opencl | wine*.drv | \
                *.sys | *16 | *.vxd | *test*) continue ;;
            esac
            case " $* $extra " in *" $m "*) continue ;; esac
            extra="$extra $m"
        done
    else
        for m in d3dx9_24 d3dx9_25 d3dx9_26 d3dx9_27 d3dx9_28 d3dx9_29 d3dx9_30 d3dx9_31 d3dx9_32 \
            d3dx9_33 d3dx9_34 d3dx9_35 d3dx9_36 d3dx9_37 d3dx9_38 d3dx9_39 d3dx9_40 d3dx9_41 d3dx9_42 \
            d3dx9_43 d3dcompiler_43 d3dcompiler_47 d3dxof \
            xinput1_1 xinput1_2 xinput1_3 xinput1_4 xinput9_1_0 \
            xaudio2_0 xaudio2_1 xaudio2_2 xaudio2_3 xaudio2_4 xaudio2_5 xaudio2_6 xaudio2_7 xaudio2_8 xaudio2_9 \
            x3daudio1_0 x3daudio1_1 x3daudio1_2 x3daudio1_3 x3daudio1_4 x3daudio1_5 x3daudio1_6 x3daudio1_7 \
            xapofx1_1 xapofx1_2 xapofx1_3 xapofx1_4 xapofx1_5 \
            xactengine2_0 xactengine2_4 xactengine2_7 xactengine2_9 xactengine3_0 xactengine3_1 xactengine3_2 \
            xactengine3_3 xactengine3_4 xactengine3_5 xactengine3_6 xactengine3_7 \
            msvcp60 msvcp70 msvcp71 msvcp80 msvcp90 msvcp100 msvcp110 msvcp120 msvcp140 msvcp140_1 \
            msvcr70 msvcr71 msvcr80 msvcr90 msvcr100 msvcr110 msvcr120 vcruntime140 concrt140 msvcrt20 msvcrt40 \
            dmime dmusic dmloader dmsynth dswave dmband dmcompos dmstyle dmscript dsdmo msdmo \
            dplayx dpnet dpwsockx dpvoice amstream devenum quartz mf mfplat mfreadwrite msvfw32 avifil32 \
            mciavi32 mciseq mciwave midimap l3codeca.acm imaadp32.acm msadp32.acm msgsm32.acm \
            wsock32 winhttp wininet urlmon mswsock crypt32 bcrypt secur32 wintrust imagehlp dbghelp psapi \
            uxtheme comdlg32 winspool.drv gdiplus windowscodecs msimg32 oledlg olepro32 oleacc \
            riched20 riched32 msxml3 msxml6 mpr userenv dwmapi powrprof wtsapi32 glu32 dxdiagn ddrawex; do
            [ -d "$wine/dlls/$m" ] && extra="$extra $m"
        done
    fi
    set -- "$@" $extra
fi
# WinPad's change to the i386 ntdll, see the patch header. The tree may come
# from a cache with the patch already applied.
p="$here/../../patches/wine/0003-i386-ntdll-wow64-bop.patch"
git -C "$wine" apply -R --check "$p" 2>/dev/null || git -C "$wine" apply "$p"

# The i386 PE target of module M (dlls/M/i386-windows/M.dll, .drv, .acm...), or nothing.
target_of() {
    grep -oE "^dlls/$1/i386-windows/[^/ :]+\.(dll|drv|acm|ax|ocx|cpl)" "$b/Makefile" | sort -u | head -1
}
targets=
for m in "$@"; do
    t=$(target_of "$m")
    [ -n "$t" ] || { echo "no i386 target for $m in $b/Makefile" >&2; exit 2; }
    targets="$targets $t"
done
echo "i386 modules:$targets"
: >"$work/make-i386.log"
make_targets() {
    # shellcheck disable=SC2086 # a list of make targets
    if ! make -C "$b" -j"$jobs" "$@" >>"$work/make-i386.log" 2>&1; then
        grep -E 'error|Error' "$work/make-i386.log" | head -40 >&2
        exit 1
    fi
}
# shellcheck disable=SC2086 # a list of make targets
make_targets $targets

rm -rf "$out"
mkdir -p "$out"
for t in $targets; do
    cp "$b/$t" "$out/"
done
# Whatever the modules import, until nothing is missing: the loader stops at the
# first missing DLL (c0000135). Direct3D 8/9 come from DXMT (build-d3d9.sh), and
# Wine's own Direct3D 10-12 and DXGI draw through OpenGL, which iOS has not;
# api-ms-win-* and ext-ms-win-* are API sets ntdll resolves.
while :; do
    more=
    for f in "$out"/*; do
        llvm-objdump -p "$f" 2>/dev/null | sed -n 's/^ *DLL Name: *//p'
    done | tr 'A-Z' 'a-z' | sort -u >"$work/i386-imports.txt"
    while read -r dll; do
        [ -e "$out/$dll" ] && continue
        m=${dll%.dll}
        case $m in
        api-ms-win-* | ext-ms-win-* | d3d8 | d3d9 | d3d10* | d3d11 | d3d12 | dxgi) continue ;;
        esac
        t=$(target_of "$m")
        [ -n "$t" ] || { echo "i386: nothing builds $dll (imported by a built module)"; continue; }
        case " $targets $more " in *" $t "*) continue ;; esac
        more="$more $t"
    done <"$work/i386-imports.txt"
    [ -n "$more" ] || break
    echo "i386 modules they import:$more"
    # shellcheck disable=SC2086 # a list of make targets
    make_targets $more
    for t in $more; do
        cp "$b/$t" "$out/"
    done
    targets="$targets $more"
    extra="$extra $(for t in $more; do n=${t##*/}; echo "${n%.*}"; done)"
done
# Debug information only of what the default set did not have before (see above).
for m in $extra; do
    for f in "$out/$m".*; do
        [ -f "$f" ] && llvm-strip --strip-debug "$f"
    done
done
[ -z "$extra" ] || echo "i386: $(echo $extra | wc -w | tr -d ' ') modules for games beyond the base set, $(du -sh "$out" | cut -f1) in all"

# The test program: i686 PE, entry point of its own, kernel32 import library
# from this tree.
implib() {
    l=$(grep -oE "^dlls/$1/[^ :]*lib$1\\.a" "$b/Makefile" | sort -u | head -1)
    [ -n "$l" ] || { echo "no $1 import library target in $b/Makefile" >&2; exit 2; }
    make -C "$b" "$l" >>"$work/make-i386.log" 2>&1 || { tail -20 "$work/make-i386.log" >&2; exit 1; }
    echo "$b/$l"
}
kernel32=$(implib kernel32)
clang -target i686-windows -O2 -nostdlib -fno-builtin -ffreestanding \
    -Wl,-entry:start -Wl,-subsystem:console \
    "$here/hello.c" "$kernel32" -o "$out/hello.exe" -fuse-ld=lld
# The same program in an image without NX_COMPAT, as a game of that time is:
# the 32-bit ntdll's loader then turns DEP off for the process.
clang -target i686-windows -O2 -nostdlib -fno-builtin -ffreestanding \
    -Wl,-entry:start -Wl,-subsystem:console -Wl,-nxcompat:no \
    "$here/hello.c" "$kernel32" -o "$out/nodep.exe" -fuse-ld=lld
# VirtualProtect around a patch of its own code, as a hook installer does
# (kernel32 only).
clang -target i686-windows -O2 -nostdlib -fno-builtin -ffreestanding \
    -Wl,-entry:start -Wl,-subsystem:console \
    "$here/hook.c" "$kernel32" -o "$out/hook.exe" -fuse-ld=lld
# x86 code copied into memory of its own and made executable there, as a
# game's sound system loads its modules (kernel32 only).
clang -target i686-windows -O2 -nostdlib -fno-builtin -ffreestanding \
    -Wl,-entry:start -Wl,-subsystem:console \
    "$here/rtcode.c" "$kernel32" -o "$out/rtcode.exe" -fuse-ld=lld
# 16- and 32-bit accesses at every byte offset, as a hook installer's pattern
# scan makes (kernel32 only).
clang -target i686-windows -O2 -nostdlib -fno-builtin -ffreestanding \
    -Wl,-entry:start -Wl,-subsystem:console \
    "$here/unaligned.c" "$kernel32" -o "$out/unaligned.exe" -fuse-ld=lld
# Stack growth and guard pages (kernel32 only); the image asks for an 8 MB
# stack, as a game's does.
clang -target i686-windows -O2 -nostdlib -fno-builtin -ffreestanding \
    -Wl,-entry:start -Wl,-subsystem:console -Wl,-stack:8388608 \
    "$here/guard.c" "$kernel32" -o "$out/guard.exe" -fuse-ld=lld
# SIMD instructions whose results FEX's NoJIT interpreter has to match its
# JIT on (inline assembly; kernel32 only).
clang -target i686-windows -O2 -nostdlib -fno-builtin -ffreestanding \
    -Wl,-entry:start -Wl,-subsystem:console \
    "$here/simd.c" "$kernel32" -o "$out/simd.exe" -fuse-ld=lld
# A file read by a relative path, as a game reads its data.
clang -target i686-windows -O2 -nostdlib -fno-builtin -ffreestanding \
    -Wl,-entry:start -Wl,-subsystem:console \
    "$here/cwd.c" "$kernel32" -o "$out/cwd.exe" -fuse-ld=lld
# The program with a window, if this build has its modules.
if [ -f "$out/user32.dll" ] && [ -f "$out/gdi32.dll" ]; then
    user32=$(implib user32)
    gdi32=$(implib gdi32)
    clang -target i686-windows -O2 -nostdlib -fno-builtin -ffreestanding \
        -Wl,-entry:start -Wl,-subsystem:windows \
        "$here/window.c" "$kernel32" "$user32" "$gdi32" -o "$out/window.exe" -fuse-ld=lld
fi
# The program with a game's imports, if this build has their DLLs.
game_dlls="user32 advapi32 gdi32 winmm dinput8 ddraw ws2_32 shfolder shell32 tapi32 netapi32"
have=1
for m in $game_dlls dsound; do [ -f "$out/$m.dll" ] || have=; done
if [ -n "$have" ]; then
    libs=
    for m in $game_dlls; do libs="$libs $(implib "$m")"; done
    # Games import DirectSoundCreate by its ordinal, 1, not by name; Wine's
    # import library has it by name, so this one is made here.
    printf 'LIBRARY DSOUND.dll\nEXPORTS\nDirectSoundCreate@12 @1 NONAME\n' >"$work/dsound-ordinal.def"
    llvm-dlltool -m i386 -d "$work/dsound-ordinal.def" -l "$work/libdsound-ordinal.a"
    libs="$libs $work/libdsound-ordinal.a"
    # The program's own DLL, next to it (no entry point, no imports).
    clang -target i686-windows -O2 -nostdlib -fno-builtin -ffreestanding -shared \
        -Wl,-noentry -Wl,-implib:"$work/libcasetest.a" \
        "$here/casetest.c" -o "$out/casetest.dll" -fuse-ld=lld
    libs="$libs $work/libcasetest.a"
    # kernel32 last: its import library has winmm's time* functions too,
    # and they have to come from winmm, as in the game.
    # shellcheck disable=SC2086 # a list of import libraries
    clang -target i686-windows -O2 -nostdlib -fno-builtin -ffreestanding \
        -Wl,-entry:start -Wl,-subsystem:console \
        "$here/imports.c" $libs "$kernel32" -o "$out/imports.exe" -fuse-ld=lld
    # A game names some DLLs in capitals (USER32.dll, DINPUT8.dll) and the files
    # are lowercase, so the loader has to find them without regard to case. The
    # import table names are rewritten in place, same length.
    python3 -I - "$out/imports.exe" <<'PY'
import sys
path = sys.argv[1]
data = open(path, "rb").read()
for name in (b"user32.dll", b"advapi32.dll", b"gdi32.dll", b"dinput8.dll", b"casetest.dll"):
    old, new = b"\0" + name + b"\0", b"\0" + name[:-4].upper() + b".dll\0"
    if data.count(old) != 1:
        sys.exit(f"imports.exe: {name.decode()} is in it {data.count(old)} times, not once")
    data = data.replace(old, new)
open(path, "wb").write(data)
PY
fi
ls -l "$out"
for exe in "$out"/*.exe; do
    llvm-objdump -p "$exe" | grep -E 'Magic|DLL Name|Machine' || true
done
