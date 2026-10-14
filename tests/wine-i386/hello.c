/* A 32-bit x86 Windows console program that needs nothing but kernel32:
 * prints a line and exits with code 0. The x86 code runs under FEX through
 * WoW64 (xtajit.dll). No headers: the three kernel32 functions it calls are
 * declared here. */
typedef void* HANDLE;
typedef unsigned long DWORD;
#define STD_OUTPUT_HANDLE ((DWORD)-11)

__declspec(dllimport) HANDLE __stdcall GetStdHandle(DWORD);
__declspec(dllimport) int __stdcall WriteFile(HANDLE, const void*, DWORD, DWORD*, void*);
__declspec(dllimport) __declspec(noreturn) void __stdcall ExitProcess(unsigned);

static unsigned add(unsigned a, unsigned b) { return a + b; }

void start(void) {
  static const char text[] = "Hello from x86\n";
  DWORD written;
  WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), text, sizeof(text) - 1, &written, 0);
  ExitProcess(add(40, 2) == 42 ? 0 : 1);
}
