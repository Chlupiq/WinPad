// SPDX-License-Identifier: MIT
// JITPool.c on a Mac, with StikDebug's universal.js played by a SIGTRAP handler: brk #0xf00d
// with x16 = 1 (x0 = 0, x1 = size) gets an executable region in x0, x16 = 0 detaches; the
// handler moves the pc past the brk, as the script does. Checks that the app asks for the
// region, makes a writable alias, runs code from the region and detaches once, that the
// environment for Wine is set and the marker gone, and that a script that gives no region ends
// in a detach and no JIT. Run by CI (tests/wine-app/jit-protocol-test.sh).
#include "JITPool.h"

#include <signal.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/mman.h>
#include <sys/ucontext.h>
#include <sys/wait.h>
#include <unistd.h>

static int prepares, detaches, give_nothing;
static size_t asked_size;

static void on_trap(int sig, siginfo_t* info, void* context) {
  (void)sig;
  (void)info;
  ucontext_t* uc = context;
  uint64_t* x = uc->uc_mcontext->__ss.__x;
  const uint32_t insn = *(const uint32_t*)uc->uc_mcontext->__ss.__pc;
  if ((insn & 0xffe0001f) != 0xd4200000 || ((insn >> 5) & 0xffff) != 0xf00d) {
    fprintf(stderr, "FAIL: a trap that is not brk #0xf00d (%#x)\n", insn);
    _exit(3);
  }
  if (x[16] == 1) {
    prepares++;
    asked_size = x[1];
    void* region = MAP_FAILED;
    if (!give_nothing && x[0] == 0)
      region = mmap(NULL, x[1], PROT_READ | PROT_EXEC, MAP_ANON | MAP_PRIVATE, -1, 0);
    x[0] = region == MAP_FAILED ? 0 : (uint64_t)region;
  } else if (x[16] == 0) {
    detaches++;
  } else {
    fprintf(stderr, "FAIL: unknown command %llu\n", (unsigned long long)x[16]);
    _exit(3);
  }
  uc->uc_mcontext->__ss.__pc += 4;
}

static int failures;
static void check(int ok, const char* what) {
  printf("%s: %s\n", ok ? "ok" : "FAIL", what);
  if (!ok) failures++;
}

int main(int argc, char** argv) {
  const char* marker = argc > 1 ? argv[1] : "/tmp/winpad-jit-check";
  struct sigaction sa;
  memset(&sa, 0, sizeof(sa));
  sa.sa_sigaction = on_trap;
  sa.sa_flags = SA_SIGINFO;
  sigaction(SIGTRAP, &sa, NULL);

  char why[256];
  setenv("WINPAD_JIT_TXM", "1", 1);
  printf("traced %d, CS_DEBUGGED %d, Xcode %d\n", winpad_jit_traced(), winpad_jit_cs_debugged(),
         winpad_jit_under_xcode());
  const enum winpad_jit_kind kind = winpad_jit_kind(why, sizeof(why));
  printf("kind %d: %s\n", kind, why);
  check(kind == WINPAD_JIT_NONE, "TXM and no debugger: no JIT");

  // A script that gives no region: no JIT, and the debugger is let go.
  pid_t child = fork();
  if (child == 0) {
    give_nothing = 1;
    const int ret = winpad_jit_prepare_pool(1 << 20, marker, why, sizeof(why));
    printf("  no region: %d, %s\n", ret, why);
    _exit(ret == -1 && prepares == 1 && detaches == 1 && !getenv("WINE_IOS_JIT_RX") ? 0 : 1);
  }
  int status = 0;
  waitpid(child, &status, 0);
  check(WIFEXITED(status) && WEXITSTATUS(status) == 0, "no region from the script: no JIT pool, one detach");

  unlink(marker);
  const int ret = winpad_jit_prepare_pool((4 << 20) + 100, marker, why, sizeof(why));
  printf("prepare: %d, %s\n", ret, why);
  check(ret == 0 && winpad_jit_pool_ready(), "the pool is ready");
  check(prepares == 1 && detaches == 1, "one region asked for, then one detach");
  check(asked_size == (size_t)(4 << 20) + 16384, "the size asked for is whole 16 KB pages");
  const char* rx = getenv("WINE_IOS_JIT_RX");
  const char* rw = getenv("WINE_IOS_JIT_RW");
  const char* size = getenv("WINE_IOS_JIT_SIZE");
  check(rx && rw && size && strcmp(rx, rw), "WINE_IOS_JIT_RX, RW and SIZE set for Wine, RW another mapping");
  if (rx && rw && size) {
    // Through the alias, the way FEX writes (DualMap::WriteOffset): the region sees it.
    volatile uint8_t* w = (volatile uint8_t*)strtoull(rw, NULL, 16);
    const volatile uint8_t* r = (const volatile uint8_t*)strtoull(rx, NULL, 16);
    const size_t n = strtoull(size, NULL, 16);
    w[n - 1] = 0x5a;
    check(r[n - 1] == 0x5a && n == (size_t)asked_size, "the writable alias is the same memory, as large");
  }
  check(access(marker, F_OK) != 0, "the marker of the check is gone");
  check(winpad_jit_prepare_pool(1 << 20, marker, why, sizeof(why)) == 0 && prepares == 1,
        "a second call keeps the pool, no new breakpoint");

  FILE* f = fopen(marker, "w");
  if (f) fclose(f);
  check(winpad_jit_failed_before(marker) == 1 && winpad_jit_failed_before(marker) == 0,
        "a marker left from a stopped check is seen once");

  printf("%s\n", failures ? "jit protocol: FAILED" : "jit protocol: all checks passed");
  return failures ? 1 : 0;
}
