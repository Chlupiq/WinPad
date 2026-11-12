// SPDX-License-Identifier: MIT
// Microsoft's DirectX DLLs out of its installer (Redist.h), with libmspack's cabinet
// decompressor (kyz/libmspack, LGPL-2.1, fetched by fetch-mspack.sh).
#include "Redist.h"

#include <errno.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <unistd.h>

#include <mspack.h>

static void say(char* err, size_t errlen, const char* fmt, ...) {
  if (!err || !errlen) return;
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(err, errlen, fmt, ap);
  va_end(ap);
}

// SHA-256 (FIPS 180-4), small and portable: the check also runs in CI on Linux.
static const uint32_t K[64] = {
    0x428a2f98, 0x71374491, 0xb5c0fbcf, 0xe9b5dba5, 0x3956c25b, 0x59f111f1, 0x923f82a4, 0xab1c5ed5,
    0xd807aa98, 0x12835b01, 0x243185be, 0x550c7dc3, 0x72be5d74, 0x80deb1fe, 0x9bdc06a7, 0xc19bf174,
    0xe49b69c1, 0xefbe4786, 0x0fc19dc6, 0x240ca1cc, 0x2de92c6f, 0x4a7484aa, 0x5cb0a9dc, 0x76f988da,
    0x983e5152, 0xa831c66d, 0xb00327c8, 0xbf597fc7, 0xc6e00bf3, 0xd5a79147, 0x06ca6351, 0x14292967,
    0x27b70a85, 0x2e1b2138, 0x4d2c6dfc, 0x53380d13, 0x650a7354, 0x766a0abb, 0x81c2c92e, 0x92722c85,
    0xa2bfe8a1, 0xa81a664b, 0xc24b8b70, 0xc76c51a3, 0xd192e819, 0xd6990624, 0xf40e3585, 0x106aa070,
    0x19a4c116, 0x1e376c08, 0x2748774c, 0x34b0bcb5, 0x391c0cb3, 0x4ed8aa4a, 0x5b9cca4f, 0x682e6ff3,
    0x748f82ee, 0x78a5636f, 0x84c87814, 0x8cc70208, 0x90befffa, 0xa4506ceb, 0xbef9a3f7, 0xc67178f2,
};

#define ROR(x, n) (((x) >> (n)) | ((x) << (32 - (n))))

static void sha256_block(uint32_t h[8], const unsigned char* p) {
  uint32_t w[64];
  for (int i = 0; i < 16; i++)
    w[i] = (uint32_t)p[4 * i] << 24 | (uint32_t)p[4 * i + 1] << 16 | (uint32_t)p[4 * i + 2] << 8 | p[4 * i + 3];
  for (int i = 16; i < 64; i++) {
    const uint32_t s0 = ROR(w[i - 15], 7) ^ ROR(w[i - 15], 18) ^ (w[i - 15] >> 3);
    const uint32_t s1 = ROR(w[i - 2], 17) ^ ROR(w[i - 2], 19) ^ (w[i - 2] >> 10);
    w[i] = w[i - 16] + s0 + w[i - 7] + s1;
  }
  uint32_t a = h[0], b = h[1], c = h[2], d = h[3], e = h[4], f = h[5], g = h[6], k = h[7];
  for (int i = 0; i < 64; i++) {
    const uint32_t t1 = k + (ROR(e, 6) ^ ROR(e, 11) ^ ROR(e, 25)) + ((e & f) ^ (~e & g)) + K[i] + w[i];
    const uint32_t t2 = (ROR(a, 2) ^ ROR(a, 13) ^ ROR(a, 22)) + ((a & b) ^ (a & c) ^ (b & c));
    k = g;
    g = f;
    f = e;
    e = d + t1;
    d = c;
    c = b;
    b = a;
    a = t1 + t2;
  }
  h[0] += a;
  h[1] += b;
  h[2] += c;
  h[3] += d;
  h[4] += e;
  h[5] += f;
  h[6] += g;
  h[7] += k;
}

int winpad_redist_sha256(const char* path, char hex[65], char* err, size_t errlen) {
  FILE* f = fopen(path, "rb");
  if (!f) {
    say(err, errlen, "%s: %s", path, strerror(errno));
    return -1;
  }
  uint32_t h[8] = {0x6a09e667, 0xbb67ae85, 0x3c6ef372, 0xa54ff53a, 0x510e527f, 0x9b05688c, 0x1f83d9ab, 0x5be0cd19};
  static unsigned char buf[1 << 16];
  unsigned char tail[128];
  uint64_t total = 0;
  size_t n, have = 0;  // bytes of an unfinished block in tail
  while ((n = fread(buf, 1, sizeof(buf), f)) > 0) {
    total += n;
    size_t at = 0;
    if (have) {
      const size_t take = n < 64 - have ? n : 64 - have;
      memcpy(tail + have, buf, take);
      have += take;
      at = take;
      if (have < 64) continue;
      sha256_block(h, tail);
      have = 0;
    }
    for (; at + 64 <= n; at += 64) sha256_block(h, buf + at);
    memcpy(tail, buf + at, n - at);
    have = n - at;
  }
  const int bad = ferror(f);
  fclose(f);
  if (bad) {
    say(err, errlen, "%s: read error", path);
    return -1;
  }
  tail[have++] = 0x80;
  const size_t end = have <= 56 ? 64 : 128;
  memset(tail + have, 0, end - have);
  const uint64_t bits = total * 8;
  for (int i = 0; i < 8; i++) tail[end - 1 - i] = (unsigned char)(bits >> (8 * i));
  sha256_block(h, tail);
  if (end == 128) sha256_block(h, tail + 64);
  for (int i = 0; i < 8; i++) snprintf(hex + 8 * i, 9, "%08x", h[i]);
  return 0;
}

