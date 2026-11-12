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

// How a game's picture fills the screen once it draws through Metal (main.m): "fit" (all of
// it in its own shape, black bars at the sides), "stretch" (the whole screen, the picture
// stretched to it) or "fill" (the whole screen in the picture's shape, its edges cut off). The
// game's winpad.json "scaling" wins over the setting (Nastavení › Obraz hry).
NSString* WinPadPictureScaling(NSDictionary* settings);
// Whether the picture stays out of an iPhone's camera cutout and rounded corners (left and
// right safe area in landscape).
BOOL WinPadPictureAvoidsCutout(void);
// With "custom" scaling: how much wider than its own shape the picture is, in percent (0-100,
// the "pictureStretch" setting or winpad.json "stretch"), at most as wide as the screen.
NSInteger WinPadPictureStretch(NSDictionary* settings);
// The monitor the game is told it has (MADEIRA_SCREEN_W/H), or CGSizeZero for Wine's 1024x768.
// "Širokoúhlý monitor" (the "gameScreen" setting "wide") or the game's winpad.json "screen":
// "wide" makes it 768 lines tall in the shape of DISPLAY (an iPhone 16 Pro: 1670x768), so a game
// that lists the monitor's modes can pick a wide one; "WxH" names a size, "4:3" keeps 1024x768.
CGSize WinPadGameScreen(NSDictionary* settings, CGSize display);

// The inputs of a game controller that become keys (main.m's Gamepads), in the order the
// settings list them.
// Up..Right are the d-pad, LUp..LRight the left stick (on its own since the stick presets; until
// one is set it is what the d-pad is), RUp..RRight the right stick. A..Y are the face buttons by
// where they sit: A the bottom one, B the right, X the left, Y the top (GCExtendedGamepad's).
enum { PadUp, PadDown, PadLeft, PadRight, PadA, PadB, PadX, PadY, PadL1, PadR1, PadL2, PadR2, PadMenu, PadOptions,
       PadRUp, PadRDown, PadRLeft, PadRRight, PadLUp, PadLDown, PadLLeft, PadLRight, PadCount };
// The Windows virtual key of each input (0: none): the defaults, made for a racing game, with the
// changes made in the settings (the "padKeys" setting: input name → key, e.g. {a = 32;}).
void WinPadPadKeys(unsigned short keys[PadCount]);
// The controller's look: "xbox" (A B X Y, LB RB LT RT, View Menu), "playstation" (✕ ○ □ △, L1 R1
// L2 R2, Create Options, the d-pad above the left stick) or "nintendo" (B A Y X by place, L R ZL
// ZR, − +). The "padStyle" setting, or with "auto" (the default) the connected controller's.
NSString* WinPadPadStyle(void);
// An input's short label in STYLE (a button's face, "L" for the left stick), for the touch controller.
NSString* WinPadPadLabel(int input, NSString* style);

@interface LibraryViewController : UIViewController
// Runs a program: "game" with the game picked, or a test program (hello, window) with nil.
@property(nonatomic, copy) void (^start)(NSString* program, WinPadGame* game);
// Installs the packages at URLS (opened from AirDrop, Files or a share sheet) and the ones
// waiting in Documents, then shows the game.
- (void)openPackages:(NSArray<NSURL*>*)urls;
@end
