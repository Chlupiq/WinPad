// SPDX-License-Identifier: MIT
// GameDetect.h: a game's PE header, the APIs its imports name, and installers.
#include "GameDetect.h"

#include <ctype.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static uint32_t rd32(const unsigned char* p) {
  return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;
}

static uint16_t rd16(const unsigned char* p) {
  return (uint16_t)(p[0] | p[1] << 8);
}

// The PE header of the file F, read into H (at least 4 KB): the offset of "PE\0\0", or 0.
static size_t pe_at(const unsigned char* h, size_t n) {
  if (n < 64 || h[0] != 'M' || h[1] != 'Z') return 0;
  const uint32_t pe = rd32(h + 60);
  if (pe < 4 || (size_t)pe + 24 + 2 > n || memcmp(h + pe, "PE\0\0", 4)) return 0;
  return pe;
}

int winpad_pe_header(const char* path, struct winpad_traits* t) {
  FILE* f = fopen(path, "rb");
  if (!f) return -1;
  unsigned char h[4096];
  const size_t n = fread(h, 1, sizeof(h), f);
  fclose(f);
  const size_t pe = pe_at(h, n);
  if (!pe) return -1;
  const unsigned char* coff = h + pe + 4;
  const unsigned opt_size = rd16(coff + 16);
  const unsigned char* opt = coff + 20;
  t->machine = rd16(coff);
  if ((size_t)(opt - h) + 72 > n || opt_size < 72) return 0;
  t->linker_major = opt[2];
  // The same offsets in PE32 and PE32+ up to the subsystem.
  t->os_major = rd16(opt + 40);
  t->subsystem = rd16(opt + 68);
  t->dll_characteristics = rd16(opt + 70);
  return 0;
}

// DLL's name in lowercase without ".dll" into OUT.
static void stem(const char* dll, char* out, size_t len) {
  size_t i = 0;
  for (; dll[i] && i < len - 1; i++) out[i] = (char)tolower((unsigned char)dll[i]);
  out[i] = 0;
  if (i > 4 && !strcmp(out + i - 4, ".dll")) out[i - 4] = 0;
}

static int starts(const char* s, const char* prefix) {
  return !strncmp(s, prefix, strlen(prefix));
}

static void graphics(struct winpad_traits* t, int g) {
  if (g > t->graphics) t->graphics = g;
}

void winpad_traits_add_import(struct winpad_traits* t, const char* dll) {
  char s[64];
  stem(dll, s, sizeof(s));
  if (!strcmp(s, "d3d12") || !strcmp(s, "d3d12core")) graphics(t, WINPAD_GFX_D3D12);
  else if (!strcmp(s, "d3d11") || !strcmp(s, "dxgi") || starts(s, "d3dx11_")) graphics(t, WINPAD_GFX_D3D11);
  else if (!strcmp(s, "d3d10") || !strcmp(s, "d3d10_1") || starts(s, "d3dx10")) graphics(t, WINPAD_GFX_D3D10);
  else if (!strcmp(s, "d3d9") || starts(s, "d3dx9")) graphics(t, WINPAD_GFX_D3D9);
  else if (!strcmp(s, "d3d8") || starts(s, "d3dx8")) graphics(t, WINPAD_GFX_D3D8);
  else if (!strcmp(s, "vulkan-1")) graphics(t, WINPAD_GFX_VULKAN);
  else if (!strcmp(s, "opengl32") || !strcmp(s, "glu32")) graphics(t, WINPAD_GFX_OPENGL);
  else if (!strcmp(s, "ddraw")) {
    graphics(t, WINPAD_GFX_DDRAW);
    t->uses |= WINPAD_USES_DDRAW;
  } else if (starts(s, "glide")) graphics(t, WINPAD_GFX_GLIDE);
  if (starts(s, "d3dx") || starts(s, "d3dcompiler_")) t->uses |= WINPAD_USES_D3DX;
  if (!strcmp(s, "dinput") || !strcmp(s, "dinput8")) t->uses |= WINPAD_USES_DINPUT;
  if (starts(s, "xinput")) t->uses |= WINPAD_USES_XINPUT;
  if (!strcmp(s, "dsound")) t->uses |= WINPAD_USES_DSOUND;
  if (starts(s, "xaudio2") || starts(s, "x3daudio") || starts(s, "xactengine")) t->uses |= WINPAD_USES_XAUDIO;
  if (!strcmp(s, "openal32") || !strcmp(s, "soft_oal") || !strcmp(s, "wrap_oal")) t->uses |= WINPAD_USES_OPENAL;
  if (!strcmp(s, "mscoree")) t->uses |= WINPAD_USES_DOTNET;
  if (!strcmp(s, "physxloader") || starts(s, "physx3") || !strcmp(s, "physxcore") || starts(s, "physx_") ||
      starts(s, "physxcommon") || starts(s, "physxfoundation"))
    t->uses |= WINPAD_USES_PHYSX;
  if (!strcmp(s, "steam_api") || !strcmp(s, "steam_api64") || starts(s, "steamclient")) t->uses |= WINPAD_USES_STEAM;
  // Visual C++ runtimes; not msvcrt.dll, which Windows (and Wine) has itself.
  if (starts(s, "msvcp") || (starts(s, "msvcr") && strcmp(s, "msvcrt")) || starts(s, "vcruntime") || starts(s, "mfc"))
    t->uses |= WINPAD_USES_VCRUNTIME;
}

