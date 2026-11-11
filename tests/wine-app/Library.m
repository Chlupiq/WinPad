// SPDX-License-Identifier: MIT
// WinPad Wine's game library: the screen the app opens on, like a console's.
// It lists the games copied into the app's Documents (Finder → the iPad →
// Files → WinPad Wine), one per folder: the folder's winpad.json may name the
// game ("title") and its program ("exe"), else the folder's name is the title
// and its largest .exe that is no installer or helper is the program. Its
// cover is cover.png or cover.jpg in the folder; a game without one gets one from the
// internet by its title (Covers.m: Steam, Wikipedia, SteamGridDB with a key), and "Obal"
// under the game (or a long press on its tile) picks another. A game's AOT image is
// Frameworks/fexaot-FOLDER.dylib (WinPadGameImage), else fexaot-game.dylib,
// the one tests/wine-app/game-aot.sh makes. So one app holds the images of
// any number of games (WinPad Translator's library writes them into one IPA).
// An image in the game folder itself, fexaot.dylib, comes first: WinPad
// Translator signs it on the Mac with the developer identity the app is
// signed with (--sign-identity), so a game is added without installing the
// app again. It is used only when its fexaot.build names this build of the
// app (winpad-build.txt in the bundle), and main.m falls back to the bundle's
// image if iOS refuses to load it.
//
// WinPad Translator may have put a game profile into winpad.json (the settings a known game
// needs: its program, DLL overrides, environment, registry values; WinPadGameSettings), and
// main.m starts the game with them.
//
// It looks like a console's home screen: a row of square tiles, the focused
// one large with a white frame and its title, tags and Spustit below, on a
// backdrop picked in the settings (Nastavení › Vzhled: four glows, the
// focused game's cover blurred, or a picture of the user's own, with or
// without the waves). On an iPhone, which runs it on its side, everything is
// smaller. A game controller (the d-pad or left stick picks, A starts, Y
// opens the settings, B closes them), a hardware keyboard (arrows, Enter) or
// a tap picks and starts one. Wine runs once per process, so a game starts in
// place of the library (main.m) and the app is started again for the next.
//
// A game without its code in the image runs it in FEX's interpreter, which
// writes each block it learns to the game's code maps right away
// (patches/fex-wow64/0038), so nothing is lost when iPadOS ends the app.
// "Exportovat pro převodník" (or the controller's X) shares them as one zip
// (AirDrop to the Mac, Files, Mail…) for WinPad Translator's next round; the
// tag under the title counts the maps written since the last export.
//
// A game also comes as one file, a WinPad package (NAME.winpad, made by
// WinPad Translator's --package): opened from AirDrop, Files or a share sheet
// (Info.plist's document type), or copied into Documents, it is unpacked into
// Documents/<its folder> (WinPadInstallPackage, Package.c) and the game shows
// in the library.
//
// With the "libraryTest" setting (CI, tests/wine-app/build-xcode.sh) the
// library writes the games it found to Documents/library.txt, exports the
// maps of each game that has some to Documents/export-FOLDER.zip, then
// presses right and A.
#import "Library.h"

#import "Covers.h"
#import "Package.h"
#import "WinPadJIT.h"
#import "WinPadRedist.h"

#import <GameController/GameController.h>
#import <PhotosUI/PhotosUI.h>
#import <UniformTypeIdentifiers/UniformTypeIdentifiers.h>

#include <math.h>
#include <string.h>
#include <sys/utsname.h>

static NSString* Documents(void) {
  return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

static UIColor* Hex(uint32_t rgb) {
  return [UIColor colorWithRed:((rgb >> 16) & 255) / 255.0 green:((rgb >> 8) & 255) / 255.0 blue:(rgb & 255) / 255.0 alpha:1];
}

@implementation WinPadGame
@end

// Frameworks/fexaot-FOLDER.dylib, FOLDER in lower case with each run of other
// characters than letters and digits one "-"; else fexaot-game.dylib; else nil.
static NSString* Slug(NSString* folder) {
  NSString* lower = folder.lowercaseString;
  NSMutableString* slug = [NSMutableString new];
  BOOL dash = NO;
  for (NSUInteger i = 0; i < lower.length; i++) {
    const unichar c = [lower characterAtIndex:i];
    if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) {
      if (dash && slug.length) [slug appendString:@"-"];
      dash = NO;
      [slug appendFormat:@"%C", c];
    } else {
      dash = YES;
    }
  }
  return slug;
}

static NSString* WinPadGameImage(NSString* folder) {
  NSString* slug = Slug(folder);
  NSString* frameworks = NSBundle.mainBundle.privateFrameworksPath;
  for (NSString* name in @[ [NSString stringWithFormat:@"fexaot-%@.dylib", slug], @"fexaot-game.dylib" ]) {
    NSString* path = [frameworks stringByAppendingPathComponent:name];
    if ([NSFileManager.defaultManager fileExistsAtPath:path]) return path;
  }
  return nil;
}

// The build of this app (build-xcode.sh's winpad-build.txt), or nil.
static NSString* AppBuild(void) {
  NSString* path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"winpad-build.txt"];
  NSString* build = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
  build = [build stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  return build.length ? build : nil;
}

// The game folder's own image, if it is for this build of the app; else nil, with why in *note.
static NSString* FolderImage(NSString* dir, NSString** note) {
  NSString* image = [dir stringByAppendingPathComponent:@"fexaot.dylib"];
  if (![NSFileManager.defaultManager fileExistsAtPath:image]) return nil;
  NSString* app = AppBuild();
  NSString* made = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"fexaot.build"]
                                             encoding:NSUTF8StringEncoding
                                                error:nil];
  made = [made stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (app && ![made isEqualToString:app]) {
    *note = [NSString stringWithFormat:@"fexaot.dylib is for app build %@, this is %@", made.length ? made : @"?", app];
    return nil;
  }
  return image;
}

// An installer, an uninstaller, a settings tool and the like, by its name.
static BOOL HelperProgram(NSString* name) {
  NSString* lower = name.lowercaseString;
  for (NSString* word in @[ @"setup", @"unins", @"install", @"config", @"crash", @"update", @"redist", @"register", @"patch" ])
    if ([lower containsString:word]) return YES;
  return NO;
}

// "32bit" or "64bit" from a Windows program's PE header, or nil.
static NSString* ProgramArch(NSString* path) {
  NSFileHandle* f = [NSFileHandle fileHandleForReadingAtPath:path];
  NSData* head = [f readDataOfLength:4096];
  [f closeFile];
  if (head.length < 64) return nil;
  const uint8_t* b = head.bytes;
  const uint32_t pe = b[0x3c] | b[0x3d] << 8 | b[0x3e] << 16 | (uint32_t)b[0x3f] << 24;
  if (pe > head.length - 6 || memcmp(b + pe, "PE\0\0", 4)) return nil;
  const uint16_t machine = b[pe + 4] | b[pe + 5] << 8;
  return machine == 0x14c ? @"32bit" : machine == 0x8664 ? @"64bit" : nil;
}

// Where the game's code maps are written (main.m: FEX's cache folder Documents/fexcache/FOLDER).
static NSString* MapsDir(NSString* folder) {
  return [[Documents() stringByAppendingPathComponent:@"fexcache"]
      stringByAppendingPathComponent:[folder stringByAppendingPathComponent:@"codemap/new"]];
}

// The non-empty code maps (ID.TIME.bin) in DIR, with when each was last written.
static NSDictionary<NSString*, NSDate*>* MapFiles(NSString* dir) {
  NSFileManager* fm = NSFileManager.defaultManager;
  NSMutableDictionary* maps = [NSMutableDictionary new];
  for (NSString* name in [fm contentsOfDirectoryAtPath:dir error:nil]) {
    if (![name.pathExtension isEqualToString:@"bin"] || [name hasPrefix:@"."]) continue;
    NSDictionary* attrs = [fm attributesOfItemAtPath:[dir stringByAppendingPathComponent:name] error:nil];
    if ([attrs.fileType isEqualToString:NSFileTypeRegular] && attrs.fileSize > 0) maps[name] = attrs.fileModificationDate;
  }
  return maps;
}

// When the maps of each game folder were last exported ("mapsExported": folder → date).
static NSDate* MapsExported(NSString* folder) {
  id date = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"mapsExported"][folder];
  return [date isKindOfClass:NSDate.class] ? date : nil;
}

void WinPadMarkMapsExported(WinPadGame* game, NSDate* date) {
  NSMutableDictionary* all = [[NSUserDefaults.standardUserDefaults dictionaryForKey:@"mapsExported"] mutableCopy] ?: [NSMutableDictionary new];
  all[game.folder] = date;
  [NSUserDefaults.standardUserDefaults setObject:all forKey:@"mapsExported"];
}

static void CountMaps(WinPadGame* game) {
  NSDictionary<NSString*, NSDate*>* maps = MapFiles(MapsDir(game.folder));
  NSDate* exported = MapsExported(game.folder);
  NSInteger fresh = 0;
  for (NSDate* written in maps.allValues)
    if (!exported || [written compare:exported] == NSOrderedDescending) fresh++;
  game.maps = (NSInteger)maps.count;
  game.newMaps = fresh;
}

static NSError* ExportError(NSString* text) {
  return [NSError errorWithDomain:@"WinPadExport" code:1 userInfo:@{NSLocalizedDescriptionKey : text}];
}

NSURL* WinPadExportMaps(WinPadGame* game, NSError** error) {
  NSFileManager* fm = NSFileManager.defaultManager;
  NSString* maps = MapsDir(game.folder);
  const NSUInteger count = MapFiles(maps).count;
  if (!count) {
    if (error) *error = ExportError(@"Hra zatím nezapsala žádné code mapy: zahraj si ji a zkus to znovu.");
    return nil;
  }
  NSDate* now = NSDate.date;
  NSDateFormatter* stamp = [NSDateFormatter new];
  stamp.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
  stamp.dateFormat = @"yyyyMMdd-HHmm";
  NSString* slug = Slug(game.folder);
  NSString* name = [NSString stringWithFormat:@"WinPad-mapy-%@-%@", slug.length ? slug : @"hra", [stamp stringFromDate:now]];
  NSString* work = [NSTemporaryDirectory() stringByAppendingPathComponent:@"export"];
  [fm removeItemAtPath:work error:nil];
  NSString* top = [work stringByAppendingPathComponent:name];
  NSString* codemap = [[[top stringByAppendingPathComponent:@"fexcache"] stringByAppendingPathComponent:game.folder]
      stringByAppendingPathComponent:@"codemap"];
  NSError* e = nil;
  // The same layout as the app's Documents/fexcache: WinPad Translator takes it as it takes that folder.
  if (![fm createDirectoryAtPath:codemap withIntermediateDirectories:YES attributes:nil error:&e] ||
      ![fm copyItemAtPath:maps toPath:[codemap stringByAppendingPathComponent:@"new"] error:&e]) {
    if (error) *error = e;
    return nil;
  }
  struct utsname machine;
  uname(&machine);
  NSISO8601DateFormatter* iso = [NSISO8601DateFormatter new];
  NSDictionary* manifest = @{
    @"kind" : @"winpad-codemaps",
    @"version" : @1,
    @"game" : @{@"folder" : game.folder, @"title" : game.title ?: game.folder, @"exe" : game.exe ?: @""},
    @"maps" : @(count),
    @"exported" : [iso stringFromDate:now],
    @"app_build" : AppBuild() ?: @"",
    @"device" : @(machine.machine),
    @"image" : game.image.lastPathComponent ?: @"",
  };
  NSData* json = [NSJSONSerialization dataWithJSONObject:manifest options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:&e];
  if (!json || ![json writeToFile:[top stringByAppendingPathComponent:@"winpad-export.json"] options:0 error:&e]) {
    if (error) *error = e;
    return nil;
  }
  // Reading a folder "for uploading" makes a zip of it (removed after the block): the system's
  // own zip, which Finder, Windows and Python open.
  NSURL* zip = [NSURL fileURLWithPath:[work stringByAppendingPathComponent:[name stringByAppendingPathExtension:@"zip"]]];
  __block BOOL zipped = NO;
  __block NSError* copy_error = nil;
  NSError* coordinate_error = nil;
  [[NSFileCoordinator new] coordinateReadingItemAtURL:[NSURL fileURLWithPath:top]
                                              options:NSFileCoordinatorReadingForUploading
                                                error:&coordinate_error
                                           byAccessor:^(NSURL* made) {
                                             NSError* failed = nil;
                                             zipped = [fm copyItemAtURL:made toURL:zip error:&failed];
                                             copy_error = failed;
                                           }];
  [fm removeItemAtPath:top error:nil];
  if (!zipped) {
    if (error) *error = copy_error ?: coordinate_error ?: ExportError(@"Zip s code mapami se nepodařilo vytvořit.");
    return nil;
  }
  return zip;
}

// "1 nová code mapa", "3 nové code mapy", "5 nových code map".
static NSString* NewMapsText(NSInteger n) {
  return n == 1 ? @"1 nová code mapa"
         : n >= 2 && n <= 4 ? [NSString stringWithFormat:@"%ld nové code mapy", (long)n]
                            : [NSString stringWithFormat:@"%ld nových code map", (long)n];
}

