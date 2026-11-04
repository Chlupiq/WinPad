// SPDX-License-Identifier: MIT
// Package.c on the command line, for its tests (tools/winpad-translator/tests):
//   package-tool read PACKAGE NAME     prints the entry NAME
//   package-tool extract PACKAGE DIR   writes every entry into DIR
#include <stdio.h>
#include <string.h>
#include <stdlib.h>

#include "Package.h"

int main(int argc, char** argv) {
  char err[512] = "";
  if (argc == 4 && !strcmp(argv[1], "read")) {
    void* data;
    size_t size;
    if (winpad_package_read(argv[2], argv[3], 1 << 20, &data, &size, err, sizeof err)) {
      fprintf(stderr, "error: %s\n", err);
      return 1;
    }
    fwrite(data, 1, size, stdout);
    free(data);
    return 0;
  }
  if (argc == 4 && !strcmp(argv[1], "extract")) {
    if (winpad_package_extract(argv[2], argv[3], NULL, NULL, err, sizeof err)) {
      fprintf(stderr, "error: %s\n", err);
      return 1;
    }
    return 0;
  }
  fprintf(stderr, "usage: package-tool read PACKAGE NAME | extract PACKAGE DIR\n");
  return 2;
}
