// SPDX-License-Identifier: MIT
// A WinPad package (.winpad, Package.c): one file with a game folder in it,
// a ZIP archive whose entries are the folder's files and winpad.json.
#ifndef WINPAD_PACKAGE_H
#define WINPAD_PACKAGE_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

// Reads the entry NAME (at most MAX bytes) into a malloc'd buffer *DATA of *SIZE bytes.
// 0 when done, else -1 with why in ERR.
int winpad_package_read(const char* package, const char* name, size_t max, void** data, size_t* size, char* err,
                        size_t errlen);

// Called as the files are written, with the bytes written so far and in all; a nonzero
// return stops the extraction.
typedef int (*winpad_package_progress)(void* ctx, uint64_t done, uint64_t total);

// Writes every entry into the folder DEST (made if needed). An entry with an absolute
// path, a "..", a backslash or a link is refused, as is one whose CRC does not match.
// 0 when done, else -1 with why in ERR (DEST then holds part of the package).
int winpad_package_extract(const char* package, const char* dest, winpad_package_progress progress, void* ctx,
                           char* err, size_t errlen);

#ifdef __cplusplus
}
#endif
#endif
