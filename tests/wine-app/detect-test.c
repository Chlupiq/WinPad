// SPDX-License-Identifier: MIT
// GameDetect.c's rules (detect-test.sh, CI): what import names mean, and real files: a
// program's header and imports, and installers.
#include "GameDetect.h"
#include "Redist.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static int failed;

static void expect(int ok, const char* what) {
  printf("%s: %s\n", ok ? "ok" : "FAILED", what);
  if (!ok) failed = 1;
}

static struct winpad_traits of(const char* const* dlls) {
  struct winpad_traits t = {0};
  for (; *dlls; dlls++) winpad_traits_add_import(&t, *dlls);
  return t;
}

static void add(const char* dll, void* ctx) {
  winpad_traits_add_import(ctx, dll);
}

int main(int argc, char** argv) {
  // One file: its header, the APIs its imports name and whether it is an installer.
  if (argc == 3 && !strcmp(argv[1], "--file")) {
    struct winpad_traits t = {0};
    char err[256], kind[32];
    const int pe = winpad_pe_header(argv[2], &t);
    if (!pe && winpad_pe_imports(argv[2], add, &t, err, sizeof(err))) fprintf(stderr, "%s\n", err);
    const int inst = winpad_installer_kind(argv[2], kind, sizeof(kind));
    printf("machine %#x subsystem %u os %u linker %u graphics %s uses %#x installer %s\n", t.machine, t.subsystem,
           t.os_major, t.linker_major, winpad_graphics_name(t.graphics), t.uses, inst > 0 ? kind : "no");
    return pe && inst <= 0;
  }
  {
    const char* d[] = {"KERNEL32.dll", "USER32.dll", "d3d9.dll", "DINPUT8.dll", "DSOUND.dll", "ddraw.dll", NULL};
    const struct winpad_traits t = of(d);
    expect(t.graphics == WINPAD_GFX_D3D9, "d3d9 wins over ddraw");
    expect((t.uses & WINPAD_USES_DINPUT) && (t.uses & WINPAD_USES_DSOUND) && (t.uses & WINPAD_USES_DDRAW),
           "dinput8, dsound and ddraw seen");
  }
  {
    const char* d[] = {"ddraw.dll", "WINMM.dll", "GDI32.dll", NULL};
    const struct winpad_traits t = of(d);
    expect(t.graphics == WINPAD_GFX_DDRAW && !(t.uses & (WINPAD_USES_DINPUT | WINPAD_USES_XINPUT)),
           "a DirectDraw game without DirectInput");
  }
  {
    const char* d[] = {"d3dx9_43.dll", "XINPUT1_3.dll", "PhysXLoader.dll", "MSVCR80.dll", NULL};
    const struct winpad_traits t = of(d);
    expect(t.graphics == WINPAD_GFX_D3D9, "d3dx9_43 means Direct3D 9");
    expect((t.uses & WINPAD_USES_XINPUT) && (t.uses & WINPAD_USES_PHYSX) && (t.uses & WINPAD_USES_D3DX) &&
               (t.uses & WINPAD_USES_VCRUNTIME),
           "xinput, PhysX, D3DX and Visual C++ seen");
  }
  {
    const char* d[] = {"dxgi.dll", "d3d11.dll", "steam_api64.dll", "mscoree.dll", NULL};
    const struct winpad_traits t = of(d);
    expect(t.graphics == WINPAD_GFX_D3D11, "dxgi + d3d11 is Direct3D 11");
    expect((t.uses & WINPAD_USES_STEAM) && (t.uses & WINPAD_USES_DOTNET), "Steam and .NET seen");
  }
  {
    const char* d[] = {"OPENGL32", "glide2x.dll", NULL};
    expect(of(d).graphics == WINPAD_GFX_OPENGL, "OpenGL wins over Glide, names without .dll");
  }
  {
    const char* d[] = {"d3d12.dll", "d3d11.dll", NULL};
    expect(of(d).graphics == WINPAD_GFX_D3D12, "Direct3D 12 is the newest");
  }
  {
    const char* d[] = {"kernel32.dll", "user32.dll", "gdi32.dll", NULL};
    expect(of(d).graphics == WINPAD_GFX_UNKNOWN && !of(d).uses, "a plain program names nothing");
  }
  // Files: PROGRAM EXPECT pairs, EXPECT a word of the line below (d3d11, 0x8664, wixburn,
  // no-installer) or "installer".
  for (int i = 1; i + 1 < argc; i += 2) {
    struct winpad_traits t = {0};
    char err[256], kind[32] = "", line[256];
    if (!winpad_pe_header(argv[i], &t)) winpad_pe_imports(argv[i], add, &t, err, sizeof(err));
    const int inst = winpad_installer_kind(argv[i], kind, sizeof(kind));
    snprintf(line, sizeof(line), " %#x %s %s ", t.machine, winpad_graphics_name(t.graphics), inst > 0 ? kind : "no-installer");
    char want[64], what[512];
    snprintf(want, sizeof(want), " %s ", argv[i + 1]);
    snprintf(what, sizeof(what), "%s is %s (%s)", argv[i], argv[i + 1], line);
    // "installer": any kind of one.
    expect(!strcmp(argv[i + 1], "installer") ? inst > 0 : strstr(line, want) != NULL, what);
  }
  return failed;
}
