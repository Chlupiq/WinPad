/* SPDX-License-Identifier: MIT
 * winpad-xinput.dll: XInput for the games that read an Xbox controller, fed by the iPad's
 * controller (a Bluetooth/MFi one or the app's touch controller). The app writes the state
 * into a file (winpad-pad.h) and links this DLL into the prefix as xinput1_1..1_4 and
 * xinput9_1_0 for those games (main.m, the game's "padMode" "xinput"). Wine's own XInput
 * reads HID devices, which an iPad gives a Wine program none of.
 * Built without a C runtime: kernel32 only. */
#include <windows.h>

#include "winpad-pad.h"

#define XINPUT_DEVTYPE_GAMEPAD 1
#define XINPUT_DEVSUBTYPE_GAMEPAD 1
#define BATTERY_TYPE_WIRED 1
#define BATTERY_LEVEL_FULL 3

typedef struct {
  WORD wButtons;
  BYTE bLeftTrigger, bRightTrigger;
  SHORT sThumbLX, sThumbLY, sThumbRX, sThumbRY;
} XINPUT_GAMEPAD;
typedef struct {
  DWORD dwPacketNumber;
  XINPUT_GAMEPAD Gamepad;
} XINPUT_STATE;
typedef struct {
  WORD wLeftMotorSpeed, wRightMotorSpeed;
} XINPUT_VIBRATION;
typedef struct {
  BYTE Type, SubType;
  WORD Flags;
  XINPUT_GAMEPAD Gamepad;
  XINPUT_VIBRATION Vibration;
} XINPUT_CAPABILITIES;
typedef struct {
  BYTE BatteryType, BatteryLevel;
} XINPUT_BATTERY_INFORMATION;

static HANDLE file = INVALID_HANDLE_VALUE;
static BOOL enabled = TRUE;
static struct winpad_pad last;
static DWORD last_tick;
static BOOL have_last;

/* No C runtime: what the compiler may call for a struct copy or zeroing. */
void* __cdecl memset(void* d, int c, size_t n) {
  unsigned char* p = d;
  while (n--) *p++ = (unsigned char)c;
  return d;
}
void* __cdecl memcpy(void* d, const void* s, size_t n) {
  unsigned char* p = d;
  const unsigned char* q = s;
  while (n--) *p++ = *q++;
  return d;
}

static void open_file(void) {
  if (file != INVALID_HANDLE_VALUE) return;
  WCHAR path[1024];
  const DWORD n = GetEnvironmentVariableW(L"WINPAD_PAD_FILE", path, 1024);
  if (!n || n >= 1024) return;
  file = CreateFileW(path, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE, NULL, OPEN_EXISTING,
                     FILE_ATTRIBUTE_NORMAL, NULL);
}

/* The state, read from the file at most once a millisecond. FALSE when there is none. */
static BOOL read_pad(struct winpad_pad* out) {
  const DWORD now = GetTickCount();
  if (have_last && now == last_tick) {
    *out = last;
    return last.magic == WINPAD_PAD_MAGIC;
  }
  open_file();
  if (file == INVALID_HANDLE_VALUE) return FALSE;
  for (int tries = 0; tries < 8; tries++) {
    struct winpad_pad p;
    DWORD got = 0;
    if (SetFilePointer(file, 0, NULL, FILE_BEGIN) == INVALID_SET_FILE_POINTER) return FALSE;
    if (!ReadFile(file, &p, sizeof(p), &got, NULL) || got != sizeof(p)) return FALSE;
    if (p.magic != WINPAD_PAD_MAGIC) return FALSE;
    if ((p.seq & 1) || p.seq != p.seq_end) continue; /* the app is writing it */
    last = p;
    last_tick = now;
    have_last = TRUE;
    *out = p;
    return TRUE;
  }
  return have_last && last.magic == WINPAD_PAD_MAGIC ? (*out = last, TRUE) : FALSE;
}

static DWORD get_state(DWORD user, XINPUT_STATE* state, BOOL guide) {
  if (!state) return ERROR_BAD_ARGUMENTS;
  if (user >= 4) return ERROR_BAD_ARGUMENTS;
  struct winpad_pad p;
  if (user != 0 || !read_pad(&p) || !p.connected) return ERROR_DEVICE_NOT_CONNECTED;
  state->dwPacketNumber = p.packet;
  if (!enabled) {
    /* XInputEnable(FALSE): connected, but at rest. */
    memset(&state->Gamepad, 0, sizeof(state->Gamepad));
    return ERROR_SUCCESS;
  }
  state->Gamepad.wButtons = guide ? p.buttons : (WORD)(p.buttons & ~0x0400);
  state->Gamepad.bLeftTrigger = p.left_trigger;
  state->Gamepad.bRightTrigger = p.right_trigger;
  state->Gamepad.sThumbLX = p.thumb_lx;
  state->Gamepad.sThumbLY = p.thumb_ly;
  state->Gamepad.sThumbRX = p.thumb_rx;
  state->Gamepad.sThumbRY = p.thumb_ry;
  return ERROR_SUCCESS;
}

