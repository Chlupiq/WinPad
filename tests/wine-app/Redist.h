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

// The SHA-256 of the file PATH as 64 lowercase hex digits into HEX (65 bytes). 0 when
// done, else -1 with why in ERR.
int winpad_redist_sha256(const char* path, char hex[65], char* err, size_t errlen);

// Writes the 32-bit DLLs of the installer EXE into the folder DEST (which must exist),
// lowercase names. *COUNT gets how many. 0 when done, else -1 with why in ERR.
int winpad_redist_extract_directx(const char* exe, const char* dest, int* count, char* err, size_t errlen);

// The DLLs the PE file PATH imports, normally or delay-loaded: calls FOUND with each name as
// the file has it (any case), duplicates included. 0 when read, else -1 with why in ERR (not
// a PE file, a damaged table...). Used before a game's first run to find the DLLs it lacks.
int winpad_pe_imports(const char* path, void (*found)(const char* dll, void* ctx), void* ctx, char* err,
                      size_t errlen);

#ifdef __cplusplus
}
#endif

#endif
