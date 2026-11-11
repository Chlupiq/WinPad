// SPDX-License-Identifier: MIT
// Redist.c against Microsoft's real DirectX installer (redist-test.sh): its SHA-256 is the
// one the app checks, and the 32-bit DLLs games ask for come out of it as i386 PE files.
#include "Redist.h"

#include <stdio.h>
#include <string.h>

// The machine field of a PE file, or 0.
static unsigned pe_machine(const char* path) {
  FILE* f = fopen(path, "rb");
  if (!f) return 0;
  unsigned char h[4096];
  const size_t n = fread(h, 1, sizeof(h), f);
  fclose(f);
  if (n < 64 || h[0] != 'M' || h[1] != 'Z') return 0;
  const unsigned off = h[60] | h[61] << 8 | h[62] << 16 | (unsigned)h[63] << 24;
  if (off + 6 > n || memcmp(h + off, "PE\0\0", 4)) return 0;
  return h[off + 4] | h[off + 5] << 8;
}

int main(int argc, char** argv) {
  if (argc == 2 && !strcmp(argv[1], "--url")) {
    puts(WINPAD_DIRECTX_URL);
    return 0;
  }
  if (argc != 3) {
    fprintf(stderr, "usage: redist-test INSTALLER DEST\n");
    return 2;
  }
  char err[512], hex[65];
  if (winpad_redist_sha256(argv[1], hex, err, sizeof(err))) {
    fprintf(stderr, "%s\n", err);
    return 1;
  }
  printf("SHA-256 %s\n", hex);
  if (strcmp(hex, WINPAD_DIRECTX_SHA256)) {
    fprintf(stderr, "not the SHA-256 Redist.h has (%s)\n", WINPAD_DIRECTX_SHA256);
    return 1;
  }
  int count = 0;
  if (winpad_redist_extract_directx(argv[1], argv[2], &count, err, sizeof(err))) {
    fprintf(stderr, "%s\n", err);
    return 1;
  }
  printf("%d DLLs\n", count);
  const char* want[] = {"d3dx9_24.dll", "d3dx9_30.dll", "d3dx9_43.dll", "d3dcompiler_43.dll", "xinput1_3.dll",
                        "xaudio2_7.dll", "x3daudio1_7.dll", "xactengine3_7.dll", "d3dx10_43.dll"};
  int bad = 0;
  for (size_t i = 0; i < sizeof(want) / sizeof(want[0]); i++) {
    char path[1024];
    snprintf(path, sizeof(path), "%s/%s", argv[2], want[i]);
    const unsigned m = pe_machine(path);
    printf("%s: %s\n", want[i], m == 0x14c ? "i386" : m ? "another machine" : "missing");
    if (m != 0x14c) bad = 1;
  }
  return bad;
}
