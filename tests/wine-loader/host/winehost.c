// SPDX-License-Identifier: MIT
// The smallest Wine host: wineserver and one Wine process in this process,
// as Madeira's WineServerBridge.m and WineProcessBridge.m start them, without
// the app around them. Runs as a command-line program on the iPad simulator
// (xcrun simctl spawn).
//
// Usage: winehost SECONDS PROGRAM [ARGS...]
// Environment: WINEPREFIX (created if missing), WINEDLLPATH, optional
// WINEHOST_NLS (directory with the .nls files).
// Prints what it starts, then waits SECONDS and exits with 0 if the server
// came up. Whatever Wine does in the meantime goes to stderr.
#include <errno.h>
#include <pthread.h>
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
  __wine_main(wine_argc, wine_argv);
  fprintf(stderr, "winehost: __wine_main returned\n");
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
