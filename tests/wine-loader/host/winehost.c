// SPDX-License-Identifier: MIT
// The smallest Wine host: wineserver and one Wine process in this process,
// as Madeira's WineServerBridge.m and WineProcessBridge.m start them, without
// the app around them. Runs as a command-line program on the iPad simulator
// (xcrun simctl spawn).
//
// Usage: winehost SECONDS PROGRAM [ARGS...]
// Environment: WINEPREFIX (created if missing), WINEDLLPATH, optional
// WINEHOST_NLS (directory with the .nls files) and WINEHOST_FRAMES (directory
// that gets the newest content of each window as HWND.bmp). WINEHOST_TYPE
// types its text and WINEHOST_CLICK_MENU=1 clicks the first menu of the
// first window, 2 s after that window first showed (see winios_pProcessEvents);
// WINEHOST_CLICK=X,Y clicks at X %, Y % of its client area instead.
// WINEHOST_AOT_IMAGE names a dylib with FEX AOT code caches linked in
// (tools/cache2macho); its index goes to FEX as WINE_IOS_AOT_INDEX.
// Prints what it starts, then waits SECONDS and exits with 0 if the server
// came up. Whatever Wine does in the meantime goes to stderr.
// Built with -DWINEHOST_LIBRARY it has no main: an app calls winehost_main
// (tests/wine-app), and with WINEHOST_RETURN=1 that returns at the end
// instead of ending the process.
#include <dlfcn.h>
#include <errno.h>
#include <mach/mach.h>
#include <pthread.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <time.h>
#include <unistd.h>

extern int wineserver_main(int argc, char* argv[]);
extern void wineserver_inject_client_fd(int fd);
extern void wineserver_set_nls_dir(const char* path);
extern int wineserver_ready;
extern int foreground;
extern void __wine_main(int argc, char* argv[]);
// Set before __wine_main for a 32-bit x86 program, so the unix side reserves
// its WoW64 guest window before the first TEB (virtual_ios.c, loader_ios.c).
extern int ios_main_image_i386;

// Checked by the server's main loop (fd_ios.c); the app defines it.
volatile int g_wineserver_should_stop = 0;

// Madeira's ntdll turns exit() into a longjmp back to the thread that called
// __wine_main (shims/wine_ios_exit.h); the app defines these thread-locals.
// They cannot be stubs: a thread-local reference goes through a descriptor.
_Thread_local jmp_buf wine_ios_exit_jmpbuf;
_Thread_local volatile int wine_ios_exit_code = 0;
_Thread_local pthread_t wine_ios_main_thread;
_Thread_local int wine_ios_exit_initialized = 0;

// Printed by `wine --version`; the app's build defines it.
const char wine_build[] = "wine-9.x-winpad";

// The server calls this on errors it cannot go on from. The app's version
// ends only the server thread; so does this one.
void fatal_error(const char* err, ...) {
  va_list args;
  va_start(args, err);
  fprintf(stderr, "winehost: wineserver fatal: ");
  vfprintf(stderr, err, args);
  va_end(args);
  pthread_exit(NULL);
}

// win32u's winios display driver (driver_ios.c, MADEIRA_DESKTOP=1) hands
// over the content of a window whenever GDI flushes it; the app uploads it
// into a layer. Here the newest frame of each window goes to a BMP file.
static const char* frames_dir;

static double now(void) {
  struct timespec ts;
  clock_gettime(CLOCK_MONOTONIC, &ts);
  return ts.tv_sec + ts.tv_nsec / 1e9;
}

// Scripted input. States: 0 = no window yet, 1 = window shown, 2 = typing,
// 3 = typed, 4 = clicking, 5 = clicked. What the app's touch and key handlers
// queue is posted from a Wine thread in winios_pProcessEvents, as Madeira's
// Winios.m drains it. Typing and the tap are 2 s apart, so the frames in
// between show the text and nothing else.
static int input_state;
static double state_time;
static void* first_window;
static int menu_x, menu_y;  // a point in the first window's menu bar
static int client_x, client_y, client_w, client_h;  // the first window's client area
static unsigned char* before_click;  // the first window's last frame before the click
static int before_w, before_h;
static void* windows_before_click[64];
static int windows_before_count;
// What the run has to show (WINEHOST_* env) and what it has shown so far;
// the host exits early once everything has shown up.
enum { GOAL_FRAME = 1, GOAL_TYPED = 2, GOAL_NEW_WINDOW = 4, GOAL_CHANGED = 8 };
static int goals_needed, goals_met, wine_exited;
static void met(int goal) { __atomic_fetch_or(&goals_met, goal, __ATOMIC_RELEASE); }
static long dark_before_typing;  // most dark pixels a frame had before typing

