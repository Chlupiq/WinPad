#!/bin/sh
# Builds OpenGL for 32-bit Windows programs on iOS into
# WORK_DIR/opengl-SDK/libwinpad_opengl.a, which link-host.sh links:
#
#   - the unix side of Wine's opengl32.dll (dlls/opengl32/unix_wgl.c and the
#     generated unix_thunks.c), with its 32-bit (wow64) call table rewritten
#     for Madeira's guest window by wow64-ptrs.py: a pointer a 32-bit program
#     hands over is a guest address, B + it on the host. Its tables are what
#     opengl32_table.c gives Madeira's ntdll (patches/madeira/0012);
#   - gl4es (https://github.com/ptitSeb/gl4es, MIT), which turns desktop
#     OpenGL 1.x/2.x into OpenGL ES 2 calls, as a static library with no
#     loader of its own (NOEGL, NOX11);
#   - winpad_egl.m and gl4es-glue.c: the EGL win32u (patches/wine/0004) draws
#     through, on EAGL and Apple's OpenGL ES.
#
# The i386 opengl32.dll (the PE side) comes from tests/wine-i386/build.sh, the
# window side of win32u from tests/wine-loader/build-win32u.sh with the patch.
#
# Usage: build.sh WORK_DIR SDK   (SDK: iphoneos or iphonesimulator)
# WORK_DIR must hold the Wine tree tests/wine-loader/build.sh fetched and
# configured, with its generated headers (build-win32u.sh makes them).
set -eu

here=$(cd "$(dirname "$0")" && pwd)
root=$(cd "$here/../.." && pwd)
work=$1
sdk_name=$2
madeira="$work/madeira"
wine="$madeira/wine"
out="$work/opengl-$sdk_name"
GL4ES_REPO=https://github.com/ptitSeb/gl4es.git
GL4ES_COMMIT=8b1a3da5d2331d0f88b70be25963182d46eed857

case $sdk_name in
    iphoneos) target=arm64-apple-ios17.0 ;;
    iphonesimulator) target=arm64-apple-ios17.0-simulator ;;
    *) echo "unknown SDK $sdk_name" >&2; exit 2 ;;
esac
sdk=$(xcrun --sdk "$sdk_name" --show-sdk-path)
cc="xcrun -sdk $sdk_name clang -target $target -isysroot $sdk"
test -d "$sdk/System/Library/Frameworks/OpenGLES.framework" ||
    { echo "the $sdk_name SDK has no OpenGLES.framework" >&2; exit 1; }

rm -rf "$out"
mkdir -p "$out/obj" "$out/src"
failed=0
compile() {  # SOURCE NAME FLAGS...
    c_src=$1 c_name=$2
    shift 2
    # shellcheck disable=SC2086 # $cc is a list
    if ! $cc -O2 -fPIC -fno-stack-protector -fno-strict-aliasing "$@" -c "$c_src" -o "$out/obj/$c_name.o" \
        2>"$out/obj/$c_name.err"; then
        echo "failed: $c_name" >&2
        sed -n '1,20p' "$out/obj/$c_name.err" >&2
        failed=$((failed + 1))
    fi
}

# gl4es, the sources its CMake build takes for a static library outside Linux.
g="$work/gl4es"
if [ "$(git -C "$g" rev-parse HEAD 2>/dev/null || true)" != "$GL4ES_COMMIT" ]; then
    rm -rf "$g"
    git init -q "$g"
    git -C "$g" fetch -q --depth 1 "$GL4ES_REPO" "$GL4ES_COMMIT"
    git -C "$g" checkout -q FETCH_HEAD
fi
gl4es_flags="-w -DNOX11 -DNOEGL -DSTATICLIB -DNO_GBM -DNO_LOADER -DNO_INIT_CONSTRUCTOR -DDEFAULT_ES=2
    -fvisibility=hidden -I$g/include -I$g/src -I$g/src/util -I$g/src/glx"