NSDictionary* WinPadGameSettings(NSDictionary* info) {
  NSMutableDictionary* out = [NSMutableDictionary new];
  NSDictionary* profile = [info[@"profile"] isKindOfClass:NSDictionary.class] ? info[@"profile"] : nil;
  if ([profile[@"settings"] isKindOfClass:NSDictionary.class]) [out addEntriesFromDictionary:profile[@"settings"]];
  for (NSString* key in info) {
    if ([key isEqualToString:@"profile"]) continue;
    id mine = info[key], theirs = out[key];
    if ([@[ @"dllOverrides", @"env", @"registry" ] containsObject:key] && [mine isKindOfClass:NSDictionary.class] &&
        [theirs isKindOfClass:NSDictionary.class]) {
      NSMutableDictionary* merged = [theirs mutableCopy];
      for (NSString* k in mine) {
        if ([key isEqualToString:@"registry"] && [mine[k] isKindOfClass:NSDictionary.class] &&
            [merged[k] isKindOfClass:NSDictionary.class]) {
          NSMutableDictionary* values = [merged[k] mutableCopy];
          [values addEntriesFromDictionary:mine[k]];
          merged[k] = values;
        } else {
          merged[k] = mine[k];
        }
      }
      out[key] = merged;
    } else {
      out[key] = mine;
    }
  }
  return out;
}

NSArray<WinPadGame*>* WinPadFindGames(void) {
  NSFileManager* fm = NSFileManager.defaultManager;
  NSString* docs = Documents();
  NSMutableArray<WinPadGame*>* games = [NSMutableArray new];
  NSArray* folders = [[fm contentsOfDirectoryAtPath:docs error:nil] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
  for (NSString* folder in folders) {
    // The app's own folders (main.m): the Wine prefix, FEX's caches, the window's frames.
    // Inbox: where iOS puts the files other apps (AirDrop) hand over.
    if ([folder hasPrefix:@"."] || [@[ @"prefix", @"fexcache", @"frames", @"Inbox" ] containsObject:folder]) continue;
    NSString* dir = [docs stringByAppendingPathComponent:folder];
    BOOL is_dir = NO;
    if (![fm fileExistsAtPath:dir isDirectory:&is_dir] || !is_dir) continue;
    NSArray* files = [fm contentsOfDirectoryAtPath:dir error:nil];
    NSDictionary* info = nil;
    NSData* json = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"winpad.json"]];
    if (json) {
      id obj = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
      if ([obj isKindOfClass:NSDictionary.class]) info = obj;
    }
    NSDictionary* settings = WinPadGameSettings(info);
    NSString* exe = [settings[@"exe"] isKindOfClass:NSString.class] ? settings[@"exe"] : nil;
    if (exe && ([exe containsString:@".."] || ![fm fileExistsAtPath:[dir stringByAppendingPathComponent:exe]])) exe = nil;
    if (!exe) {
      unsigned long long best = 0;
      BOOL best_helper = YES;
      for (NSString* f in files) {
        if (![f.pathExtension.lowercaseString isEqualToString:@"exe"]) continue;
        const unsigned long long size = [fm attributesOfItemAtPath:[dir stringByAppendingPathComponent:f] error:nil].fileSize;
        const BOOL helper = HelperProgram(f);
        if (!exe || (best_helper && !helper) || (helper == best_helper && size > best)) {
          exe = f;
          best = size;
          best_helper = helper;
        }
      }
    }
    if (!exe) continue;
    WinPadGame* game = [WinPadGame new];
    game.folder = folder;
    game.exe = [folder stringByAppendingPathComponent:exe];
    NSString* title = [settings[@"title"] isKindOfClass:NSString.class] ? settings[@"title"] : nil;
    game.settings = settings;
    NSDictionary* profile = [info[@"profile"] isKindOfClass:NSDictionary.class] ? info[@"profile"] : nil;
    if ([profile[@"id"] isKindOfClass:NSString.class])
      game.profile = [NSString stringWithFormat:@"%@ v%@", profile[@"id"], profile[@"version"] ?: @"?"];
    game.title = title.length ? title : folder;
    game.arch = ProgramArch([docs stringByAppendingPathComponent:game.exe]);
    game.bundleImage = WinPadGameImage(folder);
    NSString* note = nil;
    NSString* own = FolderImage(dir, &note);
    game.image = own ?: game.bundleImage;
    game.imageInFolder = own != nil;
    game.folderImageNote = note;
    game.cover = [UIImage imageWithContentsOfFile:WinPadOwnCoverPath(folder)];
    for (NSString* f in game.cover ? @[] : files) {
      if ([@[ @"cover.png", @"cover.jpg", @"cover.jpeg" ] containsObject:f.lowercaseString]) {
        game.cover = [UIImage imageWithContentsOfFile:[dir stringByAppendingPathComponent:f]];
        break;
      }
    }
    CountMaps(game);
    [games addObject:game];
  }
  return games;
}

// A folder name a package may unpack into: one name, not one of the app's own folders.
static BOOL PackageFolderOK(NSString* name) {
  if (!name.length || [name hasPrefix:@"."] || [name containsString:@"/"] || [name containsString:@"\\"]) return NO;
  for (NSString* own in @[ @"prefix", @"fexcache", @"frames", @"inbox" ])
    if ([name.lowercaseString isEqualToString:own]) return NO;
  return YES;
}

// Moves SRC to DST; where both are folders, each of SRC's items into DST, so the files
// the game wrote itself (saves, its settings) stay unless the package has them too.
static BOOL MergeInto(NSString* src, NSString* dst, NSError** error) {
  NSFileManager* fm = NSFileManager.defaultManager;
  BOOL src_dir = NO, dst_dir = NO;
  [fm fileExistsAtPath:src isDirectory:&src_dir];
  if (![fm fileExistsAtPath:dst isDirectory:&dst_dir]) return [fm moveItemAtPath:src toPath:dst error:error];
  if (src_dir && dst_dir) {
    for (NSString* name in [fm contentsOfDirectoryAtPath:src error:nil])
      if (!MergeInto([src stringByAppendingPathComponent:name], [dst stringByAppendingPathComponent:name], error)) return NO;
    return YES;
  }
  return [fm removeItemAtPath:dst error:error] && [fm moveItemAtPath:src toPath:dst error:error];
}

typedef struct {
  __unsafe_unretained void (^progress)(double);
  CFAbsoluteTime last;
} PackageProgress;

static int ReportPackageProgress(void* ctx, uint64_t done, uint64_t total) {
  PackageProgress* p = ctx;
  const CFAbsoluteTime now = CFAbsoluteTimeGetCurrent();
  if (p->progress && (now - p->last > 0.1 || done == total)) {
    p->last = now;
    p->progress(total ? (double)done / (double)total : 1);
  }
  return 0;
}

NSString* WinPadInstallPackage(NSString* path, void (^progress)(double), NSString** error) {
  char err[512] = "";
  void* data = NULL;
  size_t size = 0;
  if (winpad_package_read(path.fileSystemRepresentation, "winpad.json", 1 << 20, &data, &size, err, sizeof err)) {
    *error = [NSString stringWithFormat:@"Není to balíček WinPad: %s", err];
    return nil;
  }
  id settings = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytesNoCopy:data length:size freeWhenDone:YES]
                                                options:0
                                                  error:nil];
  NSDictionary* package = [settings isKindOfClass:NSDictionary.class] ? settings[@"package"] : nil;
  if (![package isKindOfClass:NSDictionary.class]) package = @{};
  NSNumber* format = [package[@"format"] isKindOfClass:NSNumber.class] ? package[@"format"] : @1;
  if (format.integerValue > 1) {
    *error = @"Balíček je z novější verze převodníku: aktualizuj aplikaci.";
    return nil;
  }
  NSString* folder = [package[@"folder"] isKindOfClass:NSString.class] ? package[@"folder"]
                                                                       : path.lastPathComponent.stringByDeletingPathExtension;
  if (!PackageFolderOK(folder)) {
    *error = [NSString stringWithFormat:@"Balíček chce složku „%@“, tu aplikace nemůže použít.", folder];
    return nil;
  }
  NSFileManager* fm = NSFileManager.defaultManager;
  NSString* docs = Documents();
  NSString* dest = [docs stringByAppendingPathComponent:folder];
  if ([package[@"game_files"] isEqual:@NO] && ![fm fileExistsAtPath:dest]) {
    *error = [NSString stringWithFormat:@"V balíčku nejsou soubory hry a složka %@ tu ještě není: zkopíruj nejdřív hru "
                                        @"(nebo balíček s ní).",
                                        folder];
    return nil;
  }
  // Unpacked next to the games first, then moved in: a broken package leaves the game as it was.
  NSString* work = [[docs stringByAppendingPathComponent:@".winpad-install"] stringByAppendingPathComponent:NSUUID.UUID.UUIDString];
  PackageProgress report = {progress, 0};
  if (winpad_package_extract(path.fileSystemRepresentation, work.fileSystemRepresentation, ReportPackageProgress, &report,
                             err, sizeof err)) {
    [fm removeItemAtPath:work error:nil];
    *error = [NSString stringWithFormat:@"Rozbalení selhalo: %s", err];
    return nil;
  }
  NSError* move_error = nil;
  BOOL ok = [fm createDirectoryAtPath:dest withIntermediateDirectories:YES attributes:nil error:&move_error];
  for (NSString* name in ok ? [fm contentsOfDirectoryAtPath:work error:nil] : @[]) {
    ok = MergeInto([work stringByAppendingPathComponent:name], [dest stringByAppendingPathComponent:name], &move_error);
    if (!ok) break;
  }
  [fm removeItemAtPath:work error:nil];
  if (!ok) {
    *error = [NSString stringWithFormat:@"Hru se nepodařilo přesunout do %@: %@", folder, move_error.localizedDescription];
    return nil;
  }
  return folder;
}

NSArray<NSURL*>* WinPadWaitingPackages(void) {
  NSMutableArray<NSURL*>* found = [NSMutableArray new];
  NSString* docs = Documents();
  for (NSString* dir in @[ docs, [docs stringByAppendingPathComponent:@"Inbox"] ]) {
    for (NSString* name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) {
      if ([name.pathExtension.lowercaseString isEqualToString:@"winpad"] && ![name hasPrefix:@"."])
        [found addObject:[NSURL fileURLWithPath:[dir stringByAppendingPathComponent:name]]];
    }
  }
  return found;
}

// Whether the file at URL is the app's own copy (in its Documents), to delete once installed.
static BOOL InDocuments(NSURL* url) {
  NSString* docs = Documents().stringByResolvingSymlinksInPath;
  NSString* path = url.path.stringByResolvingSymlinksInPath;
  return [path hasPrefix:[docs stringByAppendingString:@"/"]];
}

// The controller's inputs, named as on an Xbox controller: their names in the settings and in the
// "padKeys" setting (the first names, kept from before), and the keys they are by default: the
// left stick and d-pad steer, RT accelerates and LT brakes; the right stick is no key.
static NSString* const PadTitles[PadCount] = {
    @"Nahoru", @"Dolů", @"Doleva", @"Doprava", @"A", @"B", @"X", @"Y", @"LB", @"RB", @"LT", @"RT", @"Menu", @"View",
    @"Pravá páčka nahoru", @"Pravá páčka dolů", @"Pravá páčka doleva", @"Pravá páčka doprava"};
static NSString* const PadIds[PadCount] = {@"up", @"down", @"left", @"right", @"a",  @"b",    @"x",       @"y",
                                           @"l1", @"r1",   @"l2",   @"r2",    @"menu", @"options", @"rup", @"rdown",
                                           @"rleft", @"rright"};
static const unsigned short PadDefaults[PadCount] = {0x26, 0x28, 0x25, 0x27, 0x0d, 0x1b, 0x20, 'C', 'Z',
                                                     'A',  0x28, 0x26, 0x1b, 0x0d, 0,    0,    0,    0};

void WinPadPadKeys(unsigned short keys[PadCount]) {
  NSDictionary* saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"padKeys"];
  for (int i = 0; i < PadCount; i++) {
    id key = saved[PadIds[i]];
    keys[i] = [key respondsToSelector:@selector(intValue)] ? (unsigned short)([key intValue] & 0xff) : PadDefaults[i];
  }
}

static void SavePadKey(int input, unsigned short vk) {
  NSMutableDictionary* saved = [[NSUserDefaults.standardUserDefaults dictionaryForKey:@"padKeys"] mutableCopy] ?: [NSMutableDictionary new];
  saved[PadIds[input]] = @(vk);
  [NSUserDefaults.standardUserDefaults setObject:saved forKey:@"padKeys"];
}

// The keys an input can be: those a game is most likely to use.
static NSArray<NSNumber*>* KeyChoices(void) {
  NSMutableArray* keys = [@[ @0x26, @0x28, @0x25, @0x27, @0x0d, @0x1b, @0x20, @0x10, @0x11, @0x12, @0x09, @0x08 ] mutableCopy];
  for (int c = 'A'; c <= 'Z'; c++) [keys addObject:@(c)];
  for (int c = '0'; c <= '9'; c++) [keys addObject:@(c)];
  for (int f = 0; f < 12; f++) [keys addObject:@(0x70 + f)];
  [keys addObject:@0];
  return keys;
}

static NSString* KeyName(unsigned short vk) {
  switch (vk) {
    case 0: return @"Nic";
    case 0x26: return @"Šipka nahoru";
    case 0x28: return @"Šipka dolů";
    case 0x25: return @"Šipka doleva";
    case 0x27: return @"Šipka doprava";
    case 0x0d: return @"Enter";
    case 0x1b: return @"Esc";
    case 0x20: return @"Mezerník";
    case 0x10: return @"Shift";
    case 0x11: return @"Ctrl";
    case 0x12: return @"Alt";
    case 0x09: return @"Tab";
    case 0x08: return @"Backspace";
  }
  if ((vk >= 'A' && vk <= 'Z') || (vk >= '0' && vk <= '9')) return [NSString stringWithFormat:@"%c", vk];
  if (vk >= 0x70 && vk < 0x7c) return [NSString stringWithFormat:@"F%d", vk - 0x70 + 1];
  return [NSString stringWithFormat:@"Klávesa 0x%02x", vk];
}

