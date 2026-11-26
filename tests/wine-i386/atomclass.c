/* A 32-bit x86 Windows console program that creates windows by class ATOM,
 * as a dialog-based game launcher does (CreateDialog -> CreateWindowEx with
 * the dialog class, MAKEINTATOM(0x8002)). Under WoW64 a class atom travels
 * to win32u as the Buffer of a UNICODE_STRING; WinPad's wow64win.dll must
 * pass it through as an atom and not as a guest address (+ the guest window
 * base), or NtUserCreateWindowEx reads unmapped memory
 * (patches/wine/0005-wow64win-atoms-stay-atoms.patch; Morrowind Launcher.exe
 * died like that).
 * Each check prints "atomclass: ok ..." or "atomclass: FAIL ..."; the last
 * line, "atomclass: all passed", only when every one passed (exit 0, else 1).
 * kernel32 and user32 only, no headers. */
typedef void *HANDLE, *HWND, *HINSTANCE, *HICON, *HCURSOR, *HBRUSH, *HMENU;
typedef unsigned long DWORD;
typedef unsigned short WORD, ATOM, WCHAR;
typedef unsigned int UINT;
typedef long LONG, LRESULT;
typedef long LPARAM;
typedef unsigned int WPARAM;
typedef int BOOL;
typedef LRESULT(__stdcall *WNDPROC)(HWND, UINT, WPARAM, LPARAM);
typedef long(__stdcall *DLGPROC)(HWND, UINT, WPARAM, LPARAM);

#define STD_OUTPUT_HANDLE ((DWORD)-11)
#define MAKEINTATOM(a) ((const WCHAR *)(unsigned long)(WORD)(a))
#define WC_DIALOG_ATOM 0x8002
#define WS_OVERLAPPEDWINDOW 0x00cf0000
#define WS_POPUP 0x80000000u
#define DS_SETFONT 0x40
#define WM_CREATE 0x0001
#define WM_INITDIALOG 0x0110

typedef struct {
  UINT cbSize, style;
  WNDPROC lpfnWndProc;
  int cbClsExtra, cbWndExtra;
  HINSTANCE hInstance;
  HICON hIcon;
  HCURSOR hCursor;
  HBRUSH hbrBackground;
  const WCHAR *lpszMenuName, *lpszClassName;
  HICON hIconSm;
} WNDCLASSEXW;

typedef struct {
  void *lpCreateParams;
  HINSTANCE hInstance;
  HMENU hMenu;
  HWND hwndParent;
  int cy, cx, y, x;
  LONG style;
  const WCHAR *lpszName, *lpszClass;
  DWORD dwExStyle;
} CREATESTRUCTW;

/* A dialog template with no controls and no font. */
typedef struct {
  DWORD style, dwExtendedStyle;
  WORD cdit;
  short x, y, cx, cy;
  WORD menu, windowClass, title;
} DLGTEMPLATE0;

__declspec(dllimport) HANDLE __stdcall GetStdHandle(DWORD);
__declspec(dllimport) int __stdcall WriteFile(HANDLE, const void *, DWORD, DWORD *, void *);
__declspec(dllimport) HINSTANCE __stdcall GetModuleHandleW(const WCHAR *);
__declspec(dllimport) __declspec(noreturn) void __stdcall ExitProcess(unsigned);
__declspec(dllimport) ATOM __stdcall RegisterClassExW(const WNDCLASSEXW *);
__declspec(dllimport) BOOL __stdcall GetClassInfoExW(HINSTANCE, const WCHAR *, WNDCLASSEXW *);
__declspec(dllimport) BOOL __stdcall UnregisterClassW(const WCHAR *, HINSTANCE);
__declspec(dllimport) HWND __stdcall CreateWindowExW(DWORD, const WCHAR *, const WCHAR *, DWORD, int, int,
                                                    int, int, HWND, HMENU, HINSTANCE, void *);
__declspec(dllimport) HWND __stdcall CreateWindowExA(DWORD, const char *, const char *, DWORD, int, int,
                                                    int, int, HWND, HMENU, HINSTANCE, void *);
__declspec(dllimport) HWND __stdcall CreateDialogIndirectParamW(HINSTANCE, const void *, HWND, DLGPROC,
                                                               LPARAM);
__declspec(dllimport) BOOL __stdcall DestroyWindow(HWND);
__declspec(dllimport) int __stdcall GetClassNameW(HWND, WCHAR *, int);
__declspec(dllimport) HWND __stdcall FindWindowW(const WCHAR *, const WCHAR *);
__declspec(dllimport) DWORD __stdcall GetClassLongW(HWND, int);
__declspec(dllimport) LRESULT __stdcall DefWindowProcW(HWND, UINT, WPARAM, LPARAM);
#define GCW_ATOM (-32)

static int failed;
static const WCHAR *create_class;
static int init_dialog_seen;

