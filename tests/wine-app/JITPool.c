// SPDX-License-Identifier: MIT
// FEX's JIT on an iPad (JITPool.h): is it there, and the JIT pool from StikDebug's script.
#include "JITPool.h"

#include <CoreFoundation/CoreFoundation.h>
#include <TargetConditionals.h>
#include <dlfcn.h>
#include <errno.h>
#include <fcntl.h>
#include <libkern/OSCacheControl.h>
#include <mach/mach.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/sysctl.h>
#include <unistd.h>

// <sys/codesign.h> is not in the iOS SDK.
extern int csops(pid_t pid, unsigned int ops, void* useraddr, size_t usersize);
#define WINPAD_CS_OPS_STATUS 0
#define WINPAD_CS_DEBUGGED 0x10000000u

// The address the debugger writes each page at is 9 hex digits in StikDebug (makeBulkWriteCommands):
// a region must end below 64 GB.
#define WINPAD_JIT_ADDRESS_LIMIT 0x1000000000ull

static void say(char* why, size_t size, const char* format, ...) {
  if (!why || !size) return;
  va_list args;
  va_start(args, format);
  vsnprintf(why, size, format, args);
  va_end(args);
}

int winpad_jit_cs_debugged(void) {
  uint32_t flags = 0;
  if (csops(getpid(), WINPAD_CS_OPS_STATUS, &flags, sizeof(flags))) return 0;
  return (flags & WINPAD_CS_DEBUGGED) != 0;
}

int winpad_jit_traced(void) {
  struct kinfo_proc info;
  size_t size = sizeof(info);
  int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
  memset(&info, 0, sizeof(info));
  if (sysctl(mib, 4, &info, &size, NULL, 0)) return 0;
  return (info.kp_proc.p_flag & P_TRACED) != 0;
}

int winpad_jit_under_xcode(void) {
  return getenv("__XCODE_BUILT_PRODUCTS_DIR_PATHS") != NULL || getenv("OS_ACTIVITY_DT_MODE") != NULL;
}

// TXM's region in the device tree's memory map, as StikJIT looks for it (ProcessInfo+TXM.swift).
// IOKit has no headers in the iOS SDK: its functions come from dlsym. -1 when it cannot tell.
// Only a device has it (the simulator never asks).
#if !TARGET_OS_SIMULATOR
static int txm_in_device_tree(void) {
  void* iokit = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_LAZY);
  if (!iokit) return -1;
  uint32_t (*from_path)(mach_port_t, const char*) = dlsym(iokit, "IORegistryEntryFromPath");
  CFTypeRef (*property)(uint32_t, CFStringRef, CFAllocatorRef, uint32_t) =
      dlsym(iokit, "IORegistryEntryCreateCFProperty");
  kern_return_t (*release)(uint32_t) = dlsym(iokit, "IOObjectRelease");
  if (!from_path || !property || !release) return -1;
  uint32_t map = from_path(MACH_PORT_NULL, "IODeviceTree:/chosen/memory-map");
  if (!map) return -1;
  CFTypeRef keys = property(map, CFSTR("IORegistryEntryPropertyKeys"), kCFAllocatorDefault, 0);
  release(map);
  if (!keys) return -1;
  int found = -1;
  if (CFGetTypeID(keys) == CFArrayGetTypeID())
    found = CFArrayContainsValue(keys, CFRangeMake(0, CFArrayGetCount(keys)), CFSTR("TXM")) ? 1 : 0;
  CFRelease(keys);
  return found;
}

static int os_major(void) {
  char version[32] = "";
  size_t size = sizeof(version);
  if (sysctlbyname("kern.osproductversion", version, &size, NULL, 0)) return 0;
  return atoi(version);
}
#endif

int winpad_jit_has_txm(void) {
  const char* force = getenv("WINPAD_JIT_TXM");
  if (force && *force) return atoi(force) != 0;
#if TARGET_OS_SIMULATOR
  return 0;
#else
  int txm = txm_in_device_tree();
  // Not readable from the sandbox: StikDebug's own rule, every device on iOS 27 (the A12/A13 iPads
  // aside, which do not get it) and an A15/M2 or newer on iOS 26. An iPad that cannot have it
  // runs no iOS 26 anyway, so iOS 26 and newer counts as TXM.
  if (txm < 0) txm = os_major() >= 26;
  return txm;
#endif
}

