/* A 32-bit x86 Windows console program for stack growth and guard pages:
 *  1. deep stack use through _chkstk (64 KB frames, alloca) down most of an
 *     8 MB stack, on the main thread (the image asks for 8 MB) and on a
 *     thread made with CreateThread and an 8 MB reserve, as a game makes its
 *     main thread; that thread then runs into the end of its stack and has
 *     to get STATUS_STACK_OVERFLOW;
 *  2. VirtualAlloc: an 8 MB reservation, pages committed with PAGE_GUARD
 *     (one STATUS_GUARD_PAGE_VIOLATION each, then plain read-write), a
 *     guard-page chain grown downwards one 4 KB page at a time from a
 *     vectored handler, and a write to the reservation's lowest page that
 *     the handler commits on the access violation;
 *  3. writes to the lowest committed page of a stack after it grew, and
 *     after the overflow.
 * Exceptions are caught with a vectored handler (no CRT, no __try). It
 * prints a line per check and "guard: all passed" at the end, exit code 0;
 * a failed check prints FAIL and the exit code is 1. No headers. */
typedef void* HANDLE;
typedef unsigned long DWORD, SIZE_T, ULONG_PTR;
typedef long LONG;
typedef int BOOL;

typedef struct {
  DWORD ExceptionCode, ExceptionFlags;
  void* ExceptionRecord;
  void* ExceptionAddress;
  DWORD NumberParameters;
  ULONG_PTR ExceptionInformation[15];
} EXCEPTION_RECORD;
typedef struct {
  EXCEPTION_RECORD* rec;
  unsigned char* ctx; /* i386 CONTEXT */
} EXCEPTION_POINTERS;
#define CTX_EIP 0xb8
#define CTX_ESP 0xc4
typedef struct {
  void* BaseAddress;
  void* AllocationBase;
  DWORD AllocationProtect;
  SIZE_T RegionSize;
  DWORD State, Protect, Type;
} MEMORY_BASIC_INFORMATION;

#define STD_OUTPUT_HANDLE ((DWORD)-11)
#define MEM_COMMIT 0x1000
#define MEM_RESERVE 0x2000
#define MEM_RELEASE 0x8000
#define PAGE_NOACCESS 0x01
#define PAGE_READWRITE 0x04
#define PAGE_GUARD 0x100
#define STACK_SIZE_PARAM_IS_A_RESERVATION 0x10000
#define STATUS_GUARD_PAGE_VIOLATION 0x80000001
#define STATUS_ACCESS_VIOLATION 0xc0000005
#define STATUS_STACK_OVERFLOW 0xc00000fd
#define CONTINUE_EXECUTION (-1)
#define CONTINUE_SEARCH 0
#define MB (1024 * 1024)

__declspec(dllimport) HANDLE __stdcall GetStdHandle(DWORD);
__declspec(dllimport) BOOL __stdcall WriteFile(HANDLE, const void*, DWORD, DWORD*, void*);
__declspec(dllimport) __declspec(noreturn) void __stdcall ExitProcess(unsigned);
__declspec(dllimport) __declspec(noreturn) void __stdcall ExitThread(DWORD);
__declspec(dllimport) HANDLE __stdcall CreateThread(void*, SIZE_T, DWORD(__stdcall*)(void*), void*, DWORD,
                                                   DWORD*);
__declspec(dllimport) DWORD __stdcall WaitForSingleObject(HANDLE, DWORD);
__declspec(dllimport) BOOL __stdcall GetExitCodeThread(HANDLE, DWORD*);
__declspec(dllimport) void* __stdcall VirtualAlloc(void*, SIZE_T, DWORD, DWORD);
__declspec(dllimport) BOOL __stdcall VirtualFree(void*, SIZE_T, DWORD);
__declspec(dllimport) BOOL __stdcall VirtualProtect(void*, SIZE_T, DWORD, DWORD*);
__declspec(dllimport) SIZE_T __stdcall VirtualQuery(const void*, MEMORY_BASIC_INFORMATION*, SIZE_T);
__declspec(dllimport) void* __stdcall AddVectoredExceptionHandler(DWORD, LONG(__stdcall*)(EXCEPTION_POINTERS*));

/* MSVC's _chkstk: EAX bytes, touched a page at a time from the stack
 * pointer down (reads, as MSVC's does), then ESP moves there. Clang calls
 * it for frames of 4 KB and more and for alloca. */
