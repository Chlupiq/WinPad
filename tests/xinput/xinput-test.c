/* SPDX-License-Identifier: MIT
 * winpad-xinput.dll on Windows (CI): writes a controller state into a file as the app does
 * (winpad-pad.h), points WINPAD_PAD_FILE at it and checks what XInputGetState and the rest
 * give back, then the same with nothing connected and with a state half written.
 * Usage: xinput-test.exe DLL */
#include <stdio.h>
#include <string.h>
#include <windows.h>

#include "winpad-pad.h"

typedef struct {
  DWORD dwPacketNumber;
  WORD wButtons;
  BYTE bLeftTrigger, bRightTrigger;
  SHORT sThumbLX, sThumbLY, sThumbRX, sThumbRY;
} STATE;

static int failed;
static void expect(int ok, const char* what) {
  printf("%s: %s\n", ok ? "ok" : "FAILED", what);
  if (!ok) failed = 1;
}

static void write_pad(const char* path, const struct winpad_pad* p) {
  FILE* f = fopen(path, "wb");
  fwrite(p, sizeof(*p), 1, f);
  fclose(f);
}

int main(int argc, char** argv) {
  if (argc != 2) return 2;
  char path[MAX_PATH];
  GetTempPathA(sizeof(path), path);
  strcat(path, "winpad-pad-test");
  struct winpad_pad p = {WINPAD_PAD_MAGIC, 2, 1, 7, 0x1000 | 0x0010, 10, 250, -32768, 32767, 100, -100, 2};
  write_pad(path, &p);
  SetEnvironmentVariableA("WINPAD_PAD_FILE", path);
  HMODULE dll = LoadLibraryA(argv[1]);
  expect(dll != NULL, "the DLL loads");
  if (!dll) return 1;
  DWORD(WINAPI * get)(DWORD, STATE*) = (void*)GetProcAddress(dll, "XInputGetState");
  DWORD(WINAPI * get_ex)(DWORD, STATE*) = (void*)GetProcAddress(dll, (LPCSTR)100);
  DWORD(WINAPI * caps)(DWORD, DWORD, void*) = (void*)GetProcAddress(dll, "XInputGetCapabilities");
  void(WINAPI * enable)(BOOL) = (void*)GetProcAddress(dll, "XInputEnable");
  expect(get && get_ex && caps && enable && GetProcAddress(dll, "XInputSetState") &&
             GetProcAddress(dll, "XInputGetBatteryInformation") && GetProcAddress(dll, "XInputGetKeystroke") &&
             GetProcAddress(dll, "XInputGetDSoundAudioDeviceGuids"),
         "XInput's functions are exported, XInputGetStateEx as ordinal 100");
  if (!get || !get_ex || !caps || !enable) return 1;
  STATE s;
  memset(&s, 0, sizeof(s));
  expect(get(0, &s) == ERROR_SUCCESS, "controller 0 is connected");
  expect(s.dwPacketNumber == 7 && s.wButtons == 0x1010 && s.bLeftTrigger == 10 && s.bRightTrigger == 250 &&
             s.sThumbLX == -32768 && s.sThumbLY == 32767 && s.sThumbRX == 100 && s.sThumbRY == -100,
         "its state is the file's (A + Start, triggers, sticks)");
  STATE x;
  expect(get(1, &x) == ERROR_DEVICE_NOT_CONNECTED && get(3, &x) == ERROR_DEVICE_NOT_CONNECTED,
         "controllers 1-3 are not connected");
  expect(get(4, &x) == ERROR_BAD_ARGUMENTS, "controller 4 does not exist");
  BYTE c[32];
  expect(caps(0, 0, c) == ERROR_SUCCESS && c[0] == 1, "capabilities: a gamepad");
  // The guide button only through XInputGetStateEx.
  p.buttons |= 0x0400;
  p.packet = 8;
  write_pad(path, &p);
  Sleep(20);
  expect(get(0, &s) == ERROR_SUCCESS && s.dwPacketNumber == 8 && s.wButtons == 0x1010, "a new state, without the guide button");
  expect(get_ex(0, &s) == ERROR_SUCCESS && s.wButtons == 0x1410, "XInputGetStateEx has the guide button");
  enable(FALSE);
  expect(get(0, &s) == ERROR_SUCCESS && !s.wButtons && !s.sThumbLX, "XInputEnable(FALSE): at rest");
  enable(TRUE);
  // Half written (seq odd): the last state stays.
  struct winpad_pad half = p;
  half.seq = 5;
  half.seq_end = 4;
  half.buttons = 0x2000;
  half.packet = 9;
  write_pad(path, &half);
  Sleep(20);
  expect(get(0, &s) == ERROR_SUCCESS && s.dwPacketNumber == 8, "a state being written is not taken");
  p.connected = 0;
  p.seq = p.seq_end = 6;
  write_pad(path, &p);
  Sleep(20);
  expect(get(0, &s) == ERROR_DEVICE_NOT_CONNECTED, "no controller: not connected");
  DeleteFileA(path);
  return failed;
}
