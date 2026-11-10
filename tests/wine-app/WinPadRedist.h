// SPDX-License-Identifier: MIT
// Microsoft's DirectX DLLs, downloaded by the app when a game needs them (WinPadRedist.m):
// the June 2010 DirectX End-User Runtimes from Microsoft, the 32-bit DLLs taken out on the
// device (Redist.c) into Documents/.redist/directx. main.m links them into the prefix's
// syswow64: a DLL Wine does not have always, one Wine has (D3DX9, XInput...) only with the
// setting "Používat DirectX od Microsoftu", and then loaded native first (=n,b).
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// The folder with the DLLs, and their names (lowercase, d3dx9_30.dll...); empty until downloaded.
NSString* WinPadDirectXDir(void);
NSArray<NSString*>* WinPadDirectXDLLs(void);

// The setting: Microsoft's DLLs in place of Wine's own (key msDirectX, off by default).
BOOL WinPadDirectXPreferred(void);
void WinPadDirectXSetPreferred(BOOL on);

// Whether DLL (d3dx9_30.dll, any case) is one of those the installer holds.
BOOL WinPadDirectXProvides(NSString* dll);

// The DLL the last game run stopped on because no file of it was there (Wine's "Library X
// (which is needed by ...) not found" in wine.log or wine.log.crashed), or nil.
NSString* _Nullable WinPadMissingDLLOfLastRun(void);

// Downloads the installer from Microsoft (about 95 MB), checks its SHA-256 and takes the
// DLLs out; the installer itself is deleted. PROGRESS (0...1, then 1 while unpacking) and
// DONE (nil, or why not) are called on the main queue. One download at a time.
BOOL WinPadDirectXDownloading(void);
void WinPadDirectXDownload(void (^progress)(double fraction), void (^done)(NSString* _Nullable error));

// For main.m, while it makes the prefix: links the DLLs into SYSWOW64 as said above
// (BUNDLE_I386 is the app's i386-windows) and returns the module names to load native
// first (d3dx9_30...) for WINEDLLOVERRIDES.
NSArray<NSString*>* WinPadDirectXLink(NSString* syswow64, NSString* bundleI386);

NS_ASSUME_NONNULL_END
