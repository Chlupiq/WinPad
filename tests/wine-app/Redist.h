// SPDX-License-Identifier: MIT
// Microsoft's own DirectX DLLs for the games (Redist.c): the DirectX End-User Runtimes
// (June 2010) installer, directx_Jun2010_redist.exe, as Microsoft serves it, is a cabinet
// that holds one cabinet per component (Jun2010_d3dx9_43_x86.cab...). The 32-bit DLLs of
// those (D3DX9 24-43, D3DX10, D3DX11, D3DCompiler, XInput, XAudio2, X3DAudio, XAPOFX, XACT)
// are taken out on the device, as winetricks does on a PC with cabextract. The app may not
// carry them itself (Microsoft's licence), so it downloads the installer from Microsoft.
#ifndef WINPAD_REDIST_H
#define WINPAD_REDIST_H

#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

// The installer: where Microsoft serves it, its size and its SHA-256 (as winetricks checks it).
#define WINPAD_DIRECTX_URL                                                                       \
  "https://download.microsoft.com/download/8/4/A/84A35BF1-DAFE-4AE8-82AF-AD2AE20B6B14/"         \
  "directx_Jun2010_redist.exe"
#define WINPAD_DIRECTX_SHA256 "053f76dcbb28802e23341b6a787e3b0791c0fa5c8d4d011b1044172dbf89c73b"

// NVIDIA's legacy PhysX System Software (PhysX 2.x runtime, PhysXLoader.dll), as NVIDIA serves it.
// Its checksum is not pinned: the app only takes it from an nvidia.com host.
#define WINPAD_PHYSX_URL "https://us.download.nvidia.com/Windows/9.13.0604/PhysX-9.13.0604-SystemSoftware-Legacy.msi"

// The SHA-256 of the file PATH as 64 lowercase hex digits into HEX (65 bytes). 0 when
// done, else -1 with why in ERR.
int winpad_redist_sha256(const char* path, char hex[65], char* err, size_t errlen);

// Writes the 32-bit DLLs of the installer EXE into the folder DEST (which must exist),
// lowercase names. *COUNT gets how many. 0 when done, else -1 with why in ERR.
int winpad_redist_extract_directx(const char* exe, const char* dest, int* count, char* err, size_t errlen);

// Writes the DLLs for MACHINE (0x14c: 32-bit x86) found in the Microsoft installer or
// cabinet PATH into DEST (which must exist): every cabinet in the file (also one appended to a
// program, or stored in an .msi), and the cabinets and installers inside those, three levels
// deep. That covers a game's own DirectX folder (DXSETUP's *_x86.cab), the Visual C++
// installers (vcredist_x86.exe 2005-2013 and VC_redist.x86.exe 2015-2022, whose DLLs are named
// F_CENTRAL_msvcr100_x86, msvcp140.dll_x86...) and the like. Each DLL is named by its export
// directory (MFC100.dll -> mfc100.dll), so the cabinet's names do not matter. A file already
// in DEST stays. *COUNT gets how many were written. 0 when PATH was read (also when it held
// none), else -1 with why in ERR.
int winpad_redist_extract_dlls(const char* path, const char* dest, unsigned machine, int* count, char* err,
                               size_t errlen);

// The Visual C++ runtime installers from Microsoft, 32-bit, as winetricks downloads them
// (vcrun2005 ... vcrun2022). YEAR 2005, 2008, 2010, 2012, 2013 or 2022 (2022 holds 2015-2022).
// SHA256 is NULL for 2022, whose link always gives the newest one: the app then only takes
// it from a Microsoft host.
struct winpad_vcredist {
  int year;
  const char* url;
  const char* sha256;
};
const struct winpad_vcredist* winpad_vcredist_for_year(int year);
// The installer year whose package holds DLL (mfc100.dll -> 2010, msvcp140.dll -> 2022), or 0.
int winpad_vcredist_year_of(const char* dll);

// The DLLs the PE file PATH imports, normally or delay-loaded: calls FOUND with each name as
// the file has it (any case), duplicates included. 0 when read, else -1 with why in ERR (not
// a PE file, a damaged table...). Used before a game's first run to find the DLLs it lacks.
int winpad_pe_imports(const char* path, void (*found)(const char* dll, void* ctx), void* ctx, char* err,
                      size_t errlen);

#ifdef __cplusplus
}
#endif

#endif
