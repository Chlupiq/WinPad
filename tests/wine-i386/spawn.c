/* A 32-bit x86 Windows console program that starts another program next to it, as a game's
 * launcher starts the game (Morrowind Launcher.exe: Play -> Morrowind.exe). On iOS a 32-bit
 * program cannot start a second one; with WINPAD_HANDOFF_FILE and WINPAD_HANDOFF_DIR set
 * Wine writes the start to that file and refuses it with ERROR_ACCESS_DENIED
 * (patches/madeira/0014-handoff-child-program), which the app turns into its next launch.
 * Starts "hello.exe" -arg "two words" from its own folder; prints "spawn: handed over" when
 * CreateProcessA failed with ERROR_ACCESS_DENIED, "spawn: started" when it ran (exit 0 for
 * both), else "spawn: FAIL <error>" (exit 1). kernel32 only, no headers. */
typedef void* HANDLE;
typedef unsigned long DWORD;
typedef int BOOL;
#define STD_OUTPUT_HANDLE ((DWORD)-11)

typedef struct {
  DWORD cb;
  char *lpReserved, *lpDesktop, *lpTitle;
  DWORD dwX, dwY, dwXSize, dwYSize, dwXCountChars, dwYCountChars, dwFillAttribute, dwFlags;
  unsigned short wShowWindow, cbReserved2;
  unsigned char* lpReserved2;
  HANDLE hStdInput, hStdOutput, hStdError;
} STARTUPINFOA;
typedef struct {
  HANDLE hProcess, hThread;
  DWORD dwProcessId, dwThreadId;
} PROCESS_INFORMATION;

__declspec(dllimport) HANDLE __stdcall GetStdHandle(DWORD);
__declspec(dllimport) int __stdcall WriteFile(HANDLE, const void*, DWORD, DWORD*, void*);
__declspec(dllimport) DWORD __stdcall GetModuleFileNameA(HANDLE, char*, DWORD);
__declspec(dllimport) BOOL __stdcall CreateProcessA(const char*, char*, void*, void*, BOOL, DWORD, void*,
                                                    const char*, STARTUPINFOA*, PROCESS_INFORMATION*);
__declspec(dllimport) DWORD __stdcall GetLastError(void);
__declspec(dllimport) DWORD __stdcall WaitForSingleObject(HANDLE, DWORD);
__declspec(dllimport) __declspec(noreturn) void __stdcall ExitProcess(unsigned);

static void puts_(const char* s) {
  DWORD n = 0, written;
  while (s[n]) n++;
  WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), s, n, &written, 0);
}
static void num(DWORD v) {
  char b[12];
  int i = 11;
  b[i] = 0;
  do b[--i] = '0' + v % 10; while (v /= 10);
  puts_(b + i);
}

void start(void) {
  static char path[600], cmd[700];
  DWORD n = GetModuleFileNameA(0, path, 520);
  while (n && path[n - 1] != '\\') n--;
  const char* name = "hello.exe";
  for (int i = 0; name[i]; i++) path[n++] = name[i];
  path[n] = 0;
  int c = 0;
  cmd[c++] = '"';
  for (int i = 0; path[i]; i++) cmd[c++] = path[i];
  const char* rest = "\" -arg \"two words\"";
  for (int i = 0; rest[i]; i++) cmd[c++] = rest[i];
  cmd[c] = 0;
  puts_("spawn: starting ");
  puts_(cmd);
  puts_("\n");
  STARTUPINFOA si = {sizeof(si)};
  PROCESS_INFORMATION pi;
  if (CreateProcessA(path, cmd, 0, 0, 0, 0, 0, 0, &si, &pi)) {
    WaitForSingleObject(pi.hProcess, 30000);
    puts_("spawn: started\n");
    ExitProcess(0);
  }
  DWORD err = GetLastError();
  if (err == 5) {
    puts_("spawn: handed over\n");
    ExitProcess(0);
  }
  puts_("spawn: FAIL ");
  num(err);
  puts_("\n");
  ExitProcess(1);
}