enum winpad_jit_kind winpad_jit_kind(char* why, size_t why_size) {
#if TARGET_OS_SIMULATOR
  say(why, why_size, "simulator: the JIT runs without a debugger");
  return WINPAD_JIT_SIMULATOR;
#else
  if (winpad_jit_pool_ready()) {
    say(why, why_size, "StikDebug prepared the JIT pool");
    return WINPAD_JIT_TXM_SCRIPT;
  }
  const int txm = winpad_jit_has_txm(), traced = winpad_jit_traced(), debugged = winpad_jit_cs_debugged();
  if (!txm) {
    if (debugged) {
      say(why, why_size, "no TXM, a debugger has had the app (CS_DEBUGGED): the JIT runs");
      return WINPAD_JIT_DEBUGGED;
    }
    say(why, why_size, "no TXM, no debugger: no JIT (StikDebug turns it on)");
    return WINPAD_JIT_NONE;
  }
  if (!traced) {
    say(why, why_size, debugged ? "TXM: the debugger left before it prepared the JIT pool: no JIT"
                                : "TXM, no debugger: no JIT (StikDebug with universal.js turns it on)");
    return WINPAD_JIT_NONE;
  }
  if (winpad_jit_under_xcode()) {
    say(why, why_size, "TXM under Xcode's debugger, which cannot make memory executable: no JIT");
    return WINPAD_JIT_NONE;
  }
  say(why, why_size, "TXM, a debugger is attached (StikDebug): it prepares the JIT pool");
  return WINPAD_JIT_TXM_SCRIPT;
#endif
}

#if defined(__aarch64__)
// StikDebug's JIT "system calls" (universal.js): x16 the command, x0 and x1 its arguments, x0 the
// result. The script moves the pc past the brk.
__attribute__((naked, noinline)) static void* jit26_prepare_region(void* address, size_t size) {
  __asm__ volatile("mov x16, #1\n"
                   "brk #0xf00d\n"
                   "ret\n");
}

__attribute__((naked, noinline)) static void jit26_detach(void) {
  __asm__ volatile("mov x16, #0\n"
                   "brk #0xf00d\n"
                   "ret\n");
}
#endif

static int pool_state;  // 0 not tried, 1 ready, -1 failed
static char pool_why[256];

int winpad_jit_pool_ready(void) { return pool_state == 1; }

int winpad_jit_failed_before(const char* marker) {
  if (!marker || access(marker, F_OK)) return 0;
  unlink(marker);
  return 1;
}

// The region [address, address + size) is mapped and executable throughout. The debugger's
// writes to each page can split it into many VM entries, so each one is checked in turn.
static char region_note[96];
static int executable_region(vm_address_t address, size_t size) {
  region_note[0] = 0;
  const vm_address_t end = address + size;
  vm_address_t at = address;
  while (at < end) {
    vm_address_t start = at;
    vm_size_t length = 0;
    vm_region_basic_info_data_64_t info;
    mach_msg_type_number_t count = VM_REGION_BASIC_INFO_COUNT_64;
    mach_port_t object = MACH_PORT_NULL;
    if (vm_region_64(mach_task_self(), &start, &length, VM_REGION_BASIC_INFO_64, (vm_region_info_t)&info, &count,
                     &object) != KERN_SUCCESS) {
      snprintf(region_note, sizeof(region_note), "nothing mapped at %#lx", (unsigned long)at);
      return 0;
    }
    if (object != MACH_PORT_NULL) mach_port_deallocate(mach_task_self(), object);
    if (start > at || !length) {
      snprintf(region_note, sizeof(region_note), "nothing mapped at %#lx", (unsigned long)at);
      return 0;
    }
    if (!(info.protection & VM_PROT_EXECUTE)) {
      snprintf(region_note, sizeof(region_note), "%#lx is not executable (prot %d/%d)", (unsigned long)at,
               info.protection, info.max_protection);
      return 0;
    }
    at = start + length;
  }
  return 1;
}

