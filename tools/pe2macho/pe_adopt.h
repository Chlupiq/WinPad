// SPDX-License-Identifier: MIT
// Finds the PE image inside a dylib from tools/pe2macho, so a loader can
// take it over as a loaded module instead of mapping (or copying) the DLL.
//
// After dlopen the image is already what a PE loader produces: every byte at
// its RVA from _PREFIX_image, base relocations applied by dyld, the header's
// ImageBase field holding the address the image landed at, and SizeOfImage
// covering the x18 trampolines and the TEB slot word pe2macho appended. All
// that is left for the loader is to register the range as the module's view
// (Wine: virtual_create_builtin_view, like its .so builtins) and to write the
// TSD slot offset of the TEB into _PREFIX_teb_slot.
//
// No Wine headers here: this is shared by Wine's loader patch and the tests.
#ifndef WINPAD_PE_ADOPT_H
#define WINPAD_PE_ADOPT_H

#include <dlfcn.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct {
  uint8_t* base;       // _PREFIX_image: the DOS header, the module handle
  size_t size;         // SizeOfImage
  uint32_t nt_offset;  // e_lfanew
  uint64_t* teb_slot;  // _PREFIX_teb_slot, or NULL when the code never reads x18
} PeAdopted;

// The symbol prefix pe2macho gives a module: "pe_" and the file name without
// its last extension, characters outside [A-Za-z0-9_] replaced by '_'
// (pe2macho.default_prefix). `name` is the PE file name, e.g. "kernel32.dll".
static inline void pe_adopt_prefix(const char* name, char* out, size_t size) {
  const char* slash = strrchr(name, '/');
  if (slash) name = slash + 1;
  const char* dot = strrchr(name, '.');
  size_t len = dot ? (size_t)(dot - name) : strlen(name);
  size_t n = 0;
  for (const char* p = "pe_"; *p && n + 1 < size; p++) out[n++] = *p;
  for (size_t i = 0; i < len && n + 1 < size; i++) {
    char c = name[i];
    int ok = (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_';
    out[n++] = ok ? c : '_';
  }
  if (size) out[n] = 0;
}

// Fills `out` for the module `prefix` in the dlopen handle. Returns NULL, or
// why the dylib holds no usable image (into `err`).
static inline const char* pe_adopt(void* handle, const char* prefix, PeAdopted* out, char* err,
                                   size_t err_size) {
  char sym[256];
  snprintf(sym, sizeof(sym), "%s_image", prefix);
  uint8_t* base = (uint8_t*)dlsym(handle, sym);
  if (!base) {
    snprintf(err, err_size, "no symbol %s", sym);
    return err;
  }
  uint32_t nt;
  memcpy(&nt, base + 0x3c, 4);
  if (memcmp(base, "MZ", 2) || nt > 0x1000 || memcmp(base + nt, "PE\0\0", 4)) {
    snprintf(err, err_size, "%s holds no PE headers", sym);
    return err;
  }
  uint16_t machine, magic;
  memcpy(&machine, base + nt + 4, 2);
  memcpy(&magic, base + nt + 24, 2);
  if ((machine != 0xAA64 && machine != 0xA641) || magic != 0x20B) {
    snprintf(err, err_size, "%s is not an ARM64 PE32+ image (machine %#x)", sym, machine);
    return err;
  }
  uint64_t image_base;
  uint32_t size_of_image;
  memcpy(&image_base, base + nt + 24 + 24, 8);
  memcpy(&size_of_image, base + nt + 24 + 56, 4);
  if (image_base != (uint64_t)(uintptr_t)base) {
    snprintf(err, err_size, "ImageBase is %#llx, not the image's address %p (not rebased by dyld)",
             (unsigned long long)image_base, (void*)base);
    return err;
  }
  if ((uintptr_t)base & 0x3fff) {
    snprintf(err, err_size, "%s at %p is not page aligned", sym, (void*)base);
    return err;
  }
  snprintf(sym, sizeof(sym), "%s_teb_slot", prefix);
  out->base = base;
  out->size = size_of_image;
  out->nt_offset = nt;
  out->teb_slot = (uint64_t*)dlsym(handle, sym);
  return NULL;
}

#endif
