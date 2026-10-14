// SPDX-License-Identifier: MIT
// Loads the dylib that tools/pe2macho made from testdll.dll and calls the
// DLL's code: the PE image runs as ordinary signed Mach-O code.
#include <dlfcn.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include "teb-test.h"

int main(int argc, char** argv) {
  if (argc != 2) {
    fprintf(stderr, "usage: pe2macho-test DYLIB\n");
    return 2;
  }
  void* lib = dlopen(argv[1], RTLD_NOW | RTLD_LOCAL);
  if (!lib) {
    fprintf(stderr, "dlopen: %s\n", dlerror());
    return 1;
  }
  const uint8_t* image = dlsym(lib, "pe_testdll_image");
  int (*add_mul)(int, int) = dlsym(lib, "pe_testdll_export_pe_add_mul");
  const char* (*greeting)(void) = dlsym(lib, "pe_testdll_export_pe_greeting");
  int (*counter)(void) = dlsym(lib, "pe_testdll_export_pe_counter");
  if (!image || !add_mul || !greeting || !counter) {
    fprintf(stderr, "the dylib lacks the image or an export\n");
    return 1;
  }
  if (memcmp(image, "MZ", 2) != 0) {
    fprintf(stderr, "the image does not start with the PE headers\n");
    return 1;
  }
  // counter starts at 5; add_mul adds a, returns a * b + counter through a
  // rebased pointer.
  const int product = add_mul(3, 4);
  const int count = counter();
  const char* text = greeting();
  printf("add_mul(3, 4) = %d, counter = %d, greeting at image + %#lx: \"%s\"\n", product, count,
         (unsigned long)((const uint8_t*)text - image), text);
  const int ok = product == 20 && count == 8 && strcmp(text, "hello from a PE image") == 0;
  printf("%s\n", ok ? "PE code ran from the dylib" : "FAILED");
  const int teb_failed = pe_teb_test(lib);
  return ok && !teb_failed ? 0 : 1;
}