static int prepare(size_t size, const char* marker, char* why, size_t why_size) {
#if !defined(__aarch64__)
  say(why, why_size, "not arm64");
  return -1;
#else
  const vm_address_t page = 16384;
  size = (size + page - 1) & ~(size_t)(page - 1);
  // Command 1 with no address: the debugger allocates the region and writes to its pages.
  const vm_address_t rx = (vm_address_t)jit26_prepare_region(NULL, size);
  if (!rx || (rx & (page - 1)) || !executable_region(rx, size)) {
    jit26_detach();
    say(why, why_size, "StikDebug's script gave no executable region (%#lx, %s): is it universal.js?",
        (unsigned long)rx, region_note[0] ? region_note : "not on a 16 KB page");
    return -1;
  }
  if (rx + size > WINPAD_JIT_ADDRESS_LIMIT) {
    jit26_detach();
    say(why, why_size, "StikDebug's region %#lx is above 64 GB, where it cannot prepare pages", (unsigned long)rx);
    return -1;
  }
  // The writable alias FEX writes its code through (FEXCore::DualMap::WriteOffset).
  vm_address_t rw = 0;
  vm_prot_t cur = 0, max = 0;
  kern_return_t kr = vm_remap(mach_task_self(), &rw, size, 0, VM_FLAGS_ANYWHERE, mach_task_self(), rx, FALSE, &cur,
                              &max, VM_INHERIT_NONE);
  if (kr == KERN_SUCCESS) {
    kr = vm_protect(mach_task_self(), rw, size, FALSE, VM_PROT_READ | VM_PROT_WRITE);
    if (kr != KERN_SUCCESS) vm_deallocate(mach_task_self(), rw, size);
  }
  if (kr != KERN_SUCCESS) {
    jit26_detach();
    say(why, why_size, "no writable alias of the JIT region %#lx: %s", (unsigned long)rx, mach_error_string(kr));
    return -1;
  }
  // Code written through the alias runs from the region: mov w0, #42; ret. Should TXM refuse it,
  // the app stops here, and the marker tells the next launch to run without the JIT.
  int fd = marker ? open(marker, O_WRONLY | O_CREAT | O_TRUNC, 0644) : -1;
  if (fd >= 0) {
    (void)!write(fd, "jit check\n", 10);
    fsync(fd);
    close(fd);
  }
  volatile uint32_t* code = (volatile uint32_t*)rw;
  code[0] = 0x52800540;
  code[1] = 0xd65f03c0;
  sys_icache_invalidate((void*)rx, 8);
  const int answer = ((int (*)(void))rx)();
  code[0] = 0;
  code[1] = 0;
  if (marker) unlink(marker);
  // The pages stay executable after the debugger has gone; the process stays CS_DEBUGGED.
  jit26_detach();
  if (answer != 42) {
    say(why, why_size, "code in the JIT region returned %d, not 42", answer);
    return -1;
  }
  char buf[32];
  snprintf(buf, sizeof(buf), "%lx", (unsigned long)rx);
  setenv("WINE_IOS_JIT_RX", buf, 1);
  snprintf(buf, sizeof(buf), "%lx", (unsigned long)rw);
  setenv("WINE_IOS_JIT_RW", buf, 1);
  snprintf(buf, sizeof(buf), "%lx", (unsigned long)size);
  setenv("WINE_IOS_JIT_SIZE", buf, 1);
  say(why, why_size, "StikDebug prepared the JIT pool: RX %#lx RW %#lx, %zu MB", (unsigned long)rx, (unsigned long)rw,
      size >> 20);
  return 0;
#endif
}

int winpad_jit_prepare_pool(size_t size, const char* marker, char* why, size_t why_size) {
  if (!pool_state) pool_state = prepare(size, marker, pool_why, sizeof(pool_why)) ? -1 : 1;
  say(why, why_size, "%s", pool_why);
  return pool_state == 1 ? 0 : -1;
}
