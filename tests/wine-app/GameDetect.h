// SPDX-License-Identifier: MIT
// What a Windows game is, read from its files before it runs (GameDetect.c), so the app can
// set it up without a profile: the program's PE header (32 or 64 bit, GUI or console, the
// Windows version it was linked for), the APIs its imports name (Direct3D 8-12, DirectDraw,
// OpenGL, Glide, Vulkan; DirectInput, XInput; .NET, PhysX, Steam...) and whether the program
// is an installer (Inno Setup, NSIS, InstallShield, a WiX bundle, a cabinet self-extractor).
// WinPadAuto.m turns that into settings and into the variants it tries after a failed start.
#ifndef WINPAD_GAME_DETECT_H
#define WINPAD_GAME_DETECT_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// The graphics API a game draws with, the newest its imports name (a game that imports both
// d3d9 and ddraw draws with Direct3D 9; one that imports d3dx9_43 does too).
enum winpad_graphics {
  WINPAD_GFX_UNKNOWN = 0,  // none of them: GDI, or it loads its renderer by name (Unreal's)
  WINPAD_GFX_GLIDE,
  WINPAD_GFX_DDRAW,
  WINPAD_GFX_OPENGL,
  WINPAD_GFX_VULKAN,
  WINPAD_GFX_D3D8,
  WINPAD_GFX_D3D9,
  WINPAD_GFX_D3D10,
  WINPAD_GFX_D3D11,
  WINPAD_GFX_D3D12,
};

// Other things its imports name (winpad_traits.uses).
enum {
  WINPAD_USES_DINPUT = 1 << 0,   // dinput.dll / dinput8.dll: keyboard, mouse and joysticks
  WINPAD_USES_XINPUT = 1 << 1,   // xinput1_x / xinput9_1_0: an Xbox controller
  WINPAD_USES_DSOUND = 1 << 2,
  WINPAD_USES_XAUDIO = 1 << 3,   // xaudio2_x, x3daudio, xactengine
  WINPAD_USES_OPENAL = 1 << 4,
  WINPAD_USES_DOTNET = 1 << 5,   // mscoree.dll: a .NET program
  WINPAD_USES_PHYSX = 1 << 6,    // PhysXLoader.dll, PhysX3*, physxcore: NVIDIA's PhysX
  WINPAD_USES_STEAM = 1 << 7,    // steam_api(64).dll, steamclient: Steam's client
  WINPAD_USES_D3DX = 1 << 8,     // d3dx8/9/10/11, d3dcompiler_xx: Microsoft's DirectX helpers
  WINPAD_USES_VCRUNTIME = 1 << 9,  // msvcp/msvcr/vcruntime/mfc of Visual C++
  WINPAD_USES_DDRAW = 1 << 10,   // ddraw.dll, whatever else it draws with
  WINPAD_USES_WINMM_ONLY = 1 << 11,  // reserved
};

struct winpad_traits {
  unsigned machine;          // 0x14c i386, 0x8664 x86-64, 0 when not a PE file
  unsigned subsystem;        // 2 GUI, 3 console
  unsigned os_major;         // MajorOperatingSystemVersion: 4 for programs of Windows 9x days
  unsigned linker_major;     // MajorLinkerVersion: 6 = Visual C++ 6 (1998)
  unsigned dll_characteristics;  // 0x100 NX_COMPAT...
  int graphics;              // enum winpad_graphics
  unsigned uses;             // WINPAD_USES_*
};

// Reads PATH's PE header into T (the other fields stay). 0 when it is a PE file, else -1.
int winpad_pe_header(const char* path, struct winpad_traits* t);

// Adds what the imported DLL name DLL (any case, with or without .dll) says to T.
void winpad_traits_add_import(struct winpad_traits* t, const char* dll);

// The kind of installer PATH is, as a word into KIND ("inno", "nsis", "installshield", "wise",
// "wixburn", "setupfactory", "cab", "msi", "7zsfx"): 1 when it is one, 0 when not, -1 when it
// cannot be read. Reads the PE header, its section names, the first 2 MB and the start of
// the data appended after the last section (where Inno Setup, NSIS and 7-Zip keep theirs).
int winpad_installer_kind(const char* path, char* kind, size_t kindlen);

// A short English word for GRAPHICS ("d3d9", "ddraw", "opengl"...), for logs and JSON.
const char* winpad_graphics_name(int graphics);

#ifdef __cplusplus
}
#endif

#endif