__asm__(".globl __chkstk\n"
        "__chkstk:\n"
        "  pushl %ecx\n"
        "  pushl %eax\n"
        "  leal 12(%esp), %ecx\n" /* the stack pointer before the call */
        "1: cmpl $0x1000, %eax\n"
        "  jb 2f\n"
        "  subl $0x1000, %ecx\n"
        "  testl %eax, (%ecx)\n"
        "  subl $0x1000, %eax\n"
        "  jmp 1b\n"
        "2: subl %eax, %ecx\n"
        "  testl %eax, (%ecx)\n"
        "  popl %eax\n"
        "  movl %esp, %eax\n"
        "  movl %ecx, %esp\n"
        "  movl (%eax), %ecx\n"
        "  pushl 4(%eax)\n"
        "  ret\n");

static HANDLE out;
static int failures;

static void put(const char* s) {
  DWORD n = 0, w;
  while (s[n]) n++;
  WriteFile(out, s, n, &w, 0);
}
static void hex(ULONG_PTR v) {
  char b[11];
  int i;
  b[0] = '0';
  b[1] = 'x';
  for (i = 0; i < 8; i++) b[2 + i] = "0123456789abcdef"[(v >> (28 - 4 * i)) & 15];
  b[10] = 0;
  put(b);
}
static void dec(unsigned v) {
  char b[12];
  int i = 11;
  b[i] = 0;
  do b[--i] = '0' + v % 10;
  while (v /= 10);
  put(b + i);
}
static void check(int ok, const char* what) {
  put(ok ? "guard: ok   " : "guard: FAIL ");
  put(what);
  put("\n");
  if (!ok) failures++;
}

/* The thread's stack from its TEB. */
static char* stack_base(void) {
  char* p;
  __asm__ volatile("movl %%fs:4, %0" : "=r"(p));
  return p;
}
static char* stack_limit(void) {
  char* p;
  __asm__ volatile("movl %%fs:8, %0" : "=r"(p));
  return p;
}
static char* dealloc_stack(void) {
  char* teb;
  __asm__ volatile("movl %%fs:0x18, %0" : "=r"(teb));
  return *(char**)(teb + 0xe0c);
}
static char* esp(void) {
  char* p;
  __asm__ volatile("movl %%esp, %0" : "=r"(p));
  return p;
}

static void show_mem(const char* what, const void* p) {
  MEMORY_BASIC_INFORMATION m;
  put("guard:   ");
  put(what);
  put(" ");
  hex((ULONG_PTR)p);
  if (!VirtualQuery(p, &m, sizeof(m))) {
    put(" VirtualQuery failed\n");
    return;
  }
  put(" base ");
  hex((ULONG_PTR)m.BaseAddress);
  put(" alloc ");
  hex((ULONG_PTR)m.AllocationBase);
  put(" size ");
  hex(m.RegionSize);
  put(" state ");
  hex(m.State);
  put(" protect ");
  hex(m.Protect);
  put("\n");
}
static DWORD protect_of(const void* p) {
  MEMORY_BASIC_INFORMATION m;
  if (!VirtualQuery(p, &m, sizeof(m))) return 0xffffffff;
  return m.State == MEM_COMMIT ? m.Protect : 0;
}
static void show_stack(const char* who) {
  put("guard: ");
  put(who);
  put(" stack ");
  hex((ULONG_PTR)dealloc_stack());
  put("-");
  hex((ULONG_PTR)stack_limit());
  put("-");
  hex((ULONG_PTR)stack_base());
  put(" esp ");
  hex((ULONG_PTR)esp());
  put("\n");
}

/* What the vectored handler saw. */
enum { MODE_NONE, MODE_STACK, MODE_GUARD, MODE_CHAIN, MODE_COMMIT };
static volatile int mode;
static char *region_lo, *region_hi; /* the range the handler answers for */
static volatile unsigned n_guard, n_av, n_overflow, n_other;
static volatile DWORD last_code;
static volatile ULONG_PTR last_addr, last_rw;
static char* resume_esp;  /* MODE_STACK: where the thread goes on */
static void* resume_eip;