static int seen_before_click(void* hwnd) {
  for (int i = 0; i < windows_before_count; i++)
    if (windows_before_click[i] == hwnd) return 1;
  return 0;
}

static void put32(unsigned char* p, unsigned v) {
  p[0] = v;
  p[1] = v >> 8;
  p[2] = v >> 16;
  p[3] = v >> 24;
}

int winios_surface_present(void* hwnd, int dirty_x, int dirty_y, int dirty_w, int dirty_h,
                           int surf_w, int surf_h, int stride, const void* bits) {
  static int presents, after_input;
  long dark = 0;
  met(GOAL_FRAME);
  for (int y = 0; y < surf_h; y++) {
    const unsigned char* row = (const unsigned char*)bits + (size_t)y * stride;
    for (int x = 0; x < surf_w; x++)
      if (row[x * 4] + row[x * 4 + 1] + row[x * 4 + 2] < 3 * 64) dark++;
  }
  int state = __atomic_load_n(&input_state, __ATOMIC_ACQUIRE);
  if (presents++ < 20 || (state >= 3 && after_input++ < 20))
    fprintf(stderr, "winehost: frame of window %p, %dx%d, dirty %d,%d %dx%d, %ld dark pixels\n",
            hwnd, surf_w, surf_h, dirty_x, dirty_y, dirty_w, dirty_h, dark);
  if (state < 2 && dark > dark_before_typing) dark_before_typing = dark;
  static int said_text;
  if (hwnd == first_window && state < 4) {
    size_t row = (size_t)surf_w * 4;
    unsigned char* copy = realloc(before_click, row * surf_h);
    if (copy) {
      for (int y = 0; y < surf_h; y++) memcpy(copy + y * row, (const unsigned char*)bits + (size_t)y * stride, row);
      before_click = copy;
      before_w = surf_w;
      before_h = surf_h;
    }
  }
  static int said_changed;
  if (hwnd == first_window && state == 5 && before_click && surf_w == before_w &&
      surf_h == before_h && !said_changed) {
    long changed = 0;
    for (int y = 0; y < surf_h; y++) {
      const unsigned char* now_row = (const unsigned char*)bits + (size_t)y * stride;
      const unsigned char* old_row = before_click + (size_t)y * surf_w * 4;
      for (int x = 0; x < surf_w; x++)
        changed += memcmp(now_row + x * 4, old_row + x * 4, 3) != 0;
    }
    if (changed > 100) {
      said_changed = 1;
      fprintf(stderr, "winehost: window content changed after the click, %ld pixels\n", changed);
      met(GOAL_CHANGED);
    }
  }
  if (hwnd == first_window && state == 5 && !before_click && !said_changed) {
    // The window showed nothing before the click (winemine's gets no WM_PAINT
    // when it is shown, see the PR), so its first frame is the change.
    said_changed = 1;
    fprintf(stderr, "winehost: window content changed after the click, first frame of the window\n");
  }
  if (state == 3 && hwnd == first_window && dark > dark_before_typing + 50 && !said_text++) {
    fprintf(stderr, "winehost: typed text shows up, %ld dark pixels, at most %ld before\n", dark,
            dark_before_typing);
    met(GOAL_TYPED);
  }
  if (!frames_dir || surf_w <= 0 || surf_h <= 0) return 1;
  // 32-bit top-down BMP: the surface is a 32bpp top-down BGRX DIB already.
  unsigned char header[54] = {'B', 'M'};
  unsigned size = (unsigned)surf_w * surf_h * 4;
  put32(header + 2, 54 + size);
  put32(header + 10, 54);
  put32(header + 14, 40);
  put32(header + 18, surf_w);
  put32(header + 22, -surf_h);
  header[26] = 1;
  header[28] = 32;
  put32(header + 34, size);
  char path[1024], tmp[1040];
  snprintf(path, sizeof(path), "%s/%p.bmp", frames_dir, hwnd);
  snprintf(tmp, sizeof(tmp), "%s.tmp", path);
  FILE* f = fopen(tmp, "wb");
  if (!f) return 1;
  fwrite(header, 1, sizeof(header), f);
  for (int y = 0; y < surf_h; y++) {
    const unsigned char* row = (const unsigned char*)bits + (size_t)y * stride;
    for (int x = 0; x < surf_w; x++) {
      unsigned char px[4] = {row[x * 4], row[x * 4 + 1], row[x * 4 + 2], 0xff};
      fwrite(px, 1, 4, f);
    }
  }
  fclose(f);
  rename(tmp, path);
  return 1;
}

