// SPDX-License-Identifier: MIT
// Reads WinPad packages (.winpad): ZIP archives WinPad Translator writes
// (tools/winpad-translator/winpad_translator/package.py), with the game's
// files stored or deflated, ZIP64 when the game is larger than 4 GB. iOS
// has no public API to unpack a ZIP, so this reads it with zlib. Plain C, so
// that it is tested on Linux too (tools/winpad-translator/tests).
#include "Package.h"

#include <errno.h>
#include <fcntl.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

#define CHUNK (1 << 20)

typedef struct {
  char* name;
  uint64_t offset;  // of its local header
  uint64_t csize, usize;
  uint32_t crc;
  uint16_t method, flags;
  uint32_t mode;  // Unix mode bits, if the archive was made on Unix
} Entry;

typedef struct {
  int fd;
  Entry* entries;
  size_t count;
  char* err;
  size_t errlen;
} Zip;

static int fail(Zip* z, const char* fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  if (z->errlen) vsnprintf(z->err, z->errlen, fmt, ap);
  va_end(ap);
  return -1;
}

static uint16_t u16(const uint8_t* p) { return (uint16_t)(p[0] | p[1] << 8); }
static uint32_t u32(const uint8_t* p) { return (uint32_t)p[0] | (uint32_t)p[1] << 8 | (uint32_t)p[2] << 16 | (uint32_t)p[3] << 24; }
static uint64_t u64(const uint8_t* p) { return (uint64_t)u32(p) | (uint64_t)u32(p + 4) << 32; }

static int read_at(Zip* z, void* buf, size_t len, uint64_t off) {
  size_t got = 0;
  while (got < len) {
    const ssize_t n = pread(z->fd, (char*)buf + got, len - got, (off_t)(off + got));
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return fail(z, "the package is cut short (read at %llu)", (unsigned long long)(off + got));
    got += (size_t)n;
  }
  return 0;
}

static void close_zip(Zip* z) {
  for (size_t i = 0; i < z->count; i++) free(z->entries[i].name);
  free(z->entries);
  if (z->fd >= 0) close(z->fd);
}

static int open_zip(Zip* z, const char* path) {
  z->fd = open(path, O_RDONLY);
  if (z->fd < 0) return fail(z, "cannot open %s: %s", path, strerror(errno));
  struct stat st;
  if (fstat(z->fd, &st)) return fail(z, "cannot read %s: %s", path, strerror(errno));
  const uint64_t size = (uint64_t)st.st_size;
  if (size < 22) return fail(z, "not a WinPad package (too small)");

  // The end of central directory record, in the last 64 KB + 22 bytes.
  const size_t tail_len = size < 65557 ? (size_t)size : 65557;
  uint8_t* tail = malloc(tail_len);
  if (!tail) return fail(z, "out of memory");
  if (read_at(z, tail, tail_len, size - tail_len)) {
    free(tail);
    return -1;
  }
  long eocd = -1;
  for (long i = (long)tail_len - 22; i >= 0; i--)
    if (u32(tail + i) == 0x06054b50) {
      eocd = i;
      break;
    }
  if (eocd < 0) {
    free(tail);
    return fail(z, "not a WinPad package (no ZIP directory)");
  }
  uint64_t count = u16(tail + eocd + 10), cd_size = u32(tail + eocd + 12), cd_off = u32(tail + eocd + 16);
  const uint64_t eocd_pos = size - tail_len + (uint64_t)eocd;
  free(tail);
  if (count == 0xffff || cd_size == 0xffffffff || cd_off == 0xffffffff) {
    // ZIP64: its locator is right before, and points to the ZIP64 end record.
    uint8_t loc[20], rec[56];
    if (eocd_pos < 20 || read_at(z, loc, 20, eocd_pos - 20)) return fail(z, "broken ZIP64 package");
    if (u32(loc) != 0x07064b50) return fail(z, "broken ZIP64 package (no locator)");
    if (read_at(z, rec, 56, u64(loc + 8)) || u32(rec) != 0x06064b50) return fail(z, "broken ZIP64 package (no end record)");
    count = u64(rec + 32);
    cd_size = u64(rec + 40);
    cd_off = u64(rec + 48);
  }
  if (cd_off > size || cd_size > size - cd_off || count > cd_size / 46) return fail(z, "broken package directory");

  uint8_t* cd = malloc(cd_size ? cd_size : 1);
  if (!cd) return fail(z, "out of memory");
  if (read_at(z, cd, cd_size, cd_off)) {
    free(cd);
    return -1;
  }
  z->entries = calloc(count ? count : 1, sizeof(Entry));
  if (!z->entries) {
    free(cd);
    return fail(z, "out of memory");
  }
  uint64_t pos = 0;
  for (uint64_t i = 0; i < count; i++) {
    if (pos + 46 > cd_size || u32(cd + pos) != 0x02014b50) {
      free(cd);
      return fail(z, "broken package directory (entry %llu)", (unsigned long long)i);
    }
    const uint8_t* h = cd + pos;
    const uint16_t name_len = u16(h + 28), extra_len = u16(h + 30), comment_len = u16(h + 32);
    if (pos + 46 + name_len + extra_len + comment_len > cd_size) {
      free(cd);
      return fail(z, "broken package directory (entry %llu)", (unsigned long long)i);
    }
    Entry* e = &z->entries[z->count++];
    e->flags = u16(h + 8);
    e->method = u16(h + 10);
    e->crc = u32(h + 16);
    e->csize = u32(h + 20);
    e->usize = u32(h + 24);
    e->offset = u32(h + 42);
    e->mode = u16(h + 4) >> 8 == 3 ? u32(h + 38) >> 16 : 0;  // made on Unix
    e->name = malloc(name_len + 1u);
    if (!e->name) {
      free(cd);
      return fail(z, "out of memory");
    }
    memcpy(e->name, h + 46, name_len);
    e->name[name_len] = 0;
    // The ZIP64 extra field has the sizes and offset that did not fit, in this order.
    const uint8_t* x = h + 46 + name_len;
    for (uint16_t at = 0; at + 4 <= extra_len;) {
      const uint16_t id = u16(x + at), len = u16(x + at + 2);
      if (at + 4u + len > extra_len) break;
      if (id == 1) {
        const uint8_t* v = x + at + 4;
        uint16_t left = len;
        uint64_t* fields[] = {&e->usize, &e->csize, &e->offset};
        for (int f = 0; f < 3; f++) {
          if (*fields[f] != 0xffffffff) continue;
          if (left < 8) break;
          *fields[f] = u64(v);
          v += 8;
          left -= 8;
        }
      }
      at += 4 + len;
    }
    pos += 46u + name_len + extra_len + comment_len;
  }
  free(cd);
  return 0;
}

