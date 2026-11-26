// SPDX-License-Identifier: MIT
// Games without hand tuning (WinPadAuto.m): what the game's program is (GameDetect.c: its
// bitness, graphics API, input and the runtimes it imports, whether it is an installer), the
// settings that follow from it, and after a start that failed the next of a few variants to
// try, until one works; that one is remembered for the game. All of it stays under the
// game's winpad.json, its profile and the user's own settings: those always win.
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// What GameDetect.c read of the program at EXE (a full path) and of the DLLs and .asi plugins
// beside it: {"machine": 0x14c, "graphics": "d3d9", "uses": ["dinput", "xinput", ...],
// "subsystem": 2, "os": 4, "installer": "inno" (only for one), "asiLoader": YES (a dinput8.dll
// beside it)}. Kept in Documents/.winpad-games/.detect.json by path, size and date, so it is
// read once. Nil when EXE is not a Windows program.
NSDictionary* _Nullable WinPadProgramTraits(NSString* exe);
// The same without the DLLs beside it and without the cache file: for picking a folder's
// program among many (BestProgram), cached in memory only.
NSDictionary* _Nullable WinPadQuickTraits(NSString* exe);
// Whether TRAITS name a graphics API or game input (DirectInput, XInput): a game's program,
// not its launcher or settings tool.
BOOL WinPadTraitsLookLikeGame(NSDictionary* _Nullable traits);
// The installer kind of TRAITS ("inno", "nsis"...) as the library says it, or nil.
NSString* _Nullable WinPadInstallerName(NSDictionary* _Nullable traits);
// The graphics API of TRAITS as the settings say it ("DirectX 9", "DirectDraw", "OpenGL"), or nil.
NSString* _Nullable WinPadGraphicsName(NSDictionary* _Nullable traits);

// The variants for a game whose program has TRAITS and is called EXENAME (its file name),
// first the one to try first: [{"id": "base", "title": "...", "settings": {...}}]. SETTINGS
// are the game's own (winpad.json, profile, the user's): a variant does not try what they set.
NSArray<NSDictionary*>* WinPadAutoVariants(NSDictionary* traits, NSString* exeName, NSDictionary* settings);

// The game's settings for its next run: the variant the game's state picks (the one that
// worked, else the one to try next) with SETTINGS over it (dllOverrides, env, registry and
// padKeys merged key by key). STATE is the user's own settings of the game
// (WinPadOwnGameSettings: "autoVariant", "autoWorked"). *VARIANT gets the variant used.
NSDictionary* WinPadSettingsWithAuto(NSDictionary* traits, NSString* exeName, NSDictionary* settings,
                                     NSDictionary* state, NSDictionary* _Nullable* _Nullable variant);

// The run record of the last game (Documents/.winpad-lastrun.json), written by main.m.
// Started: the game FOLDER, its variant's id and what it is.
void WinPadRunStarted(NSString* folder, NSString* _Nullable variant, NSString* _Nullable variantTitle);
// How many frames it has drawn so far (main.m calls it every few seconds; the time since
// WinPadRunStarted goes with it).
void WinPadRunProgress(long frames);
// How it ended: "exited" (with Wine's exit code), "player" (Exit), "handoff" (the launcher
// handed over to the game, which starts at the next launch).
void WinPadRunEnded(NSString* how, int exitCode);

// What the library makes of the last run, once: nil when there is nothing to say (no run,
// already judged, a hand-over), else {"folder", "variant", "ok": YES/NO, "seconds", "frames",
// "why": "spadla po 4 s"}. Marks the record judged.
NSDictionary* _Nullable WinPadJudgeLastRun(void);

NS_ASSUME_NONNULL_END