void winios_window_frame(void* hwnd, int x, int y, int w, int h, int visible, int cx, int cy,
                         int cw, int ch) {
  fprintf(stderr, "winehost: window %p at %d,%d %dx%d, visible %d, client %d,%d %dx%d\n", hwnd, x,
          y, w, h, visible, cx, cy, cw, ch);
  // The first visible window with a menu bar (which sits right above the
  // client area, its first item at the left) gets the scripted input.
  if (visible && !first_window && cy - y > 30 && cw > 0) {
    menu_x = cx + 12;
    menu_y = cy - 9;
    first_window = hwnd;
    state_time = now();
    __atomic_store_n(&input_state, 1, __ATOMIC_RELEASE);
  }
  if (visible && cw > 0 && (first_window ? hwnd == first_window : cy - y > 30)) {
    client_x = cx;
    client_y = cy;
    client_w = cw;
    client_h = ch;
  }
  if (!visible || w <= 1 || h <= 1) return;
  int state = __atomic_load_n(&input_state, __ATOMIC_ACQUIRE);
  if (state < 4 && !seen_before_click(hwnd) && windows_before_count < 64)
    windows_before_click[windows_before_count++] = hwnd;
  static int said_new;
  if (state == 5 && !seen_before_click(hwnd) && !said_new++) {
    fprintf(stderr, "winehost: new window %p after the click\n", hwnd);
    met(GOAL_NEW_WINDOW);
  }
}

// From driver_ios.c: they hand one key or mouse event to the wineserver as
// hardware input. Absolute mouse coordinates are screen pixels.
extern void winios_drv_post_key(unsigned short vk, unsigned int flags);
extern void winios_drv_post_mouse(int x, int y, unsigned int flags, unsigned int mouse_data,
                                  void* hwnd);
enum { KEYUP = 2, MOVE = 1, LEFTDOWN = 2, LEFTUP = 4, ABSOLUTE = 0x8000, VK_SHIFT = 0x10 };

static void tap_key(unsigned short vk, int shift) {
  if (shift) winios_drv_post_key(VK_SHIFT, 0);
  winios_drv_post_key(vk, 0);
  winios_drv_post_key(vk, KEYUP);
  if (shift) winios_drv_post_key(VK_SHIFT, KEYUP);
}

// win32u calls this on Wine threads that check for input; in desktop mode
// their message waits wake every 16 ms for it (message_ios.c).
static int advance(int from, int to) {
  return __atomic_compare_exchange_n(&input_state, &from, to, 0, __ATOMIC_ACQ_REL,
                                     __ATOMIC_ACQUIRE);
}

int winios_pProcessEvents(unsigned int mask) {
  (void)mask;
  int state = __atomic_load_n(&input_state, __ATOMIC_ACQUIRE);
  if ((state != 1 && state != 3) || now() < state_time + 2) return 0;
  if (state == 1 && advance(1, 2)) {
    const char* text = getenv("WINEHOST_TYPE");
    if (text && *text) {
      for (const char* c = text; *c; c++) {
        if (*c >= 'a' && *c <= 'z') tap_key(*c - 'a' + 'A', 0);
        else if ((*c >= 'A' && *c <= 'Z') || (*c >= '0' && *c <= '9') || *c == ' ')
          tap_key(*c, *c >= 'A');
      }
      fprintf(stderr, "winehost: typed \"%s\" into window %p\n", text, first_window);
    }
    state_time = now();
    __atomic_store_n(&input_state, 3, __ATOMIC_RELEASE);
    return 1;
  }
  if (state == 3 && advance(3, 4)) {
    const char* menu = getenv("WINEHOST_CLICK_MENU");
    const char* at = getenv("WINEHOST_CLICK");
    int px, py, x = -1, y = -1;
    if (menu && *menu == '1') {
      x = menu_x;
      y = menu_y;
    } else if (at && sscanf(at, "%d,%d", &px, &py) == 2) {
      x = client_x + client_w * px / 100;
      y = client_y + client_h * py / 100;
    }
    if (x >= 0) {
      winios_drv_post_mouse(x, y, MOVE | ABSOLUTE, 0, NULL);
      winios_drv_post_mouse(x, y, MOVE | LEFTDOWN | ABSOLUTE, 0, NULL);
      winios_drv_post_mouse(x, y, LEFTUP | ABSOLUTE, 0, NULL);
      fprintf(stderr, "winehost: clicked %d,%d in window %p (client %d,%d %dx%d)\n", x, y,
              first_window, client_x, client_y, client_w, client_h);
    }
    __atomic_store_n(&input_state, 5, __ATOMIC_RELEASE);
    return 1;
  }
  return 0;
}