# Mach-O has no symbol aliases: directstate.c's AliasDecl lines become calls.
python3 -I "$here/no-aliases.py" "$g/src/gl/directstate.c" "$g/src/gl/directstate_ios.c"
n=0
for f in $(sed -n '/^SET(GL_SRC/,/^)/p' "$g/src/CMakeLists.txt" | grep -o 'gl/[a-z_/0-9]*\.c' |
    sed 's|^gl/directstate\.c$|gl/directstate_ios.c|') glx/hardext.c; do
    # shellcheck disable=SC2086
    compile "$g/src/$f" "gl4es_$(echo "$f" | tr '/' '_' | sed 's/\.c$//')" $gl4es_flags
    n=$((n + 1))
done
echo "gl4es: $n files"
# shellcheck disable=SC2086
compile "$here/gl4es-glue.c" gl4es-glue $gl4es_flags
compile "$here/winpad_egl.m" winpad_egl -fno-objc-arc -fvisibility=hidden -Wall -Wno-unused-function
cp "$g/LICENSE" "$out/gl4es-LICENSE"

# The unix side of opengl32, from a copy: the 32-bit thunks with guest pointers
# made host pointers, and the few that unix_wgl.c handles itself. get_teb64:
# the caller is the current thread, its TEB is the host's NtCurrentTeb().
cp "$wine"/dlls/opengl32/*.h "$out/src/"
python3 -I "$here/wow64-ptrs.py" "$wine/dlls/opengl32/unix_thunks.c" "$out/src/unix_thunks.c"
sed -e 's/strcpy( UlongToPtr(\*wow64_str), str )/strcpy( ios_wow_host_ptr(*wow64_str), str )/' \
    -e 's/\*wow_ptr = PtrToUlong( buffer->map_ptr )/*wow_ptr = ios_wow_guest_ptr32( buffer->map_ptr )/' \
    -e 's/\.formats = ULongToPtr(params32->formats)/.formats = ios_wow_host_ptr(params32->formats)/' \
    "$wine/dlls/opengl32/unix_wgl.c" >"$out/src/unix_wgl.c"
for s in 'ios_wow_host_ptr(\*wow64_str)' 'ios_wow_guest_ptr32( buffer->map_ptr )' 'ios_wow_host_ptr(params32->formats)'; do
    grep -q "$s" "$out/src/unix_wgl.c" || { echo "unix_wgl.c: no $s after the rewrite" >&2; exit 1; }
done
python3 -I - "$out/src/unix_private.h" <<'EOF'
import sys
p = sys.argv[1]
s = open(p).read()
old = '''static inline TEB *get_teb64( ULONG teb32 )
{
    TEB32 *teb32_ptr = ULongToPtr( teb32 );
    return (TEB *)((char *)teb32_ptr + teb32_ptr->WowTebOffset);
}'''
assert old in s, 'get_teb64 changed upstream'
s = s.replace(old, '''static inline TEB *get_teb64( ULONG teb32 )
{
    return NtCurrentTeb();  /* WinPad: the 32-bit TEB is a guest address here */
}''')
open(p, 'w').write(s)
EOF
ntdll_flags="-fvisibility=hidden -Wno-implicit-function-declaration -Wno-int-conversion
    -include $wine/build-macos/include/config.h -include $madeira/build/ntdll-unix/shims/wine_ios_exit.h
    -I$madeira/build/ntdll-unix/shims -I$out/src -I$wine/build-macos/include -I$wine/include
    -D__WINESRC__ -D_ACRTIMP= -DWINBASEAPI= -DWINE_UNIX_LIB -DWINE_IOS=1
    -D__wine_unix_call_funcs=opengl32_unix_call_funcs -D__wine_unix_call_wow64_funcs=opengl32_unix_call_wow64_funcs"
# shellcheck disable=SC2086
compile "$out/src/unix_wgl.c" opengl32_unix_wgl $ntdll_flags
# shellcheck disable=SC2086
compile "$out/src/unix_thunks.c" opengl32_unix_thunks $ntdll_flags
compile "$here/opengl32_table.c" opengl32_table -Wall

[ "$failed" = 0 ] || { echo "$failed files failed" >&2; exit 1; }
rm -f "$out/libwinpad_opengl.a"
xcrun ar rcs "$out/libwinpad_opengl.a" "$out"/obj/*.o
echo "$out/libwinpad_opengl.a: $(wc -c <"$out/libwinpad_opengl.a" | tr -d ' ') bytes"
