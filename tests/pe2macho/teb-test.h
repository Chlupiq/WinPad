// SPDX-License-Identifier: MIT
// Calls the TEB functions of testdll.c through a dylib from tools/pe2macho:
// their x18 reads were rewritten to load the TEB from a TSD slot, which the
// caller names by writing its offset into the dylib's _PREFIX_teb_slot.
// Shared by the Mac test (main.c) and the iPad app (tests/ios/app/main.mm).
#ifndef WINPAD_TEB_TEST_H
#define WINPAD_TEB_TEST_H

#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>

typedef struct {
  void* lib;
  uint64_t teb[0x200];  // a stand-in TEB: Self at 0x30, LastErrorValue at 0x68
  int failed;
} PeTebRun;

static pthread_key_t pe_teb_key;

// The byte offset of pe_teb_key's slot from TPIDRRO_EL0 (clear the CPU number
// in its low bits), found with a sentinel like Wine on iOS does.
static long pe_teb_slot_offset(void) {
  uintptr_t tsd;
  __asm__ volatile("mrs %0, TPIDRRO_EL0" : "=r"(tsd));
  tsd &= ~(uintptr_t)7;
  void* const sentinel = (void*)(uintptr_t)0x5445425F534C4F54ULL;
  void* old = pthread_getspecific(pe_teb_key);
  pthread_setspecific(pe_teb_key, sentinel);
  long found = -1;
  for (int s = 0; s < 768 && found < 0; s++) {  // 768: the TSD array of struct _pthread
    if (((void* const*)tsd)[s] == sentinel) found = s * 8;
  }
  pthread_setspecific(pe_teb_key, old);
  return found;
}

static void pe_teb_expect(PeTebRun* run, const char* what, uint64_t got, uint64_t want) {
  printf("TEB test: %s = %#llx%s\n", what, (unsigned long long)got, got == want ? "" : " (WRONG)");
  if (got != want) run->failed = 1;
}

static void* pe_teb_run(void* arg) {
  PeTebRun* run = (PeTebRun*)arg;
  uint64_t (*self)(void) = (uint64_t(*)(void))dlsym(run->lib, "pe_testdll_export_pe_teb_self");
  void (*set_error)(unsigned) = (void (*)(unsigned))dlsym(run->lib, "pe_testdll_export_pe_set_last_error");
  unsigned (*error)(void) = (unsigned (*)(void))dlsym(run->lib, "pe_testdll_export_pe_last_error");
  uint64_t (*teb)(void) = (uint64_t(*)(void))dlsym(run->lib, "pe_testdll_export_pe_teb");
  uint64_t (*error_addr)(void) = (uint64_t(*)(void))dlsym(run->lib, "pe_testdll_export_pe_last_error_addr");
  void (*pair)(uint64_t*) = (void (*)(uint64_t*))dlsym(run->lib, "pe_testdll_export_pe_store_teb_pair");
  if (!self || !set_error || !error || !teb || !error_addr || !pair) {
    printf("TEB test: the dylib lacks a TEB export\n");
    run->failed = 1;
    return NULL;
  }
  const uint64_t base = (uint64_t)(uintptr_t)run->teb;
  run->teb[0x30 / 8] = base;
  pthread_setspecific(pe_teb_key, run->teb);
  pe_teb_expect(run, "ldr [x18, #0x30]", self(), base);
  set_error(1234);
  pe_teb_expect(run, "str [x18, #0x68]", run->teb[0x68 / 8] & 0xffffffff, 1234);
  pe_teb_expect(run, "ldr [x18, x1]", error(), 1234);
  pe_teb_expect(run, "mov x0, x18", teb(), base);
  pe_teb_expect(run, "add x0, x18, #0x68", error_addr(), base + 0x68);
  uint64_t out[2] = {0, 0};
  pair(out);
  pe_teb_expect(run, "stp x17, x18", out[1], base);
  return NULL;
}

// 0 when every TEB read of the DLL found this thread's TEB, on the calling
// thread and on a second thread with a TEB of its own.
static int pe_teb_test(void* lib) {
  static PeTebRun main_run, thread_run;
  uint64_t* slot = (uint64_t*)dlsym(lib, "pe_testdll_teb_slot");
  if (!slot || pthread_key_create(&pe_teb_key, NULL) != 0) {
    printf("TEB test: no pe_testdll_teb_slot in the dylib, or no pthread key\n");
    return 1;
  }
  long offset = pe_teb_slot_offset();
  if (offset < 0) {
    printf("TEB test: could not find the pthread key's TSD slot\n");
    return 1;
  }
  *slot = (uint64_t)offset;
  printf("TEB test: TEB in TSD slot at offset %#lx\n", offset);
  main_run.lib = thread_run.lib = lib;
  pe_teb_run(&main_run);
  pthread_t thread;
  if (pthread_create(&thread, NULL, pe_teb_run, &thread_run) != 0) return 1;
  pthread_join(thread, NULL);
  const int ok = !main_run.failed && !thread_run.failed;
  printf("%s\n", ok ? "TEB reads through x18 found the TEB on both threads" : "TEB test FAILED");
  return ok ? 0 : 1;
}

#endif
