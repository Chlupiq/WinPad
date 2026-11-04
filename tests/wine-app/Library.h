// SPDX-License-Identifier: MIT
// WinPad Wine's game library (Library.m): the screen the app opens on.
#import <UIKit/UIKit.h>

// A game the library found: a folder in the app's Documents with a Windows program.
@interface WinPadGame : NSObject
@property(nonatomic, copy) NSString* title;   // winpad.json's "title", else the folder's name
@property(nonatomic, copy) NSString* folder;  // the folder's name in Documents
@property(nonatomic, copy) NSString* exe;     // its program, relative to Documents
@property(nonatomic, copy) NSString* arch;    // "32bit", "64bit" or nil, from the program's PE header
@property(nonatomic, copy) NSString* image;   // the path of its AOT image, or nil
// The image in the bundle (Frameworks/fexaot-FOLDER.dylib, else fexaot-game.dylib), or nil.
@property(nonatomic, copy) NSString* bundleImage;
// image is the game folder's fexaot.dylib (signed on the Mac by WinPad Translator): main.m
// checks that it loads, else takes bundleImage.
@property(nonatomic) BOOL imageInFolder;
// Why the folder's fexaot.dylib is not used (made for another build of the app), or nil.
@property(nonatomic, copy) NSString* folderImageNote;
@property(nonatomic, strong) UIImage* cover;  // cover.png or cover.jpg in its folder, or nil
// The code maps it wrote while it ran (Documents/fexcache/FOLDER/codemap/new): code missing from
// its image, which the interpreter ran. newMaps of them since the last "Exportovat pro převodník".
@property(nonatomic) NSInteger maps;
@property(nonatomic) NSInteger newMaps;
// Its winpad.json's settings (WinPadGameSettings): args, dllOverrides, env, registry...
@property(nonatomic, copy) NSDictionary* settings;
// The game profile WinPad Translator put into winpad.json ("nfsu2 v1"), or nil.
@property(nonatomic, copy) NSString* profile;
@end

NSArray<WinPadGame*>* WinPadFindGames(void);

// A zip of the game's code maps for WinPad Translator, in the app's temporary folder: a folder
// WinPad-mapy-<game>-<date> with winpad-export.json (the game, the app build, when) and
// fexcache/FOLDER/codemap/new (the maps, runtime/ with code the game made at run time, and
// hostprobe.txt, the iPad's CPU features). Nil, with why in *error, if it has none or it failed.
NSURL* WinPadExportMaps(WinPadGame* game, NSError** error);
// Remembers that the maps written up to DATE were exported: they are no longer new.
void WinPadMarkMapsExported(WinPadGame* game, NSDate* date);
// Unpacks the WinPad package (.winpad) at PATH into Documents/<its folder>, calling
// PROGRESS (0..1, on this thread) as it goes. Returns the folder, or nil with why in *ERROR.
NSString* WinPadInstallPackage(NSString* path, void (^progress)(double), NSString** error);
// The packages waiting in Documents or Documents/Inbox (copied in, or handed over by AirDrop).
NSArray<NSURL*>* WinPadWaitingPackages(void);
// The settings of a game folder's winpad.json INFO: those of the game profile WinPad
// Translator put there ("profile": {"settings": ...}, tools/winpad-translator/winpad_translator/
// profiles.py), with the user's own top-level keys over them; dllOverrides, env and registry
// key by key (registry values by name).
NSDictionary* WinPadGameSettings(NSDictionary* info);

// The inputs of a game controller that become keys (main.m's Gamepads), in the order the
// settings list them.
enum { PadUp, PadDown, PadLeft, PadRight, PadA, PadB, PadX, PadY, PadL1, PadR1, PadL2, PadR2, PadMenu, PadOptions,
       PadRUp, PadRDown, PadRLeft, PadRRight, PadCount };
// The Windows virtual key of each input (0: none): the defaults, made for a racing game, with the
// changes made in the settings (the "padKeys" setting: input name → key, e.g. {a = 32;}).
void WinPadPadKeys(unsigned short keys[PadCount]);

@interface LibraryViewController : UIViewController
// Runs a program: "game" with the game picked, or a test program (hello, window) with nil.
@property(nonatomic, copy) void (^start)(NSString* program, WinPadGame* game);
// Installs the packages at URLS (opened from AirDrop, Files or a share sheet) and the ones
// waiting in Documents, then shows the game.
- (void)openPackages:(NSArray<NSURL*>*)urls;
@end
