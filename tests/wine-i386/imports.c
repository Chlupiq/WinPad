/* A 32-bit x86 Windows program that imports what a game imports: DirectInput 8,
 * DirectSound (by ordinal 1, as games do), DirectDraw, winmm's timers, Winsock,
 * TAPI, netapi32, shell32 and shfolder next to user32, advapi32, gdi32 and
 * kernel32. The loader has to resolve all of it, and the DLLs these import in
 * turn, before the program runs at all (a missing one is c0000135). Then it
 * calls the cheap ones, prints what they return and exits with 0. No d3d9:
 * that has a track of its own. No headers: what it uses is declared here. */
typedef void* HANDLE;
typedef HANDLE HINSTANCE, HWND, HKEY, HGDIOBJ;
typedef unsigned int UINT;
typedef unsigned long DWORD;
typedef unsigned short WORD;
typedef long LONG, HRESULT;
typedef int BOOL;
typedef struct {
  DWORD Data1;
  WORD Data2, Data3;
  unsigned char Data4[8];
} GUID;
typedef struct {
  UINT wPeriodMin, wPeriodMax;
} TIMECAPS;
typedef struct {
  WORD wVersion, wHighVersion;
  char szDescription[257], szSystemStatus[129];
  unsigned short iMaxSockets, iMaxUdpDg;
  char* lpVendorInfo;
} WSADATA;
/* A COM object: a pointer to its table of methods; Release is the third. */
typedef struct {
  struct {
    void* QueryInterface;
    void* AddRef;
    unsigned long(__stdcall* Release)(void*);
  } * vtbl;
} COMOBJ;

#define STD_OUTPUT_HANDLE ((DWORD)-11)

/* kernel32 */
__declspec(dllimport) HANDLE __stdcall GetStdHandle(DWORD);
__declspec(dllimport) BOOL __stdcall WriteFile(HANDLE, const void*, DWORD, DWORD*, void*);
__declspec(dllimport) HINSTANCE __stdcall GetModuleHandleA(const char*);
__declspec(dllimport) __declspec(noreturn) void __stdcall ExitProcess(UINT);
/* user32, advapi32, gdi32 */
__declspec(dllimport) int __stdcall GetSystemMetrics(int);
__declspec(dllimport) LONG __stdcall RegOpenKeyExA(HKEY, const char*, DWORD, DWORD, HKEY*);
__declspec(dllimport) HGDIOBJ __stdcall GetStockObject(int);
/* winmm */
__declspec(dllimport) UINT __stdcall timeSetEvent(UINT, UINT, void*, DWORD, UINT);
__declspec(dllimport) UINT __stdcall timeKillEvent(UINT);
__declspec(dllimport) UINT __stdcall timeBeginPeriod(UINT);
__declspec(dllimport) UINT __stdcall timeEndPeriod(UINT);
__declspec(dllimport) UINT __stdcall timeGetDevCaps(TIMECAPS*, UINT);
__declspec(dllimport) DWORD __stdcall timeGetTime(void);
/* DirectX */
__declspec(dllimport) HRESULT __stdcall DirectInput8Create(HINSTANCE, DWORD, const GUID*, void**, void*);
__declspec(dllimport) HRESULT __stdcall DirectSoundCreate(const GUID*, void**, void*);
__declspec(dllimport) HRESULT __stdcall DirectDrawCreate(GUID*, void**, void*);
/* ws2_32, shfolder, shell32, tapi32, netapi32 */
__declspec(dllimport) int __stdcall WSAStartup(WORD, WSADATA*);
__declspec(dllimport) int __stdcall WSACleanup(void);
__declspec(dllimport) HRESULT __stdcall SHGetFolderPathA(HWND, int, HANDLE, DWORD, char*);
__declspec(dllimport) HINSTANCE __stdcall ShellExecuteA(HWND, const char*, const char*, const char*,
                                                        const char*, int);
__declspec(dllimport) LONG __stdcall lineInitialize(void**, HINSTANCE, void*, const char*, DWORD*);
__declspec(dllimport) DWORD __stdcall NetApiBufferFree(void*);

