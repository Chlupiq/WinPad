/* A 32-bit x86 Windows console program that does what EA's sound system in
 * Need for Speed Underground 2 does with its modules: it copies x86 code into
 * memory of its own, VirtualProtects exactly that range to read-write-execute,
 * fixes up an address in it afterwards and calls it. The code is not in any
 * image, so it reaches FEX's AOT image only by its bytes and address
 * (patches/fex-wow64/0036). Writes to other data on the code's page drop its
 * blocks; they have to come back from the image, as the bytes did not change.
 * Prints "rtcode: done" and exits with 0 when every result is right.
 * kernel32 only, no headers. */
typedef void* HANDLE;
typedef unsigned long DWORD;
#define STD_OUTPUT_HANDLE ((DWORD)-11)
#define MEM_COMMIT 0x1000
#define MEM_RESERVE 0x2000
#define PAGE_READWRITE 0x04
#define PAGE_EXECUTE_READWRITE 0x40

__declspec(dllimport) HANDLE __stdcall GetStdHandle(DWORD);
__declspec(dllimport) int __stdcall WriteFile(HANDLE, const void*, DWORD, DWORD*, void*);
__declspec(dllimport) void* __stdcall VirtualAlloc(void*, unsigned long, DWORD, DWORD);
__declspec(dllimport) int __stdcall VirtualProtect(void*, unsigned long, DWORD, DWORD*);
__declspec(dllimport) __declspec(noreturn) void __stdcall ExitProcess(unsigned);

/* unsigned f(unsigned x) { return callback(x * 5 + 3); }, callback's address
 * fixed up at offset 12 once the range is executable. */
static const unsigned char code[] = {
  0x8b, 0x44, 0x24, 0x04,       /* mov eax, [esp + 4] */
  0x6b, 0xc0, 0x05,             /* imul eax, eax, 5 */
  0x83, 0xc0, 0x03,             /* add eax, 3 */
  0x90,                         /* nop */
  0xb9, 0x00, 0x00, 0x00, 0x00, /* mov ecx, callback */
  0x50,                         /* push eax */
  0xff, 0xd1,                   /* call ecx */
  0x83, 0xc4, 0x04,             /* add esp, 4 */
  0xc3,                         /* ret */
};
#define FIXUP 12

static unsigned __cdecl callback(unsigned x) {
  return x ^ 0x55;
}

static DWORD put(const char* s) {
  DWORD n = 0, written;
  while (s[n]) {
    n++;
  }
  WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), s, n, &written, 0);
  return n;
}

typedef unsigned (*func)(unsigned);

static int run(func f) {
  unsigned sum = 0, expected = 0;
  for (unsigned i = 0; i < 1000; i++) {
    sum += f(i);
    expected += (i * 5 + 3) ^ 0x55;
  }
  return sum == expected;
}

void start(void) {
  /* The same address in every run, as the game's heap gives its modules: the
   * image's code for the range is for this address. */
  unsigned char* page = VirtualAlloc((void*)0x20000000, 4096, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
  if (!page) {
    page = VirtualAlloc(0, 4096, MEM_RESERVE | MEM_COMMIT, PAGE_READWRITE);
  }
  /* Not at the start of the page, and other data on it, as in a heap.
   * Volatile, so the compiler makes no memcpy of the copy loop. */
  volatile unsigned char* at = page + 0x964;
  volatile unsigned* data = (volatile unsigned*)(page + 0x100);
  DWORD old;
  for (unsigned i = 0; i < sizeof(code); i++) {
    at[i] = code[i];
  }
  int ok = page && VirtualProtect((void*)at, sizeof(code), PAGE_EXECUTE_READWRITE, &old);
  unsigned target = (unsigned)callback;
  for (unsigned i = 0; i < 4; i++) {
    at[FIXUP + i] = (unsigned char)(target >> (8 * i));
  }
  for (unsigned round = 0; ok && round < 3; round++) {
    ok &= run((func)(unsigned char*)at);
    *data = round + 1;
  }
  ok &= *data == 3;
  put(ok ? "rtcode: done\n" : "rtcode: FAIL\n");
  ExitProcess(ok ? 0 : 1);
}