static LONG __stdcall handler(EXCEPTION_POINTERS* ep) {
  EXCEPTION_RECORD* r = ep->rec;
  ULONG_PTR addr = r->NumberParameters >= 2 ? r->ExceptionInformation[1] : 0;
  char* page = (char*)(addr & ~0xfffUL);

  if (mode == MODE_NONE) return CONTINUE_SEARCH;
  last_code = r->ExceptionCode;
  last_addr = addr;
  last_rw = r->NumberParameters >= 1 ? r->ExceptionInformation[0] : 0;
  if (mode == MODE_STACK) {
    /* No calls here: this may run in the last pages of the stack. */
    if (r->ExceptionCode == STATUS_GUARD_PAGE_VIOLATION) {
      n_guard++; /* Windows never raises it for the thread's own stack */
      return CONTINUE_EXECUTION;
    }
    if (r->ExceptionCode == STATUS_STACK_OVERFLOW)
      n_overflow++;
    else if (r->ExceptionCode == STATUS_ACCESS_VIOLATION)
      n_av++;
    else {
      n_other++;
      return CONTINUE_SEARCH;
    }
    mode = MODE_NONE;
    *(char**)(ep->ctx + CTX_ESP) = resume_esp;
    *(void**)(ep->ctx + CTX_EIP) = resume_eip;
    return CONTINUE_EXECUTION;
  }
  if ((char*)addr < region_lo || (char*)addr >= region_hi) {
    n_other++;
    return CONTINUE_SEARCH;
  }
  if (r->ExceptionCode == STATUS_GUARD_PAGE_VIOLATION) {
    n_guard++;
    /* A guard-page chain: the next page down becomes the guard page. */
    if (mode == MODE_CHAIN && page - 0x1000 >= region_lo)
      VirtualAlloc(page - 0x1000, 0x1000, MEM_COMMIT, PAGE_READWRITE | PAGE_GUARD);
    return CONTINUE_EXECUTION;
  }
  if (r->ExceptionCode == STATUS_ACCESS_VIOLATION && (mode == MODE_COMMIT || mode == MODE_CHAIN)) {
    /* MODE_CHAIN: a page of the chain that should have been a guard page
     * and was not committed; counted, committed, and the test goes on. */
    n_av++;
    if (!VirtualAlloc(page, 0x1000, MEM_COMMIT, PAGE_READWRITE)) return CONTINUE_SEARCH;
    return CONTINUE_EXECUTION;
  }
  n_other++;
  return CONTINUE_SEARCH;
}
static void reset_counts(int m) {
  n_guard = n_av = n_overflow = n_other = 0;
  last_code = 0;
  last_addr = 0;
  mode = m;
}

/* Stack use: 64 KB frames through _chkstk, and alloca, down to target. */
static char* volatile target;
static char* volatile deepest;
__attribute__((noinline)) static unsigned dive(unsigned depth) {
  volatile char frame[64 * 1024];
  unsigned r;
  frame[0] = (char)depth;
  frame[sizeof(frame) - 1] = (char)depth;
  if ((char*)frame < deepest) deepest = (char*)frame;
  if ((char*)frame - sizeof(frame) <= target) return frame[0];
  if (depth & 1) {
    /* Odd depths take 12 KB more through alloca, also probed by _chkstk. */
    volatile char* a = __builtin_alloca(12 * 1024);
    a[0] = 1;
    if ((char*)a < deepest) deepest = (char*)a;
  }
  r = dive(depth + 1);
  return r + frame[0] + frame[sizeof(frame) - 1];
}

__attribute__((noinline, noreturn)) static void grow_failed(void) {
  put("guard: FAIL deep stack use raised ");
  hex(last_code);
  put(" at ");
  hex(last_addr);
  put(" (");
  put(last_rw ? "write" : "read");
  put("), went down to ");
  hex((ULONG_PTR)deepest);
  put(", guard page violations ");
  dec(n_guard);
  put("\n");
  show_stack("failed");
  show_mem("bottom", dealloc_stack());
  show_mem("fault", (void*)last_addr);
  ExitProcess(1);
}

/* 1 and 3 on the current thread: down to 1 MB above the bottom of the stack,
 * then a write to the lowest committed page. */