// The file name of a cabinet entry without its folders, or NULL for a name that could
// leave the destination.
static const char* entry_name(const char* name) {
  const char* base = name;
  for (const char* p = name; *p; p++)
    if (*p == '\\' || *p == '/') base = p + 1;
  if (!*base || !strcmp(base, ".") || !strcmp(base, "..")) return NULL;
  return base;
}

static int ends_with(const char* s, const char* suffix) {
  const size_t a = strlen(s), b = strlen(suffix);
  return a >= b && !strcasecmp(s + a - b, suffix);
}

// The DLLs of one component cabinet into DEST.
static int extract_component(struct mscab_decompressor* cabd, const char* cab_path, const char* dest, int* count,
                             char* err, size_t errlen) {
  struct mscabd_cabinet* cab = cabd->open(cabd, cab_path);
  if (!cab) {
    say(err, errlen, "%s is no cabinet (libmspack error %d)", cab_path, cabd->last_error(cabd));
    return -1;
  }
  int ret = 0;
  for (struct mscabd_file* f = cab->files; f && !ret; f = f->next) {
    const char* base = entry_name(f->filename);
    if (!base || !ends_with(base, ".dll")) continue;
    char name[256], path[1024];
    snprintf(name, sizeof(name), "%s", base);
    for (char* p = name; *p; p++)
      if (*p >= 'A' && *p <= 'Z') *p += 'a' - 'A';
    snprintf(path, sizeof(path), "%s/%s", dest, name);
    if (cabd->extract(cabd, f, path) != MSPACK_ERR_OK) {
      say(err, errlen, "%s from %s: libmspack error %d", base, cab_path, cabd->last_error(cabd));
      ret = -1;
    } else {
      (*count)++;
    }
  }
  cabd->close(cabd, cab);
  return ret;
}

int winpad_redist_extract_directx(const char* exe, const char* dest, int* count, char* err, size_t errlen) {
  *count = 0;
  struct mscab_decompressor* cabd = mspack_create_cab_decompressor(NULL);
  if (!cabd) {
    say(err, errlen, "libmspack: no cabinet decompressor");
    return -1;
  }
  // The installer is a program with its cabinet appended; search finds it inside.
  struct mscabd_cabinet* outer = cabd->search(cabd, exe);
  if (!outer) {
    say(err, errlen, "no cabinet in %s (libmspack error %d)", exe, cabd->last_error(cabd));
    mspack_destroy_cab_decompressor(cabd);
    return -1;
  }
  int ret = 0, components = 0;
  for (struct mscabd_cabinet* c = outer; c && !ret; c = c->next) {
    for (struct mscabd_file* f = c->files; f && !ret; f = f->next) {
      const char* base = entry_name(f->filename);
      // One cabinet per component and platform: Jun2010_d3dx9_43_x86.cab, Mar2009_X3DAudio_x86.cab...
      if (!base || !ends_with(base, "_x86.cab")) continue;
      char tmp[1024];
      snprintf(tmp, sizeof(tmp), "%s/.component.cab", dest);
      if (cabd->extract(cabd, f, tmp) != MSPACK_ERR_OK) {
        say(err, errlen, "%s from %s: libmspack error %d", base, exe, cabd->last_error(cabd));
        ret = -1;
      } else {
        components++;
        ret = extract_component(cabd, tmp, dest, count, err, errlen);
      }
      unlink(tmp);
    }
  }
  cabd->close(cabd, outer);
  mspack_destroy_cab_decompressor(cabd);
  if (!ret && !*count) {
    say(err, errlen, "%s has no 32-bit DirectX DLLs (%d component cabinets)", exe, components);
    ret = -1;
  }
  return ret;
}

// The import tables of a PE file (Redist.h). The whole file is read: game executables are a
// few MB, and only the headers and the import names are looked at.
static uint32_t le32(const unsigned char* p) {
  return p[0] | p[1] << 8 | p[2] << 16 | (uint32_t)p[3] << 24;
}

static uint16_t le16(const unsigned char* p) {
  return (uint16_t)(p[0] | p[1] << 8);
}

struct pe_file {
  const unsigned char* data;
  size_t size;
  const unsigned char* sections;
  unsigned nsections;
};

