/* A 32-bit x86 Windows console program that reads a file by a relative path,
 * as a game reads its data (GLOBAL\GLOBALA.BUN): it prints the current
 * directory, opens DATA\CWD.TXT relative to it and prints its first line.
 * Prints "cwd: done" and exits 0 when the file was read, else exits 1.
 * kernel32 only, no headers. */
typedef void* HANDLE;
typedef unsigned long DWORD;
#define STD_OUTPUT_HANDLE ((DWORD)-11)
#define GENERIC_READ 0x80000000u
#define FILE_SHARE_READ 1
#define OPEN_EXISTING 3
#define INVALID_HANDLE_VALUE ((HANDLE)-1)

__declspec(dllimport) HANDLE __stdcall GetStdHandle(DWORD);
__declspec(dllimport) int __stdcall WriteFile(HANDLE, const void*, DWORD, DWORD*, void*);
__declspec(dllimport) int __stdcall ReadFile(HANDLE, void*, DWORD, DWORD*, void*);
__declspec(dllimport) HANDLE __stdcall CreateFileA(const char*, DWORD, DWORD, void*, DWORD, DWORD, HANDLE);
__declspec(dllimport) DWORD __stdcall GetCurrentDirectoryA(DWORD, char*);
__declspec(dllimport) __declspec(noreturn) void __stdcall ExitProcess(unsigned);

static void out(const char* s, DWORD n) {
  DWORD written;
  WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), s, n, &written, 0);
}
static void puts_(const char* s) {
  DWORD n = 0;
  while (s[n]) n++;
  out(s, n);
}

void start(void) {
  char dir[520];
  DWORD n = GetCurrentDirectoryA(sizeof(dir), dir);
  puts_("cwd: current directory ");
  out(dir, n < sizeof(dir) ? n : 0);
  puts_("\n");
  HANDLE f = CreateFileA("DATA\\CWD.TXT", GENERIC_READ, FILE_SHARE_READ, 0, OPEN_EXISTING, 0, 0);
  if (f == INVALID_HANDLE_VALUE) {
    puts_("cwd: FAIL DATA\\CWD.TXT not found relative to it\n");
    ExitProcess(1);
  }
  char buf[128];
  DWORD got = 0;
  ReadFile(f, buf, sizeof(buf), &got, 0);
  DWORD line = 0;
  while (line < got && buf[line] != '\n') line++;
  puts_("cwd: read ");
  out(buf, line);
  puts_("\ncwd: done\n");
  ExitProcess(0);
}