/* Imported but not called here: what they would start (a timer thread,
 * DirectDraw's wined3d, a TAPI or network session) is not what this checks.
 * Their addresses are taken so the import table keeps them. */
static void* volatile not_called[] = {
    (void*)timeSetEvent,  (void*)timeKillEvent,  (void*)DirectDrawCreate, (void*)RegOpenKeyExA,
    (void*)ShellExecuteA, (void*)lineInitialize, (void*)NetApiBufferFree, (void*)SHGetFolderPathA,
};

static const GUID IID_IDirectInput8A = {
    0xbf798030, 0x483a, 0x4da2, {0xaa, 0x99, 0x5d, 0x64, 0xed, 0x36, 0x97, 0x00}};

static HANDLE out;

static void put(const char* s) {
  DWORD n = 0, written;
  while (s[n]) n++;
  WriteFile(out, s, n, &written, 0);
}

static void put_dec(unsigned long v) {
  char b[12];
  int i = sizeof(b) - 1;
  b[i] = 0;
  do b[--i] = (char)('0' + v % 10); while ((v /= 10) && i);
  put(b + i);
}

static void put_hex(unsigned long v) {
  char b[11];
  b[0] = '0';
  b[1] = 'x';
  for (int i = 0; i < 8; i++) b[2 + i] = "0123456789abcdef"[(v >> (28 - 4 * i)) & 15];
  b[10] = 0;
  put(b);
}

static void line_dec(const char* what, unsigned long v) {
  put(what);
  put_dec(v);
  put("\n");
}

static void line_hr(const char* what, HRESULT hr) {
  put(what);
  put_hex((unsigned long)hr);
  put(hr >= 0 ? " (ok)\n" : " (failed)\n");
}

void start(void) {
  out = GetStdHandle(STD_OUTPUT_HANDLE);
  put("imports: kernel32, user32, advapi32, gdi32, winmm, dinput8, dsound, ddraw, ws2_32, "
      "shfolder, shell32, tapi32 and netapi32 resolved\n");
  line_dec("imports: GetSystemMetrics(SM_CXSCREEN) = ", (unsigned long)GetSystemMetrics(0));
  line_dec("imports: GetStockObject(BLACK_BRUSH) != 0: ", GetStockObject(4) != 0);

  line_dec("imports: timeGetTime() = ", timeGetTime());
  TIMECAPS caps = {0, 0};
  UINT r = timeGetDevCaps(&caps, sizeof(caps));
  put("imports: timeGetDevCaps = ");
  put_dec(r);
  put(", period ");
  put_dec(caps.wPeriodMin);
  put("..");
  put_dec(caps.wPeriodMax);
  put(" ms\n");
  line_dec("imports: timeBeginPeriod(1) = ", timeBeginPeriod(1));
  line_dec("imports: timeEndPeriod(1) = ", timeEndPeriod(1));

  /* Without an audio device this may fail; the call has to come back. */
  COMOBJ* ds = 0;
  HRESULT hr = DirectSoundCreate(0, (void**)&ds, 0);
  line_hr("imports: DirectSoundCreate = ", hr);
  if (hr >= 0 && ds) ds->vtbl->Release(ds);

  COMOBJ* di = 0;
  hr = DirectInput8Create(GetModuleHandleA(0), 0x0800, &IID_IDirectInput8A, (void**)&di, 0);
  line_hr("imports: DirectInput8Create = ", hr);
  if (hr >= 0 && di) di->vtbl->Release(di);

  static WSADATA wsa; /* static: zeroed without a memset call */
  int w = WSAStartup(0x0202, &wsa);
  put("imports: WSAStartup(2.2) = ");
  put_dec((unsigned long)w);
  put(", version ");
  put_dec(wsa.wVersion & 0xff);
  put(".");
  put_dec(wsa.wVersion >> 8);
  put("\n");
  if (!w) WSACleanup();

  unsigned n = 0;
  for (unsigned i = 0; i < sizeof(not_called) / sizeof(not_called[0]); i++) n += not_called[i] != 0;
  line_dec("imports: functions imported but not called, resolved: ", n);
  put("imports: done\n");
  ExitProcess(0);
}
