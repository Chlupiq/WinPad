/* A 32-bit x86 Windows program with a window, like the smallest game shell:
 * registers a class, opens a window with a menu bar, paints its client area
 * with GDI and changes colour on a click (WM_LBUTTONDOWN). Shortly after
 * it closes the window and exits with 0, so that FEX writes its code map. The x86 code runs under FEX through WoW64, and so
 * does that of the 32-bit user32, gdi32 and win32u it calls. No headers: the
 * types and functions it uses are declared here. */
typedef void* HANDLE;
typedef HANDLE HWND, HINSTANCE, HMENU, HDC, HBRUSH, HICON, HCURSOR, HGDIOBJ;
typedef unsigned int UINT;
typedef unsigned long DWORD;
typedef long LONG;
typedef int BOOL;
typedef unsigned int WPARAM;
typedef long LPARAM, LRESULT;
typedef LRESULT(__stdcall* WNDPROC)(HWND, UINT, WPARAM, LPARAM);

typedef struct { LONG left, top, right, bottom; } RECT;
typedef struct { LONG x, y; } POINT;
typedef struct {
  UINT style;
  WNDPROC lpfnWndProc;
  int cbClsExtra, cbWndExtra;
  HINSTANCE hInstance;
  HICON hIcon;
  HCURSOR hCursor;
  HBRUSH hbrBackground;
  const char *lpszMenuName, *lpszClassName;
} WNDCLASSA;
typedef struct {
  HWND hwnd;
  UINT message;
  WPARAM wParam;
  LPARAM lParam;
  DWORD time;
  POINT pt;
} MSG;
typedef struct {
  HDC hdc;
  BOOL fErase;
  RECT rcPaint;
  BOOL fRestore, fIncUpdate;
  unsigned char rgbReserved[32];
} PAINTSTRUCT;

#define WM_DESTROY 0x0002
#define WM_PAINT 0x000f
#define WM_TIMER 0x0113
#define WM_LBUTTONDOWN 0x0201
#define WS_OVERLAPPEDWINDOW 0x00cf0000
#define WS_VISIBLE 0x10000000
#define CW_USEDEFAULT ((int)0x80000000)
#define SW_SHOW 5
#define MF_STRING 0
#define TRANSPARENT 1

__declspec(dllimport) HINSTANCE __stdcall GetModuleHandleA(const char*);
__declspec(dllimport) __declspec(noreturn) void __stdcall ExitProcess(UINT);
__declspec(dllimport) unsigned short __stdcall RegisterClassA(const WNDCLASSA*);
__declspec(dllimport) HWND __stdcall CreateWindowExA(DWORD, const char*, const char*, DWORD, int, int, int,
                                                     int, HWND, HMENU, HINSTANCE, void*);
__declspec(dllimport) HMENU __stdcall CreateMenu(void);
__declspec(dllimport) BOOL __stdcall AppendMenuA(HMENU, UINT, UINT, const char*);
__declspec(dllimport) BOOL __stdcall ShowWindow(HWND, int);
__declspec(dllimport) BOOL __stdcall UpdateWindow(HWND);
__declspec(dllimport) BOOL __stdcall GetMessageA(MSG*, HWND, UINT, UINT);
__declspec(dllimport) BOOL __stdcall TranslateMessage(const MSG*);
__declspec(dllimport) LRESULT __stdcall DispatchMessageA(const MSG*);
__declspec(dllimport) LRESULT __stdcall DefWindowProcA(HWND, UINT, WPARAM, LPARAM);
__declspec(dllimport) void __stdcall PostQuitMessage(int);
__declspec(dllimport) HDC __stdcall BeginPaint(HWND, PAINTSTRUCT*);
__declspec(dllimport) BOOL __stdcall EndPaint(HWND, const PAINTSTRUCT*);
__declspec(dllimport) BOOL __stdcall GetClientRect(HWND, RECT*);
__declspec(dllimport) BOOL __stdcall InvalidateRect(HWND, const RECT*, BOOL);
__declspec(dllimport) int __stdcall FillRect(HDC, const RECT*, HBRUSH);
__declspec(dllimport) HBRUSH __stdcall CreateSolidBrush(DWORD);
__declspec(dllimport) BOOL __stdcall DeleteObject(HGDIOBJ);
__declspec(dllimport) int __stdcall SetBkMode(HDC, int);
__declspec(dllimport) BOOL __stdcall TextOutA(HDC, int, int, const char*, int);
__declspec(dllimport) UINT __stdcall SetTimer(HWND, UINT, UINT, void*);
__declspec(dllimport) BOOL __stdcall KillTimer(HWND, UINT);
__declspec(dllimport) BOOL __stdcall DestroyWindow(HWND);

static unsigned clicks;

static LRESULT __stdcall window_proc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  /* Dark blue, then dark red, green... on each click: a big change in pixels. */
  static const DWORD colours[] = {0x00602010, 0x00101080, 0x00108010, 0x00a0a0a0};
  switch (msg) {
  case WM_PAINT: {
    PAINTSTRUCT ps;
    RECT rc;
    HDC dc = BeginPaint(hwnd, &ps);
    GetClientRect(hwnd, &rc);
    HBRUSH brush = CreateSolidBrush(colours[clicks % 4]);
    FillRect(dc, &rc, brush);
    DeleteObject(brush);
    SetBkMode(dc, TRANSPARENT);
    TextOutA(dc, 16, 16, "Hello from x86", 14);
    EndPaint(hwnd, &ps);
    return 0;
  }
  case WM_LBUTTONDOWN:
    clicks++;
    InvalidateRect(hwnd, 0, 1);
    SetTimer(hwnd, 1, 300, 0);
    return 0;
  case WM_TIMER:
    KillTimer(hwnd, 1);
    DestroyWindow(hwnd);
    return 0;
  case WM_DESTROY:
    PostQuitMessage(0);
    return 0;
  }
  return DefWindowProcA(hwnd, msg, wp, lp);
}

void start(void) {
  HINSTANCE inst = GetModuleHandleA(0);
  static WNDCLASSA wc; /* static: zeroed without a memset call */
  wc.lpfnWndProc = window_proc;
  wc.hInstance = inst;
  wc.lpszClassName = "WinPadX86Window";
  if (!RegisterClassA(&wc)) ExitProcess(1);
  /* The menu bar is also what winehost recognises the window to tap by. */
  HMENU menu = CreateMenu();
  AppendMenuA(menu, MF_STRING, 1, "Game");
  HWND hwnd = CreateWindowExA(0, wc.lpszClassName, "WinPad x86 window", WS_OVERLAPPEDWINDOW, CW_USEDEFAULT,
                              CW_USEDEFAULT, 400, 300, 0, menu, inst, 0);
  if (!hwnd) ExitProcess(2);
  ShowWindow(hwnd, SW_SHOW);
  UpdateWindow(hwnd);
  MSG msg;
  while (GetMessageA(&msg, 0, 0, 0) > 0) {
    TranslateMessage(&msg);
    DispatchMessageA(&msg);
  }
  ExitProcess(0);
}
