/* A 32-bit x86 Windows console program that asks for many files that are not there in a large
 * folder, by names in another case than the files', as Morrowind looks for a loose file under
 * Data Files\Textures for every texture it loads from its archives. Wine reads the whole folder
 * for each such name; on the iPad's case-sensitive volume that kept Morrowind at 100% CPU with
 * no picture. patches/madeira/0015-dir-lookup-cache keeps the folder's listing while it does
 * not change.
 * Run from a folder with TEXTURES\TX_1.DDS .. TX_3000.DDS (CI makes them): finds
 * textures\tx_17.dds in another case, then asks for 20000 names that are not there and prints
 * the milliseconds it took. "dirlookup: done" when the found one was found (exit 0), else
 * "dirlookup: FAIL ..." (exit 1). kernel32 only, no headers. */
typedef void* HANDLE;
typedef unsigned long DWORD;
#define STD_OUTPUT_HANDLE ((DWORD)-11)
#define INVALID_FILE_ATTRIBUTES ((DWORD)-1)

__declspec(dllimport) HANDLE __stdcall GetStdHandle(DWORD);
__declspec(dllimport) int __stdcall WriteFile(HANDLE, const void*, DWORD, DWORD*, void*);
__declspec(dllimport) DWORD __stdcall GetFileAttributesA(const char*);
__declspec(dllimport) DWORD __stdcall GetTickCount(void);
__declspec(dllimport) __declspec(noreturn) void __stdcall ExitProcess(unsigned);

static void puts_(const char* s) {
  DWORD n = 0, written;
  while (s[n]) n++;
  WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), s, n, &written, 0);
}
static char* put_uint(char* p, unsigned v) {
  char tmp[12];
  int n = 0;
  do tmp[n++] = '0' + v % 10; while (v /= 10);
  while (n) *p++ = tmp[--n];
  return p;
}

void start(void) {
  char name[64], line[96], *p;
  if (GetFileAttributesA("textures\\tx_17.dds") == INVALID_FILE_ATTRIBUTES) {
    puts_("dirlookup: FAIL textures\\tx_17.dds not found\n");
    ExitProcess(1);
  }
  puts_("dirlookup: ok textures\\tx_17.dds found in another case\n");
  DWORD t0 = GetTickCount();
  for (unsigned i = 0; i < 20000; i++) {
    p = name;
    for (const char* s = "textures\\missing_"; *s; s++) *p++ = *s;
    p = put_uint(p, i);
    for (const char* s = ".dds"; *s; s++) *p++ = *s;
    *p = 0;
    if (GetFileAttributesA(name) != INVALID_FILE_ATTRIBUTES) {
      puts_("dirlookup: FAIL a missing name was found\n");
      ExitProcess(1);
    }
  }
  p = line;
  for (const char* s = "dirlookup: 20000 missing names in a folder of 3000 took "; *s; s++) *p++ = *s;
  p = put_uint(p, GetTickCount() - t0);
  for (const char* s = " ms\ndirlookup: done\n"; *s; s++) *p++ = *s;
  *p = 0;
  puts_(line);
  ExitProcess(0);
}