// Where the entry's data begins.
static int data_offset(Zip* z, const Entry* e, uint64_t* off) {
  uint8_t h[30];
  if (read_at(z, h, 30, e->offset)) return -1;
  if (u32(h) != 0x04034b50) return fail(z, "broken package (entry %s)", e->name);
  *off = e->offset + 30 + u16(h + 26) + u16(h + 28);
  return 0;
}

// Streams the entry's bytes to WRITE (a file or a buffer).
typedef int (*sink)(void* ctx, const uint8_t* data, size_t len);

static int unpack(Zip* z, const Entry* e, sink write_fn, void* ctx) {
  if (e->flags & 1) return fail(z, "%s is encrypted", e->name);
  if (e->method != 0 && e->method != 8) return fail(z, "%s is packed with method %u (only stored or deflated)", e->name, e->method);
  uint64_t off = 0;
  if (data_offset(z, e, &off)) return -1;
  uint8_t* in = malloc(CHUNK);
  uint8_t* out = malloc(CHUNK);
  if (!in || !out) {
    free(in);
    free(out);
    return fail(z, "out of memory");
  }
  int rc = 0;
  uLong crc = crc32(0, Z_NULL, 0);
  uint64_t left = e->csize, written = 0;
  z_stream s;
  memset(&s, 0, sizeof s);
  if (e->method == 8 && inflateInit2(&s, -MAX_WBITS) != Z_OK) rc = fail(z, "zlib failed");
  int done = 0;
  while (!rc && !done) {
    const size_t n = left < CHUNK ? (size_t)left : CHUNK;
    if (n && read_at(z, in, n, off)) {
      rc = -1;
      break;
    }
    off += n;
    left -= n;
    if (e->method == 0) {
      crc = crc32(crc, in, (uInt)n);
      written += n;
      if (n && write_fn(ctx, in, n)) rc = fail(z, "cannot write %s: %s", e->name, strerror(errno));
      done = left == 0;
      continue;
    }
    s.next_in = in;
    s.avail_in = (uInt)n;
    do {
      s.next_out = out;
      s.avail_out = CHUNK;
      const int r = inflate(&s, Z_NO_FLUSH);
      if (r != Z_OK && r != Z_STREAM_END && !(r == Z_BUF_ERROR && s.avail_in == 0 && left)) {
        rc = fail(z, "%s is damaged (inflate %d)", e->name, r);
        break;
      }
      const size_t got = CHUNK - s.avail_out;
      crc = crc32(crc, out, (uInt)got);
      written += got;
      if (got && write_fn(ctx, out, got)) {
        rc = fail(z, "cannot write %s: %s", e->name, strerror(errno));
        break;
      }
      if (r == Z_STREAM_END) done = 1;
    } while (!done && (s.avail_in || s.avail_out == 0));
    if (!rc && !done && left == 0) rc = fail(z, "%s is cut short", e->name);
  }
  if (e->method == 8) inflateEnd(&s);
  free(in);
  free(out);
  if (rc) return rc;
  if (written != e->usize) return fail(z, "%s has %llu bytes, not %llu", e->name, (unsigned long long)written, (unsigned long long)e->usize);
  if ((uint32_t)crc != e->crc) return fail(z, "%s is damaged (CRC)", e->name);
  return 0;
}

typedef struct {
  uint8_t* data;
  size_t len, max;
} Buffer;

