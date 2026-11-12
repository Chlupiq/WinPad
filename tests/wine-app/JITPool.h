// SPDX-License-Identifier: MIT
// FEX's JIT on an iPad: whether this process may run code it writes, and the executable
// memory (the JIT pool) FEX writes its code into. JITPool.c, plain C, so that
// tests/wine-app/jit-protocol-test.c checks it on a Mac.
//
// A process runs code it made only while a debugger has had it (CS_DEBUGGED). On an iPad or
// iPhone with TXM (A15/M2 and newer on iOS 26+) that alone is not enough: every page of
// executable memory has to be written once by the debugger itself. StikDebug's universal.js
// script does that when the app asks it to with a breakpoint (brk #0xf00d, x16 = the command,
// StikJIT's INTEGRATION.md): command 1 (x0 = 0, x1 = size) has the debugger allocate an
// executable region of that size, write to each of its 16 KB pages and return its address in
// x0; command 0 detaches the debugger. The app makes a writable alias of the region itself.
#ifndef WINPAD_JIT_POOL_H
#define WINPAD_JIT_POOL_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

enum winpad_jit_kind {
  // No JIT: the game runs from its AOT image, FEX's interpreter running what it lacks.
  WINPAD_JIT_NONE = 0,
  // A simulator (a Mac process) runs code it makes without a debugger.
  WINPAD_JIT_SIMULATOR,
  // No TXM and a debugger has had the process (CS_DEBUGGED): winehost maps the pool itself.
  WINPAD_JIT_DEBUGGED,
  // TXM, and a debugger is attached now that is not Xcode's: StikDebug with universal.js,
  // which prepares the pool (winpad_jit_prepare_pool).
  WINPAD_JIT_TXM_SCRIPT,
};

// What this process can do now, and why, in WHY (a line for the log and the settings).
enum winpad_jit_kind winpad_jit_kind(char* why, size_t why_size);

// 1 when the device has TXM, 0 when not. WINPAD_JIT_TXM=0/1 overrides it.
int winpad_jit_has_txm(void);
// 1 while a debugger is attached (P_TRACED).
int winpad_jit_traced(void);
// 1 once a debugger has had the process (CS_DEBUGGED): it may run code it made.
int winpad_jit_cs_debugged(void);
// 1 when Xcode started the process (it puts its own variables into the environment). Xcode's
// debugger does not answer StikDebug's breakpoints: one would stop the app.
int winpad_jit_under_xcode(void);

// With a StikDebug script attached (WINPAD_JIT_TXM_SCRIPT): asks it for an executable region
// of SIZE bytes, maps a writable alias of it, checks that code written through the alias runs
// and detaches the debugger. MARKER is a file written just before that check and removed after
// it: one that is still there at the next launch means the check stopped the app
// (winpad_jit_failed_before). On success sets WINE_IOS_JIT_RX, WINE_IOS_JIT_RW and
// WINE_IOS_JIT_SIZE for Wine and FEX (winehost.c then makes no pool of its own) and returns 0;
// else returns -1. WHY says what happened. Only the first call does anything: later ones return
// its result.
int winpad_jit_prepare_pool(size_t size, const char* marker, char* why, size_t why_size);
// 1 when the pool is prepared.
int winpad_jit_pool_ready(void);
// 1 when MARKER is there (the check of an earlier launch stopped the app). Removes it, so that
// the launch after this one tries again.
int winpad_jit_failed_before(const char* marker);

#ifdef __cplusplus
}
#endif

#endif
