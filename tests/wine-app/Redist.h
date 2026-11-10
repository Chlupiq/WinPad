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
#define WINPAD_DIRECTX_SHA256 "8746ee1a84a083a90e37899d71d50d5c7c015e69688a466aa80447f011780c0d"

// The SHA-256 of the file PATH as 64 lowercase hex digits into HEX (65 bytes). 0 when
// done, else -1 with why in ERR.
int winpad_redist_sha256(const char* path, char hex[65], char* err, size_t errlen);

// Writes the 32-bit DLLs of the installer EXE into the folder DEST (which must exist),
// lowercase names. *COUNT gets how many. 0 when done, else -1 with why in ERR.
int winpad_redist_extract_directx(const char* exe, const char* dest, int* count, char* err, size_t errlen);

#ifdef __cplusplus
}
#endif

#endif