// Picks the key of one input.
@interface WinPadKeyPickerViewController : UITableViewController
@property(nonatomic) int input;
@end

@implementation WinPadKeyPickerViewController
- (instancetype)init {
  return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = PadTitles[self.input];
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
  return (NSInteger)KeyChoices().count;
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)path {
  UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
  unsigned short keys[PadCount];
  WinPadPadKeys(keys);
  const unsigned short vk = KeyChoices()[path.row].unsignedShortValue;
  cell.textLabel.text = KeyName(vk);
  cell.accessoryType = vk == keys[self.input] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
  return cell;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)path {
  SavePadKey(self.input, KeyChoices()[path.row].unsignedShortValue);
  [self.navigationController popViewControllerAnimated:YES];
}
@end

// A label with room around its text: the game's tags.
@interface WinPadTag : UILabel
@end

@implementation WinPadTag
- (CGSize)intrinsicContentSize {
  const CGSize s = super.intrinsicContentSize;
  return CGSizeMake(s.width + 24, s.height + 12);
}

- (void)drawTextInRect:(CGRect)rect {
  [super drawTextInRect:UIEdgeInsetsInsetRect(rect, UIEdgeInsetsMake(6, 12, 6, 12))];
}
@end

static WinPadTag* Tag(NSString* text, uint32_t fg, uint32_t bg) {
  WinPadTag* tag = [WinPadTag new];
  tag.text = text;
  tag.font = [UIFont systemFontOfSize:15];
  tag.textColor = Hex(fg);
  tag.backgroundColor = Hex(bg);
  tag.layer.cornerRadius = 8;
  tag.layer.masksToBounds = YES;
  return tag;
}

// A cover: the game's picture, else its title on a plain panel.
static void ShowCover(UIImageView* view, UILabel* placeholder, WinPadGame* game) {
  view.image = game.cover;
  placeholder.hidden = game.cover != nil;
  placeholder.text = game.title;
}

static UIImageView* CoverView(UILabel** placeholder, CGFloat font) {
  UIImageView* view = [UIImageView new];
  view.contentMode = UIViewContentModeScaleAspectFill;
  view.clipsToBounds = YES;
  view.backgroundColor = Hex(0x1E2633);
  UILabel* label = [UILabel new];
  label.textColor = Hex(0xB4BDCA);
  label.font = [UIFont systemFontOfSize:font weight:UIFontWeightSemibold];
  label.textAlignment = NSTextAlignmentCenter;
  label.numberOfLines = 0;
  label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [view addSubview:label];
  *placeholder = label;
  return view;
}

// The backgrounds the library and the settings can have (Nastavení › Vzhled, the "background"
// setting): a glow from the top left in three shades, the focused game's cover blurred, or
// the user's own picture, Documents/background.jpg (from Photos in the settings, or copied in).
typedef struct {
  const char* id;
  const char* name;
  uint32_t glow, mid, edge;
} WinPadBackground;
static const WinPadBackground Backgrounds[] = {
    {"blue", "Modrá vlna", 0x1B4F9C, 0x0B2A63, 0x04122E},
    {"midnight", "Půlnoc", 0x2A3142, 0x12161F, 0x06080C},
    {"dusk", "Fialový soumrak", 0x6A35A0, 0x2E1858, 0x0E0620},
    {"emerald", "Smaragd", 0x1F7A5A, 0x0E3D2E, 0x04140F},
    {"cover", "Obal vybrané hry", 0x3B4250, 0x1A1E26, 0x0A0E16},
    {"custom", "Vlastní obrázek", 0x3A3F4A, 0x1A1D24, 0x0A0C10},
};
enum { BackgroundCount = sizeof(Backgrounds) / sizeof(Backgrounds[0]) };

static NSString* CustomBackgroundPath(void) {
  return [Documents() stringByAppendingPathComponent:@"background.jpg"];
}

static const WinPadBackground* CurrentBackground(void) {
  NSString* saved = [NSUserDefaults.standardUserDefaults stringForKey:@"background"];
  for (int i = 0; i < BackgroundCount; i++)
    if ([saved isEqualToString:@(Backgrounds[i].id)]) return &Backgrounds[i];
  return &Backgrounds[0];
}

static BOOL BackgroundWaves(void) {
  id waves = [NSUserDefaults.standardUserDefaults objectForKey:@"backgroundWaves"];
  return !waves || [waves boolValue];
}

// The background itself; it follows the settings as they change.
@interface WinPadBackdrop : UIView
@property(nonatomic, strong) UIImage* cover;  // the focused game's cover, for the "cover" background
@end

@interface WinPadBackdrop ()
@property(nonatomic, strong) CAGradientLayer* glow;
@property(nonatomic, strong) UIImageView* picture;
@property(nonatomic, strong) UIVisualEffectView* blur;
@property(nonatomic, strong) UIView* dim;
@property(nonatomic, strong) CAShapeLayer* wave1;
@property(nonatomic, strong) CAShapeLayer* wave2;
@property(nonatomic, strong) id observer;
- (void)refresh;
@end

@implementation WinPadBackdrop
- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  self.userInteractionEnabled = NO;
  self.clipsToBounds = YES;
  self.glow = [CAGradientLayer layer];
  self.glow.type = kCAGradientLayerRadial;
  self.glow.startPoint = CGPointMake(0.2, 0);
  self.glow.endPoint = CGPointMake(1.4, 0.9);
  self.glow.locations = @[ @0, @0.45, @1 ];
  [self.layer addSublayer:self.glow];
  self.picture = [UIImageView new];
  self.picture.contentMode = UIViewContentModeScaleAspectFill;
  [self addSubview:self.picture];
  self.blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
  [self addSubview:self.blur];
  self.dim = [UIView new];
  self.dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
  [self addSubview:self.dim];
  self.wave1 = [CAShapeLayer layer];
  self.wave2 = [CAShapeLayer layer];
  for (CAShapeLayer* wave in @[ self.wave1, self.wave2 ]) {
    wave.fillColor = UIColor.clearColor.CGColor;
    wave.lineWidth = 2;
    [self.layer addSublayer:wave];
  }
  self.wave1.strokeColor = [Hex(0x7FB2FF) colorWithAlphaComponent:0.18].CGColor;
  self.wave2.strokeColor = [Hex(0x7FB2FF) colorWithAlphaComponent:0.10].CGColor;
  __weak WinPadBackdrop* weak = self;
  self.observer = [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification
                                                                  object:nil
                                                                   queue:NSOperationQueue.mainQueue
                                                              usingBlock:^(NSNotification* note) {
                                                                [weak refresh];
                                                              }];
  [self refresh];
  return self;
}

- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self.observer];
}

- (void)setCover:(UIImage*)cover {
  _cover = cover;
  [self refresh];
}

- (void)refresh {
  const WinPadBackground* bg = CurrentBackground();
  self.glow.colors = @[ (id)Hex(bg->glow).CGColor, (id)Hex(bg->mid).CGColor, (id)Hex(bg->edge).CGColor ];
  UIImage* picture = nil;
  if (!strcmp(bg->id, "cover")) picture = self.cover;
  if (!strcmp(bg->id, "custom")) picture = [UIImage imageWithContentsOfFile:CustomBackgroundPath()];
  self.picture.image = picture;
  self.picture.hidden = self.dim.hidden = !picture;
  // A cover is blurred to a backdrop; the user's own picture shows as it is, a little darker.
  self.blur.hidden = !picture || strcmp(bg->id, "cover");
  self.wave1.hidden = self.wave2.hidden = !BackgroundWaves();
}

- (void)layoutSubviews {
  [super layoutSubviews];
  const CGRect b = self.bounds;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  self.glow.frame = b;
  const CGFloat w = b.size.width, h = b.size.height;
  for (int i = 0; i < 2; i++) {
    const CGFloat y = h * (0.70 + 0.04 * i);
    UIBezierPath* path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(0, y)];
    [path addCurveToPoint:CGPointMake(w * 0.66, y + h * 0.01) controlPoint1:CGPointMake(w * 0.23, y - h * 0.08)
            controlPoint2:CGPointMake(w * 0.45, y + h * 0.12)];
    [path addCurveToPoint:CGPointMake(w, y - h * 0.02) controlPoint1:CGPointMake(w * 0.85, y - h * 0.08)
            controlPoint2:CGPointMake(w * 0.95, y - h * 0.05)];
    (i ? self.wave2 : self.wave1).path = path.CGPath;
  }
  [CATransaction commit];
  self.picture.frame = self.blur.frame = self.dim.frame = b;
}
@end

// Picks the background: one of Backgrounds, a picture from Photos for "custom".
@interface WinPadBackgroundViewController : UITableViewController <PHPickerViewControllerDelegate>
@end

@implementation WinPadBackgroundViewController
- (instancetype)init {
  return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Pozadí";
  self.tableView.backgroundView = [WinPadBackdrop new];
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
  return BackgroundCount;
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
  return @"Vlastní obrázek vybereš z Fotek, nebo ho nahraj jako background.jpg do Soubory › WinPad Wine.";
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)path {
  UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
  const WinPadBackground* bg = &Backgrounds[path.row];
  cell.textLabel.text = @(bg->name);
  cell.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
  // A swatch of its colours.
  UIGraphicsImageRenderer* r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(44, 30)];
  cell.imageView.image = [r imageWithActions:^(UIGraphicsImageRendererContext* ctx) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGGradientRef g = CGGradientCreateWithColors(
        space, (__bridge CFArrayRef) @[ (id)Hex(bg->glow).CGColor, (id)Hex(bg->mid).CGColor, (id)Hex(bg->edge).CGColor ], NULL);
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 44, 30) cornerRadius:5] addClip];
    CGContextDrawRadialGradient(ctx.CGContext, g, CGPointMake(8, 0), 0, CGPointMake(8, 0), 52, kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(g);
    CGColorSpaceRelease(space);
  }];
  cell.accessoryType = bg == CurrentBackground() ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
  return cell;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)path {
  [tableView deselectRowAtIndexPath:path animated:YES];
  const WinPadBackground* bg = &Backgrounds[path.row];
  if (!strcmp(bg->id, "custom")) {
    PHPickerConfiguration* config = [PHPickerConfiguration new];
    config.filter = PHPickerFilter.imagesFilter;
    config.selectionLimit = 1;
    PHPickerViewController* picker = [[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
    return;
  }
  [NSUserDefaults.standardUserDefaults setObject:@(bg->id) forKey:@"background"];
  [tableView reloadData];
}

- (void)picker:(PHPickerViewController*)picker didFinishPicking:(NSArray<PHPickerResult*>*)results {
  [picker dismissViewControllerAnimated:YES completion:nil];
  NSItemProvider* item = results.firstObject.itemProvider;
  if (![item canLoadObjectOfClass:UIImage.class]) return;
  __weak WinPadBackgroundViewController* weak = self;
  [item loadObjectOfClass:UIImage.class
        completionHandler:^(id<NSItemProviderReading> object, NSError* error) {
          NSData* jpeg = [object isKindOfClass:UIImage.class] ? UIImageJPEGRepresentation((UIImage*)object, 0.9) : nil;
          dispatch_async(dispatch_get_main_queue(), ^{
            if (![jpeg writeToFile:CustomBackgroundPath() atomically:YES]) return;
            [NSUserDefaults.standardUserDefaults setObject:@"custom" forKey:@"background"];
            [weak.tableView reloadData];
          });
        }];
}
@end

// The settings: touch controls, the controller's keys, the last log, the test programs.
@interface WinPadLogViewController : UIViewController
@end

@implementation WinPadLogViewController
- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Poslední log";
  UITextView* text = [[UITextView alloc] initWithFrame:self.view.bounds];
  text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  text.editable = NO;
  text.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
  NSMutableString* all = [NSMutableString new];
  // main.m keeps the log of a run that stopped the app as wine.log.crashed.
  for (NSString* name in @[ @"wine.log", @"wine.log.crashed" ]) {
    NSString* log = [NSString stringWithContentsOfFile:[Documents() stringByAppendingPathComponent:name]
                                              encoding:NSUTF8StringEncoding
                                                 error:nil];
    if (log.length) [all appendFormat:@"== %@\n\n%@\n\n", name, log.length > 200000 ? [log substringFromIndex:log.length - 200000] : log];
  }
  text.text = all.length ? all : @"Zatím žádný log.";
  [self.view addSubview:text];
}
@end

// The settings' section 0 is the look; the others follow it, numbered from 0 after it in the code.
enum { AppearanceSection = 0 };

@interface WinPadSettingsViewController : UITableViewController
@property(nonatomic, copy) void (^run)(NSString* program);
@property(nonatomic, copy) NSString* directXState;  // the download's progress or its error, or nil
@end

// The settings' section of Microsoft's DirectX DLLs, counted after the look like the others.
enum { DirectXSection = 4 };

// What the DirectX row says: downloaded or not.
static NSString* DirectXSummary(void) {
  const NSUInteger n = WinPadDirectXDLLs().count;
  return n ? [NSString stringWithFormat:@"Staženo, %lu DLL", (unsigned long)n] : @"Nestaženo";
}

@implementation WinPadSettingsViewController
- (instancetype)init {
  return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Nastavení";
  self.tableView.backgroundView = [WinPadBackdrop new];
  self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                         target:self
                                                                                         action:@selector(done)];
}

// Back from a picker, which changed a key.
- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self.tableView reloadData];
}

- (void)done {
  [self dismissViewControllerAnimated:YES completion:nil];
}