// The machine field of a PE file's header, or 0 if it is not one.
static unsigned pe_machine(const char* path) {
  unsigned char buf[0x200];
  FILE* f = fopen(path, "rb");
  if (!f) return 0;
  size_t n = fread(buf, 1, sizeof(buf), f);
  fclose(f);
  if (n < 0x40 || buf[0] != 'M' || buf[1] != 'Z') return 0;
  unsigned off = buf[0x3c] | buf[0x3d] << 8 | buf[0x3e] << 16 | (unsigned)buf[0x3f] << 24;
  if (off + 6 > n || memcmp(buf + off, "PE\0\0", 4)) return 0;
  return buf[off + 4] | buf[off + 5] << 8;
}

// FEX's WoW64 module cannot call sysctl; the app hands it the CPU features
// it needs in FEX_MADEIRA_HOSTPROBE (WineProcessBridge.m, the same keys).
static void publish_host_probe(void) {
  static const struct { const char *key, *sysctl; } probes[] = {
      {"AFP", "hw.optional.arm.FEAT_AFP"},       {"FLAGM", "hw.optional.arm.FEAT_FlagM"},
      {"FLAGM2", "hw.optional.arm.FEAT_FlagM2"}, {"FCMA", "hw.optional.arm.FEAT_FCMA"},
      {"RCPC", "hw.optional.arm.FEAT_LRCPC"},    {"LRCPC2", "hw.optional.arm.FEAT_LRCPC2"},
      {"AES", "hw.optional.arm.FEAT_AES"},       {"PMULL", "hw.optional.arm.FEAT_PMULL"},
      {"SHA", "hw.optional.arm.FEAT_SHA256"},    {"CRC", "hw.optional.armv8_crc32"},
      {"ATOMICS", "hw.optional.arm.FEAT_LSE"},
  };
  char buf[256];
  size_t len = 0;
  buf[0] = 0;
  for (size_t i = 0; i < sizeof(probes) / sizeof(probes[0]); i++) {
    int v = 0;
    size_t sz = sizeof(v);
    const char* val = sysctlbyname(probes[i].sysctl, &v, &sz, NULL, 0) == 0 ? (v ? "1" : "0") : "?";
    len += snprintf(buf + len, sizeof(buf) - len, "%s%s=%s", i ? "," : "", probes[i].key, val);
    if (len >= sizeof(buf)) return;
  }
  setenv("FEX_MADEIRA_HOSTPROBE", buf, 1);
  printf("winehost: FEX host features %s\n", buf);
}