static int to_buffer(void* ctx, const uint8_t* data, size_t len) {
  Buffer* b = ctx;
  if (len > b->max - b->len) {
    errno = EFBIG;
    return -1;
  }
  memcpy(b->data + b->len, data, len);
  b->len += len;
  return 0;
}

int winpad_package_read(const char* package, const char* name, size_t max, void** data, size_t* size, char* err,
                        size_t errlen) {
  Zip z = {.fd = -1, .err = err, .errlen = errlen};
  int rc = open_zip(&z, package);
  const Entry* e = NULL;
  for (size_t i = 0; !rc && i < z.count && !e; i++)
    if (!strcmp(z.entries[i].name, name)) e = &z.entries[i];
  if (!rc && !e) rc = fail(&z, "no %s in the package", name);
  if (!rc && e->usize > max) rc = fail(&z, "%s is too large", name);
  Buffer b = {0};
  if (!rc) {
    b.max = (size_t)e->usize;
    b.data = malloc(b.max + 1);
    if (!b.data) rc = fail(&z, "out of memory");
  }
  if (!rc) rc = unpack(&z, e, to_buffer, &b);
  close_zip(&z);
  if (rc) {
    free(b.data);
    return rc;
  }
  b.data[b.len] = 0;
  *data = b.data;
  *size = b.len;
  return 0;
}

// Whether NAME may be written under the destination: relative, no "." or ".."
// parts, no backslashes (a Windows path), nothing empty but a folder's last "/".
static int safe_name(const char* name) {
  if (!*name || *name == '/' || strchr(name, '\\') || strlen(name) > 1000) return 0;
  const char* p = name;
  while (*p) {
    const char* slash = strchr(p, '/');
    const size_t len = slash ? (size_t)(slash - p) : strlen(p);
    if (len == 0 || (len == 1 && p[0] == '.') || (len == 2 && p[0] == '.' && p[1] == '.')) return 0;
    if (!slash) break;
    p = slash + 1;
  }
  return 1;
}

static int make_dirs(const char* path) {
  char buf[4096];
  if (strlen(path) >= sizeof buf) return -1;
  strcpy(buf, path);
  for (char* p = buf + 1; *p; p++) {
    if (*p != '/') continue;
    *p = 0;
    if (mkdir(buf, 0755) && errno != EEXIST) return -1;
    *p = '/';
  }
  return mkdir(buf, 0755) && errno != EEXIST ? -1 : 0;
}

typedef struct {
  int fd;
  uint64_t* done;
  uint64_t total;
  winpad_package_progress progress;
  void* ctx;
  int stopped;
} FileSink;

static int to_file(void* ctx, const uint8_t* data, size_t len) {
  FileSink* f = ctx;
  while (len) {
    const ssize_t n = write(f->fd, data, len);
    if (n < 0 && errno == EINTR) continue;
    if (n <= 0) return -1;
    data += n;
    len -= (size_t)n;
    *f->done += (uint64_t)n;
  }
  if (f->progress && f->progress(f->ctx, *f->done, f->total)) {
    f->stopped = 1;
    errno = ECANCELED;
    return -1;
  }
  return 0;
}

int winpad_package_extract(const char* package, const char* dest, winpad_package_progress progress, void* ctx,
                           char* err, size_t errlen) {
  Zip z = {.fd = -1, .err = err, .errlen = errlen};
  int rc = open_zip(&z, package);
  uint64_t total = 0, done = 0;
  for (size_t i = 0; !rc && i < z.count; i++) {
    const Entry* e = &z.entries[i];
    if (!safe_name(e->name)) rc = fail(&z, "the package has a file outside its folder: %s", e->name);
    else if ((e->mode & 0170000) == 0120000) rc = fail(&z, "the package has a link: %s", e->name);
    total += e->usize;
  }
  if (!rc && make_dirs(dest)) rc = fail(&z, "cannot make %s: %s", dest, strerror(errno));
  char path[4096];
  for (size_t i = 0; !rc && i < z.count; i++) {
    const Entry* e = &z.entries[i];
    if ((size_t)snprintf(path, sizeof path, "%s/%s", dest, e->name) >= sizeof path) {
      rc = fail(&z, "path too long: %s", e->name);
      break;
    }
    const size_t len = strlen(path);
    if (path[len - 1] == '/') {
      path[len - 1] = 0;
      if (make_dirs(path)) rc = fail(&z, "cannot make %s: %s", path, strerror(errno));
      continue;
    }
    char* slash = strrchr(path, '/');
    *slash = 0;
    if (make_dirs(path)) {
      rc = fail(&z, "cannot make %s: %s", path, strerror(errno));
      break;
    }
    *slash = '/';
    FileSink f = {.done = &done, .total = total, .progress = progress, .ctx = ctx};
    f.fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (f.fd < 0) {
      rc = fail(&z, "cannot write %s: %s", path, strerror(errno));
      break;
    }
    rc = unpack(&z, e, to_file, &f);
    if (close(f.fd) && !rc) rc = fail(&z, "cannot write %s: %s", path, strerror(errno));
    if (f.stopped) rc = fail(&z, "stopped");
  }
  if (!rc && progress) progress(ctx, total, total);
  close_zip(&z);
  return rc;
}