- (BOOL)hasWindowProgram {
  return [NSFileManager.defaultManager
      fileExistsAtPath:[NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"fexaot-window.dylib"]];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView {
  return 7;
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
  if (section == AppearanceSection) return 4;
  section -= 1;
  return section == 0 ? 2 : section == 1 ? PadCount + 1 : section == 2 ? (self.hasWindowProgram ? 4 : 3) : section == 3 ? 3 : 2;
}

- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section {
  return @[ @"Vzhled", @"Ovládání", @"Mapování tlačítek", @"Diagnostika", @"JIT", @"DirectX od Microsoftu", @"O aplikaci" ][section];
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
  if (section == AppearanceSection)
    return @"Pozadí knihovny a nastavení, na iPadu i iPhonu. Obaly her bez obalu aplikace sama najde na internetu "
           @"podle názvu (Steam, Wikipedie) a uloží jen ten, jehož název sedí; jiný vybereš tlačítkem Obal pod hrou. "
           @"S klíčem SteamGridDB (zdarma: steamgriddb.com › Preferences › API) najde víc a hezčích obalů.";
  section -= 1;
  if (section == 0) return @"Ovladač na obrazovce se ukáže jen tehdy, když není připojený herní ovladač.";
  if (section == 1)
    return @"Klávesa, kterou hra dostane za každé tlačítko ovladače. Nahoru až doprava jsou křížový ovladač "
           @"i levá páčka. Platí pro všechny hry.";
  if (section == 2)
    return @"Ukazatel FPS ukáže ve hře snímky za sekundu, nejdelší snímek za poslední sekundu a rozlišení. "
           @"Testovací programy spustí Wine místo hry; pro další hru aplikaci spusť znovu.";
  if (section == 3)
    return @"S JITem hra běží bez vlastního AOT obrazu: co ještě neběželo, FEX přeloží za běhu. JIT zapíná "
           @"vestavěný pomocník (potřebuje párovací soubor a LocalDevVPN nebo vestavěnou VPN), nebo aplikace StikDebug. Bez JITu hra "
           @"běží ze svého AOT obrazu a interpretu. Návod je pod štítkem JIT v knihovně.";
  if (section == DirectXSection)
    return @"Originální DLL od Microsoftu (D3DX9, D3DX10/11, XInput, XAudio2, XACT…) z jeho instalačky DirectX "
           @"(červen 2010, asi 95 MB), stažené přímo od Microsoftu. Hra, které nějaká chybí, je dostane vždy; "
           @"s přepínačem je dostanou všechny hry místo verzí z Wine.";
  return @"Hry se přidávají ve Finderu: iPad → Soubory → WinPad Wine, každá ve své složce.";
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)path {
  UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
  cell.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
  if (path.section == AppearanceSection && path.row == 0) {
    cell.textLabel.text = @"Pozadí";
    cell.detailTextLabel.text = @(CurrentBackground()->name);
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
  }
  if (path.section == AppearanceSection && path.row == 2) {
    cell.textLabel.text = @"Stahovat obaly her";
    UISwitch* toggle = [UISwitch new];
    toggle.on = WinPadAutoCoversWanted();
    [toggle addTarget:self action:@selector(coverAutoChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
  }
  if (path.section == AppearanceSection && path.row == 3) {
    cell.textLabel.text = @"Klíč SteamGridDB";
    cell.detailTextLabel.text = [NSUserDefaults.standardUserDefaults stringForKey:@"steamGridDBKey"].length ? @"Zadán" : @"Nezadán";
    return cell;
  }
  if (path.section == AppearanceSection) {
    cell.textLabel.text = @"Vlny na pozadí";
    UISwitch* toggle = [UISwitch new];
    toggle.on = BackgroundWaves();
    [toggle addTarget:self action:@selector(wavesChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
  }
  path = [NSIndexPath indexPathForRow:path.row inSection:path.section - 1];
  if (path.section == 0 && path.row == 0) {
    cell.textLabel.text = @"Dotykové ovládání";
    UISwitch* toggle = [UISwitch new];
    id touch = [NSUserDefaults.standardUserDefaults objectForKey:@"touchControls"];
    toggle.on = !touch || [touch boolValue];
    [toggle addTarget:self action:@selector(touchChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
  } else if (path.section == 0) {
    cell.textLabel.text = @"Herní ovladač";
    GCController* pad = GCController.controllers.firstObject;
    cell.detailTextLabel.text = pad ? (pad.vendorName ?: @"Připojen") : @"Nepřipojen";
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
  } else if (path.section == 1 && path.row < PadCount) {
    unsigned short keys[PadCount];
    WinPadPadKeys(keys);
    cell.textLabel.text = PadTitles[path.row];
    cell.detailTextLabel.text = KeyName(keys[path.row]);
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  } else if (path.section == 1) {
    cell.textLabel.text = @"Obnovit výchozí mapování";
    cell.textLabel.textColor = UIColor.systemRedColor;
  } else if (path.section == 2 && path.row == 0) {
    cell.textLabel.text = @"Ukazatel FPS";
    UISwitch* toggle = [UISwitch new];
    toggle.on = [NSUserDefaults.standardUserDefaults boolForKey:@"fpsOverlay"];
    [toggle addTarget:self action:@selector(fpsChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
  } else if (path.section == 2) {
    cell.textLabel.text = @[ @"Poslední log", @"Spustit hello.exe", @"Spustit window.exe" ][path.row - 1];
    cell.accessoryType = path.row == 1 ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
  } else if (path.section == 3 && path.row < 2) {
    cell.textLabel.text = path.row == 0 ? @"Hrát s JITem, když je k dispozici" : @"Před hrou zapnout JIT";
    UISwitch* toggle = [UISwitch new];
    toggle.on = path.row == 0 ? WinPadJITWanted() : WinPadJITAskWanted();
    toggle.tag = path.row;
    [toggle addTarget:self action:@selector(jitChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
  } else if (path.section == 3) {
    cell.textLabel.text = @"Stav";
    cell.detailTextLabel.text = WinPadJITStatus();
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
  } else if (path.section == DirectXSection && path.row == 0) {
    cell.textLabel.text = WinPadDirectXDLLs().count ? @"Stáhnout znovu" : @"Stáhnout od Microsoftu";
    cell.detailTextLabel.text = self.directXState ?: DirectXSummary();
    cell.textLabel.textColor = WinPadDirectXDownloading() ? UIColor.secondaryLabelColor : UIColor.systemBlueColor;
  } else if (path.section == DirectXSection) {
    cell.textLabel.text = @"Používat místo verzí z Wine";
    UISwitch* toggle = [UISwitch new];
    toggle.on = WinPadDirectXPreferred();
    [toggle addTarget:self action:@selector(directXChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
  } else {
    NSDictionary* info = NSBundle.mainBundle.infoDictionary;
    cell.textLabel.text = path.row == 0 ? @"Verze" : @"Hry";
    cell.detailTextLabel.text = path.row == 0 ? [NSString stringWithFormat:@"%@ (%@)", info[@"CFBundleShortVersionString"] ?: @"?",
                                                                           info[@"CFBundleVersion"] ?: @"?"]
                                              : [NSString stringWithFormat:@"%lu", (unsigned long)WinPadFindGames().count];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
  }
  return cell;
}

- (void)wavesChanged:(UISwitch*)toggle {
  [NSUserDefaults.standardUserDefaults setBool:toggle.on forKey:@"backgroundWaves"];
}

- (void)coverAutoChanged:(UISwitch*)toggle {
  [NSUserDefaults.standardUserDefaults setBool:toggle.on forKey:@"coverAuto"];
  // Back on: the games tried before are tried again.
  if (toggle.on) [NSUserDefaults.standardUserDefaults removeObjectForKey:@"coverTried"];
}

- (void)askSteamGridDBKey {
  UIAlertController* alert = [UIAlertController
      alertControllerWithTitle:@"Klíč SteamGridDB"
                       message:@"Na steamgriddb.com se přihlas (třeba účtem Steam), v Preferences › API vytvoř klíč a vlož ho sem. "
                               @"Prázdné pole klíč smaže."
                preferredStyle:UIAlertControllerStyleAlert];
  [alert addTextFieldWithConfigurationHandler:^(UITextField* field) {
    field.text = [NSUserDefaults.standardUserDefaults stringForKey:@"steamGridDBKey"];
    field.placeholder = @"API klíč";
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
  }];
  [alert addAction:[UIAlertAction actionWithTitle:@"Zrušit" style:UIAlertActionStyleCancel handler:nil]];
  __weak UIAlertController* weak_alert = alert;
  __weak WinPadSettingsViewController* weak = self;
  [alert addAction:[UIAlertAction actionWithTitle:@"Uložit"
                                            style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction* action) {
                                            NSString* key = [weak_alert.textFields.firstObject.text
                                                stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
                                            if (key.length) {
                                              [NSUserDefaults.standardUserDefaults setObject:key forKey:@"steamGridDBKey"];
                                              // With the key, games without a cover are tried again.
                                              [NSUserDefaults.standardUserDefaults removeObjectForKey:@"coverTried"];
                                            } else {
                                              [NSUserDefaults.standardUserDefaults removeObjectForKey:@"steamGridDBKey"];
                                            }
                                            [weak.tableView reloadData];
                                          }]];
  [self presentViewController:alert animated:YES completion:nil];
}

- (void)touchChanged:(UISwitch*)toggle {
  [NSUserDefaults.standardUserDefaults setBool:toggle.on forKey:@"touchControls"];
}

- (void)fpsChanged:(UISwitch*)toggle {
  [NSUserDefaults.standardUserDefaults setBool:toggle.on forKey:@"fpsOverlay"];
}

- (void)directXChanged:(UISwitch*)toggle {
  WinPadDirectXSetPreferred(toggle.on);
}

- (void)downloadDirectX {
  if (WinPadDirectXDownloading()) return;
  __weak WinPadSettingsViewController* weak = self;
  void (^show)(NSString*) = ^(NSString* state) {
    weak.directXState = state;
    [weak.tableView reloadRowsAtIndexPaths:@[ [NSIndexPath indexPathForRow:0 inSection:DirectXSection + 1] ]
                          withRowAnimation:UITableViewRowAnimationNone];
  };
  show(@"Stahuji…");
  WinPadDirectXDownload(
      ^(double fraction) {
        show(fraction < 1 ? [NSString stringWithFormat:@"Stahuji %d %%", (int)(fraction * 100)] : @"Rozbaluji…");
      },
      ^(NSString* error) {
        show(error ? @"Nepovedlo se" : nil);
        if (!error || !weak) return;
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"DirectX se nestáhl"
                                                                       message:error
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [weak presentViewController:alert animated:YES completion:nil];
      });
}

- (void)jitChanged:(UISwitch*)toggle {
  [NSUserDefaults.standardUserDefaults setBool:toggle.on forKey:toggle.tag == 0 ? @"jit" : @"jitStikDebug"];
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)path {
  [tableView deselectRowAtIndexPath:path animated:YES];
  if (path.section == AppearanceSection) {
    if (path.row == 0) [self.navigationController pushViewController:[WinPadBackgroundViewController new] animated:YES];
    if (path.row == 3) [self askSteamGridDBKey];
    return;
  }
  path = [NSIndexPath indexPathForRow:path.row inSection:path.section - 1];
  if (path.section == 1 && path.row < PadCount) {
    WinPadKeyPickerViewController* picker = [WinPadKeyPickerViewController new];
    picker.input = (int)path.row;
    [self.navigationController pushViewController:picker animated:YES];
    return;
  }
  if (path.section == 1) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"padKeys"];
    [tableView reloadSections:[NSIndexSet indexSetWithIndex:2] withRowAnimation:UITableViewRowAnimationNone];
    return;
  }
  if (path.section == DirectXSection && path.row == 0) {
    [self downloadDirectX];
    return;
  }
  if (path.section != 2 || path.row == 0) return;
  if (path.row == 1) {
    [self.navigationController pushViewController:[WinPadLogViewController new] animated:YES];
    return;
  }
  NSString* program = path.row == 2 ? @"hello" : @"window";
  void (^run)(NSString*) = self.run;
  [self dismissViewControllerAnimated:YES completion:^{
    if (run) run(program);
  }];
}
@end

// How to turn the JIT on, step by step, with what is already done ticked. Opened from the
// library's JIT badge and when a game needs the JIT.
@interface WinPadJITGuideViewController : UITableViewController <UIDocumentPickerDelegate>
@property(nonatomic, copy) void (^closed)(void);
@property(nonatomic, strong) id observer;
@property(nonatomic) BOOL busy;              // turning the JIT on
@property(nonatomic, copy) NSString* lastError;  // why it did not, or why a pairing file was refused
@end

@implementation WinPadJITGuideViewController
- (instancetype)init {
  return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Zapnout JIT";
  self.tableView.backgroundView = [WinPadBackdrop new];
  self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                         target:self
                                                                                         action:@selector(done)];
  __weak UITableView* table = self.tableView;
  self.observer = [NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                                  object:nil
                                                                   queue:NSOperationQueue.mainQueue
                                                              usingBlock:^(NSNotification* note) {
                                                                [table reloadData];
                                                              }];
}

- (void)dealloc {
  if (self.observer) [NSNotificationCenter.defaultCenter removeObserver:self.observer];
}

- (void)done {
  void (^closed)(void) = self.closed;
  [self dismissViewControllerAnimated:YES completion:closed];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView {
  return 2;
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
  return section == 0 ? 1 : 4;
}

- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section {
  return section == 0 ? @"Stav" : @"Jednou na iPadu";
}

// The built-in JIT, unless this installation cannot have it: then StikDebug.
- (BOOL)builtin {
  return WinPadJITBuiltInUnavailableReason() == nil;
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
  if (section == 0)
    return @"S JITem běží každá hra hned, bez překladu předem. Bez JITu běží jen hry přeložené "
           @"převodníkem WinPad Translator.";
  if (self.builtin && WinPadVPNBuiltIn())
    return @"Pak už jen vybereš hru a ťukneš na Spustit: WinPad Wine si zapne vlastní VPN i JIT sám, "
           @"bez další aplikace. JIT platí do zavření aplikace.";
  if (self.builtin)
    return @"Pak už jen vybereš hru a ťukneš na Spustit: WinPad Wine si JIT zapne sám, bez další aplikace. "
           @"Při spuštění musí být zapnutá LocalDevVPN. JIT platí do zavření aplikace. "
           @"Místo vestavěného JITu jde použít i aplikace StikDebug.";
  return [NSString stringWithFormat:@"%@ Pak už jen vybereš hru a ťukneš na Spustit: WinPad Wine sám otevře "
                                    @"StikDebug, ten JIT zapne a hra se spustí.",
                                    WinPadJITBuiltInUnavailableReason()];
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)path {
  UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
  cell.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
  cell.detailTextLabel.numberOfLines = 0;
  cell.detailTextLabel.textColor = Hex(0xB8C8E8);
  if (path.section == 0) {
    const BOOL on = WinPadJITUsable();
    cell.textLabel.text = self.busy ? @"Zapínám JIT…" : on ? @"JIT je zapnutý" : @"JIT je vypnutý";
    cell.detailTextLabel.text = self.lastError ?: WinPadJITStatus();
    cell.imageView.image = [UIImage systemImageNamed:on ? @"bolt.fill" : @"bolt.slash"];
    cell.imageView.tintColor = on ? Hex(0x9BEDB5) : Hex(0xF2C46D);
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
  }
  const BOOL builtin = self.builtin, on = WinPadJITUsable();
  const BOOL pairing = builtin && WinPadJITHasPairing(), stikdebug = WinPadJITStikDebugInstalled();
  const BOOL can = WinPadJITCanTurnOn();
  NSString* title = nil;
  NSString* detail = nil;
  BOOL ticked = NO, action = NO;
  switch (path.row) {
    case 0:
      title = @"1. Režim pro vývojáře";
      detail = @"Nastavení → Soukromí a zabezpečení → Režim pro vývojáře → zapnout a restartovat iPad. "
               @"Bývá zapnutý, pokud sem instaluješ aplikace z Xcode nebo SideStore.";
      ticked = can || on;
      break;
    case 1:
      if (builtin && WinPadVPNBuiltIn()) {
        title = @"2. VPN";
        detail = @"Vestavěná, zapne se sama při spuštění hry. Napoprvé iPad požádá o povolení konfigurace VPN.";
        ticked = YES;
        break;
      }
      title = @"2. LocalDevVPN";
      detail = @"Zdarma z App Storu (ťukni). Zapni ji před hraním: přes ni se WinPad Wine připojí sám k sobě "
               @"jako debugger. Pokud máš SideStore, nejspíš ji už máš.";
      action = YES;
      break;
    case 2:
      if (builtin) {
        title = @"3. Párovací soubor";
        detail = pairing ? @"Nahraný."
                         : @"Ťukni a vyber ho, nebo ho na Macu přetáhni do Finder → iPad → Soubory → WinPad Wine. "
                           @"Vyrobí ho jitterbugpair nebo idevice_pair (návod StikDebugu, stačí jednou). "
                           @"Pokud používáš SideStore, je to tentýž soubor.";
        ticked = pairing;
        action = YES;
      } else {
        title = @"3. StikDebug";
        detail = stikdebug ? @"Nainstalovaný." : @"Nainstaluj ho přes SideStore nebo AltStore (ťukni pro stikdebug.org).";
        ticked = stikdebug;
        action = !stikdebug;
      }
      break;
    default:
      title = @"4. Zapnout JIT teď";
      detail = on ? @"Hotovo, JIT je zapnutý."
             : self.busy ? @"Zapínám…"
             : can ? @"Vyzkouší to hned. Jinak se JIT zapne sám při spuštění hry."
                   : @"Až budou hotové kroky nahoře.";
      ticked = on;
      action = can && !on && !self.busy;
      if (action) cell.textLabel.textColor = UIColor.systemBlueColor;
      break;
  }
  cell.textLabel.text = title;
  cell.detailTextLabel.text = detail;
  cell.imageView.image = [UIImage systemImageNamed:ticked ? @"checkmark.circle.fill" : @"circle"];
  cell.imageView.tintColor = ticked ? Hex(0x9BEDB5) : Hex(0xB8C8E8);
  cell.accessoryType = action ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
  cell.selectionStyle = action ? UITableViewCellSelectionStyleDefault : UITableViewCellSelectionStyleNone;
  return cell;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)path {
  [tableView deselectRowAtIndexPath:path animated:YES];
  if (path.section != 1) return;
  UIApplication* app = UIApplication.sharedApplication;
  if (path.row == 1 && !(self.builtin && WinPadVPNBuiltIn())) {
    [app openURL:[NSURL URLWithString:@"itms-apps://search.itunes.apple.com/WebObjects/MZSearch.woa/wa/"
                                      @"search?media=software&term=LocalDevVPN"]
          options:@{}
        completionHandler:nil];
  } else if (path.row == 2 && self.builtin) {
    UIDocumentPickerViewController* picker =
        [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeItem ] asCopy:YES];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
  } else if (path.row == 2) {
    [app openURL:[NSURL URLWithString:@"https://stikdebug.org"] options:@{} completionHandler:nil];
  } else if (path.row == 3 && WinPadJITCanTurnOn() && !WinPadJITUsable() && !self.busy) {
    self.busy = YES;
    self.lastError = nil;
    [tableView reloadData];
    __weak WinPadJITGuideViewController* weak = self;
    WinPadJITTurnOn(^(BOOL ok, NSString* message) {
      WinPadJITGuideViewController* me = weak;
      me.busy = NO;
      me.lastError = ok ? nil : message;
      [me.tableView reloadData];
    });
  }
}

- (void)documentPicker:(UIDocumentPickerViewController*)picker didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
  NSString* error = nil;
  if (urls.firstObject && !WinPadJITImportPairing(urls.firstObject, &error)) self.lastError = error;
  else self.lastError = nil;
  [self.tableView reloadData];
}
@end

@interface LibraryViewController ()
@property(nonatomic, strong) NSArray<WinPadGame*>* games;
@property(nonatomic) NSInteger focus;
@property(nonatomic, strong) WinPadBackdrop* backdrop;
@property(nonatomic, strong) UIButton* settings;
@property(nonatomic, strong) UILabel* clock;
// Is the JIT on: a tap opens the guide to turning it on (WinPadJITGuideViewController).
@property(nonatomic, strong) UIButton* jitBadge;
@property(nonatomic, strong) NSTimer* clockTimer;
@property(nonatomic, strong) UILabel* heroTitle;
@property(nonatomic, strong) UIStackView* tags;
@property(nonatomic, strong) UIButton* play;
@property(nonatomic, strong) UIButton* exportMaps;  // "Exportovat pro převodník"
@property(nonatomic, strong) UIButton* coverButton;  // "Obal": WinPadCoverPickerViewController
@property(nonatomic) BOOL exporting;
@property(nonatomic) BOOL exportCompact;  // the button's short title, as on an iPhone
@property(nonatomic, strong) UIView* info;
@property(nonatomic, strong) UILabel* infoText;
@property(nonatomic, strong) UIScrollView* row;
@property(nonatomic, strong) NSMutableArray<UIButton*>* cards;
@property(nonatomic, strong) UILabel* addGame;
@property(nonatomic, strong) UILabel* empty;
@property(nonatomic, strong) UILabel* hints;
@property(nonatomic, strong) NSMutableArray* observers;
@property(nonatomic) unsigned pad;  // the controller buttons held at the last change (Nav*)
@property(nonatomic) BOOL started;
@property(nonatomic, readonly) BOOL compact;  // an iPhone's height: smaller, no hints or info card
// Packages to install (openPackages:), whether one is being installed, and what the
// installs said (for libraryTest's report).
@property(nonatomic, strong) NSMutableArray<NSURL*>* packages;
@property(nonatomic) BOOL installing;
// StikDebug was asked for the JIT before this start (WinPadJIT.m): asked once per launch.
@property(nonatomic) BOOL jitAsked;
@property(nonatomic, strong) NSMutableString* installReport;
- (void)reload;
- (void)showFocus;
- (void)tick;
- (void)moveFocusBy:(NSInteger)by;
- (void)startFocused;
- (void)exportFocused;
- (void)pickCoverFor:(WinPadGame*)game;
- (void)coverChanged:(WinPadGame*)game;
- (void)coverFocused;
- (void)titleExport:(BOOL)compact;
- (void)startProgram:(NSString*)program game:(WinPadGame*)game;
- (void)waitForJITThen:(void (^)(void))start;
- (void)refreshJIT;
- (void)openJITGuide;
- (void)offerDirectX;
- (void)downloadDirectXFor:(NSString*)dll;
- (void)openSettings;
- (void)attach:(GCController*)controller;
- (void)readPad:(GCExtendedGamepad*)pad;
- (void)installNext;
- (void)focusFolder:(NSString*)folder;
@end

enum { NavLeft = 1, NavRight = 2, NavA = 4, NavB = 8, NavY = 16, NavX = 32 };
// A card's cover; the card's own tag is the game's index.
enum { CoverTag = 1001 };

// The game's tags: on the backdrop they are light and see-through.
static WinPadTag* LightTag(NSString* text, uint32_t fg, UIColor* bg) {
  WinPadTag* tag = Tag(text, fg, 0);
  tag.backgroundColor = bg;
  tag.layer.cornerRadius = 4;
  return tag;
}

@implementation LibraryViewController
// The look of a console's home screen: a row of square tiles at the top, the focused one
// larger with a white frame, its title, tags and Spustit below, on the chosen backdrop. On
// an iPhone (on its side) everything is smaller, without the hints and the info card.
- (BOOL)compact {
  return self.view.bounds.size.height < 500;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = Hex(0x04122E);
  self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;

  self.backdrop = [WinPadBackdrop new];
  [self.view addSubview:self.backdrop];

  self.settings = [UIButton buttonWithType:UIButtonTypeSystem];
  [self.settings setImage:[UIImage systemImageNamed:@"slider.horizontal.3"] forState:UIControlStateNormal];
  self.settings.tintColor = UIColor.whiteColor;
  self.settings.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
  self.settings.accessibilityLabel = @"Nastavení";
  [self.settings addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:self.settings];

  self.jitBadge = [UIButton buttonWithConfiguration:[UIButtonConfiguration filledButtonConfiguration] primaryAction:nil];
  [self.jitBadge addTarget:self action:@selector(openJITGuide) forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:self.jitBadge];
  [self refreshJIT];

  self.clock = [UILabel new];
  self.clock.textColor = Hex(0xDCE8FF);
  self.clock.textAlignment = NSTextAlignmentRight;
  [self.view addSubview:self.clock];
  [self tick];
  __weak LibraryViewController* clock_owner = self;
  self.clockTimer = [NSTimer scheduledTimerWithTimeInterval:10
                                                    repeats:YES
                                                      block:^(NSTimer* timer) {
                                                        [clock_owner tick];
                                                      }];

  self.row = [UIScrollView new];
  self.row.showsHorizontalScrollIndicator = NO;
  self.row.clipsToBounds = NO;
  [self.view addSubview:self.row];

  self.addGame = [UILabel new];
  self.addGame.text = @"Přidat hru\n\nOtevři soubor .winpad z převodníku (AirDrop nebo Soubory), nebo složku hry "
                      @"zkopíruj do Soubory › WinPad Wine";
  self.addGame.numberOfLines = 0;
  self.addGame.textAlignment = NSTextAlignmentCenter;
  self.addGame.textColor = Hex(0xDCE8FF);
  self.addGame.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
  self.addGame.layer.cornerRadius = 6;
  self.addGame.layer.masksToBounds = YES;
  [self.row addSubview:self.addGame];

  self.heroTitle = [UILabel new];
  self.heroTitle.textColor = UIColor.whiteColor;
  self.heroTitle.adjustsFontSizeToFitWidth = YES;
  self.heroTitle.minimumScaleFactor = 0.5;
  [self.view addSubview:self.heroTitle];

  self.tags = [UIStackView new];
  self.tags.axis = UILayoutConstraintAxisHorizontal;
  self.tags.spacing = 10;
  self.tags.alignment = UIStackViewAlignmentLeading;
  [self.view addSubview:self.tags];

  UIButtonConfiguration* config = [UIButtonConfiguration filledButtonConfiguration];
  config.baseBackgroundColor = UIColor.whiteColor;
  config.baseForegroundColor = Hex(0x0B2A63);
  config.cornerStyle = UIButtonConfigurationCornerStyleFixed;
  config.background.cornerRadius = 4;
  config.image = [UIImage systemImageNamed:@"play.fill"];
  config.imagePadding = 10;
  config.title = @"Spustit";
  config.contentInsets = NSDirectionalEdgeInsetsMake(14, 32, 14, 40);
  self.play = [UIButton buttonWithConfiguration:config primaryAction:nil];
  [self.play addTarget:self action:@selector(startFocused) forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:self.play];

  // Shares the focused game's code maps for WinPad Translator's next round.
  UIButtonConfiguration* share = [UIButtonConfiguration filledButtonConfiguration];
  share.baseBackgroundColor = [UIColor colorWithWhite:1 alpha:0.16];
  share.baseForegroundColor = UIColor.whiteColor;
  share.cornerStyle = UIButtonConfigurationCornerStyleFixed;
  share.background.cornerRadius = 4;
  share.image = [UIImage systemImageNamed:@"square.and.arrow.up"];
  share.imagePadding = 10;
  share.title = @"Exportovat pro převodník";
  share.contentInsets = NSDirectionalEdgeInsetsMake(14, 24, 14, 28);
  self.exportMaps = [UIButton buttonWithConfiguration:share primaryAction:nil];
  self.exportMaps.accessibilityLabel = @"Exportovat code mapy pro převodník";
  [self.exportMaps addTarget:self action:@selector(exportFocused) forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:self.exportMaps];

  // Picks the focused game's cover: one found on the internet by its title, or from Photos.
  UIButtonConfiguration* obal = [share copy];
  obal.image = [UIImage systemImageNamed:@"photo"];
  obal.title = @"Obal";
  obal.contentInsets = NSDirectionalEdgeInsetsMake(14, 20, 14, 24);
  self.coverButton = [UIButton buttonWithConfiguration:obal primaryAction:nil];
  self.coverButton.accessibilityLabel = @"Najít obal hry";
  [self.coverButton addTarget:self action:@selector(coverFocused) forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:self.coverButton];

  self.info = [UIView new];
  self.info.backgroundColor = [Hex(0x04122E) colorWithAlphaComponent:0.55];
  self.info.layer.cornerRadius = 6;
  self.infoText = [UILabel new];
  self.infoText.numberOfLines = 0;
  [self.info addSubview:self.infoText];
  [self.view addSubview:self.info];

  self.empty = [UILabel new];
  self.empty.text = @"Zatím tu není žádná hra.\n\nPřelož hru převodníkem WinPad Translator a soubor .winpad pošli "
                    @"na iPad (AirDrop) nebo ho otevři v Souborech. Nebo složku hry zkopíruj přes Finder → iPad → "
                    @"Soubory → WinPad Wine. Knihovna ji pak sama ukáže.";
  self.empty.numberOfLines = 0;
  self.empty.textAlignment = NSTextAlignmentCenter;
  self.empty.font = [UIFont systemFontOfSize:20];
  self.empty.textColor = Hex(0xDCE8FF);
  [self.view addSubview:self.empty];

  self.hints = [UILabel new];
  self.hints.text = @"Ⓐ Spustit     ◀ ▶ Vybrat     Ⓧ Export map     Ⓨ Nastavení     Ťuknutím vybereš, druhým spustíš, podržením změníš obal";
  self.hints.font = [UIFont systemFontOfSize:16];
  self.hints.textColor = Hex(0xDCE8FF);
  self.hints.textAlignment = NSTextAlignmentRight;
  [self.view addSubview:self.hints];

  self.cards = [NSMutableArray new];
  self.observers = [NSMutableArray new];
  __weak LibraryViewController* weak = self;
  // Games copied in from Finder while the app was in the background.
  [self.observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillEnterForegroundNotification
                                                                            object:nil
                                                                             queue:NSOperationQueue.mainQueue
                                                                        usingBlock:^(NSNotification* note) {
                                                                          [weak reload];
                                                                          [weak openPackages:@[]];
                                                                        }]];
  [self.observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidConnectNotification
                                                                            object:nil
                                                                             queue:NSOperationQueue.mainQueue
                                                                        usingBlock:^(NSNotification* note) {
                                                                          [weak attach:note.object];
                                                                        }]];
  // Back from StikDebug: the JIT pool right away, while its script waits for it.
  [self.observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:UIApplicationDidBecomeActiveNotification
                                                                            object:nil
                                                                             queue:NSOperationQueue.mainQueue
                                                                        usingBlock:^(NSNotification* note) {
                                                                          if (WinPadJITWanted() && WinPadJITAttached()) {
                                                                            NSString* why = nil;
                                                                            WinPadJITPrepare(&why);
                                                                            NSLog(@"WinPad Wine: JIT: %@", why);
                                                                          }
                                                                          [weak refreshJIT];
                                                                          [weak showFocus];
                                                                        }]];
  for (GCController* pad in GCController.controllers) [self attach:pad];
  // CI: what the cover sources find for a title, in Documents/covers.txt (build-xcode.sh).
  NSString* cover_test = [NSUserDefaults.standardUserDefaults stringForKey:@"coverTest"];
  if (cover_test.length) {
    WinPadGame* fake = [WinPadGame new];
    fake.title = [cover_test stringByAppendingString:@"_v1.2 (GOG)"];
    NSMutableString* report = [NSMutableString stringWithFormat:@"query: %@\n", WinPadCoverQuery(fake)];
    NSString* path = [Documents() stringByAppendingPathComponent:@"covers.txt"];
    __weak LibraryViewController* weak_test = self;
    // Saving into a game folder copied read-only (build-xcode.sh makes "Cover Game" so).
    WinPadGame* ro = [WinPadGame new];
    ro.folder = @"Cover Game";
    ro.title = @"Cover Game";
    UIImage* red = [[[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(20, 30)] imageWithActions:^(UIGraphicsImageRendererContext* ctx) {
      [UIColor.redColor setFill];
      UIRectFill(CGRectMake(0, 0, 20, 30));
    }];
    NSError* save_error = nil;
    [report appendFormat:@"save read-only: %@\n", WinPadSaveCover(ro, red, &save_error) ? @"ok" : save_error.localizedDescription];
    WinPadFindCovers(cover_test, 0, ^(NSArray<WinPadCover*>* covers, NSError* error) {
      if (error) [report appendFormat:@"error: %@\n", error.localizedDescription];
      for (WinPadCover* c in covers) [report appendFormat:@"cover: %@ | %@ | %@\n", c.source, c.name, c.urls.firstObject];
      void (^finish)(void) = ^{
        // Is "Obal" on the screen, inside the safe area and not under another button (an
        // iPhone on its side is short: build-xcode.sh runs this on one too).
        LibraryViewController* me = weak_test;
        [me.view layoutIfNeeded];
        const CGRect safe = UIEdgeInsetsInsetRect(me.view.bounds, me.view.safeAreaInsets);
        const CGRect obal = me.coverButton.frame;
        BOOL covered = NO;
        for (UIView* other in @[ me.play, me.exportMaps, me.tags, me.heroTitle ])
          if (!other.hidden && CGRectIntersectsRect(CGRectInset(other.frame, 1, 1), obal)) covered = YES;
        [report appendFormat:@"cover button: %@ %@ in %@\n",
                             !me || me.coverButton.hidden || !me.games.count ? @"hidden"
                             : !CGRectContainsRect(safe, obal)               ? @"outside"
                             : covered                                       ? @"covered"
                                                                             : @"visible",
                             NSStringFromCGRect(obal), NSStringFromCGRect(safe)];
        [report appendString:@"== finished\n"];
        [report writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
      };
      if (!covers.count) {
        finish();
        return;
      }
      WinPadLoadCover(covers.firstObject, NO, ^(UIImage* image, NSData* data) {
        [report appendFormat:@"loaded: %@ %.0fx%.0f\n", covers.firstObject.source, image.size.width * image.scale,
                             image.size.height * image.scale];
        finish();
      });
    });
  }
  if (!self.packages) self.packages = [NSMutableArray new];
  self.installReport = [NSMutableString new];
  // CI: the packages waiting in Documents go in before the report, one after the other.
  if ([NSUserDefaults.standardUserDefaults boolForKey:@"libraryTest"]) {
    for (NSURL* url in WinPadWaitingPackages()) {
      NSString* error = nil;
      NSString* folder = WinPadInstallPackage(url.path, nil, &error);
      if (folder) [NSFileManager.defaultManager removeItemAtURL:url error:nil];
      [self.installReport appendFormat:@"package: %@ -> %@\n", url.lastPathComponent, folder ?: error];
    }
  }
  [self reload];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  [self becomeFirstResponder];
  [self openPackages:@[]];
#if !TARGET_OS_SIMULATOR
  // The first launch on a device without the JIT: how to turn it on, once.
  if (![NSUserDefaults.standardUserDefaults boolForKey:@"libraryTest"] &&
      ![NSUserDefaults.standardUserDefaults boolForKey:@"jitGuideShown"] && !WinPadJITUsable() &&
      !self.installing && !self.presentedViewController) {
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"jitGuideShown"];
    [self openJITGuide];
  }
#endif
  [self offerDirectX];
  static BOOL tested;
  if (tested || ![NSUserDefaults.standardUserDefaults boolForKey:@"libraryTest"]) return;
  tested = YES;
  NSMutableString* report = [NSMutableString stringWithFormat:@"%@library: %lu games\n", self.installReport,
                                                             (unsigned long)self.games.count];
  for (WinPadGame* game in self.games)
    [report appendFormat:@"library: %@ | %@ | %@ | image %@%@%@\n", game.title, game.exe, game.arch ?: @"?",
                         game.image.lastPathComponent ?: @"none", game.imageInFolder ? @" (game folder)" : @"",
                         game.profile ? [@" | profile " stringByAppendingString:game.profile] : @""];
  // What "Exportovat pro převodník" shares, without the share sheet: Documents/export-FOLDER.zip.
  for (WinPadGame* game in self.games) {
    if (!game.maps) continue;
    NSError* error = nil;
    NSURL* zip = WinPadExportMaps(game, &error);
    NSString* copy = [Documents() stringByAppendingPathComponent:[NSString stringWithFormat:@"export-%@.zip", game.folder]];
    [NSFileManager.defaultManager removeItemAtPath:copy error:nil];
    if (zip && [NSFileManager.defaultManager moveItemAtPath:zip.path toPath:copy error:&error]) {
      [report appendFormat:@"export: %@ | %ld maps, %ld new | %@\n", game.folder, (long)game.maps, (long)game.newMaps,
                           zip.lastPathComponent];
      WinPadMarkMapsExported(game, NSDate.date);
    } else {
      [report appendFormat:@"export: %@ failed: %@\n", game.folder, error.localizedDescription];
    }
  }
  if (self.games.count) {
    self.games = WinPadFindGames();
    for (WinPadGame* game in self.games)
      if (game.maps) [report appendFormat:@"export: %@ after it, %ld new\n", game.folder, (long)game.newMaps];
  }
  [report writeToFile:[Documents() stringByAppendingPathComponent:@"library.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    [self moveFocusBy:1];
    [self startFocused];
  });
}

- (BOOL)canBecomeFirstResponder {
  return YES;
}

- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  if (self.started) [self.clockTimer invalidate];
}

- (void)tick {
  NSDateFormatter* f = [NSDateFormatter new];
  f.timeStyle = NSDateFormatterShortStyle;
  f.dateStyle = NSDateFormatterNoStyle;
  self.clock.text = [f stringFromDate:NSDate.date];
}

- (void)reload {
  if (self.started) return;
  NSString* focused = self.games.count ? self.games[self.focus].folder : [NSUserDefaults.standardUserDefaults stringForKey:@"lastGame"];
  self.games = WinPadFindGames();
  self.focus = 0;
  for (NSUInteger i = 0; i < self.games.count; i++)
    if ([self.games[i].folder isEqualToString:focused]) self.focus = (NSInteger)i;

  for (UIButton* card in self.cards) [card removeFromSuperview];
  [self.cards removeAllObjects];
  for (NSUInteger i = 0; i < self.games.count; i++) {
    UIButton* card = [UIButton buttonWithType:UIButtonTypeCustom];
    card.tag = (NSInteger)i;
    card.accessibilityLabel = self.games[i].title;
    UILabel* placeholder;
    UIImageView* cover = CoverView(&placeholder, 15);
    cover.layer.cornerRadius = 6;
    cover.tag = CoverTag;
    cover.userInteractionEnabled = NO;
    ShowCover(cover, placeholder, self.games[i]);
    [card addSubview:cover];
    [card addTarget:self action:@selector(tapCard:) forControlEvents:UIControlEventTouchUpInside];
    // A long press: the game's cover (a button's own menu; it opens on a long press).
    __weak LibraryViewController* weak_menu = self;
    WinPadGame* menu_game = self.games[i];
    card.menu = [UIMenu menuWithTitle:menu_game.title
                             children:@[ [UIAction actionWithTitle:@"Najít obal"
                                                             image:[UIImage systemImageNamed:@"photo"]
                                                        identifier:nil
                                                           handler:^(UIAction* action) {
                                                             [weak_menu pickCoverFor:menu_game];
                                                           }] ]];
    card.showsMenuAsPrimaryAction = NO;
    [self.row addSubview:card];
    [self.cards addObject:card];
  }
  const BOOL none = self.games.count == 0;
  for (UIView* v in @[ self.heroTitle, self.tags, self.play, self.info, self.coverButton ]) v.hidden = none;
  self.exportMaps.hidden = none || !self.games[self.focus].maps;
  self.empty.hidden = !none;
  [self showFocus];
  [self.view setNeedsLayout];
  // Covers for the games without one, saved one by one as they come (not in CI's library test).
  if (![NSUserDefaults.standardUserDefaults boolForKey:@"libraryTest"] &&
      ![NSUserDefaults.standardUserDefaults stringForKey:@"coverTest"]) {
    __weak LibraryViewController* weak = self;
    WinPadAutoCovers(self.games, ^(WinPadGame* game) {
      [weak coverChanged:game];
    });
  }
}

// GAME's cover changed (WinPadAutoCovers, the picker): its tile and the backdrop show it.
- (void)coverChanged:(WinPadGame*)game {
  const NSUInteger i = [self.games indexOfObjectIdenticalTo:game];
  if (i == NSNotFound || i >= self.cards.count) return;
  UIImageView* cover = (UIImageView*)[self.cards[i] viewWithTag:CoverTag];
  UILabel* placeholder = (UILabel*)cover.subviews.firstObject;
  if ([placeholder isKindOfClass:UILabel.class]) ShowCover(cover, placeholder, game);
  if ((NSInteger)i == self.focus) self.backdrop.cover = game.cover;
}

- (void)coverFocused {
  if (self.games.count) [self pickCoverFor:self.games[self.focus]];
}

- (void)pickCoverFor:(WinPadGame*)game {
  if (self.presentedViewController || self.started) return;
  WinPadCoverPickerViewController* picker = [[WinPadCoverPickerViewController alloc] initWithGame:game];
  __weak LibraryViewController* weak = self;
  picker.saved = ^{
    [weak coverChanged:game];
  };
  UINavigationController* nav = [[UINavigationController alloc] initWithRootViewController:picker];
  nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
  nav.modalPresentationStyle = UIModalPresentationFormSheet;
  [self presentViewController:nav animated:YES completion:nil];
}


- (void)showFocus {
  for (UIButton* card in self.cards) {
    UIView* cover = [card viewWithTag:CoverTag];
    const BOOL on = card.tag == self.focus;
    cover.layer.borderWidth = on ? 4 : 0;
    cover.layer.borderColor = UIColor.whiteColor.CGColor;
    cover.alpha = on ? 1 : 0.9;
  }
  [UIView animateWithDuration:0.18
                   animations:^{
                     [self.view setNeedsLayout];
                     [self.view layoutIfNeeded];
                   }];
  if (!self.games.count) {
    self.backdrop.cover = nil;
    self.exportMaps.hidden = YES;
    return;
  }
  WinPadGame* game = self.games[self.focus];
  self.exportMaps.hidden = !game.maps;
  [self.view setNeedsLayout];
  self.backdrop.cover = game.cover;
  self.heroTitle.text = game.title;
  for (UIView* tag in self.tags.arrangedSubviews) [tag removeFromSuperview];
  UIColor* plain = [UIColor colorWithWhite:1 alpha:0.12];
  UIColor* good = [Hex(0x7DDC9A) colorWithAlphaComponent:0.18];
  UIColor* warn = [Hex(0xF2C46D) colorWithAlphaComponent:0.18];
  [self.tags addArrangedSubview:LightTag(game.arch ? [@"Windows · " stringByAppendingString:game.arch] : @"Windows", 0xDCE8FF, plain)];
  // A simulator keeps running a game with an image from its image (main.m).
  const BOOL jit = WinPadJITUsable() && (!TARGET_OS_SIMULATOR || !game.image);
  [self.tags addArrangedSubview:jit                ? LightTag(@"Poběží s JITem", 0x9BEDB5, good)
                                 : game.imageInFolder ? LightTag(@"Přeloženo (obraz ve složce hry)", 0x9BEDB5, good)
                                 : game.image      ? LightTag(@"Přeloženo", 0x9BEDB5, good)
                                                   : LightTag(@"Potřebuje JIT", 0xF2C46D, warn)];
  if (game.folderImageNote) [self.tags addArrangedSubview:LightTag(@"Obraz ve složce je pro jiné sestavení", 0xF2C46D, warn)];
  if (game.newMaps) [self.tags addArrangedSubview:LightTag(NewMapsText(game.newMaps), 0xF2C46D, warn)];
  NSString* state = jit ? @"JIT je zapnutý: hra se přeloží za běhu, žádný překlad předem není potřeba."
                    : game.image ? @"Hra běží z přeloženého obrazu. Rychlejší a bez překladu předem je to s JITem "
                                   @"(ťukni na JIT nahoře)."
                                 : @"Hra nemá přeložený obraz: zapni JIT (ťukni na JIT nahoře), nebo ji přelož "
                                   @"převodníkem WinPad Translator.";
  NSMutableAttributedString* text = [NSMutableAttributedString new];
  [text appendAttributedString:[[NSAttributedString alloc]
                                   initWithString:@"STAV PŘEKLADU\n"
                                       attributes:@{NSFontAttributeName : [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold],
                                                    NSForegroundColorAttributeName : Hex(0x9DB9E8)}]];
  [text appendAttributedString:[[NSAttributedString alloc]
                                   initWithString:[NSString stringWithFormat:@"%@\nSložka %@ · %@%@", state, game.folder,
                                                                             game.exe.lastPathComponent,
                                                                             game.maps ? [NSString stringWithFormat:@" · code map %ld, nových %ld",
                                                                                                                    (long)game.maps, (long)game.newMaps]
                                                                                       : @""]
                                       attributes:@{NSFontAttributeName : [UIFont systemFontOfSize:15],
                                                    NSForegroundColorAttributeName : Hex(0xDCE8FF)}]];
  self.infoText.attributedText = text;
  if (self.focus < (NSInteger)self.cards.count) {
    const CGRect card = self.cards[self.focus].frame;
    [self.row scrollRectToVisible:CGRectInset(card, -24, 0) animated:YES];
  }
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  const CGRect b = self.view.bounds;
  const UIEdgeInsets safe = self.view.safeAreaInsets;
  const BOOL compact = self.compact;
  self.backdrop.frame = b;
  const CGFloat m = MAX(safe.left, safe.right) + (compact ? 16 : 64), top = safe.top + (compact ? 12 : 36);
  const CGFloat w = b.size.width - 2 * m, button = compact ? 44 : 48;
  self.settings.frame = CGRectMake(m, top, button, button);
  self.settings.layer.cornerRadius = button / 2;
  [self.jitBadge sizeToFit];
  self.jitBadge.frame = CGRectMake(m + button + 12, top, MAX(self.jitBadge.bounds.size.width, 120), button);
  self.clock.font = [UIFont systemFontOfSize:compact ? 18 : 26 weight:UIFontWeightLight];
  self.clock.frame = CGRectMake(m + w - 200, top, 200, button);

  // The row: the focused tile large, the others smaller, all on one bottom line.
  const CGFloat big = compact ? 150 : 260, small = compact ? 100 : 170, gap = compact ? 12 : 18;
  const CGFloat row_y = top + button + (compact ? 14 : 36);
  self.row.frame = CGRectMake(0, row_y, b.size.width, big);
  self.row.contentInset = UIEdgeInsetsMake(0, m, 0, m);
  CGFloat x = 0;
  for (UIButton* card in self.cards) {
    const CGFloat side = card.tag == self.focus ? big : small;
    card.frame = CGRectMake(x, big - side, side, side);
    [card viewWithTag:CoverTag].frame = card.bounds;
    x += side + gap;
  }
  self.addGame.font = [UIFont systemFontOfSize:compact ? 11 : 14];
  self.addGame.frame = CGRectMake(x, big - small, small, small);
  self.row.contentSize = CGSizeMake(x + small, big);

  // The focused game.
  CGFloat y = row_y + big + (compact ? 12 : 36);
  self.heroTitle.font = [UIFont systemFontOfSize:compact ? 24 : 44 weight:UIFontWeightLight];
  const CGFloat title_h = compact ? 30 : 54;
  const CGSize play = [self.play sizeThatFits:CGSizeMake(w, 60)];
  if (compact) {
    // Title and tags on the left, Spustit on the right, side by side.
    const CGFloat pw = MAX(play.width, 140);
    self.heroTitle.frame = CGRectMake(m, y, w - pw - 16, title_h);
    // Narrower when Obal sits beside the export, left of Spustit's column.
    self.tags.frame = CGRectMake(m, y + title_h + 8, w - pw - 16 - (self.exportMaps.hidden ? 0 : 118), 26);
    self.play.frame = CGRectMake(m + w - pw, y + 6, pw, 48);
    [self titleExport:YES];
    // Under it Obal, and the export beside it when the game has maps: one row, which an
    // iPhone on its side has room for.
    const CGFloat row2 = y + 6 + 48 + 8;
    if (self.exportMaps.hidden) {
      self.coverButton.frame = CGRectMake(m + w - pw, row2, pw, 44);
    } else {
      self.coverButton.frame = CGRectMake(m + w - pw - 8 - 110, row2, 110, 44);
      self.exportMaps.frame = CGRectMake(m + w - pw, row2, pw, 44);
    }
    self.info.hidden = self.hints.hidden = YES;
  } else {
    self.heroTitle.frame = CGRectMake(m, y, MIN(w, 900), title_h);
    y += title_h + 14;
    self.tags.frame = CGRectMake(m, y, w, 32);
    y += 32 + 26;
    self.play.frame = CGRectMake(m, y, MAX(play.width, 180), 56);
    [self titleExport:NO];
    const CGSize share = [self.exportMaps sizeThatFits:CGSizeMake(w, 60)];
    self.exportMaps.frame = CGRectMake(CGRectGetMaxX(self.play.frame) + 16, y, share.width, 56);
    const CGSize obal = [self.coverButton sizeThatFits:CGSizeMake(w, 60)];
    self.coverButton.frame =
        CGRectMake(CGRectGetMaxX(self.exportMaps.hidden ? self.play.frame : self.exportMaps.frame) + 16, y, obal.width, 56);
    y += 56 + 36;
    self.info.hidden = !self.games.count;
    self.info.frame = CGRectMake(m, y, MIN(w, 440), 140);
    self.infoText.frame = CGRectInset(self.info.bounds, 20, 14);
    self.hints.hidden = NO;
    self.hints.frame = CGRectMake(m, b.size.height - safe.bottom - 56, w, 32);
  }
  self.empty.frame = CGRectMake(m, row_y, w, MAX(120, b.size.height - row_y - safe.bottom - 40));
}

- (void)moveFocusBy:(NSInteger)by {
  if (!self.games.count) return;
  self.focus = MAX(0, MIN((NSInteger)self.games.count - 1, self.focus + by));
  [self showFocus];
}

- (void)tapCard:(UIButton*)card {
  if (card.tag == self.focus) {
    [self startFocused];
    return;
  }
  self.focus = card.tag;
  [self showFocus];
}

- (void)openPackages:(NSArray<NSURL*>*)urls {
  if (self.started || [NSUserDefaults.standardUserDefaults boolForKey:@"libraryTest"]) return;
  if (!self.packages) self.packages = [NSMutableArray new];
  NSMutableArray<NSURL*>* all = [urls mutableCopy];
  [all addObjectsFromArray:WinPadWaitingPackages()];
  for (NSURL* url in all) {
    BOOL known = NO;
    for (NSURL* queued in self.packages) known |= [queued.path isEqualToString:url.path];
    if (!known) [self.packages addObject:url];
  }
  if (!self.installing) [self installNext];
}

// Installs the first package of the queue with a progress alert, then the next one.
- (void)installNext {
  NSURL* url = self.packages.firstObject;
  if (!url || self.started) {
    self.installing = NO;
    return;
  }
  // Not over the settings or another alert: when that one closes, the library appears again.
  if (self.presentedViewController || !self.view.window) return;
  self.installing = YES;
  [self.packages removeObjectAtIndex:0];
  UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Přidávám hru"
                                                                 message:url.lastPathComponent
                                                          preferredStyle:UIAlertControllerStyleAlert];
  [self presentViewController:alert animated:YES completion:nil];
  const BOOL scoped = [url startAccessingSecurityScopedResource];
  const BOOL own = InDocuments(url);
  NSString* name = url.lastPathComponent;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSString* error = nil;
    NSString* folder = WinPadInstallPackage(url.path,
                                            ^(double done) {
                                              dispatch_async(dispatch_get_main_queue(), ^{
                                                alert.message = [NSString stringWithFormat:@"%@\n%.0f %%", name, done * 100];
                                              });
                                            },
                                            &error);
    // The app's own copy (AirDrop's Inbox, or copied into Documents) goes once installed; a
    // file opened in place in Files stays where it is.
    if (folder && own) [NSFileManager.defaultManager removeItemAtURL:url error:nil];
    if (scoped) [url stopAccessingSecurityScopedResource];
    dispatch_async(dispatch_get_main_queue(), ^{
      [alert dismissViewControllerAnimated:YES
                                completion:^{
                                  self.installing = NO;
                                  [self reload];
                                  if (folder) {
                                    [self focusFolder:folder];
                                    [self installNext];
                                    return;
                                  }
                                  UIAlertController* failed =
                                      [UIAlertController alertControllerWithTitle:@"Hru se nepodařilo přidat"
                                                                          message:[NSString stringWithFormat:@"%@\n\n%@", name, error]
                                                                   preferredStyle:UIAlertControllerStyleAlert];
                                  [failed addAction:[UIAlertAction actionWithTitle:@"OK"
                                                                             style:UIAlertActionStyleDefault
                                                                           handler:^(UIAlertAction* action) {
                                                                             [self installNext];
                                                                           }]];
                                  // A copy in Documents that cannot be installed would come back
                                  // at every start: it is set aside with a name the library skips.
                                  if (own) {
                                    NSString* aside = [url.path.stringByDeletingLastPathComponent
                                        stringByAppendingPathComponent:[name stringByAppendingString:@".failed"]];
                                    [NSFileManager.defaultManager removeItemAtPath:aside error:nil];
                                    [NSFileManager.defaultManager moveItemAtPath:url.path toPath:aside error:nil];
                                  }
                                  [self presentViewController:failed animated:YES completion:nil];
                                }];
    });
  });
}

- (void)focusFolder:(NSString*)folder {
  for (NSUInteger i = 0; i < self.games.count; i++) {
    if ([self.games[i].folder isEqualToString:folder]) {
      self.focus = (NSInteger)i;
      [self showFocus];
      return;
    }
  }
}

- (void)startFocused {
  if (!self.games.count) return;
  [self startProgram:@"game" game:self.games[self.focus]];
}

// The export button's title: in full, or short where there is little room (an iPhone).
- (void)titleExport:(BOOL)compact {
  if (self.exportCompact == compact && self.exportMaps.configuration.title) return;
  self.exportCompact = compact;
  UIButtonConfiguration* config = self.exportMaps.configuration;
  config.title = compact ? @"Export map" : @"Exportovat pro převodník";
  config.contentInsets = compact ? NSDirectionalEdgeInsetsMake(8, 10, 8, 10) : NSDirectionalEdgeInsetsMake(14, 24, 14, 28);
  self.exportMaps.configuration = config;
}

// Zips the focused game's code maps (in the background: a long session writes megabytes) and
// opens the share sheet with it: AirDrop to the Mac, Save to Files, Mail… The maps count as
// exported once it was shared; the zip itself is temporary.
- (void)exportFocused {
  if (!self.games.count || self.presentedViewController || self.started || self.exporting) return;
  WinPadGame* game = self.games[self.focus];
  if (!game.maps) return;
  self.exporting = YES;
  UIButtonConfiguration* busy = self.exportMaps.configuration;
  busy.showsActivityIndicator = YES;
  self.exportMaps.configuration = busy;
  NSDate* started = NSDate.date;
  __weak LibraryViewController* weak = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSError* error = nil;
    NSURL* zip = WinPadExportMaps(game, &error);
    dispatch_async(dispatch_get_main_queue(), ^{
      LibraryViewController* me = weak;
      if (!me) return;
      me.exporting = NO;
      UIButtonConfiguration* idle = me.exportMaps.configuration;
      idle.showsActivityIndicator = NO;
      me.exportMaps.configuration = idle;
      if (!zip) {
        UIAlertController* alert = [UIAlertController alertControllerWithTitle:@"Export se nepodařil"
                                                                       message:error.localizedDescription
                                                                preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
        [me presentViewController:alert animated:YES completion:nil];
        return;
      }
      UIActivityViewController* sheet = [[UIActivityViewController alloc] initWithActivityItems:@[ zip ]
                                                                          applicationActivities:nil];
      sheet.popoverPresentationController.sourceView = me.exportMaps;
      sheet.popoverPresentationController.sourceRect = me.exportMaps.bounds;
      sheet.completionWithItemsHandler = ^(UIActivityType type, BOOL completed, NSArray* items, NSError* failed) {
        if (completed) {
          WinPadMarkMapsExported(game, started);
          [weak reload];
        }
        [NSFileManager.defaultManager removeItemAtURL:zip error:nil];
      };
      [me presentViewController:sheet animated:YES completion:nil];
    });
  });
}

- (void)startProgram:(NSString*)program game:(WinPadGame*)game {
  if (self.started || self.installing) return;
  // A game without the JIT: StikDebug turns it on first (WinPadJIT.m), if it is installed and the
  // settings want it. The game starts once a debugger is attached, or without the JIT after 60 s
  // or when the user says so.
  if (game && !self.jitAsked && ![NSUserDefaults.standardUserDefaults boolForKey:@"libraryTest"] &&
      WinPadJITShouldAskStikDebug()) {
    self.jitAsked = YES;
    [self waitForJITThen:^{
      [self startProgram:program game:game];
    }];
    return;
  }
  // Without the JIT a game without an image cannot run on a device: say how to get one.
  if (game && !game.image && !WinPadJITUsable() && ![NSUserDefaults.standardUserDefaults boolForKey:@"libraryTest"]) {
    self.jitAsked = NO;
    UIAlertController* alert =
        [UIAlertController alertControllerWithTitle:@"Hra potřebuje JIT"
                                            message:@"Tahle hra nemá přeložený obraz, takže na iPadu poběží jen s JITem. "
                                                    @"Zapni ho přes StikDebug, nebo hru přelož převodníkem WinPad Translator."
                                     preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"Jak zapnout JIT"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction* action) {
                                              [self openJITGuide];
                                            }]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Zavřít" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
    return;
  }
  self.started = YES;
  if (game) [NSUserDefaults.standardUserDefaults setObject:game.folder forKey:@"lastGame"];
  // The game reads the controllers itself (main.m's Gamepads).
  for (id observer in self.observers) [NSNotificationCenter.defaultCenter removeObserver:observer];
  [self.observers removeAllObjects];
  for (GCController* pad in GCController.controllers) pad.extendedGamepad.valueChangedHandler = nil;
  if (self.start) self.start(program, game);
}

- (void)refreshJIT {
  const BOOL on = WinPadJITUsable();
  UIButtonConfiguration* config = [UIButtonConfiguration filledButtonConfiguration];
  config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
  config.title = on ? @"JIT zapnutý" : @"JIT vypnutý";
  config.image = [UIImage systemImageNamed:on ? @"bolt.fill" : @"bolt.slash"];
  config.imagePadding = 8;
  config.contentInsets = NSDirectionalEdgeInsetsMake(0, 16, 0, 18);
  config.baseForegroundColor = on ? Hex(0x9BEDB5) : Hex(0xDCE8FF);
  config.baseBackgroundColor = on ? [Hex(0x7DDC9A) colorWithAlphaComponent:0.22] : [UIColor colorWithWhite:1 alpha:0.12];
  self.jitBadge.configuration = config;
  self.jitBadge.accessibilityLabel = on ? @"JIT je zapnutý" : @"JIT je vypnutý, ťukni pro návod";
  [self.view setNeedsLayout];
}

// The last game run stopped because a DLL of Microsoft's DirectX was missing (Wine has no
// file of it): offers the download, once for that run.
- (void)offerDirectX {
  if ([NSUserDefaults.standardUserDefaults boolForKey:@"libraryTest"] || self.presentedViewController ||
      self.installing || WinPadDirectXDownloading())
    return;
  NSString* dll = WinPadMissingDLLOfLastRun();
  if (!dll || !WinPadDirectXProvides(dll) || [WinPadDirectXDLLs() containsObject:dll]) return;
  NSString* log = [Documents() stringByAppendingPathComponent:@"wine.log"];
  NSDate* date = [NSFileManager.defaultManager attributesOfItemAtPath:log error:nil].fileModificationDate;
  NSString* key = [NSString stringWithFormat:@"%@ %.0f", dll, date.timeIntervalSince1970];
  if ([[NSUserDefaults.standardUserDefaults stringForKey:@"directXOffered"] isEqualToString:key]) return;
  [NSUserDefaults.standardUserDefaults setObject:key forKey:@"directXOffered"];
  NSString* text = [NSString stringWithFormat:@"Hra potřebuje %@, kterou má DirectX od Microsoftu. Stáhnout ho "
                                              @"(asi 95 MB, přímo od Microsoftu)?",
                                              dll];
  UIAlertController* ask = [UIAlertController alertControllerWithTitle:@"Chybí DLL"
                                                               message:text
                                                        preferredStyle:UIAlertControllerStyleAlert];
  [ask addAction:[UIAlertAction actionWithTitle:@"Teď ne" style:UIAlertActionStyleCancel handler:nil]];
  __weak LibraryViewController* weak = self;
  [ask addAction:[UIAlertAction actionWithTitle:@"Stáhnout"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction* action) {
                                          [weak downloadDirectXFor:dll];
                                        }]];
  [self presentViewController:ask animated:YES completion:nil];
}