// FEX translates x86 code at run time and Madeira's ntdll copies plain PE
// code (xtajit.dll) into a JIT pool: one memory entry mapped twice, read-write
// and read-execute (JITAllocator.c in the app, which on a device gets the
// executable view from a debugger). The simulator lets a process map it
// itself. WINE_IOS_JIT_RX/RW/SIZE hand it to Wine, as ContentView.swift does.
static int publish_jit_pool(size_t size) {
  mach_port_t task = mach_task_self(), entry = MACH_PORT_NULL;
  memory_object_size_t entry_size = size;
  kern_return_t kr = mach_make_memory_entry_64(
      task, &entry_size, 0, MAP_MEM_NAMED_CREATE | VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE,
      &entry, MACH_PORT_NULL);
  if (kr != KERN_SUCCESS) {
    printf("winehost: JIT pool memory entry failed: %s\n", mach_error_string(kr));
    return 1;
  }
  vm_address_t rw = 0, rx = 0;
  kr = vm_map(task, &rw, size, 0, VM_FLAGS_ANYWHERE, entry, 0, FALSE, VM_PROT_READ | VM_PROT_WRITE,
              VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_DEFAULT);
  if (kr == KERN_SUCCESS)
    kr = vm_map(task, &rx, size, 0, VM_FLAGS_ANYWHERE, entry, 0, FALSE, VM_PROT_READ | VM_PROT_EXECUTE,
                VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE, VM_INHERIT_DEFAULT);
  if (kr != KERN_SUCCESS) {
    printf("winehost: JIT pool mapping failed: %s\n", mach_error_string(kr));
    return 1;
  }
  char buf[32];
  snprintf(buf, sizeof(buf), "%lx", (unsigned long)rx);
  setenv("WINE_IOS_JIT_RX", buf, 1);
  snprintf(buf, sizeof(buf), "%lx", (unsigned long)rw);
  setenv("WINE_IOS_JIT_RW", buf, 1);
  snprintf(buf, sizeof(buf), "%lx", (unsigned long)size);
  setenv("WINE_IOS_JIT_SIZE", buf, 1);
  printf("winehost: JIT pool RX %#lx RW %#lx, %zu MB\n", (unsigned long)rx, (unsigned long)rw, size >> 20);
  return 0;
}

static void* server_thread(void* arg) {
  (void)arg;
  foreground = 1;
  char* argv[] = {"wineserver", "--foreground", NULL};
  int ret = wineserver_main(2, argv);
  fprintf(stderr, "winehost: wineserver_main returned %d\n", ret);
  return NULL;
}

// FEX's WoW64 module is a Windows DLL and cannot look symbols up itself, so
// the host loads the image and passes the address of its index on.
static int publish_aot_image(const char* path) {
  void* image = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (!image) {
    printf("winehost: AOT image %s: %s\n", path, dlerror());
    return 1;
  }
  const struct { char magic[4]; unsigned version; unsigned long long count; }* index = dlsym(image, "fexaot_index");
  if (!index || memcmp(index->magic, "FXAI", 4) || index->version != 1) {
    printf("winehost: AOT image %s has no index\n", path);
    return 1;
  }
  char buf[32];
  snprintf(buf, sizeof(buf), "%lx", (unsigned long)index);
  setenv("WINE_IOS_AOT_INDEX", buf, 1);
  printf("winehost: AOT image %s, %llu caches, index at %p\n", path, index->count, (void*)index);
  return 0;
}

static int wine_argc;
static char** wine_argv;

static void* wine_thread(void* arg) {
  (void)arg;
  wine_ios_main_thread = pthread_self();
  wine_ios_exit_initialized = 1;
  if (setjmp(wine_ios_exit_jmpbuf) == 0) {
    __wine_main(wine_argc, wine_argv);
    fprintf(stderr, "winehost: __wine_main returned\n");
  } else {
    fprintf(stderr, "winehost: Wine process exited with code %d\n", wine_ios_exit_code);
  }
  __atomic_store_n(&wine_exited, 1, __ATOMIC_RELEASE);
  return NULL;
}

static int start(void* (*fn)(void*), size_t stack) {
  pthread_attr_t attr;
  pthread_t t;
  pthread_attr_init(&attr);
  if (stack) pthread_attr_setstacksize(&attr, stack);
  int ret = pthread_create(&t, &attr, fn, NULL);
  pthread_attr_destroy(&attr);
  if (!ret) pthread_detach(t);
  return ret;
}

// The end of a run: the command-line host ends the process (Wine's threads
// would keep it alive), an app keeps running.
static int finish(void) {
  fflush(stderr);
  const char* ret = getenv("WINEHOST_RETURN");
  if (ret && !strcmp(ret, "1")) return 0;
  _exit(0);
}