DWORD WINAPI XInputGetState(DWORD user, XINPUT_STATE* state) {
  return get_state(user, state, FALSE);
}

DWORD WINAPI XInputGetStateEx(DWORD user, XINPUT_STATE* state) {
  return get_state(user, state, TRUE);
}

DWORD WINAPI XInputSetState(DWORD user, XINPUT_VIBRATION* vibration) {
  if (user >= 4) return ERROR_BAD_ARGUMENTS;
  struct winpad_pad p;
  if (user != 0 || !read_pad(&p) || !p.connected) return ERROR_DEVICE_NOT_CONNECTED;
  (void)vibration; /* no rumble yet */
  return ERROR_SUCCESS;
}

DWORD WINAPI XInputGetCapabilities(DWORD user, DWORD flags, XINPUT_CAPABILITIES* caps) {
  (void)flags;
  if (user >= 4 || !caps) return ERROR_BAD_ARGUMENTS;
  struct winpad_pad p;
  if (user != 0 || !read_pad(&p) || !p.connected) return ERROR_DEVICE_NOT_CONNECTED;
  memset(caps, 0, sizeof(*caps));
  caps->Type = XINPUT_DEVTYPE_GAMEPAD;
  caps->SubType = XINPUT_DEVSUBTYPE_GAMEPAD;
  caps->Gamepad.wButtons = 0xf3ff;
  caps->Gamepad.bLeftTrigger = caps->Gamepad.bRightTrigger = 0xff;
  caps->Gamepad.sThumbLX = caps->Gamepad.sThumbLY = caps->Gamepad.sThumbRX = caps->Gamepad.sThumbRY = (SHORT)0xffc0;
  caps->Vibration.wLeftMotorSpeed = caps->Vibration.wRightMotorSpeed = 0xff;
  return ERROR_SUCCESS;
}

void WINAPI XInputEnable(BOOL enable) {
  enabled = enable;
}

DWORD WINAPI XInputGetBatteryInformation(DWORD user, BYTE type, XINPUT_BATTERY_INFORMATION* info) {
  (void)type;
  if (user >= 4 || !info) return ERROR_BAD_ARGUMENTS;
  struct winpad_pad p;
  if (user != 0 || !read_pad(&p) || !p.connected) return ERROR_DEVICE_NOT_CONNECTED;
  info->BatteryType = BATTERY_TYPE_WIRED;
  info->BatteryLevel = BATTERY_LEVEL_FULL;
  return ERROR_SUCCESS;
}

DWORD WINAPI XInputGetKeystroke(DWORD user, DWORD reserved, void* keystroke) {
  (void)reserved;
  (void)keystroke;
  if (user >= 4 && user != 0xff) return ERROR_BAD_ARGUMENTS;
  struct winpad_pad p;
  if ((user != 0 && user != 0xff) || !read_pad(&p) || !p.connected) return ERROR_DEVICE_NOT_CONNECTED;
  return ERROR_EMPTY;
}

DWORD WINAPI XInputGetDSoundAudioDeviceGuids(DWORD user, GUID* render, GUID* capture) {
  if (user >= 4 || !render || !capture) return ERROR_BAD_ARGUMENTS;
  memset(render, 0, sizeof(*render));
  memset(capture, 0, sizeof(*capture));
  return user == 0 ? ERROR_SUCCESS : ERROR_DEVICE_NOT_CONNECTED;
}

DWORD WINAPI XInputGetAudioDeviceIds(DWORD user, WCHAR* render, UINT* render_count, WCHAR* capture, UINT* capture_count) {
  (void)render;
  (void)capture;
  if (user >= 4) return ERROR_BAD_ARGUMENTS;
  if (render_count) *render_count = 0;
  if (capture_count) *capture_count = 0;
  return user == 0 ? ERROR_SUCCESS : ERROR_DEVICE_NOT_CONNECTED;
}

BOOL WINAPI DllMain(HINSTANCE instance, DWORD reason, void* reserved) {
  (void)reserved;
  if (reason == DLL_PROCESS_ATTACH) DisableThreadLibraryCalls(instance);
  return TRUE;
}
