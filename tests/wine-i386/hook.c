/* A 32-bit x86 Windows console program that does what a hook installer (an
 * ASI loader, a widescreen fix) does to a game's code: VirtualProtect a page
 * of its own .text to read-write-execute and back, once without writing to it
 * (page A) and once patching code on it that never runs (page B, after gb).
 * FEX drops the blocks of a page made executable; the blocks of an AOT image
 * whose code did not change have to come back from it (patches/fex-wow64/0029),
 * fa's with its page, gb's although its page changed. It calls fa and gb
 * before and after, prints "hook: done" and exits with 0 when the results
 * and the patch are right. kernel32 only, no headers. */
typedef void* HANDLE;
typedef unsigned long DWORD;
#define STD_OUTPUT_HANDLE ((DWORD)-11)
#define PAGE_EXECUTE_READWRITE 0x40

__declspec(dllimport) HANDLE __stdcall GetStdHandle(DWORD);
__declspec(dllimport) int __stdcall WriteFile(HANDLE, const void*, DWORD, DWORD*, void*);
__declspec(dllimport) int __stdcall VirtualProtect(void*, unsigned long, DWORD, DWORD*);
__declspec(dllimport) __declspec(noreturn) void __stdcall ExitProcess(unsigned);

/* Page A holds fa only, page B gb and, 64 bytes on, the code that gets patched. */
__asm__(".text\n"
        ".p2align 12\n"
        "_page_a:\n"
        "_fa:\n"
        "  movl 4(%esp), %eax\n"
        "  addl $7, %eax\n"
        "  ret\n"
        ".p2align 12\n"
        "_page_b:\n"
        "_gb:\n"
        "  movl 4(%esp), %eax\n"
        "  imull $3, %eax, %eax\n"
        "  ret\n"
        ".p2align 6\n"
        "_patched:\n"
        "  movl $1, %eax\n"
        "  ret\n"
        ".p2align 12\n");
extern unsigned char page_a[], page_b[], patched[];
unsigned fa(unsigned);
unsigned gb(unsigned);

static DWORD put(const char* s) {
  DWORD n = 0, written;
  while (s[n]) {
    n++;
  }
  WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), s, n, &written, 0);
  return n;
}

static unsigned run(void) {
  unsigned sum = 0;
  for (unsigned i = 0; i < 1000; i++) {
    sum += fa(i) + gb(i);
  }
  return sum;
}

void start(void) {
  /* sum of (i + 7) + 3 i for i < 1000 */
  const unsigned expected = 4 * (999 * 1000 / 2) + 7 * 1000;
  int ok = run() == expected;
  DWORD old, dummy;
  ok &= VirtualProtect(page_a, 4096, PAGE_EXECUTE_READWRITE, &old) && VirtualProtect(page_a, 4096, old, &dummy);
  ok &= VirtualProtect(page_b, 4096, PAGE_EXECUTE_READWRITE, &old);
  patched[1] = 2; /* movl $2, %eax */
  ok &= VirtualProtect(page_b, 4096, old, &dummy);
  ok &= patched[1] == 2;
  ok &= run() == expected;
  put(ok ? "hook: done\n" : "hook: FAIL\n");
  ExitProcess(ok ? 0 : 1);
}