int winehost_main(int argc, char* argv[]) {
  setvbuf(stdout, NULL, _IONBF, 0);
  if (argc < 3) {
    fprintf(stderr, "usage: winehost SECONDS PROGRAM [ARGS...]\n");
    return 2;
  }
  int seconds = atoi(argv[1]);
  const char* prefix = getenv("WINEPREFIX");
  if (!prefix || prefix[0] != '/') {
    fprintf(stderr, "winehost: WINEPREFIX must be an absolute path\n");
    return 2;
  }
  mkdir(prefix, 0700);
  setenv("HOME", prefix, 1);
  setenv("WINELOADERNOEXEC", "1", 1);
  const char* nls = getenv("WINEHOST_NLS");
  if (nls) wineserver_set_nls_dir(nls);
  frames_dir = getenv("WINEHOST_FRAMES");
  if (frames_dir) mkdir(frames_dir, 0700);

  printf("winehost: pid %d\n", (int)getpid());
  printf("winehost: starting wineserver, prefix %s\n", prefix);
  if (start(server_thread, 0)) return 1;
  for (int i = 0; i < 200 && !__atomic_load_n(&wineserver_ready, __ATOMIC_ACQUIRE); i++)
    usleep(50000);
  if (!__atomic_load_n(&wineserver_ready, __ATOMIC_ACQUIRE)) {
    printf("winehost: wineserver not ready after 10 s\n");
    return 1;
  }
  printf("winehost: wineserver ready\n");

  // The app connects the process to the server over a socketpair (accept()
  // on a Unix socket does not work in the iOS sandbox).
  int pair[2];
  if (socketpair(AF_UNIX, SOCK_STREAM, 0, pair)) {
    printf("winehost: socketpair: %s\n", strerror(errno));
    return 1;
  }
  char fd[16];
  snprintf(fd, sizeof(fd), "%d", pair[1]);
  setenv("WINESERVERSOCKET", fd, 1);
  wineserver_inject_client_fd(pair[0]);

  static char* args[64];
  wine_argc = 0;
  args[wine_argc++] = "wine";
  for (int i = 2; i < argc && wine_argc < 63; i++) args[wine_argc++] = argv[i];
  args[wine_argc] = NULL;
  wine_argv = args;
  if (pe_machine(argv[2]) == 0x14c) {
    ios_main_image_i386 = 1;
    publish_host_probe();
    // With NoJIT nothing runs from the pool: FEX runs only the AOT image and xtajit.dll runs from
    // its dylib. A device without a debugger cannot map the pool's executable view at all.
    const char* nojit = getenv("FEX_NOJIT");
    if (nojit && !strcmp(nojit, "1"))
      printf("winehost: NoJIT, so no JIT pool\n");
    else if (publish_jit_pool(512 << 20))
      return 1;
    const char* aot = getenv("WINEHOST_AOT_IMAGE");
    if (aot && *aot && publish_aot_image(aot)) return 1;
    printf("winehost: 32-bit x86 program, running it through WoW64\n");
  }
  else if (getenv("WINEHOST_JIT") && !strcmp(getenv("WINEHOST_JIT"), "1")) {
    /* A 64-bit program that generates code itself (FEX's offline compiler). */
    publish_host_probe();
    if (publish_jit_pool(512 << 20)) return 1;
  }
  printf("winehost: starting %s\n", argv[2]);
  if (start(wine_thread, 8 << 20)) return 1;

  // A program with a window is done once everything the run checks has shown
  // up (and a little later, for a few more frames); cmd.exe once it exits.
  const char* env;
  if ((env = getenv("WINEHOST_WINDOW")) && *env) goals_needed |= GOAL_FRAME;
  if ((env = getenv("WINEHOST_TYPE")) && *env) goals_needed |= GOAL_TYPED;
  if ((env = getenv("WINEHOST_CLICK_MENU")) && !strcmp(env, "1")) goals_needed |= GOAL_NEW_WINDOW;
  if ((env = getenv("WINEHOST_CLICK")) && *env) goals_needed |= GOAL_CHANGED;
  double begin = now(), done_at = 0;
  while (now() - begin < seconds) {
    usleep(100000);
    int met_all = (__atomic_load_n(&goals_met, __ATOMIC_ACQUIRE) & goals_needed) == goals_needed;
    if (__atomic_load_n(&wine_exited, __ATOMIC_ACQUIRE) || (goals_needed && met_all)) {
      if (!done_at) done_at = now();
      if (now() - done_at >= 2) {
        printf("winehost: done after %.0f s, exiting\n", now() - begin);
        return finish();
      }
    }
  }
  printf("winehost: %d s passed, exiting\n", seconds);
  return finish();
}

#ifndef WINEHOST_LIBRARY
int main(int argc, char* argv[]) { return winehost_main(argc, argv); }
#endif
