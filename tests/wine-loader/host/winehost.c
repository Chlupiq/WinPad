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
// first window, 2 s after that window first showed (see winios_pProcessEvents).
// Prints what it starts, then waits SECONDS and exits with 0 if the server
// came up. Whatever Wine does in the meantime goes to stderr.
#include <errno.h>
#include <pthread.h>
#include <setjmp.h>
#include <stdarg.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <sys/stat.h>
#include <time.h>
#include <unistd.h>

extern int wineserver_main(int argc, char* argv[]);
extern void wineserver_inject_client_fd(int fd);
extern void wineserver_set_nls_dir(const char* path);
extern int wineserver_ready;
extern int foreground;
extern void __wine_main(int argc, char* argv[]);

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

// Scripted input: 0 = waiting for a window, 1 = window shown, 2 = posting,
// 3 = posted. What the app's touch and key handlers queue is posted from a
// Wine thread in winios_pProcessEvents, as Madeira's Winios.m drains it.
static int input_state;
static double first_window_time;
static void* first_window;
static int menu_x, menu_y;  // a point in the first window's menu bar
static void* windows_before_input[64];
static int windows_before_count;
static long dark_before_input;  // most dark pixels any frame had before

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
  for (int y = 0; y < surf_h; y++) {
    const unsigned char* row = (const unsigned char*)bits + (size_t)y * stride;
    for (int x = 0; x < surf_w; x++)
      if (row[x * 4] + row[x * 4 + 1] + row[x * 4 + 2] < 3 * 64) dark++;
  }
  int state = __atomic_load_n(&input_state, __ATOMIC_ACQUIRE);
  if (presents++ < 20 || (state == 3 && after_input++ < 20))
    fprintf(stderr, "winehost: frame of window %p, %dx%d, dirty %d,%d %dx%d, %ld dark pixels\n",
            hwnd, surf_w, surf_h, dirty_x, dirty_y, dirty_w, dirty_h, dark);
  if (state < 2) {
    if (dark > dark_before_input) dark_before_input = dark;
    int seen = 0;
    for (int i = 0; i < windows_before_count; i++) seen |= windows_before_input[i] == hwnd;
    if (!seen && windows_before_count < 64) windows_before_input[windows_before_count++] = hwnd;
    if (state == 0 && menu_y > 0) {
      first_window = hwnd;
      first_window_time = now();
      __atomic_store_n(&input_state, 1, __ATOMIC_RELEASE);
    }
  } else if (state == 3) {
    static int said_new, said_text;
    int seen = 0;
    for (int i = 0; i < windows_before_count; i++) seen |= windows_before_input[i] == hwnd;
    if (!seen && !said_new++) fprintf(stderr, "winehost: new window %p after input\n", hwnd);
    if (hwnd == first_window && dark > dark_before_input + 50 && !said_text++)
      fprintf(stderr, "winehost: typed text shows up, %ld dark pixels, at most %ld before\n", dark,
              dark_before_input);
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
  // The menu bar sits right above the client area, its first item at the left.
  if (visible && !first_window && cy - y > 30 && cw > 0) {
    menu_x = cx + 12;
    menu_y = cy - 9;
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
int winios_pProcessEvents(unsigned int mask) {
  (void)mask;
  int expected = 1;
  if (__atomic_load_n(&input_state, __ATOMIC_ACQUIRE) != 1 || now() < first_window_time + 2 ||
      !__atomic_compare_exchange_n(&input_state, &expected, 2, 0, __ATOMIC_ACQ_REL,
                                   __ATOMIC_ACQUIRE))
    return 0;
  const char* text = getenv("WINEHOST_TYPE");
  if (text) {
    for (const char* c = text; *c; c++) {
      if (*c >= 'a' && *c <= 'z') tap_key(*c - 'a' + 'A', 0);
      else if ((*c >= 'A' && *c <= 'Z') || (*c >= '0' && *c <= '9') || *c == ' ') tap_key(*c, *c >= 'A');
    }
    fprintf(stderr, "winehost: typed \"%s\" into window %p\n", text, first_window);
  }
  const char* click = getenv("WINEHOST_CLICK_MENU");
  if (click && *click == '1') {
    winios_drv_post_mouse(menu_x, menu_y, MOVE | ABSOLUTE, 0, NULL);
    winios_drv_post_mouse(menu_x, menu_y, MOVE | LEFTDOWN | ABSOLUTE, 0, NULL);
    winios_drv_post_mouse(menu_x, menu_y, LEFTUP | ABSOLUTE, 0, NULL);
    fprintf(stderr, "winehost: clicked %d,%d, the menu of window %p\n", menu_x, menu_y, first_window);
  }
  __atomic_store_n(&input_state, 3, __ATOMIC_RELEASE);
  return 1;
}

static void* server_thread(void* arg) {
  (void)arg;
  foreground = 1;
  char* argv[] = {"wineserver", "--foreground", NULL};
  int ret = wineserver_main(2, argv);
  fprintf(stderr, "winehost: wineserver_main returned %d\n", ret);
  return NULL;
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

int main(int argc, char* argv[]) {
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
  printf("winehost: starting %s\n", argv[2]);
  if (start(wine_thread, 8 << 20)) return 1;

  sleep(seconds);
  printf("winehost: %d s passed, exiting\n", seconds);
  fflush(stderr);
  _exit(0);
}