// The file offset of RVA, or 0 when no section holds it.
static size_t pe_offset(const struct pe_file* pe, uint32_t rva) {
  for (unsigned i = 0; i < pe->nsections; i++) {
    const unsigned char* s = pe->sections + i * 40;
    const uint32_t vsize = le32(s + 8), va = le32(s + 12), raw_size = le32(s + 16), raw = le32(s + 20);
    const uint32_t span = vsize > raw_size ? vsize : raw_size;
    if (rva >= va && rva - va < span) {
      if (rva - va >= raw_size) return 0;
      const size_t off = (size_t)raw + (rva - va);
      return off < pe->size ? off : 0;
    }
  }
  return 0;
}

// Calls FOUND with the name at RVA, if it is a sane DLL name.
static void pe_name(const struct pe_file* pe, uint32_t rva, void (*found)(const char*, void*), void* ctx) {
  const size_t off = pe_offset(pe, rva);
  if (!off) return;
  char name[260];
  size_t n = 0;
  while (off + n < pe->size && n < sizeof(name) - 1) {
    const unsigned char c = pe->data[off + n];
    if (!c) break;
    if (c < 0x20 || c > 0x7e) return;
    name[n++] = (char)c;
  }
  if (!n || off + n >= pe->size || n == sizeof(name) - 1) return;
  name[n] = 0;
  found(name, ctx);
}

int winpad_pe_imports(const char* path, void (*found)(const char* dll, void* ctx), void* ctx, char* err,
                      size_t errlen) {
  FILE* f = fopen(path, "rb");
  if (!f) {
    say(err, errlen, "%s: %s", path, strerror(errno));
    return -1;
  }
  fseek(f, 0, SEEK_END);
  const long size = ftell(f);
  fseek(f, 0, SEEK_SET);
  if (size < 64 || size > 1024L * 1024 * 1024) {
    fclose(f);
    say(err, errlen, "%s: not a PE file", path);
    return -1;
  }
  unsigned char* data = malloc((size_t)size);
  const size_t got = data ? fread(data, 1, (size_t)size, f) : 0;
  fclose(f);
  int rc = -1;
  if (got != (size_t)size) {
    say(err, errlen, "%s: could not read it", path);
    goto out;
  }
  if (data[0] != 'M' || data[1] != 'Z') {
    say(err, errlen, "%s: not a PE file", path);
    goto out;
  }
  const uint32_t nt = le32(data + 60);
  if ((size_t)nt + 24 > (size_t)size || memcmp(data + nt, "PE\0\0", 4)) {
    say(err, errlen, "%s: not a PE file", path);
    goto out;
  }
  const unsigned char* coff = data + nt + 4;
  const unsigned nsections = le16(coff + 2), opt_size = le16(coff + 16);
  const unsigned char* opt = coff + 20;
  if ((size_t)(opt - data) + opt_size + (size_t)nsections * 40 > (size_t)size || opt_size < 2) {
    say(err, errlen, "%s: damaged PE header", path);
    goto out;
  }
  const uint16_t magic = le16(opt);
  unsigned dirs_at, count_at;
  uint64_t image_base;
  if (magic == 0x10b && opt_size >= 96) {
    dirs_at = 96, count_at = 92, image_base = le32(opt + 28);
  } else if (magic == 0x20b && opt_size >= 112) {
    dirs_at = 112, count_at = 108, image_base = le32(opt + 24) | (uint64_t)le32(opt + 28) << 32;
  } else {
    say(err, errlen, "%s: unknown PE optional header", path);
    goto out;
  }
  uint32_t ndirs = le32(opt + count_at);
  if (ndirs > (opt_size - dirs_at) / 8) ndirs = (opt_size - dirs_at) / 8;
  const struct pe_file pe = {data, (size_t)size, opt + opt_size, nsections};
  // Normal imports: IMAGE_IMPORT_DESCRIPTOR, 20 bytes, Name at +12, ends with a zero one.
  if (ndirs > 1 && le32(opt + dirs_at + 8)) {
    size_t off = pe_offset(&pe, le32(opt + dirs_at + 8));
    for (unsigned i = 0; off && i < 4096 && off + 20 <= pe.size; i++, off += 20) {
      const unsigned char* d = data + off;
      if (!le32(d + 12) && !le32(d + 16)) break;
      pe_name(&pe, le32(d + 12), found, ctx);
    }
  }
  // Delay-loaded: IMAGE_DELAYLOAD_DESCRIPTOR, 32 bytes, DllNameRVA at +4 (an address, not an
  // RVA, in old files whose Attributes lack bit 0).
  if (ndirs > 13 && le32(opt + dirs_at + 13 * 8)) {
    size_t off = pe_offset(&pe, le32(opt + dirs_at + 13 * 8));
    for (unsigned i = 0; off && i < 4096 && off + 32 <= pe.size; i++, off += 32) {
      const unsigned char* d = data + off;
      uint32_t name = le32(d + 4);
      if (!name) break;
      if (!(le32(d) & 1) && name >= image_base) name = (uint32_t)(name - image_base);
      pe_name(&pe, name, found, ctx);
    }
  }
  rc = 0;
out:
  free(data);
  return rc;
}