static void grow(const char* who) {
  char* bottom = dealloc_stack();
  char *low, *p;
  show_stack(who);
  reset_counts(MODE_STACK);
  target = bottom + 1 * MB;
  deepest = esp();
  /* Any exception here is a failure: it ends the program. */
  resume_esp = (char*)(((ULONG_PTR)esp() - 0x2000) & ~15UL);
  resume_eip = (void*)grow_failed;
  dive(0);
  mode = MODE_NONE;
  put("guard:   ");
  put(who);
  put(" went down to ");
  hex((ULONG_PTR)deepest);
  put(", ");
  dec((unsigned)(stack_base() - deepest) / 1024);
  put(" KB\n");
  check(n_guard + n_av + n_overflow + n_other == 0, "deep stack use through _chkstk raises nothing");
  check(deepest <= bottom + 1 * MB + 64 * 1024, "the stack went down to 1 MB above its bottom");
  low = stack_limit();
  show_stack(who);
  check(low <= deepest && low >= bottom, "StackLimit is at or below the deepest page used");
  /* The lowest committed page of the stack, and every page between it and
   * the deepest one used, take a write. */
  for (p = low; p < deepest; p += 0x1000) *(volatile int*)p = 0x57ac;
  check(*(volatile int*)low == 0x57ac, "the lowest committed page of the stack takes a write");
  show_mem("lowest committed", low);
  show_mem("bottom", bottom);
}

static DWORD thread_result;
__attribute__((noinline, noreturn)) static void after_overflow(void) {
  char* bottom = dealloc_stack();
  char* low = stack_limit();
  put("guard:   overflow: code ");
  hex(last_code);
  put(" at ");
  hex(last_addr);
  put(" (");
  put(last_rw ? "write" : "read");
  put("), went down to ");
  hex((ULONG_PTR)deepest);
  put(", guard page violations ");
  dec(n_guard);
  put("\n");
  show_stack("thread after overflow");
  check(n_overflow == 1 && n_av == 0, "running into the end of the stack raises STATUS_STACK_OVERFLOW");
  check(n_guard == 0, "no STATUS_GUARD_PAGE_VIOLATION from the thread's own stack");
  check(deepest < bottom + 128 * 1024, "the stack is used down to its last 128 KB first");
  check(low >= bottom && low < bottom + 128 * 1024, "StackLimit is then in the last 128 KB");
  /* 3: the lowest committed page after the overflow takes a write. */
  *(volatile int*)low = 0x0f10;
  check(*(volatile int*)low == 0x0f10, "the lowest committed page after the overflow takes a write");
  show_mem("bottom", bottom);
  show_mem("lowest committed", low);
  ExitThread(thread_result);
}

static DWORD __stdcall game_thread(void* arg) {
  (void)arg;
  grow("thread");
  /* Now all of it. */
  show_stack("thread before overflow");
  reset_counts(MODE_STACK);
  target = dealloc_stack();
  deepest = esp();
  resume_esp = (char*)(((ULONG_PTR)esp() - 0x2000) & ~15UL);
  resume_eip = (void*)after_overflow;
  dive(0);
  mode = MODE_NONE;
  check(0, "running into the end of the stack raises an exception");
  return 1;
}

static void stack_tests(void) {
  HANDLE t;
  DWORD code = 0xdead, id;
  grow("main thread");
  t = CreateThread(0, 8 * MB, game_thread, 0, STACK_SIZE_PARAM_IS_A_RESERVATION, &id);
  check(t != 0, "CreateThread with an 8 MB stack reserve");
  if (!t) return;
  WaitForSingleObject(t, 0xffffffff);
  GetExitCodeThread(t, &code);
  check(code == 0, "the thread ran to its end");
}

/* 2: VirtualAlloc with PAGE_GUARD. */
static void touch_read(char* p) { (void)*(volatile int*)p; }
static void touch_write(char* p) { *(volatile int*)p = 0x6a; }