const char* winpad_graphics_name(int g) {
  static const char* const names[] = {"unknown", "glide", "ddraw", "opengl", "vulkan", "d3d8", "d3d9", "d3d10", "d3d11", "d3d12"};
  return g >= 0 && g < (int)(sizeof(names) / sizeof(names[0])) ? names[g] : "unknown";
}

// Whether TEXT is in DATA, in ASCII or in UTF-16LE (a version resource's strings).
static int has(const unsigned char* data, size_t n, const char* text) {
  const size_t len = strlen(text);
  if (len > n) return 0;
  for (size_t i = 0; i + len <= n; i++)
    if (data[i] == (unsigned char)text[0] && !memcmp(data + i, text, len)) return 1;
  if (len * 2 > n) return 0;
  for (size_t i = 0; i + len * 2 <= n; i++) {
    if (data[i] != (unsigned char)text[0] || data[i + 1]) continue;
    size_t j = 1;
    while (j < len && data[i + 2 * j] == (unsigned char)text[j] && !data[i + 2 * j + 1]) j++;
    if (j == len) return 1;
  }
  return 0;
}

static int found(char* kind, size_t len, const char* what) {
  snprintf(kind, len, "%s", what);
  return 1;
}

int winpad_installer_kind(const char* path, char* kind, size_t kindlen) {
  if (kindlen) kind[0] = 0;
  FILE* f = fopen(path, "rb");
  if (!f) return -1;
  enum { HEAD = 2 * 1024 * 1024, TAIL = 1024 * 1024 };
  unsigned char* head = malloc(HEAD);
  unsigned char* tail = malloc(TAIL);
  int rc = 0;
  if (!head || !tail) {
    rc = -1;
    goto out;
  }
  const size_t n = fread(head, 1, HEAD, f);
  static const unsigned char ole[8] = {0xd0, 0xcf, 0x11, 0xe0, 0xa1, 0xb1, 0x1a, 0xe1};
  if (n >= 8 && !memcmp(head, ole, 8)) {
    const size_t l = strlen(path);
    if (l > 4 && (!strcmp(path + l - 4, ".msi") || !strcmp(path + l - 4, ".MSI"))) rc = found(kind, kindlen, "msi");
    goto out;
  }
  const size_t pe = pe_at(head, n);
  if (!pe) goto out;
  const unsigned char* coff = head + pe + 4;
  const unsigned nsections = rd16(coff + 2), opt_size = rd16(coff + 16);
  const unsigned char* sections = coff + 20 + opt_size;
  // The end of the last section's data: what follows is appended (an installer's payload).
  uint64_t end = 0;
  for (unsigned i = 0; i < nsections && (size_t)(sections - head) + (i + 1) * 40 <= n; i++) {
    const unsigned char* s = sections + i * 40;
    if (!memcmp(s, ".wixburn", 8)) {
      rc = found(kind, kindlen, "wixburn");
      goto out;
    }
    const uint64_t e = (uint64_t)rd32(s + 20) + rd32(s + 16);
    if (e > end) end = e;
  }
  size_t m = 0;
  if (end && !fseek(f, (long)end, SEEK_SET)) m = fread(tail, 1, TAIL, f);
  static const unsigned char sz[6] = {'7', 'z', 0xbc, 0xaf, 0x27, 0x1c};
  if (has(tail, m, "Inno Setup Setup Data") || has(head, n, "Inno Setup") || has(tail, m, "rDlPtS"))
    rc = found(kind, kindlen, "inno");
  else if (has(tail, m, "NullsoftInst") || has(head, n, "Nullsoft.NSIS") || has(head, n, "Nullsoft Install System"))
    rc = found(kind, kindlen, "nsis");
  else if (has(head, n, "InstallShield") || has(tail, m, "InstallShield"))
    rc = found(kind, kindlen, "installshield");
  else if (has(head, n, "Wise Installation") || has(head, n, "WiseMain"))
    rc = found(kind, kindlen, "wise");
  else if (has(head, n, "Setup Factory"))
    rc = found(kind, kindlen, "setupfactory");
  else if ((m >= 6 && !memcmp(tail, sz, 6)) || has(head, n, "7zS.sfx") || has(head, n, "7-Zip SFX"))
    rc = found(kind, kindlen, "7zsfx");
  else {
    // A cabinet inside the program (DXSETUP's and IExpress' self-extractors, old vcredist).
    static const unsigned char cab[8] = {'M', 'S', 'C', 'F', 0, 0, 0, 0};
    for (size_t i = pe; i + 8 <= n && !rc; i++)
      if (head[i] == 'M' && !memcmp(head + i, cab, 8)) rc = found(kind, kindlen, "cab");
    for (size_t i = 0; i + 8 <= m && !rc; i++)
      if (tail[i] == 'M' && !memcmp(tail + i, cab, 8)) rc = found(kind, kindlen, "cab");
  }
out:
  fclose(f);
  free(head);
  free(tail);
  return rc;
}
