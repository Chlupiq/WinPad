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
// The program the last game run tried to start as a second process that could not start
// (a 32-bit child on iPad: "[Wine child] BOOT FAILED at stage 'guest-window-reserve'"), the
// file name from its NtCreateUserProcess line (Setup.exe, SafeDisc's ~e5.0001...), or nil.
NSString* _Nullable WinPadFailedChildOfLastRun(void);

// Before a game runs: the DLLs that EXE (and the DLLs and .asi plugins next to it) import that
// no one has: not the game's (its folder or EXE's folder), not Wine's (the app's
// i386-windows), not in the prefix's syswow64 and not downloaded from Microsoft. API sets
// (api-ms-win-*) are left out, Wine maps them. Lowercase names, sorted, empty when all are
// there. Reads the files, so call it off the main queue for a big game.
NSArray<NSString*>* WinPadMissingDLLsOf(NSString* exe, NSString* _Nullable gameFolder);

// Downloads the installer from Microsoft (about 95 MB), checks its SHA-256 and takes the
// DLLs out; the installer itself is deleted. PROGRESS (0...1, then 1 while unpacking) and
// DONE (nil, or why not) are called on the main queue. One download at a time.
BOOL WinPadDirectXDownloading(void);
void WinPadDirectXDownload(void (^progress)(double fraction), void (^done)(NSString* _Nullable error));

// For main.m, while it makes the prefix: links the DLLs into SYSWOW64 as said above
// (BUNDLE_I386 is the app's i386-windows) and returns the module names to load native
// first (d3dx9_30...) for WINEDLLOVERRIDES.
NSArray<NSString*>* WinPadDirectXLink(NSString* syswow64, NSString* bundleI386);

// A game profile's "nativeDirectX" (Proton's winetricks verbs: d3dx9, d3dx9_43, xact,
// d3dcompiler_43, xinput, or DLL names): the downloaded DLLs they stand for, lowercase
// names (d3dx9_43.dll...), empty when DirectX is not downloaded or has none of them.
NSArray<NSString*>* WinPadDirectXDLLsForVerbs(NSArray* verbs);
// For main.m, a game that wants DLLS (WinPadDirectXDLLsForVerbs) of Microsoft even where Wine
// has its own: links them into SYSWOW64 and returns their module names, to load native first.
NSArray<NSString*>* WinPadDirectXLinkNative(NSString* syswow64, NSArray<NSString*>* dlls);

// DLLs the app took out of other Microsoft installers: a game's own (its _CommonRedist,
// DirectX or vcredist folder) and the Visual C++ runtimes it downloads. 32-bit, lowercase
// names, shared by all games (Documents/.redist/extra). main.m links those Wine lacks into
// syswow64, like DirectX's.
NSString* WinPadExtraDir(void);
NSArray<NSString*>* WinPadExtraLink(NSString* syswow64, NSString* bundleI386);

// The installers in the game's folder GAMEFOLDER that may hold DLLs: cabinets, .msi files and
// programs named like Microsoft's redistributables (vcredist, vc_redist, DXSETUP's cabinets),
// up to four folders deep. Full paths.
NSArray<NSString*>* WinPadGameInstallers(NSString* gameFolder);
// Takes the 32-bit DLLs out of those installers into WinPadExtraDir (a file already there
// stays). How many new DLLs. Reads big files: call it off the main queue.
int WinPadTakeDLLsFromGameInstallers(NSString* gameFolder);

// The Visual C++ installer year (2005 ... 2022) whose package holds DLL, or 0.
int WinPadVCRedistYearOf(NSString* dll);
// Downloads that year's 32-bit Visual C++ installer from Microsoft (winetricks' links,
// Redist.c), checks it and takes its DLLs out into WinPadExtraDir. As WinPadDirectXDownload:
// one download (of either) at a time, PROGRESS and DONE on the main queue.
void WinPadVCRedistDownload(int year, void (^progress)(double fraction), void (^done)(NSString* _Nullable error));

NS_ASSUME_NONNULL_END