static void out(const char *s, DWORD n) {
  DWORD written;
  WriteFile(GetStdHandle(STD_OUTPUT_HANDLE), s, n, &written, 0);
}
static void puts_(const char *s) {
  DWORD n = 0;
  while (s[n]) n++;
  out(s, n);
}
static void hex(unsigned long v) {
  char b[11] = "0x";
  for (int i = 0; i < 8; i++) b[2 + i] = "0123456789abcdef"[(v >> (28 - 4 * i)) & 15];
  out(b, 10);
}
static void check(int ok, const char *what, unsigned long v) {
  puts_(ok ? "atomclass: ok " : "atomclass: FAIL ");
  puts_(what);
  puts_(" (");
  hex(v);
  puts_(")\n");
  if (!ok) failed = 1;
}
static int wcs_eq(const WCHAR *a, const char *b) {
  while (*a && *a == (WCHAR)*b) a++, b++;
  return *a == 0 && *b == 0;
}

static LRESULT __stdcall wndproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  if (msg == WM_CREATE) create_class = ((const CREATESTRUCTW *)lp)->lpszClass;
  return DefWindowProcW(hwnd, msg, wp, lp);
}
static long __stdcall dlgproc(HWND hwnd, UINT msg, WPARAM wp, LPARAM lp) {
  (void)hwnd, (void)wp, (void)lp;
  if (msg == WM_INITDIALOG) init_dialog_seen = 1;
  return msg == WM_INITDIALOG;
}

void start(void) {
  static const WCHAR name[] = {'W', 'i', 'n', 'P', 'a', 'd', 'A', 't', 'o', 'm', 0};
  HINSTANCE inst = GetModuleHandleW(0);
  WNDCLASSEXW wc = {0};
  wc.cbSize = sizeof(wc);
  wc.lpfnWndProc = wndproc;
  wc.hInstance = inst;
  wc.lpszClassName = name;
  /* A menu named by a resource id, as most programs name theirs. */
  wc.lpszMenuName = MAKEINTATOM(123);
  ATOM atom = RegisterClassExW(&wc);
  check(atom >= 0xc000, "RegisterClassExW gives a string atom", atom);
  if (!atom) ExitProcess(1);

  HWND w = CreateWindowExW(0, MAKEINTATOM(atom), name, WS_OVERLAPPEDWINDOW, 0, 0, 200, 100, 0, 0, inst, 0);
  check(w != 0, "CreateWindowExW by the class atom", (unsigned long)w);
  if (w) {
    WCHAR got[64] = {0};
    GetClassNameW(w, got, 64);
    check(wcs_eq(got, "WinPadAtom"), "GetClassNameW names the class", got[0]);
    check(GetClassLongW(w, GCW_ATOM) == atom, "GetClassLongW(GCW_ATOM) is the atom", GetClassLongW(w, GCW_ATOM));
    check(create_class == MAKEINTATOM(atom), "WM_CREATE has the atom in lpszClass",
          (unsigned long)create_class);
    check(FindWindowW(MAKEINTATOM(atom), 0) == w, "FindWindowW by the class atom", (unsigned long)w);
    DestroyWindow(w);
  }

  HWND a = CreateWindowExA(0, (const char *)MAKEINTATOM(atom), "ansi", WS_OVERLAPPEDWINDOW, 0, 0, 200, 100, 0,
                           0, inst, 0);
  check(a != 0, "CreateWindowExA by the class atom", (unsigned long)a);
  if (a) DestroyWindow(a);

  WNDCLASSEXW info = {0};
  info.cbSize = sizeof(info);
  BOOL found = GetClassInfoExW(inst, MAKEINTATOM(atom), &info);
  check(found, "GetClassInfoExW by the class atom", found);
  check(found && info.lpszMenuName == MAKEINTATOM(123), "its menu name is resource id 123",
        (unsigned long)info.lpszMenuName);

  /* The dialog class, by its atom, as CreateDialog makes a dialog. */
  HWND d = CreateWindowExW(0, MAKEINTATOM(WC_DIALOG_ATOM), name, WS_POPUP, 0, 0, 200, 100, 0, 0, inst, 0);
  check(d != 0, "CreateWindowExW with the dialog class atom 0x8002", (unsigned long)d);
  if (d) DestroyWindow(d);

  static DLGTEMPLATE0 tmpl = {WS_POPUP, 0, 0, 0, 0, 100, 50, 0, 0, 0};
  HWND dlg = CreateDialogIndirectParamW(inst, &tmpl, 0, dlgproc, 0);
  check(dlg != 0 && init_dialog_seen, "CreateDialogIndirectParamW makes a dialog (WM_INITDIALOG)",
        (unsigned long)dlg);
  if (dlg) DestroyWindow(dlg);

  check(UnregisterClassW(MAKEINTATOM(atom), inst), "UnregisterClassW by the class atom", atom);

  if (failed) ExitProcess(1);
  puts_("atomclass: all passed\n");
  ExitProcess(0);
}