static void guard_tests(void) {
  char* r = VirtualAlloc(0, 8 * MB, MEM_RESERVE, PAGE_READWRITE);
  char *top, *g, *g2, *c;
  unsigned i, before;
  int ok;

  check(r != 0 && !((ULONG_PTR)r & 0xffff), "VirtualAlloc reserves 8 MB at a 64 KB boundary");
  if (!r) return;
  show_mem("reservation", r);
  region_lo = r;
  region_hi = r + 8 * MB;
  top = r + 8 * MB - 64 * 1024;
  check(VirtualAlloc(top, 64 * 1024, MEM_COMMIT, PAGE_READWRITE) == top, "commit its top 64 KB");
  touch_write(top);

  /* A 16 KB guard region: one exception for the first touch, then the
   * memory is plain read-write. */
  g = top - 16 * 1024;
  check(VirtualAlloc(g, 16 * 1024, MEM_COMMIT, PAGE_READWRITE | PAGE_GUARD) == g,
        "commit 16 KB with PAGE_GUARD");
  check(protect_of(g) == (PAGE_READWRITE | PAGE_GUARD), "VirtualQuery says PAGE_GUARD");
  reset_counts(MODE_GUARD);
  touch_read(g + 0x3000);
  check(n_guard == 1 && last_addr >= (ULONG_PTR)g && last_addr < (ULONG_PTR)g + 0x4000,
        "touching it raises STATUS_GUARD_PAGE_VIOLATION once");
  touch_write(g + 0x3000);
  check(n_guard == 1 && n_other == 0, "the next touch goes through");
  check(protect_of(g + 0x3000) == PAGE_READWRITE, "and the page is PAGE_READWRITE now");
  mode = MODE_NONE;

  /* A guard flag on one 4 KB page of a committed 16 KB range. */
  g2 = g - 16 * 1024;
  VirtualAlloc(g2, 16 * 1024, MEM_COMMIT, PAGE_READWRITE);
  touch_write(g2);
  {
    DWORD old;
    check(VirtualProtect(g2 + 0x3000, 0x1000, PAGE_READWRITE | PAGE_GUARD, &old) && old == PAGE_READWRITE,
          "VirtualProtect sets PAGE_GUARD on one 4 KB page");
  }
  reset_counts(MODE_GUARD);
  touch_write(g2 + 0x3000);
  check(n_guard == 1 && (last_addr & ~0xfffUL) == (ULONG_PTR)g2 + 0x3000,
        "touching that page raises STATUS_GUARD_PAGE_VIOLATION for it");
  check(*(volatile int*)(g2 + 0x3000) == 0x6a && n_guard == 1, "the write went through after it");
  /* Its neighbour in the same 16 KB has no guard flag; Windows raises
   * nothing for it. Reported, not checked: a host with 16 KB pages
   * protects all 16 KB together. */
  {
    DWORD old;
    VirtualProtect(g2 + 0x1000, 0x1000, PAGE_READWRITE | PAGE_GUARD, &old);
    before = n_guard;
    touch_write(g2 + 0x2000);
    put("guard:   info: touching a page next to a 4 KB guard page in the same 16 KB raised ");
    dec(n_guard - before);
    put(" guard page violation(s) (Windows: 0)\n");
  }
  mode = MODE_NONE;

  /* A guard-page chain, the way a program grows a buffer downwards: the
   * handler commits the page below each guard page that is hit as the next
   * guard page. Every 4 KB page is hit once, top to bottom. */
  c = g2 - 64 * 1024;
  VirtualAlloc(c + 60 * 1024, 0x1000, MEM_COMMIT, PAGE_READWRITE | PAGE_GUARD);
  reset_counts(MODE_CHAIN);
  region_lo = c;
  for (i = 0; i < 16; i++) touch_write(c + 60 * 1024 - i * 0x1000 + 0x10);
  mode = MODE_NONE;
  region_lo = r;
  put("guard:   chain: ");
  dec(n_guard);
  put(" guard page violations, ");
  dec(n_av);
  put(" access violations, ");
  dec(n_other);
  put(" others for 16 pages\n");
  ok = n_other == 0 && n_guard >= 16;
  for (i = 0; i < 16; i++)
    if (*(volatile int*)(c + 60 * 1024 - i * 0x1000 + 0x10) != 0x6a) ok = 0;
  check(ok && n_av == 0, "a guard-page chain grows down 16 pages, each one written");
  check(n_guard == 16, "one guard page violation per page of the chain");

  /* The lowest page of the reservation, committed by the handler on the
   * access violation of a write to it (the reservation's base). */
  reset_counts(MODE_COMMIT);
  touch_write(r);
  mode = MODE_NONE;
  put("guard:   write to the reservation's base: ");
  dec(n_av);
  put(" access violation(s), last at ");
  hex(last_addr);
  put("\n");
  check(n_av == 1 && last_addr == (ULONG_PTR)r && last_rw == 1,
        "a write to the base of the reservation raises an access violation for it");
  check(*(volatile int*)r == 0x6a, "the write goes through once the handler committed the page");
  show_mem("base", r);

  check(VirtualFree(r, 0, MEM_RELEASE), "VirtualFree releases the reservation");
}

void start(void) {
  out = GetStdHandle(STD_OUTPUT_HANDLE);
  AddVectoredExceptionHandler(1, handler);
  stack_tests();
  guard_tests();
  if (failures) {
    put("guard: ");
    dec(failures);
    put(" check(s) failed\n");
    ExitProcess(1);
  }
  put("guard: all passed\n");
  ExitProcess(0);
}