- (void)downloadDirectXFor:(NSString*)dll {
  UIAlertController* busy = [UIAlertController alertControllerWithTitle:@"Stahuji DirectX"
                                                                message:@"Od Microsoftu…"
                                                         preferredStyle:UIAlertControllerStyleAlert];
  [self presentViewController:busy animated:YES completion:nil];
  __weak LibraryViewController* weak = self;
  WinPadDirectXDownload(
      ^(double fraction) {
        busy.message = fraction < 1 ? [NSString stringWithFormat:@"%d %%", (int)(fraction * 100)] : @"Rozbaluji…";
      },
      ^(NSString* error) {
        [busy dismissViewControllerAnimated:YES completion:^{
          const BOOL got = !error && [WinPadDirectXDLLs() containsObject:dll];
          NSString* text = error         ? error
                           : got         ? @"Hotovo. Spusť hru znovu."
                                         : [NSString stringWithFormat:@"DirectX je stažený, ale %@ v něm není.", dll];
          UIAlertController* result = [UIAlertController alertControllerWithTitle:error ? @"DirectX se nestáhl" : @"DirectX od Microsoftu"
                                                                          message:text
                                                                   preferredStyle:UIAlertControllerStyleAlert];
          [result addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
          [weak presentViewController:result animated:YES completion:nil];
        }];
      });
}

- (void)openJITGuide {
  if (self.presentedViewController || self.started) return;
  WinPadJITGuideViewController* guide = [WinPadJITGuideViewController new];
  __weak LibraryViewController* weak = self;
  guide.closed = ^{
    [weak refreshJIT];
    [weak showFocus];
  };
  UINavigationController* nav = [[UINavigationController alloc] initWithRootViewController:guide];
  nav.modalPresentationStyle = UIModalPresentationFormSheet;
  nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
  [self presentViewController:nav animated:YES completion:nil];
}

- (void)waitForJITThen:(void (^)(void))start {
  const BOOL builtin = !WinPadJITBuiltInUnavailableReason() && WinPadJITHasPairing();
  UIAlertController* alert = [UIAlertController
      alertControllerWithTitle:@"Zapínám JIT"
                       message:builtin ? @"Vestavěný JIT se připojuje k WinPad Wine. Poprvé po restartu iPadu to může "
                                         @"chvíli trvat (stahuje se vývojářský obraz disku)."
                                       : @"StikDebug se připojuje k WinPad Wine. Pokud se neotevře sám, vrať se sem "
                                         @"po zapnutí JITu ve StikDebugu."
                preferredStyle:UIAlertControllerStyleAlert];
  __block BOOL finished = NO;
  [alert addAction:[UIAlertAction actionWithTitle:@"Spustit bez JITu"
                                            style:UIAlertActionStyleCancel
                                          handler:^(UIAlertAction* action) {
                                            finished = YES;
                                            dispatch_async(dispatch_get_main_queue(), start);
                                          }]];
  [self presentViewController:alert animated:YES completion:nil];
  __weak LibraryViewController* weak = self;
  WinPadJITTurnOn(^(BOOL ok, NSString* message) {
    if (finished) return;
    if (ok) {
      finished = YES;
      [weak refreshJIT];
      if (alert.presentingViewController)
        [alert dismissViewControllerAnimated:YES completion:start];
      else
        start();
      return;
    }
    // Why not, with the choice still there: without the JIT, or how to get it.
    finished = YES;
    UIAlertController* why = [UIAlertController alertControllerWithTitle:@"JIT se nezapnul"
                                                                 message:message
                                                          preferredStyle:UIAlertControllerStyleAlert];
    [why addAction:[UIAlertAction actionWithTitle:@"Jak zapnout JIT"
                                            style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction* action) {
                                            LibraryViewController* me = weak;
                                            me.jitAsked = NO;
                                            [me openJITGuide];
                                          }]];
    [why addAction:[UIAlertAction actionWithTitle:@"Spustit bez JITu"
                                            style:UIAlertActionStyleCancel
                                          handler:^(UIAlertAction* action) {
                                            dispatch_async(dispatch_get_main_queue(), start);
                                          }]];
    void (^show)(void) = ^{
      [weak presentViewController:why animated:YES completion:nil];
    };
    if (alert.presentingViewController)
      [alert dismissViewControllerAnimated:YES completion:show];
    else
      show();
  });
}

- (void)openSettings {
  if (self.presentedViewController || self.started) return;
  WinPadSettingsViewController* settings = [WinPadSettingsViewController new];
  __weak LibraryViewController* weak = self;
  settings.run = ^(NSString* program) {
    [weak startProgram:program game:nil];
  };
  UINavigationController* nav = [[UINavigationController alloc] initWithRootViewController:settings];
  nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
  nav.modalPresentationStyle = UIModalPresentationFormSheet;
  [self presentViewController:nav animated:YES completion:nil];
}

- (void)attach:(GCController*)controller {
  if (self.started || !controller.extendedGamepad) return;
  __weak LibraryViewController* weak = self;
  controller.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad* pad, GCControllerElement* element) {
    [weak readPad:pad];
  };
}

// Acts on the buttons a controller pressed since its last change.
- (void)readPad:(GCExtendedGamepad*)pad {
  float x = pad.dpad.xAxis.value;
  if (fabsf(x) < 0.5f) x = pad.leftThumbstick.xAxis.value;
  const unsigned now = (x < -0.5f ? NavLeft : 0) | (x > 0.5f ? NavRight : 0) | (pad.buttonA.pressed ? NavA : 0) |
                       (pad.buttonB.pressed ? NavB : 0) | (pad.buttonY.pressed ? NavY : 0) |
                       (pad.buttonX.pressed ? NavX : 0);
  const unsigned pressed = now & ~self.pad;
  self.pad = now;
  if (self.presentedViewController) {
    if (pressed & NavB) [self dismissViewControllerAnimated:YES completion:nil];
    return;
  }
  if (pressed & NavLeft) [self moveFocusBy:-1];
  if (pressed & NavRight) [self moveFocusBy:1];
  if (pressed & NavY) [self openSettings];
  if (pressed & NavX) [self exportFocused];
  if (pressed & NavA) [self startFocused];
}

- (void)pressesBegan:(NSSet<UIPress*>*)presses withEvent:(UIPressesEvent*)event {
  BOOL handled = NO;
  for (UIPress* press in presses) {
    switch (press.key.keyCode) {
      case UIKeyboardHIDUsageKeyboardLeftArrow:
        [self moveFocusBy:-1];
        handled = YES;
        break;
      case UIKeyboardHIDUsageKeyboardRightArrow:
        [self moveFocusBy:1];
        handled = YES;
        break;
      case UIKeyboardHIDUsageKeyboardReturnOrEnter:
        [self startFocused];
        handled = YES;
        break;
      default:
        break;
    }
  }
  if (!handled) [super pressesBegan:presses withEvent:event];
}
@end
