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
#import "GOG.h"
#import "Package.h"
#import "WinPadAuto.h"
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

// A launcher, which starts the game as a second program: on iPad only one runs at a time, so
// the game's own program is the better pick when the folder has it.
static BOOL LauncherProgram(NSString* name) {
  NSString* lower = name.lowercaseString;
  for (NSString* word in @[ @"launch", @"start", @"menu", @"loader", @"autorun", @"editor", @"server", @"benchmark",
                            @"report", @"dxwebsetup", @"vcredist", @"dotnet" ])
    if ([lower containsString:word]) return YES;
  return NO;
}

// Folders that hold the game's installers and Microsoft's runtimes, not the game.
static BOOL RedistFolder(NSString* name) {
  NSString* lower = name.lowercaseString;
  for (NSString* word in @[ @"redist", @"directx", @"vcredist", @"dotnet", @"installer", @"support", @"physx",
                            @"__macosx", @"crack", @"setup", @"_commonredist", @"easyanticheat", @"battleye" ])
    if ([lower containsString:word]) return YES;
  return NO;
}

// Lowercase letters and digits of TEXT: "Need for Speed™ 2" -> "needforspeed2".
static NSString* Letters(NSString* text) {
  NSMutableString* out = [NSMutableString new];
  NSString* folded = [text stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch locale:nil];
  for (NSUInteger i = 0; i < folded.length; i++) {
    const unichar c = [folded characterAtIndex:i];
    if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) [out appendFormat:@"%C", c];
  }
  return out;
}

// The game's program in DIR when nothing names it: a Windows program up to three folders deep
// (many games keep it in Bin, System or Binaries\Win32), not an installer, a settings tool or a
// launcher when there is another, 32-bit before 64-bit (WinPad runs 32-bit games), named like
// the folder before others, then the largest, then the least deep. Relative to DIR, or nil.
static NSString* BestProgram(NSString* dir, NSString* folder) {
  NSFileManager* fm = NSFileManager.defaultManager;
  NSDirectoryEnumerator* walk = [fm enumeratorAtPath:dir];
  NSString* want = Letters(folder);
  NSString* best = nil;
  long long best_score[7] = {0};
  NSUInteger seen = 0;
  for (NSString* path; (path = walk.nextObject) && seen < 5000; seen++) {
    const BOOL is_dir = [walk.fileAttributes.fileType isEqualToString:NSFileTypeDirectory];
    NSString* name = path.lastPathComponent;
    if (is_dir) {
      if ([name hasPrefix:@"."] || walk.level >= 4 || RedistFolder(name)) [walk skipDescendants];
      continue;
    }
    if ([name hasPrefix:@"."] || ![name.pathExtension.lowercaseString isEqualToString:@"exe"]) continue;
    NSString* arch = ProgramArch([dir stringByAppendingPathComponent:path]);
    // What it imports and whether it is an installer (GameDetect.c): a program that draws with
    // Direct3D, OpenGL or DirectDraw or reads controllers is the game's, before a settings tool or
    // a launcher whose names tell nothing (Configure.exe, Play.exe...).
    NSDictionary* traits = WinPadQuickTraits([dir stringByAppendingPathComponent:path]);
    NSString* stem = Letters(name.stringByDeletingPathExtension);
    const BOOL named = want.length >= 3 && stem.length >= 3 && ([want containsString:stem] || [stem containsString:want]);
    // A launcher word only in what the name has beyond the folder's: "StarCraft.exe" in StarCraft
    // is the game, "Morrowind Launcher.exe" in Morrowind is not (it had won over Morrowind.exe,
    // being larger).
    const BOOL launcher =
        named ? [want containsString:stem] ? NO : LauncherProgram([stem stringByReplacingOccurrencesOfString:want withString:@""])
              : LauncherProgram(name);
    // Higher wins, field by field.
    const long long score[7] = {
        HelperProgram(name) || WinPadInstallerName(traits) ? 0 : 1,
        launcher ? 0 : 1,
        [arch isEqualToString:@"32bit"] ? 2 : [arch isEqualToString:@"64bit"] ? 1 : 0,
        named ? 1 : 0,
        WinPadTraitsLookLikeGame(traits) ? 1 : 0,
        (long long)walk.fileAttributes.fileSize,
        -(long long)walk.level,
    };
    BOOL better = best == nil;
    for (int i = 0; !better && i < 7 && score[i] >= best_score[i]; i++)
      if (score[i] > best_score[i]) better = YES;
    if (!better) continue;
    best = path;
    memcpy(best_score, score, sizeof(score));
  }
  return best;
}

// The other programs of the game when its own is 64-bit: the best 32-bit one, or nil
// (BestProgram's rules, among 32-bit programs only).
static NSString* Best32BitProgram(NSString* dir) {
  NSString* best = nil;
  unsigned long long best_size = 0;
  BOOL best_plain = NO;
  for (NSString* path in WinPadGamePrograms(dir.lastPathComponent)) {
    if (![ProgramArch([dir stringByAppendingPathComponent:path]) isEqualToString:@"32bit"]) continue;
    NSString* name = path.lastPathComponent;
    const BOOL plain = !HelperProgram(name) && !LauncherProgram(name);
    const unsigned long long size = [NSFileManager.defaultManager attributesOfItemAtPath:[dir stringByAppendingPathComponent:path] error:nil].fileSize;
    if (!best || (plain && !best_plain) || (plain == best_plain && size > best_size)) {
      best = path;
      best_size = size;
      best_plain = plain;
    }
  }
  return best;
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

// The game profiles the app carries (tools/winpad-translator/data/profiles, copied into the
// app's "profiles" folder): a game folder whose winpad.json has none, or an older version of
// one, gets the app's (WithAppProfile). The file itself is left as it is.
static NSArray<NSDictionary*>* AppProfiles(void) {
  static NSArray* profiles;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSMutableArray* list = [NSMutableArray new];
    // After the project's own profiles, those made from Proton's umu-protonfixes
    // (tools/winpad-translator/import-protonfixes.py: {"profiles": [...]}, many in one file).
    NSMutableArray* proton = [NSMutableArray new];
    NSString* dir = [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"profiles"];
    for (NSString* name in [[NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]
             sortedArrayUsingSelector:@selector(compare:)]) {
      if (![name.pathExtension isEqualToString:@"json"]) continue;
      NSData* data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:name]];
      id prof = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
      const BOOL many = [prof isKindOfClass:NSDictionary.class] && [prof[@"profiles"] isKindOfClass:NSArray.class];
      for (id one in many ? prof[@"profiles"] : prof ? @[ prof ] : @[])
        if ([one isKindOfClass:NSDictionary.class] && [one[@"id"] isKindOfClass:NSString.class] &&
            [one[@"match"] isKindOfClass:NSArray.class])
          [many ? proton : list addObject:one];
    }
    [list addObjectsFromArray:proton];
    profiles = list;
  });
  return profiles;
}

// The files of DIR by lowercase path relative to DIR (with /), as profiles.py's _files_ci: two
// folders deep when DEEP (a rule names a file in a folder), else only DIR's own, which is
// quick for a game of thousands of files.
static NSDictionary<NSString*, NSString*>* FilesAnyCase(NSString* dir, BOOL deep) {
  NSMutableDictionary* found = [NSMutableDictionary new];
  NSDirectoryEnumerator* walk = [NSFileManager.defaultManager enumeratorAtPath:dir];
  for (NSString* path in walk) {
    const BOOL folder = [walk.fileAttributes.fileType isEqualToString:NSFileTypeDirectory];
    if (folder && (!deep || walk.level >= 3)) [walk skipDescendants];
    if (folder || found[path.lowercaseString]) continue;
    found[path.lowercaseString] = path;
  }
  return found;
}

// Whether a rule of the app's profiles names a file inside a folder.
static BOOL ProfilesNameFolders(void) {
  for (NSDictionary* prof in AppProfiles())
    for (NSDictionary* rule in prof[@"match"]) {
      if (![rule isKindOfClass:NSDictionary.class]) continue;
      NSMutableArray* names = [NSMutableArray arrayWithObject:[rule[@"exe"] isKindOfClass:NSString.class] ? rule[@"exe"] : @""];
      if ([rule[@"files"] isKindOfClass:NSArray.class]) [names addObjectsFromArray:rule[@"files"]];
      for (id name in names)
        if ([name isKindOfClass:NSString.class] && ([name containsString:@"/"] || [name containsString:@"\\"])) return YES;
    }
  return NO;
}

// Whether PROF's match rules take the game in DIR (profiles.py match): its program, or @"".
static NSString* ProfileMatch(NSDictionary* prof, NSDictionary<NSString*, NSString*>* files, NSNumber* steam_id,
                              NSSet<NSNumber*>* gog_ids) {
  for (NSDictionary* rule in prof[@"match"]) {
    if (![rule isKindOfClass:NSDictionary.class]) continue;
    if (rule[@"steamAppId"] && ![rule[@"steamAppId"] isEqual:steam_id]) continue;
    if (rule[@"gogId"] && ![gog_ids containsObject:rule[@"gogId"]]) continue;
    NSString* exe = @"";
    if ([rule[@"exe"] isKindOfClass:NSString.class]) {
      exe = files[[rule[@"exe"] stringByReplacingOccurrencesOfString:@"\\" withString:@"/"].lowercaseString];
      if (!exe) continue;
    }
    BOOL all = YES;
    for (NSString* f in [rule[@"files"] isKindOfClass:NSArray.class] ? rule[@"files"] : @[])
      if (![f isKindOfClass:NSString.class] ||
          !files[[f stringByReplacingOccurrencesOfString:@"\\" withString:@"/"].lowercaseString])
        all = NO;
    if (all) return exe;
  }
  return nil;
}

// The GOG games in DIR: goggame-ID.info files (GOG's installers put one in a game's folder,
// {"gameId": "1207658883", ...}), by the number in the name and the file's gameId.
static NSSet<NSNumber*>* GOGIds(NSString* dir) {
  NSMutableSet* ids = [NSMutableSet new];
  for (NSString* name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil]) {
    NSString* lower = name.lowercaseString;
    if (![lower hasPrefix:@"goggame-"] || ![lower hasSuffix:@".info"]) continue;
    const long long n = [[lower substringWithRange:NSMakeRange(8, lower.length - 13)] longLongValue];
    if (n > 0) [ids addObject:@(n)];
    NSData* data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:name]];
    id info = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    id game_id = [info isKindOfClass:NSDictionary.class] ? info[@"gameId"] : nil;
    if ([game_id respondsToSelector:@selector(longLongValue)] && [game_id longLongValue] > 0)
      [ids addObject:@([game_id longLongValue])];
  }
  return ids;
}

// The first program PROF's rules name that the folder has (profiles.py rule_exe).
static NSString* ProfileRuleExe(NSDictionary* prof, NSDictionary<NSString*, NSString*>* files) {
  for (NSDictionary* rule in prof[@"match"])
    if ([rule isKindOfClass:NSDictionary.class] && [rule[@"exe"] isKindOfClass:NSString.class]) {
      NSString* exe = files[[rule[@"exe"] stringByReplacingOccurrencesOfString:@"\\" withString:@"/"].lowercaseString];
      if (exe) return exe;
    }
  return nil;
}

// INFO (the folder's winpad.json) with the app's profile for the game in DIR when the file has
// no profile, or an older version of the same one; *FROM_APP says so. The block is the one
// profiles.py apply writes: id, version, title, notes, settings with the program and title.
static NSDictionary* WithAppProfile(NSString* dir, NSDictionary* info, BOOL* from_app) {
  *from_app = NO;
  NSDictionary* had = [info[@"profile"] isKindOfClass:NSDictionary.class] ? info[@"profile"] : nil;
  NSDictionary* files = nil;
  NSDictionary* prof = nil;
  NSString* exe = nil;
  if ([had[@"id"] isKindOfClass:NSString.class]) {
    for (NSDictionary* p in AppProfiles())
      if ([p[@"id"] isEqualToString:had[@"id"]]) prof = p;
    if (!prof || [prof[@"version"] integerValue] <= [had[@"version"] integerValue]) return info;
    files = FilesAnyCase(dir, ProfilesNameFolders());
    NSDictionary* old_settings = [had[@"settings"] isKindOfClass:NSDictionary.class] ? had[@"settings"] : nil;
    exe = [old_settings[@"exe"] isKindOfClass:NSString.class] ? old_settings[@"exe"] : nil;
    if (!exe.length) exe = ProfileMatch(prof, files, nil, nil) ?: ProfileRuleExe(prof, files);
  } else {
    if (had || !AppProfiles().count) return info;
    files = FilesAnyCase(dir, ProfilesNameFolders());
    NSString* steam = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"steam_appid.txt"]
                                                encoding:NSUTF8StringEncoding
                                                   error:nil];
    NSNumber* steam_id = steam.integerValue > 0 ? @(steam.integerValue) : nil;
    NSSet<NSNumber*>* gog_ids = GOGIds(dir);
    for (NSDictionary* p in AppProfiles()) {
      exe = ProfileMatch(p, files, steam_id, gog_ids);
      if (exe) {
        prof = p;
        break;
      }
    }
    if (!prof) return info;
    if (!exe.length) exe = ProfileRuleExe(prof, files);
  }
  NSMutableDictionary* settings =
      [([prof[@"settings"] isKindOfClass:NSDictionary.class] ? prof[@"settings"] : @{}) mutableCopy];
  if (exe.length) settings[@"exe"] = exe;
  if (!settings[@"title"]) settings[@"title"] = prof[@"title"] ?: @"";
  NSMutableDictionary* out = [(info ?: @{}) mutableCopy];
  out[@"profile"] = @{
    @"id" : prof[@"id"],
    @"version" : prof[@"version"] ?: @0,
    @"title" : prof[@"title"] ?: @"",
    @"notes" : [prof[@"notes"] isKindOfClass:NSArray.class] ? prof[@"notes"] : @[],
    @"settings" : settings
  };
  *from_app = YES;
  return out;
}

NSDictionary* WinPadGameSettings(NSDictionary* info) {
  NSMutableDictionary* out = [NSMutableDictionary new];
  NSDictionary* profile = [info[@"profile"] isKindOfClass:NSDictionary.class] ? info[@"profile"] : nil;
  if ([profile[@"settings"] isKindOfClass:NSDictionary.class]) [out addEntriesFromDictionary:profile[@"settings"]];
  for (NSString* key in info) {
    if ([key isEqualToString:@"profile"]) continue;
    id mine = info[key], theirs = out[key];
    if ([@[ @"dllOverrides", @"env", @"registry", @"padKeys" ] containsObject:key] && [mine isKindOfClass:NSDictionary.class] &&
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

// The user's own settings of a game (Nastavení hry): Documents/.winpad-games/FOLDER.json, out of
// the game's folder, which may be read-only (copied off a disc) and which WinPad Translator and
// packages write winpad.json into.
static NSString* OwnSettingsPath(NSString* folder) {
  return [[Documents() stringByAppendingPathComponent:@".winpad-games"]
      stringByAppendingPathComponent:[folder stringByAppendingPathExtension:@"json"]];
}

NSDictionary* WinPadOwnGameSettings(NSString* folder) {
  NSData* json = [NSData dataWithContentsOfFile:OwnSettingsPath(folder)];
  id obj = json ? [NSJSONSerialization JSONObjectWithData:json options:0 error:nil] : nil;
  return [obj isKindOfClass:NSDictionary.class] ? obj : @{};
}

BOOL WinPadSetOwnGameSetting(NSString* folder, NSString* key, id value) {
  NSMutableDictionary* own = [WinPadOwnGameSettings(folder) mutableCopy];
  if (key) own[key] = value;
  else [own removeAllObjects];
  NSString* path = OwnSettingsPath(folder);
  NSFileManager* fm = NSFileManager.defaultManager;
  if (!own.count) return [fm removeItemAtPath:path error:nil] || ![fm fileExistsAtPath:path];
  [fm createDirectoryAtPath:path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
  NSData* json = [NSJSONSerialization dataWithJSONObject:own options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys error:nil];
  return [json writeToFile:path atomically:YES];
}

NSArray<NSString*>* WinPadGamePrograms(NSString* folder) {
  NSString* dir = [Documents() stringByAppendingPathComponent:folder];
  NSDirectoryEnumerator* walk = [NSFileManager.defaultManager enumeratorAtPath:dir];
  NSMutableArray<NSString*>* found = [NSMutableArray new];
  for (NSString* path; (path = walk.nextObject) && found.count < 300;) {
    if ([path.lastPathComponent hasPrefix:@"."] || walk.level > 3) {
      if ([walk.fileAttributes.fileType isEqualToString:NSFileTypeDirectory]) [walk skipDescendants];
      continue;
    }
    if ([path.pathExtension.lowercaseString isEqualToString:@"exe"] &&
        ![walk.fileAttributes.fileType isEqualToString:NSFileTypeDirectory])
      [found addObject:path];
  }
  // The folder's own programs first, then those in its subfolders, by name.
  [found sortUsingComparator:^NSComparisonResult(NSString* a, NSString* b) {
    const NSUInteger da = a.pathComponents.count, db = b.pathComponents.count;
    if (da != db) return da < db ? NSOrderedAscending : NSOrderedDescending;
    return [a localizedCaseInsensitiveCompare:b];
  }];
  return found;
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
    BOOL profile_from_app = NO;
    info = WithAppProfile(dir, info, &profile_from_app);
    NSDictionary* settings = WinPadGameSettings(info);
    NSDictionary* own_settings = WinPadOwnGameSettings(folder);
    NSString* exe = [settings[@"exe"] isKindOfClass:NSString.class] ? settings[@"exe"] : nil;
    if (exe && ([exe containsString:@".."] || ![fm fileExistsAtPath:[dir stringByAppendingPathComponent:exe]])) exe = nil;
    if (!exe) exe = BestProgram(dir, folder);
    // The program the user picked (Nastavení hry, a long press on its tile) wins, while it is there.
    NSString* auto_exe = exe;
    NSString* own_exe = [own_settings[@"exe"] isKindOfClass:NSString.class] ? own_settings[@"exe"] : nil;
    if (own_exe.length && ![own_exe containsString:@".."] && ![own_exe hasPrefix:@"/"] &&
        [fm fileExistsAtPath:[dir stringByAppendingPathComponent:own_exe]])
      exe = own_exe;
    if (!exe) continue;
    // So do its resolution and picture: main.m reads them from the settings as winpad.json's.
    if (own_settings.count) {
      NSMutableDictionary* mine = [settings mutableCopy];
      for (NSString* key in @[ @"screen", @"scaling", @"padMode" ])
        if ([own_settings[key] isKindOfClass:NSString.class]) mine[key] = own_settings[key];
      settings = mine;
    }
    WinPadGame* game = [WinPadGame new];
    game.folder = folder;
    game.exe = [folder stringByAppendingPathComponent:exe];
    game.autoExe = auto_exe;
    game.own = own_settings;
    NSString* title = [settings[@"title"] isKindOfClass:NSString.class] ? settings[@"title"] : nil;
    game.settings = settings;
    NSDictionary* profile = [info[@"profile"] isKindOfClass:NSDictionary.class] ? info[@"profile"] : nil;
    if ([profile[@"id"] isKindOfClass:NSString.class])
      game.profile = [NSString stringWithFormat:@"%@ v%@%@", profile[@"id"], profile[@"version"] ?: @"?",
                                                 profile_from_app ? @" (app)" : @""];
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

// The controller's inputs: their names in the "padKeys" setting (the first ones kept from
// before) and the keys they are by default, made for a racing game: the d-pad and the left stick
// steer, RT accelerates and LT brakes; the right stick is no key.
static NSString* const PadIds[PadCount] = {@"up",   @"down",  @"left", @"right", @"a",   @"b",     @"x",      @"y",
                                           @"l1",   @"r1",    @"l2",   @"r2",    @"menu", @"options", @"rup",  @"rdown",
                                           @"rleft", @"rright", @"lup", @"ldown", @"lleft", @"lright"};
static const unsigned short PadDefaults[PadCount] = {0x26, 0x28, 0x25, 0x27, 0x0d, 0x1b, 0x20, 'C', 'Z', 'A',  0x28,
                                                     0x26, 0x1b, 0x0d, 0,    0,    0,    0,    0x26, 0x28, 0x25, 0x27};

void WinPadPadKeys(unsigned short keys[PadCount]) {
  NSDictionary* saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"padKeys"];
  for (int i = 0; i < PadCount; i++) {
    id key = saved[PadIds[i]];
    keys[i] = [key respondsToSelector:@selector(intValue)] ? (unsigned short)([key intValue] & 0xff) : PadDefaults[i];
  }
  // The left stick was the d-pad until it had keys of its own: one not set yet is still the d-pad's.
  for (int d = 0; d < 4; d++)
    if (![saved[PadIds[PadLUp + d]] respondsToSelector:@selector(intValue)]) keys[PadLUp + d] = keys[PadUp + d];
}

int WinPadPadInput(NSString* name) {
  for (int i = 0; i < PadCount; i++)
    if ([name isKindOfClass:NSString.class] && [PadIds[i] isEqualToString:name]) return i;
  return -1;
}

NSString* WinPadPadStyle(void) {
  NSString* set = [NSUserDefaults.standardUserDefaults stringForKey:@"padStyle"];
  if ([@[ @"xbox", @"playstation", @"nintendo" ] containsObject:set]) return set;
  GCController* pad = GCController.controllers.firstObject;
  GCExtendedGamepad* extended = pad.extendedGamepad;
  if ([extended isKindOfClass:GCDualSenseGamepad.class] || [extended isKindOfClass:GCDualShockGamepad.class])
    return @"playstation";
  NSString* name = [NSString stringWithFormat:@"%@ %@", pad.productCategory ?: @"", pad.vendorName ?: @""].lowercaseString;
  if ([name containsString:@"switch"] || [name containsString:@"joy-con"] || [name containsString:@"nintendo"])
    return @"nintendo";
  return @"xbox";
}

NSString* WinPadPadLabel(int input, NSString* style) {
  const int s = [style isEqualToString:@"playstation"] ? 1 : [style isEqualToString:@"nintendo"] ? 2 : 0;
  static NSString* const buttons[3][10] = {
      {@"A", @"B", @"X", @"Y", @"LB", @"RB", @"LT", @"RT", @"Menu", @"View"},
      {@"✕", @"○", @"□", @"△", @"L1", @"R1", @"L2", @"R2", @"Options", @"Create"},
      {@"B", @"A", @"Y", @"X", @"L", @"R", @"ZL", @"ZR", @"+", @"−"},
  };
  if (input >= PadA && input <= PadOptions) return buttons[s][input - PadA];
  if (input >= PadLUp) return @"L";
  if (input >= PadRUp) return @"R";
  return @[ @"▲", @"▼", @"◀", @"▶" ][input - PadUp];
}

// An input's name in the settings, in the controller's look.
static NSString* PadTitle(int input) {
  NSString* style = WinPadPadStyle();
  NSArray<NSString*>* ways = @[ @"nahoru", @"dolů", @"doleva", @"doprava" ];
  if (input <= PadRight) return [@"Křížový ovladač " stringByAppendingString:ways[input - PadUp]];
  if (input >= PadLUp) return [@"Levá páčka " stringByAppendingString:ways[input - PadLUp]];
  if (input >= PadRUp) return [@"Pravá páčka " stringByAppendingString:ways[input - PadRUp]];
  NSString* label = WinPadPadLabel(input, style);
  if (input > PadY) return label;
  if ([style isEqualToString:@"playstation"])
    return [NSString stringWithFormat:@"%@ (%@)", label, @[ @"křížek", @"kolečko", @"čtverec", @"trojúhelník" ][input - PadA]];
  if ([style isEqualToString:@"nintendo"])
    return [NSString stringWithFormat:@"%@ (%@)", label, @[ @"dole", @"vpravo", @"vlevo", @"nahoře" ][input - PadA]];
  return label;
}

// The order the settings list the inputs in: the d-pad, the sticks, then the buttons.
static const int PadOrder[PadCount] = {PadUp,  PadDown, PadLeft,  PadRight, PadLUp,   PadLDown,   PadLLeft, PadLRight,
                                       PadRUp, PadRDown, PadRLeft, PadRRight, PadA,     PadB,       PadX,     PadY,
                                       PadL1,  PadR1,   PadL2,    PadR2,    PadMenu,  PadOptions};

// Keys for the four directions of the d-pad or a stick at once (the settings' presets).
enum { PadPresets = 3 };
static const int PadSetFirst[PadPresets] = {PadUp, PadLUp, PadRUp};

static void SavePadKey(int input, unsigned short vk) {
  NSMutableDictionary* saved = [[NSUserDefaults.standardUserDefaults dictionaryForKey:@"padKeys"] mutableCopy] ?: [NSMutableDictionary new];
  saved[PadIds[input]] = @(vk);
  [NSUserDefaults.standardUserDefaults setObject:saved forKey:@"padKeys"];
}

// The look's name in the settings.
static NSString* PadStyleName(NSString* style) {
  return @{@"xbox" : @"Xbox", @"playstation" : @"PlayStation", @"nintendo" : @"Nintendo"}[style];
}

// Keys for the four directions (up, down, left, right) of the d-pad or a stick at once.
static const struct {
  const char* name;
  unsigned short keys[4];
} DirectionSets[] = {
    {"Šipky", {0x26, 0x28, 0x25, 0x27}},
    {"W A S D", {'W', 'S', 'A', 'D'}},
    {"I J K L", {'I', 'K', 'J', 'L'}},
    {"Nic", {0, 0, 0, 0}},
};
enum { DirectionSetCount = sizeof DirectionSets / sizeof DirectionSets[0] };

// What four direction keys are, by the sets above, else "Vlastní".
static NSString* DirectionsName(const unsigned short keys[4]) {
  for (int set = 0; set < DirectionSetCount; set++)
    if (!memcmp(keys, DirectionSets[set].keys, sizeof DirectionSets[set].keys)) return @(DirectionSets[set].name);
  return @"Vlastní";
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
  self.title = PadTitle(self.input);
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

// The game's picture (Library.h). The settings keep "pictureScaling", "pictureAvoidsCutout" and
// "gameScreen"; a game's winpad.json "scaling" and "screen" win over them.
static NSArray<NSString*>* PictureScalings(void) { return @[ @"fit", @"custom", @"stretch", @"fill" ]; }

NSString* WinPadPictureScaling(NSDictionary* settings) {
  id own = settings[@"scaling"];
  if ([own isKindOfClass:NSString.class] && [PictureScalings() containsObject:[own lowercaseString]]) return [own lowercaseString];
  NSString* set = [NSUserDefaults.standardUserDefaults stringForKey:@"pictureScaling"];
  return [PictureScalings() containsObject:set] ? set : @"fit";
}

NSInteger WinPadPictureStretch(NSDictionary* settings) {
  id own = settings[@"stretch"];
  const NSInteger p = [own respondsToSelector:@selector(integerValue)]
                          ? [own integerValue]
                          : [NSUserDefaults.standardUserDefaults objectForKey:@"pictureStretch"]
                                ? [NSUserDefaults.standardUserDefaults integerForKey:@"pictureStretch"]
                                : 25;
  return MAX(0, MIN(100, p));
}

BOOL WinPadPictureAvoidsCutout(void) {
  return [NSUserDefaults.standardUserDefaults boolForKey:@"pictureAvoidsCutout"];
}

CGSize WinPadGameScreen(NSDictionary* settings, CGSize display) {
  id own = settings[@"screen"];
  NSString* want = [own isKindOfClass:NSString.class] ? [own lowercaseString]
                                                     : [NSUserDefaults.standardUserDefaults stringForKey:@"gameScreen"];
  // Neither the game nor the user said: what the program's graphics API suits (WinPadAuto.m).
  if (!want.length && [settings[@"autoScreen"] isKindOfClass:NSString.class]) want = settings[@"autoScreen"];
  if (!want.length || [want isEqualToString:@"4:3"]) return CGSizeZero;
  if ([want isEqualToString:@"wide"]) {
    const CGFloat across = MAX(display.width, display.height), down = MIN(display.width, display.height);
    if (down <= 0) return CGSizeZero;
    // 768 lines as now, as wide as the display's shape makes them (even, at most 2048).
    const long w = MIN(2048, lround(768 * across / down / 2) * 2);
    return w > 1024 ? CGSizeMake(w, 768) : CGSizeZero;
  }
  NSArray<NSString*>* parts = [want componentsSeparatedByString:@"x"];
  if (parts.count != 2) return CGSizeZero;
  const NSInteger w = parts[0].integerValue, h = parts[1].integerValue;
  return w >= 320 && h >= 200 && w <= 4096 && h <= 4096 ? CGSizeMake(w, h) : CGSizeZero;
}

// The picture's choices as the settings show them.
static NSString* PictureScalingName(NSString* scaling) {
  return @{@"fit" : @"Zachovat tvar", @"custom" : @"Vlastní roztažení", @"stretch" : @"Roztáhnout na celý displej",
            @"fill" : @"Přiblížit"}[scaling];
}

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

// The settings' section 0 is the look, 1 the game's picture; the others follow them, numbered from 0
// after them in the code.
enum { AppearanceSection = 0, PictureSection = 1, OtherSections = 2 };

@interface WinPadSettingsViewController : UITableViewController
@property(nonatomic, copy) void (^run)(NSString* program);
@property(nonatomic, copy) NSString* directXState;  // the download's progress or its error, or nil
@end

// The settings' section of Microsoft's DirectX DLLs, counted after the look and the picture like the others.
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
  return 8;
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
  if (section == AppearanceSection) return 4;
  if (section == PictureSection) return 4;
  section -= OtherSections;
  return section == 0 ? 3 : section == 1 ? PadCount + PadPresets + 1 : section == 2 ? (self.hasWindowProgram ? 4 : 3) : section == 3 ? 3 : 2;
}

- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section {
  return @[ @"Vzhled", @"Obraz hry", @"Ovládání", @"Mapování tlačítek", @"Diagnostika", @"JIT", @"DirectX od Microsoftu", @"O aplikaci" ][section];
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
  if (section == AppearanceSection)
    return @"Pozadí knihovny a nastavení, na iPadu i iPhonu. Obaly her bez obalu aplikace sama najde na internetu "
           @"podle názvu (Steam, Wikipedie) a uloží jen ten, jehož název sedí; jiný vybereš tlačítkem Obal pod hrou. "
           @"S klíčem SteamGridDB (zdarma: steamgriddb.com › Preferences › API) najde víc a hezčích obalů.";
  if (section == PictureSection)
    return @"Zachovat tvar: celý obraz hry v jeho poměru stran, po stranách černé pruhy. Vlastní roztažení: obraz se "
           @"roztáhne do šířky o tolik procent, kolik nastavíš posuvníkem (nejvýš na celý displej; posunutím se tento "
           @"režim zapne). Roztáhnout na celý displej: "
           @"obraz 4:3 se roztáhne do šířky. Přiblížit: celý displej v poměru hry, nahoře a dole se kus obrazu uřízne. "
           @"Širokoúhlý monitor: hra dostane monitor v poměru stran displeje (na iPhonu 16 Pro 1670×768) a hra, která "
           @"umí širokoúhlá rozlišení, vykreslí víc scény bez roztažení (vyber ho pak v nastavení hry). "
           @"Hra to může mít jinak ve svém winpad.json (\"scaling\", \"screen\").";
  section -= OtherSections;
  if (section == 0)
    return @"Ovladač na obrazovce se ukáže jen tehdy, když není připojený herní ovladač. Rozvržení určuje názvy "
           @"tlačítek v nastavení a vzhled ovladače na obrazovce (PlayStation: ✕ ○ □ △, křížový ovladač nad levou páčkou).";
  if (section == 1)
    return @"Klávesa, kterou hra dostane za každé tlačítko a každý směr páček. Levá páčka je to, co křížový "
           @"ovladač, dokud jí nedáš vlastní klávesy. „Celá páčka“ nastaví všechny čtyři směry naráz (šipky, WASD, "
           @"IJKL, nic). Tlačítka jsou podle místa: ✕ na PlayStationu je A na Xboxu a B na Nintendu. Platí pro všechny hry.";
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
  if (path.section == PictureSection && path.row == 0) {
    cell.textLabel.text = @"Obraz";
    cell.detailTextLabel.text = PictureScalingName(WinPadPictureScaling(nil));
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
  }
  if (path.section == PictureSection && path.row == 1) {
    const NSInteger stretch = WinPadPictureStretch(nil);
    cell.textLabel.text = [NSString stringWithFormat:@"Roztažení o %ld %%", (long)stretch];
    UISlider* slider = [[UISlider alloc] initWithFrame:CGRectMake(0, 0, 170, 32)];
    slider.minimumValue = 0;
    slider.maximumValue = 100;
    slider.value = stretch;
    [slider addTarget:self action:@selector(stretchChanged:) forControlEvents:UIControlEventValueChanged];
    [slider addTarget:self action:@selector(stretchDone:) forControlEvents:UIControlEventTouchUpInside | UIControlEventTouchUpOutside];
    cell.accessoryView = slider;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
  }
  if (path.section == PictureSection) {
    cell.textLabel.text = path.row == 2 ? @"Širokoúhlý monitor" : @"Mimo výřez displeje";
    UISwitch* toggle = [UISwitch new];
    toggle.on = path.row == 2 ? [[NSUserDefaults.standardUserDefaults stringForKey:@"gameScreen"] isEqualToString:@"wide"]
                              : WinPadPictureAvoidsCutout();
    toggle.tag = path.row;
    [toggle addTarget:self action:@selector(pictureChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
  }
  path = [NSIndexPath indexPathForRow:path.row inSection:path.section - OtherSections];
  if (path.section == 0 && path.row == 0) {
    cell.textLabel.text = @"Dotykové ovládání";
    UISwitch* toggle = [UISwitch new];
    id touch = [NSUserDefaults.standardUserDefaults objectForKey:@"touchControls"];
    // A Mac has a keyboard, a mouse and maybe a controller: no touch controller by default.
    toggle.on = touch ? [touch boolValue] : !NSProcessInfo.processInfo.isiOSAppOnMac;
    [toggle addTarget:self action:@selector(touchChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
  } else if (path.section == 0 && path.row == 2) {
    cell.textLabel.text = @"Rozvržení ovladače";
    NSString* set = [NSUserDefaults.standardUserDefaults stringForKey:@"padStyle"];
    NSString* name = PadStyleName(WinPadPadStyle());
    cell.detailTextLabel.text = [@[ @"xbox", @"playstation", @"nintendo" ] containsObject:set]
                                    ? name
                                    : [NSString stringWithFormat:@"Podle ovladače (%@)", name];
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  } else if (path.section == 0) {
    cell.textLabel.text = @"Herní ovladač";
    GCController* pad = GCController.controllers.firstObject;
    cell.detailTextLabel.text = pad ? (pad.vendorName ?: @"Připojen") : @"Nepřipojen";
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
  } else if (path.section == 1 && path.row < PadCount) {
    unsigned short keys[PadCount];
    WinPadPadKeys(keys);
    const int input = PadOrder[path.row];
    cell.textLabel.text = PadTitle(input);
    cell.detailTextLabel.text = KeyName(keys[input]);
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  } else if (path.section == 1 && path.row < PadCount + PadPresets) {
    const int first = PadSetFirst[path.row - PadCount];
    unsigned short keys[PadCount];
    WinPadPadKeys(keys);
    cell.textLabel.text = @[ @"Celý křížový ovladač", @"Celá levá páčka", @"Celá pravá páčka" ][path.row - PadCount];
    cell.detailTextLabel.text = DirectionsName(keys + first);
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

// The stretch slider, in steps of 5 %: moving it picks "Vlastní roztažení" too.
- (void)stretchChanged:(UISlider*)slider {
  const NSInteger stretch = lround(slider.value / 5) * 5;
  [NSUserDefaults.standardUserDefaults setInteger:stretch forKey:@"pictureStretch"];
  [NSUserDefaults.standardUserDefaults setObject:@"custom" forKey:@"pictureScaling"];
  UITableViewCell* cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:1 inSection:PictureSection]];
  cell.textLabel.text = [NSString stringWithFormat:@"Roztažení o %ld %%", (long)stretch];
}

- (void)stretchDone:(UISlider*)slider {
  slider.value = WinPadPictureStretch(nil);
  [self.tableView reloadRowsAtIndexPaths:@[ [NSIndexPath indexPathForRow:0 inSection:PictureSection] ]
                        withRowAnimation:UITableViewRowAnimationNone];
}

- (void)pictureChanged:(UISwitch*)toggle {
  if (toggle.tag == 2) {
    if (toggle.on) [NSUserDefaults.standardUserDefaults setObject:@"wide" forKey:@"gameScreen"];
    else [NSUserDefaults.standardUserDefaults removeObjectForKey:@"gameScreen"];
  } else {
    [NSUserDefaults.standardUserDefaults setBool:toggle.on forKey:@"pictureAvoidsCutout"];
  }
}

// A sheet of CHOICES (title → action) from the row at PATH.
- (void)sheet:(NSString*)title choices:(NSArray<NSArray*>*)choices at:(NSIndexPath*)path {
  UIAlertController* sheet = [UIAlertController alertControllerWithTitle:title
                                                                 message:nil
                                                          preferredStyle:UIAlertControllerStyleActionSheet];
  __weak UITableView* table = self.tableView;
  for (NSArray* choice in choices) {
    void (^picked)(void) = choice[1];
    [sheet addAction:[UIAlertAction actionWithTitle:choice[0]
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction* action) {
                                              picked();
                                              [table reloadData];
                                            }]];
  }
  [sheet addAction:[UIAlertAction actionWithTitle:@"Zrušit" style:UIAlertActionStyleCancel handler:nil]];
  UITableViewCell* cell = [self.tableView cellForRowAtIndexPath:path];
  sheet.popoverPresentationController.sourceView = cell ?: self.view;
  sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
  [self presentViewController:sheet animated:YES completion:nil];
}

// The controller's look: by the connected controller, or one picked.
- (void)pickPadStyle {
  NSMutableArray* choices = [NSMutableArray new];
  for (NSString* style in @[ @"auto", @"xbox", @"playstation", @"nintendo" ])
    [choices addObject:@[ [style isEqualToString:@"auto"] ? @"Podle připojeného ovladače" : PadStyleName(style), ^{
                 [NSUserDefaults.standardUserDefaults setObject:style forKey:@"padStyle"];
               } ]];
  [self sheet:@"Rozvržení ovladače" choices:choices at:[NSIndexPath indexPathForRow:2 inSection:OtherSections]];
}

// The four directions of the d-pad or a stick at once: arrows, WASD, IJKL or no keys.
- (void)pickDirections:(int)first row:(NSInteger)row {
  NSMutableArray* choices = [NSMutableArray new];
  for (int set = 0; set < DirectionSetCount; set++)
    [choices addObject:@[ @(DirectionSets[set].name), ^{
                 for (int d = 0; d < 4; d++) SavePadKey(first + d, DirectionSets[set].keys[d]);
               } ]];
  [self sheet:@"Směry" choices:choices at:[NSIndexPath indexPathForRow:row inSection:1 + OtherSections]];
}

// The picture's choices in a sheet.
- (void)pickPictureScaling {
  UIAlertController* sheet = [UIAlertController alertControllerWithTitle:@"Obraz hry"
                                                                 message:nil
                                                          preferredStyle:UIAlertControllerStyleActionSheet];
  __weak UITableView* table = self.tableView;
  for (NSString* scaling in PictureScalings())
    [sheet addAction:[UIAlertAction actionWithTitle:PictureScalingName(scaling)
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction* action) {
                                              [NSUserDefaults.standardUserDefaults setObject:scaling forKey:@"pictureScaling"];
                                              [table reloadData];
                                            }]];
  [sheet addAction:[UIAlertAction actionWithTitle:@"Zrušit" style:UIAlertActionStyleCancel handler:nil]];
  UITableViewCell* cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:PictureSection]];
  sheet.popoverPresentationController.sourceView = cell ?: self.view;
  sheet.popoverPresentationController.sourceRect = cell ? cell.bounds : self.view.bounds;
  [self presentViewController:sheet animated:YES completion:nil];
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
    [weak.tableView reloadRowsAtIndexPaths:@[ [NSIndexPath indexPathForRow:0 inSection:DirectXSection + OtherSections] ]
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
  if (path.section == PictureSection) {
    if (path.row == 0) [self pickPictureScaling];
    return;
  }
  path = [NSIndexPath indexPathForRow:path.row inSection:path.section - OtherSections];
  if (path.section == 0 && path.row == 2) {
    [self pickPadStyle];
    return;
  }
  if (path.section == 1 && path.row >= PadCount && path.row < PadCount + PadPresets) {
    [self pickDirections:PadSetFirst[path.row - PadCount] row:path.row];
    return;
  }
  if (path.section == 1 && path.row < PadCount) {
    WinPadKeyPickerViewController* picker = [WinPadKeyPickerViewController new];
    picker.input = PadOrder[path.row];
    [self.navigationController pushViewController:picker animated:YES];
    return;
  }
  if (path.section == 1) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"padKeys"];
    [tableView reloadSections:[NSIndexSet indexSetWithIndex:1 + OtherSections] withRowAnimation:UITableViewRowAnimationNone];
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

// One choice out of a list (a game's program, resolution, picture): a tick by the chosen one;
// picking one calls PICKED and goes back.
@interface WinPadChoiceViewController : UITableViewController
@property(nonatomic, copy) NSArray<NSArray*>* choices;  // @[title, detail or @"", value or NSNull]
@property(nonatomic, strong) id chosen;                // a value, or nil for NSNull's row
@property(nonatomic, copy) NSString* footer;
@property(nonatomic, copy) void (^picked)(id value);
@end

@implementation WinPadChoiceViewController
- (instancetype)init {
  return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
  return (NSInteger)self.choices.count;
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
  return self.footer;
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)path {
  UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:nil];
  NSArray* choice = self.choices[(NSUInteger)path.row];
  cell.textLabel.text = choice[0];
  cell.textLabel.numberOfLines = 0;
  cell.detailTextLabel.text = [choice[1] length] ? choice[1] : nil;
  cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
  id value = choice[2] == NSNull.null ? nil : choice[2];
  cell.accessoryType = (value == self.chosen || [value isEqual:self.chosen]) ? UITableViewCellAccessoryCheckmark
                                                                              : UITableViewCellAccessoryNone;
  return cell;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)path {
  id value = self.choices[(NSUInteger)path.row][2];
  self.chosen = value == NSNull.null ? nil : value;
  [tableView reloadData];
  if (self.picked) self.picked(self.chosen);
  [self.navigationController popViewControllerAnimated:YES];
}
@end

// The resolutions a game can be given: the monitor Wine tells it it has (MADEIRA_SCREEN_W/H,
// WinPadGameScreen), so the largest mode it can pick. @[title, value].
static NSArray<NSArray<NSString*>*>* ScreenChoices(void) {
  return @[
    @[ @"4:3 · 1024 × 768 (jako dosud)", @"4:3" ], @[ @"Širokoúhlý (podle displeje)", @"wide" ],
    @[ @"640 × 480", @"640x480" ], @[ @"800 × 600", @"800x600" ], @[ @"1280 × 960", @"1280x960" ],
    @[ @"1600 × 1200", @"1600x1200" ], @[ @"1280 × 720 (16:9)", @"1280x720" ], @[ @"1366 × 768 (16:9)", @"1366x768" ],
    @[ @"1600 × 900 (16:9)", @"1600x900" ], @[ @"1920 × 1080 (16:9)", @"1920x1080" ],
    @[ @"1280 × 800 (16:10)", @"1280x800" ], @[ @"1680 × 1050 (16:10)", @"1680x1050" ]
  ];
}

static NSString* ScreenName(NSString* screen) {
  for (NSArray<NSString*>* choice in ScreenChoices())
    if ([choice[1] caseInsensitiveCompare:screen] == NSOrderedSame) return choice[0];
  return [screen stringByReplacingOccurrencesOfString:@"x" withString:@" × "];
}

static NSString* ProgramDetail(NSString* folder, NSString* exe) {
  NSString* path = [[Documents() stringByAppendingPathComponent:folder] stringByAppendingPathComponent:exe];
  const unsigned long long size = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileSize;
  NSMutableArray* parts = [NSMutableArray arrayWithObject:[NSByteCountFormatter stringFromByteCount:(long long)size
                                                                                         countStyle:NSByteCountFormatterCountStyleFile]];
  NSString* arch = ProgramArch(path);
  if (arch) [parts addObject:[arch isEqualToString:@"32bit"] ? @"32bitový" : @"64bitový"];
  if (HelperProgram(exe.lastPathComponent)) [parts addObject:@"spíš instalátor nebo nastavení"];
  return [parts componentsJoinedByString:@" · "];
}

// A game's own settings, opened by a long press on its tile: its cover, the program that
// starts it (a game may start through a launcher or have a multiplayer program larger than
// itself, which the library would pick), its resolution and how its picture fills the screen.
// They are saved as they are changed (WinPadSetOwnGameSetting); CHANGED runs after each.
@interface WinPadGameSettingsViewController : UITableViewController
- (instancetype)initWithGame:(WinPadGame*)game;
@property(nonatomic, strong) WinPadGame* game;
@property(nonatomic, copy) void (^changed)(void);
@property(nonatomic, copy) void (^coverChanged)(void);
- (NSURL*)shareURL;
@end

enum { GameCoverSection, GameProgramSection, GamePictureSection, GameAutoSection, GameResetSection, GameSections };

@implementation WinPadGameSettingsViewController
- (instancetype)initWithGame:(WinPadGame*)game {
  if (!(self = [super initWithStyle:UITableViewStyleInsetGrouped])) return nil;
  self.game = game;
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = self.game.title;
  self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                         target:self
                                                                                         action:@selector(done)];
}

- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self.tableView reloadData];
}

- (void)done {
  [self dismissViewControllerAnimated:YES completion:nil];
}

- (NSString*)own:(NSString*)key {
  id value = WinPadOwnGameSettings(self.game.folder)[key];
  return [value isKindOfClass:NSString.class] ? value : nil;
}

- (void)set:(NSString*)key to:(id)value {
  WinPadSetOwnGameSetting(self.game.folder, key, value);
  // The game as the library sees it now (its program, settings), for the rows and the start.
  for (WinPadGame* game in WinPadFindGames()) {
    if (![game.folder isEqualToString:self.game.folder]) continue;
    self.game.exe = game.exe;
    self.game.settings = game.settings;
    self.game.own = game.own;
    self.game.arch = game.arch;
    self.game.plainSettings = nil;
  }
  [self.tableView reloadData];
  if (self.changed) self.changed();
}

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView {
  return GameSections;
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
  return section == GamePictureSection ? 2 : section == GameAutoSection ? 5 : 1;
}

- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section {
  return @[ @"Obal", @"Spouštěcí program", @"Obraz", @"Automatické nastavení", @"" ][(NSUInteger)section];
}

// What the game's program is and the automatic settings variant of its next run (WinPadAuto.m).
- (NSDictionary*)traits {
  return WinPadProgramTraits([Documents() stringByAppendingPathComponent:self.game.exe]);
}

- (NSDictionary*)variant {
  NSDictionary* variant = nil;
  WinPadSettingsWithAuto(self.traits ?: @{}, self.game.exe.lastPathComponent, self.game.plainSettings ?: self.game.settings ?: @{},
                         WinPadOwnGameSettings(self.game.folder), &variant);
  return variant;
}

// "DirectX 9 · 32bit · DirectInput, XInput"
- (NSString*)traitsText {
  NSDictionary* t = self.traits;
  if (!t) return @"Není to program pro Windows";
  NSMutableArray* parts = [NSMutableArray new];
  NSString* installer = WinPadInstallerName(t);
  if (installer) [parts addObject:[NSString stringWithFormat:@"Instalačka (%@)", installer]];
  [parts addObject:WinPadGraphicsName(t) ?: @"Grafika neznámá"];
  [parts addObject:[t[@"machine"] integerValue] == 0x8664 ? @"64bit" : @"32bit"];
  NSMutableArray* uses = [NSMutableArray new];
  NSDictionary* names = @{
    @"dinput" : @"DirectInput", @"xinput" : @"ovladač Xbox", @"dotnet" : @".NET", @"physx" : @"PhysX",
    @"steam" : @"Steam", @"openal" : @"OpenAL", @"xaudio" : @"XAudio2"
  };
  for (NSString* u in t[@"uses"])
    if (names[u]) [uses addObject:names[u]];
  if (uses.count) [parts addObject:[uses componentsJoinedByString:@", "]];
  return [parts componentsJoinedByString:@" · "];
}

// A new GitHub issue with the game's working settings filled in as a game profile
// (tools/winpad-translator/data/profiles), for WinPad's online profiles.
- (NSURL*)shareURL {
  NSDictionary* variant = self.variant;
  NSDictionary* own = WinPadOwnGameSettings(self.game.folder);
  NSMutableDictionary* settings = [NSMutableDictionary new];
  NSDictionary* auto_settings = variant[@"settings"] ?: @{};
  for (NSString* key in auto_settings) {
    if ([key isEqualToString:@"autoScreen"]) settings[@"screen"] = auto_settings[key];
    else if ([key isEqualToString:@"registryForce"]) {
      // Wine's own Windows version needs no profile.
      NSMutableDictionary* reg = [NSMutableDictionary new];
      for (NSString* k in auto_settings[key]) {
        NSMutableDictionary* values = [auto_settings[key][k] mutableCopy];
        if ([values[@"Version"] isEqual:@"win10"]) [values removeObjectForKey:@"Version"];
        if (values.count) reg[k] = values;
      }
      if (reg.count) settings[@"registry"] = reg;
    } else settings[key] = auto_settings[key];
  }
  for (NSString* key in @[ @"screen", @"scaling" ])
    if ([own[key] isKindOfClass:NSString.class]) settings[key] = own[key];
  NSString* exe = [self.game.exe substringFromIndex:MIN(self.game.exe.length, self.game.folder.length + 1)];
  // A file or two next to the program, so the profile matches this game and not any GAME.EXE.
  NSMutableArray* files = [NSMutableArray new];
  NSString* exe_dir = [Documents() stringByAppendingPathComponent:self.game.exe].stringByDeletingLastPathComponent;
  for (NSString* name in [[NSFileManager.defaultManager contentsOfDirectoryAtPath:exe_dir error:nil]
           sortedArrayUsingSelector:@selector(compare:)])
    if ([name.pathExtension.lowercaseString isEqualToString:@"dll"] && files.count < 2) [files addObject:name];
  NSMutableDictionary* match = [@{@"exe" : exe} mutableCopy];
  if (files.count) match[@"files"] = files;
  NSString* slug = Letters(self.game.title);
  NSDictionary* profile = @{
    @"id" : slug.length ? slug : @"game",
    @"version" : @1,
    @"title" : self.game.title,
    @"match" : @[ match ],
    @"settings" : settings,
    @"notes" : @[ [NSString stringWithFormat:@"Sdíleno z aplikace WinPad (%@), funguje s automatickým nastavením „%@“.",
                                             AppBuild(), variant[@"title"] ?: @"Výchozí"] ],
  };
  NSData* json = [NSJSONSerialization dataWithJSONObject:profile
                                                 options:NSJSONWritingPrettyPrinted | NSJSONWritingSortedKeys |
                                                         NSJSONWritingWithoutEscapingSlashes
                                                   error:nil];
  NSString* body = [NSString
      stringWithFormat:@"Profil hry ze sdíleného nastavení aplikace WinPad.\n\nHra: %@\nProgram: %@\nZjištěno: %@\n\n```json\n%@\n```\n",
                       self.game.title, exe, self.traitsText, [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]];
  NSURLComponents* url = [NSURLComponents componentsWithString:@"https://github.com/Chlupiq/WinPad/issues/new"];
  url.queryItems = @[
    [NSURLQueryItem queryItemWithName:@"title" value:[@"Profil hry: " stringByAppendingString:self.game.title]],
    [NSURLQueryItem queryItemWithName:@"body" value:body]
  ];
  return url.URL;
}

// Opens shareURL after saying what it holds: nothing is sent until the user sends it on GitHub.
- (void)share {
  NSURL* url = self.shareURL;
  UIAlertController* ask = [UIAlertController
      alertControllerWithTitle:@"Sdílet nastavení"
                       message:@"Otevře se GitHub s předvyplněným hlášením pro repozitář WinPad. Bude v něm název hry, název "
                               @"jejího programu a nastavení, se kterým běží; žádné soubory ani cesty z iPadu. Nic se "
                               @"neodešle, dokud ho na GitHubu sám neodešleš. Z hlášení pak vznikne online profil."
                preferredStyle:UIAlertControllerStyleAlert];
  [ask addAction:[UIAlertAction actionWithTitle:@"Zrušit" style:UIAlertActionStyleCancel handler:nil]];
  [ask addAction:[UIAlertAction actionWithTitle:@"Otevřít GitHub"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction* action) {
                                          [UIApplication.sharedApplication openURL:url options:@{} completionHandler:nil];
                                        }]];
  [self presentViewController:ask animated:YES completion:nil];
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
  if (section == GameProgramSection)
    return @"Program, který se spustí po ťuknutí na Spustit. Vyber jiný, když se hra spouští přes launcher, nebo když "
           @"aplikace vybrala multiplayer či jiný program než samotnou hru.";
  if (section == GamePictureSection)
    return @"Rozlišení je monitor, který hra uvidí: nabídne režimy až do této velikosti. Konkrétní režim pak vybereš "
           @"v nastavení hry, pokud ho hra nemá pevný.";
  if (section == GameAutoSection)
    return @"Aplikace pozná podle programu hry, jak ji spustit. Když hra spadne hned po startu, zkusí příště jiné "
           @"nastavení, a to, se kterým hra běží, si zapamatuje. Profil hry a tvoje volby výše mají vždy přednost.";
  if (section == GameResetSection) return @"Nastavení se ukládají jen pro tuto hru a platí od příštího spuštění.";
  return nil;
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)path {
  UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
  cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  cell.detailTextLabel.numberOfLines = 2;
  switch (path.section) {
    case GameCoverSection: {
      cell.textLabel.text = @"Vybrat obal";
      cell.detailTextLabel.text = self.game.cover ? @"Má obal" : @"Bez obalu";
      if (self.game.cover) {
        UIImageView* thumb = [[UIImageView alloc] initWithImage:self.game.cover];
        thumb.frame = CGRectMake(0, 0, 40, 60);
        thumb.contentMode = UIViewContentModeScaleAspectFill;
        thumb.clipsToBounds = YES;
        thumb.layer.cornerRadius = 4;
        cell.accessoryView = thumb;
      }
      break;
    }
    case GameProgramSection: {
      NSString* own = [self own:@"exe"];
      NSString* exe = [self.game.exe substringFromIndex:MIN(self.game.exe.length, self.game.folder.length + 1)];
      cell.textLabel.text = exe;
      cell.detailTextLabel.text = own && [own isEqualToString:exe] ? @"Vlastní" : @"Automaticky";
      break;
    }
    case GamePictureSection:
      if (path.row == 0) {
        NSString* own = [self own:@"screen"];
        cell.textLabel.text = @"Rozlišení";
        cell.detailTextLabel.text = own ? ScreenName(own) : @"Výchozí";
      } else {
        NSString* own = [self own:@"scaling"];
        cell.textLabel.text = @"Obraz na displeji";
        cell.detailTextLabel.text = own ? PictureScalingName(own) ?: own : @"Výchozí";
      }
      break;
    case GameAutoSection: {
      NSDictionary* own = WinPadOwnGameSettings(self.game.folder);
      if (path.row == 0) {
        cell.textLabel.text = @"Program";
        cell.detailTextLabel.text = self.traitsText;
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
      } else if (path.row == 1) {
        NSDictionary* variant = self.variant;
        cell.textLabel.text = @"Nastavení";
        NSString* state = [own[@"autoWorked"] isEqual:variant[@"id"]] ? @"funguje"
                          : [own[@"autoExhausted"] boolValue]          ? @"žádné nepomohlo"
                          : [variant[@"id"] isEqual:@"base"]            ? @"zatím nevyzkoušeno"
                                                                        : @"zkouší se";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@ (%@)", variant[@"title"] ?: @"Výchozí", state];
        cell.accessoryType = UITableViewCellAccessoryNone;
        cell.selectionStyle = UITableViewCellSelectionStyleNone;
      } else if (path.row == 2) {
        NSString* mine = [self own:@"padMode"];
        NSString* mode = mine ?: self.variant[@"settings"][@"padMode"] ?: @"keys";
        cell.textLabel.text = @"Ovladač";
        cell.detailTextLabel.text = [NSString stringWithFormat:@"%@%@", [mode isEqualToString:@"xinput"] ? @"Jako ovladač Xbox"
                                                               : [mode isEqualToString:@"hid"] ? @"Jako herní ovladač (DirectInput)"
                                                                                               : @"Jako klávesy",
                                                               mine ? @"" : @" (automaticky)"];
      } else {
        cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
        cell.textLabel.text = path.row == 3 ? @"Zkusit automatické nastavení znovu" : @"Sdílet funkční nastavení na GitHubu";
        cell.textLabel.textColor = self.view.tintColor;
        if (path.row == 4 && !own[@"autoWorked"]) {
          cell.textLabel.textColor = UIColor.secondaryLabelColor;
          cell.textLabel.text = @"Sdílet nastavení (až hra jednou poběží)";
        }
      }
      break;
    }
    default:
      cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
      cell.textLabel.text = @"Obnovit výchozí nastavení hry";
      cell.textLabel.textColor = UIColor.systemRedColor;
      cell.textLabel.textAlignment = NSTextAlignmentCenter;
      break;
  }
  return cell;
}

- (void)pickCover {
  WinPadCoverPickerViewController* picker = [[WinPadCoverPickerViewController alloc] initWithGame:self.game];
  __weak WinPadGameSettingsViewController* weak = self;
  picker.saved = ^{
    [weak.tableView reloadData];
    if (weak.coverChanged) weak.coverChanged();
  };
  UINavigationController* nav = [[UINavigationController alloc] initWithRootViewController:picker];
  nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
  nav.modalPresentationStyle = UIModalPresentationFormSheet;
  [self presentViewController:nav animated:YES completion:nil];
}

- (void)pickProgram {
  NSMutableArray* choices = [NSMutableArray new];
  NSString* auto_exe = self.game.autoExe;
  if (auto_exe)
    [choices addObject:@[ [@"Automaticky: " stringByAppendingString:auto_exe], ProgramDetail(self.game.folder, auto_exe), NSNull.null ]];
  for (NSString* exe in WinPadGamePrograms(self.game.folder))
    [choices addObject:@[ exe, ProgramDetail(self.game.folder, exe), exe ]];
  WinPadChoiceViewController* list = [WinPadChoiceViewController new];
  list.title = @"Spouštěcí program";
  list.choices = choices;
  list.chosen = [self own:@"exe"];
  list.footer = @"Programy (.exe) ve složce hry a jejích podsložkách.";
  __weak WinPadGameSettingsViewController* weak = self;
  list.picked = ^(id value) {
    [weak set:@"exe" to:value];
  };
  [self.navigationController pushViewController:list animated:YES];
}

- (void)pickScreen {
  NSMutableArray* choices = [NSMutableArray arrayWithObject:@[ @"Výchozí", @"Podle nastavení aplikace a profilu hry", NSNull.null ]];
  for (NSArray<NSString*>* choice in ScreenChoices()) [choices addObject:@[ choice[0], @"", choice[1] ]];
  WinPadChoiceViewController* list = [WinPadChoiceViewController new];
  list.title = @"Rozlišení";
  list.choices = choices;
  list.chosen = [self own:@"screen"];
  list.footer = @"Nejvyšší rozlišení, které hra může vybrat. Vyšší je ostřejší, ale hra může běžet pomaleji.";
  __weak WinPadGameSettingsViewController* weak = self;
  list.picked = ^(id value) {
    [weak set:@"screen" to:value];
  };
  [self.navigationController pushViewController:list animated:YES];
}

- (void)pickPadMode {
  WinPadChoiceViewController* list = [WinPadChoiceViewController new];
  list.title = @"Ovladač";
  list.choices = @[
    @[ @"Automaticky", @"Jako ovladač Xbox, když ho hra umí (XInput), jinak jako klávesy", NSNull.null ],
    @[ @"Jako ovladač Xbox", @"Hra dostane ovladač přímo (XInput), i s analogovými páčkami a spouštěmi", @"xinput" ],
    @[ @"Jako herní ovladač (DirectInput)", @"Pro starší hry, které umí joystick nebo gamepad přes DirectInput; ve hře ho pak vyber v nastavení ovládání", @"hid" ],
    @[ @"Jako klávesy", @"Tlačítka a páčky jsou klávesy podle Nastavení › Ovladač", @"keys" ],
  ];
  list.chosen = [self own:@"padMode"];
  list.footer = @"Platí pro herní ovladač i dotykový ovladač na displeji.";
  __weak WinPadGameSettingsViewController* weak = self;
  list.picked = ^(id value) {
    [weak set:@"padMode" to:value];
  };
  [self.navigationController pushViewController:list animated:YES];
}

- (void)pickScaling {
  NSMutableArray* choices = [NSMutableArray arrayWithObject:@[ @"Výchozí", @"Podle Nastavení › Obraz hry", NSNull.null ]];
  for (NSString* scaling in PictureScalings()) [choices addObject:@[ PictureScalingName(scaling), @"", scaling ]];
  WinPadChoiceViewController* list = [WinPadChoiceViewController new];
  list.title = @"Obraz na displeji";
  list.choices = choices;
  list.chosen = [self own:@"scaling"];
  __weak WinPadGameSettingsViewController* weak = self;
  list.picked = ^(id value) {
    [weak set:@"scaling" to:value];
  };
  [self.navigationController pushViewController:list animated:YES];
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)path {
  [tableView deselectRowAtIndexPath:path animated:YES];
  switch (path.section) {
    case GameCoverSection: [self pickCover]; break;
    case GameProgramSection: [self pickProgram]; break;
    case GamePictureSection:
      if (path.row == 0) [self pickScreen];
      else [self pickScaling];
      break;
    case GameAutoSection:
      if (path.row == 2) {
        [self pickPadMode];
      } else if (path.row == 3) {
        WinPadSetOwnGameSetting(self.game.folder, @"autoWorked", nil);
        WinPadSetOwnGameSetting(self.game.folder, @"autoExhausted", nil);
        [self set:@"autoVariant" to:nil];
      } else if (path.row == 4 && WinPadOwnGameSettings(self.game.folder)[@"autoWorked"]) {
        [self share];
      }
      break;
    default: [self set:nil to:nil]; break;
  }
}
@end

@interface LibraryViewController () <UIDocumentPickerDelegate>
@property(nonatomic, strong) NSArray<WinPadGame*>* games;
@property(nonatomic) NSInteger focus;
@property(nonatomic, strong) WinPadBackdrop* backdrop;
@property(nonatomic, strong) UIButton* settings;
// GOG: the account's games, installed straight into Documents (GOG.m).
@property(nonatomic, strong) UIButton* gog;
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
// A game folder from pickGameFolder is being copied into Documents.
@property(nonatomic) BOOL copyingGame;
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
@property(nonatomic) BOOL dllsChecked;
@property(nonatomic) BOOL archChecked;  // a 64-bit game's question was answered for this start
@property(nonatomic) BOOL installerAsked;  // the "this is an installer" question was answered for this start
@property(nonatomic, copy) NSString* judgeReport;  // CI: what judgeLastRun did
@property(nonatomic, strong) NSMutableString* installReport;
- (void)reload;
- (void)showFocus;
- (void)tick;
- (void)moveFocusBy:(NSInteger)by;
- (void)startFocused;
- (void)exportFocused;
- (void)pickCoverFor:(WinPadGame*)game;
- (void)openGameSettingsFor:(WinPadGame*)game;
- (void)holdCard:(UILongPressGestureRecognizer*)hold;
- (void)coverChanged:(WinPadGame*)game;
- (void)coverFocused;
- (void)titleExport:(BOOL)compact;
- (void)startProgram:(NSString*)program game:(WinPadGame*)game;
- (void)waitForJITThen:(void (^)(void))start;
- (void)refreshJIT;
- (void)openJITGuide;
- (void)offerDirectX;
- (void)downloadDirectXFor:(NSString*)dll;
- (BOOL)checkDLLsOf:(NSString*)program game:(WinPadGame*)game;
- (void)ask64BitFor:(WinPadGame*)game program:(NSString*)program;
- (void)askToStartWithout:(NSString*)text start:(void (^)(void))start cancel:(void (^)(void))cancel;
- (BOOL)prepareAuto:(WinPadGame*)game program:(NSString*)program;
- (BOOL)judgeLastRun;
- (void)openSettings;
- (void)openGOG;
- (void)gogInstalled:(NSNotification*)note;
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

  self.gog = [UIButton buttonWithType:UIButtonTypeSystem];
  [self.gog setImage:[UIImage systemImageNamed:@"bag"] forState:UIControlStateNormal];
  self.gog.tintColor = UIColor.whiteColor;
  self.gog.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
  self.gog.accessibilityLabel = @"Hry z GOG";
  [self.gog addTarget:self action:@selector(openGOG) forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:self.gog];
  [NSNotificationCenter.defaultCenter addObserver:self
                                         selector:@selector(gogInstalled:)
                                             name:WinPadGOGInstalledNotification
                                           object:nil];

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
  // A tap picks a game's folder (on a Mac anywhere on it) and copies it into the library.
  if (NSProcessInfo.processInfo.isiOSAppOnMac)
    self.addGame.text = @"Přidat hru\n\nKlikni a vyber složku hry na Macu, zkopíruje se do knihovny. "
                        @"Nebo otevři soubor .winpad z převodníku.";
  self.addGame.userInteractionEnabled = YES;
  [self.addGame addGestureRecognizer:[[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(pickGameFolder)]];
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
  self.hints.text = @"Ⓐ Spustit     ◀ ▶ Vybrat     Ⓧ Export map     Ⓨ Nastavení     Ťuknutím vybereš, druhým spustíš, podržením otevřeš nastavení hry";
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
  // CI: GOG against a local copy of its servers, in Documents/gog.txt (build-xcode.sh).
  NSString* gog_test = [NSUserDefaults.standardUserDefaults stringForKey:@"gogTest"];
  if (gog_test.length) WinPadGOGTest(gog_test);
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
  if (self.handedOver && !self.installing) {
    WinPadGame* game = self.handedOver;
    self.handedOver = nil;
    [self focusFolder:game.folder];
    [self startProgram:@"game" game:game];
    return;
  }
#if !TARGET_OS_SIMULATOR
  // The first launch on a device without the JIT: how to turn it on, once. A Mac turns it on
  // itself.
  if (!NSProcessInfo.processInfo.isiOSAppOnMac && ![NSUserDefaults.standardUserDefaults boolForKey:@"libraryTest"] &&
      ![NSUserDefaults.standardUserDefaults boolForKey:@"jitGuideShown"] && !WinPadJITUsable() &&
      !self.installing && !self.presentedViewController) {
    [NSUserDefaults.standardUserDefaults setBool:YES forKey:@"jitGuideShown"];
    [self openJITGuide];
  }
#endif
  // CI (build-xcode.sh): a game's settings open, as a long press opens them, for a screenshot.
  NSString* settings_test = [NSUserDefaults.standardUserDefaults stringForKey:@"gameSettingsTest"];
  for (WinPadGame* game in settings_test ? self.games : @[])
    if ([game.folder isEqualToString:settings_test]) [self openGameSettingsFor:game];
  if (![self judgeLastRun]) [self offerDirectX];
  static BOOL tested;
  if (tested || ![NSUserDefaults.standardUserDefaults boolForKey:@"libraryTest"]) return;
  tested = YES;
  NSMutableString* report = [NSMutableString stringWithFormat:@"%@library: %lu games\n", self.installReport,
                                                             (unsigned long)self.games.count];
  for (WinPadGame* game in self.games)
    [report appendFormat:@"library: %@ | %@ | %@ | image %@%@%@\n", game.title, game.exe, game.arch ?: @"?",
                         game.image.lastPathComponent ?: @"none", game.imageInFolder ? @" (game folder)" : @"",
                         game.profile ? [@" | profile " stringByAppendingString:game.profile] : @""];
  // The games' own settings (a long press on a tile): the program picked instead of the
  // library's, the resolution and picture as main.m gets them, and the programs to pick from.
  for (WinPadGame* game in self.games) {
    if (!game.own.count) continue;
    [report appendFormat:@"own: %@ | exe %@ (auto %@) | screen %@ | scaling %@ | programs %@\n", game.folder, game.exe,
                         game.autoExe, game.settings[@"screen"] ?: @"-", game.settings[@"scaling"] ?: @"-",
                         [WinPadGamePrograms(game.folder) componentsJoinedByString:@", "]];
    WinPadSetOwnGameSetting(game.folder, @"scaling", @"fill");
    WinPadSetOwnGameSetting(game.folder, @"screen", @"1280x720");
    WinPadSetOwnGameSetting(game.folder, @"stale", @"x");
    WinPadSetOwnGameSetting(game.folder, @"stale", nil);
    NSDictionary* own = WinPadOwnGameSettings(game.folder);
    [report appendFormat:@"own: %@ saved | %@\n", game.folder,
                         [[own.allKeys sortedArrayUsingSelector:@selector(compare:)] componentsJoinedByString:@" "]];
  }
  // The automatic settings (WinPadAuto.m): what the D3D9 cube is (alone in a folder, as a game's
  // program), and the variants tried for it.
  NSString* cube_dir = [NSTemporaryDirectory() stringByAppendingPathComponent:@"auto-test"];
  NSString* cube = [cube_dir stringByAppendingPathComponent:@"d3d9-cube.exe"];
  [NSFileManager.defaultManager removeItemAtPath:cube_dir error:nil];
  [NSFileManager.defaultManager createDirectoryAtPath:cube_dir withIntermediateDirectories:YES attributes:nil error:nil];
  [NSFileManager.defaultManager copyItemAtPath:[NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"i386-windows/d3d9-cube.exe"]
                                        toPath:cube
                                         error:nil];
  NSDictionary* cube_traits = WinPadProgramTraits(cube);
  [report appendFormat:@"auto: d3d9-cube.exe | graphics %@ | uses %@ | os %@\n", cube_traits[@"graphics"] ?: @"-",
                       [cube_traits[@"uses"] componentsJoinedByString:@" "] ?: @"-", cube_traits[@"os"] ?: @"-"];
  for (NSDictionary* v in WinPadAutoVariants(cube_traits ?: @{}, @"d3d9-cube.exe", @{}))
    [report appendFormat:@"auto variant: d3d9-cube.exe %@ | %@\n", v[@"id"], v[@"title"]];
  // A start that failed moves on to the next variant; one that ran keeps its variant; and the
  // settings it worked with go into a GitHub issue to share.
  WinPadSetOwnGameSetting(@"Morrowind", nil, nil);
  WinPadRunStarted(@"Morrowind", @"base", @"Výchozí");
  WinPadRunEnded(@"exited", (int)0xc0000005);
  [self judgeLastRun];
  [report appendFormat:@"%@ | own %@\n", self.judgeReport ?: @"judge: nothing", WinPadOwnGameSettings(@"Morrowind")[@"autoVariant"] ?: @"-"];
  NSDictionary* ran = @{@"folder" : @"Morrowind", @"variant" : @"rwx", @"variantTitle" : @"", @"state" : @"running",
                        @"started" : @0, @"seconds" : @120, @"frames" : @5000};
  [[NSJSONSerialization dataWithJSONObject:ran options:0 error:nil]
      writeToFile:[Documents() stringByAppendingPathComponent:@".winpad-lastrun.json"]
       atomically:YES];
  self.judgeReport = nil;
  [self judgeLastRun];
  [report appendFormat:@"%@ | own %@\n", self.judgeReport ?: @"judge: nothing", WinPadOwnGameSettings(@"Morrowind")[@"autoWorked"] ?: @"-"];
  for (WinPadGame* game in self.games)
    if ([game.folder isEqualToString:@"Morrowind"])
      [report appendFormat:@"share: %@\n", [[WinPadGameSettingsViewController alloc] initWithGame:game].shareURL.absoluteString];
  WinPadSetOwnGameSetting(@"Morrowind", nil, nil);
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

// "Přidat hru": a game's folder from Files (on a Mac its Finder), copied into Documents, where
// the library finds it. A copy, not a bookmark: Wine opens the game's files by path.
- (void)pickGameFolder {
  if (self.presentedViewController || self.copyingGame) return;
  UIDocumentPickerViewController* picker = [[UIDocumentPickerViewController alloc] initForOpeningContentTypes:@[ UTTypeFolder ]];
  picker.delegate = self;
  picker.allowsMultipleSelection = NO;
  [self presentViewController:picker animated:YES completion:nil];
}

- (void)documentPicker:(UIDocumentPickerViewController*)picker didPickDocumentsAtURLs:(NSArray<NSURL*>*)urls {
  NSURL* source = urls.firstObject;
  if (!source) return;
  NSString* target = [Documents() stringByAppendingPathComponent:source.lastPathComponent];
  if ([NSFileManager.defaultManager fileExistsAtPath:target]) {
    UIAlertController* alert = [UIAlertController
        alertControllerWithTitle:@"Hra už v knihovně je"
                         message:[NSString stringWithFormat:@"Složka %@ už v knihovně je. Smaž ji nebo přejmenuj tu, "
                                                            @"kterou přidáváš.", source.lastPathComponent]
                  preferredStyle:UIAlertControllerStyleAlert];
    [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
    [self presentViewController:alert animated:YES completion:nil];
    return;
  }
  self.copyingGame = YES;
  NSString* text = self.addGame.text;
  self.addGame.text = [NSString stringWithFormat:@"Kopíruju %@…", source.lastPathComponent];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    const BOOL scoped = [source startAccessingSecurityScopedResource];
    NSError* error = nil;
    // Hidden from the library (WinPadFindGames skips dot folders) until the copy is whole.
    NSString* partial = [Documents() stringByAppendingPathComponent:[NSString stringWithFormat:@".%@.copying", source.lastPathComponent]];
    [NSFileManager.defaultManager removeItemAtPath:partial error:nil];
    BOOL ok = [NSFileManager.defaultManager copyItemAtURL:source toURL:[NSURL fileURLWithPath:partial] error:&error] &&
              [NSFileManager.defaultManager moveItemAtPath:partial toPath:target error:&error];
    if (!ok) [NSFileManager.defaultManager removeItemAtPath:partial error:nil];
    if (scoped) [source stopAccessingSecurityScopedResource];
    dispatch_async(dispatch_get_main_queue(), ^{
      self.copyingGame = NO;
      self.addGame.text = text;
      NSLog(@"WinPad Wine: game folder %@ -> %@: %@", source.path, target, ok ? @"copied" : error);
      if (!ok) {
        UIAlertController* alert =
            [UIAlertController alertControllerWithTitle:@"Hru se nepodařilo zkopírovat"
                                                message:error.localizedDescription ?: @"?"
                                         preferredStyle:UIAlertControllerStyleAlert];
        [alert addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleCancel handler:nil]];
        [self presentViewController:alert animated:YES completion:nil];
        return;
      }
      [NSUserDefaults.standardUserDefaults setObject:target.lastPathComponent forKey:@"lastGame"];
      [self reload];
    });
  });
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
    // A long press: the game's own settings (cover, program, resolution).
    UILongPressGestureRecognizer* hold = [[UILongPressGestureRecognizer alloc] initWithTarget:self
                                                                                       action:@selector(holdCard:)];
    hold.minimumPressDuration = 0.45;
    [card addGestureRecognizer:hold];    [self.row addSubview:card];
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
  self.gog.frame = CGRectMake(m + button + 12, top, button, button);
  self.gog.layer.cornerRadius = button / 2;
  self.jitBadge.frame = CGRectMake(m + 2 * (button + 12), top, MAX(self.jitBadge.bounds.size.width, 120), button);
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

- (void)holdCard:(UILongPressGestureRecognizer*)hold {
  if (hold.state != UIGestureRecognizerStateBegan || hold.view.tag >= (NSInteger)self.games.count) return;
  self.focus = hold.view.tag;
  [self showFocus];
  [[[UIImpactFeedbackGenerator alloc] initWithStyle:UIImpactFeedbackStyleMedium] impactOccurred];
  [self openGameSettingsFor:self.games[self.focus]];
}

- (void)openGameSettingsFor:(WinPadGame*)game {
  if (self.presentedViewController || self.started) return;
  WinPadGameSettingsViewController* settings = [[WinPadGameSettingsViewController alloc] initWithGame:game];
  __weak LibraryViewController* weak = self;
  settings.changed = ^{
    [weak reload];
  };
  settings.coverChanged = ^{
    [weak reload];
  };
  UINavigationController* nav = [[UINavigationController alloc] initWithRootViewController:settings];
  nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
  nav.modalPresentationStyle = UIModalPresentationFormSheet;
  [self presentViewController:nav animated:YES completion:nil];
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
  // What the program is and the automatic settings for it (WinPadAuto.m), under the game's own.
  if (game && ![self prepareAuto:game program:program]) return;
  // The DLLs the game imports and no one has: Microsoft's DirectX ones are downloaded first.
  // 64-bit programs run through ARM64EC (with the JIT), so no question for them any more;
  // ask64BitFor stays behind the ask64Bit setting.
  if (game && !self.archChecked && [game.arch isEqualToString:@"64bit"] &&
      [NSUserDefaults.standardUserDefaults boolForKey:@"ask64Bit"] &&
      ![NSUserDefaults.standardUserDefaults boolForKey:@"libraryTest"]) {
    [self ask64BitFor:game program:program];
    return;
  }
  if (game && !self.dllsChecked && ![self checkDLLsOf:program game:game]) return;
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
  self.dllsChecked = NO;
  self.archChecked = NO;
  self.installerAsked = NO;
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
  NSString* log = [Documents() stringByAppendingPathComponent:@"wine.log"];
  NSDate* date = [NSFileManager.defaultManager attributesOfItemAtPath:log error:nil].fileModificationDate;
  // A second program the game started, which cannot start on iPad (only one 32-bit program
  // runs): SafeDisc's helper (~e5.0001, ~df*.tmp) means a copy protection Wine cannot run.
  NSString* child = WinPadFailedChildOfLastRun();
  NSString* child_key = [NSString stringWithFormat:@"child %@ %.0f", child, date.timeIntervalSince1970];
  if (child && ![[NSUserDefaults.standardUserDefaults stringForKey:@"childOffered"] isEqualToString:child_key]) {
    [NSUserDefaults.standardUserDefaults setObject:child_key forKey:@"childOffered"];
    NSString* lower = child.lowercaseString;
    const BOOL safedisc = [lower hasPrefix:@"~e5"] || [lower hasPrefix:@"~df"] || [lower hasSuffix:@".icd"];
    NSString* text =
        safedisc ? @"Hra je chráněná proti kopírování (SafeDisc): spustila jeho pomocný program, který ve Wine "
                   @"nefunguje. Použij verzi hry bez téhle ochrany, třeba ze Steamu nebo GOG."
                 : [NSString stringWithFormat:@"Hra spustila další program%@, ale na iPadu běží jen jeden. Pokud "
                                              @"je to spouštěč nebo nastavení, podrž dlaždici hry a vyber v Programu "
                                              @"přímo herní .exe.",
                                              child.length ? [NSString stringWithFormat:@" (%@)", child] : @""];
    UIAlertController* said = [UIAlertController alertControllerWithTitle:safedisc ? @"Ochrana proti kopírování"
                                                                                   : @"Hra spouští další program"
                                                                  message:text
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [said addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:said animated:YES completion:nil];
    return;
  }
  NSString* dll = WinPadMissingDLLOfLastRun();
  if (!dll || [WinPadDirectXDLLs() containsObject:dll]) return;
  NSString* key = [NSString stringWithFormat:@"%@ %.0f", dll, date.timeIntervalSince1970];
  if ([[NSUserDefaults.standardUserDefaults stringForKey:@"directXOffered"] isEqualToString:key]) return;
  [NSUserDefaults.standardUserDefaults setObject:key forKey:@"directXOffered"];
  // A DLL no download brings: what it is and what to do, instead of a game that just stopped.
  if (!WinPadDirectXProvides(dll) || WinPadDirectXDLLs().count) {
    NSString* lower = dll.lowercaseString;
    NSString* text =
        [lower hasPrefix:@"steam"]
            ? [NSString stringWithFormat:@"Při posledním spuštění hra nenašla %@: tahle kopie hry potřebuje běžícího klienta "
                                         @"Steamu, a ten na iPadu nepoběží. Použij verzi hry bez DRM (třeba z GOG).",
                                         dll]
        : WinPadDirectXProvides(dll)
            ? [NSString stringWithFormat:@"Při posledním spuštění hra nenašla %@. Stažený DirectX od Microsoftu ji nemá; "
                                         @"nakopíruj ji do složky hry.",
                                         dll]
            : [NSString stringWithFormat:@"Při posledním spuštění hra nenašla %@ a WinPad ji nemá. Pokud se hra nespustila a "
                                         @"máš tu DLL (instalační disk, podsložka hry), nakopíruj ji vedle jejího .exe.",
                                         dll];
    UIAlertController* said = [UIAlertController alertControllerWithTitle:@"Chybí DLL"
                                                                  message:text
                                                           preferredStyle:UIAlertControllerStyleAlert];
    [said addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
    [self presentViewController:said animated:YES completion:nil];
    return;
  }
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

// Before a game runs: looks for DLLs it imports that are nowhere (WinPadMissingDLLsOf). Those
// of Microsoft's DirectX are downloaded right away and the game then starts; others are only
// named, once per game and set of names, since a game may never load them. YES when the game
// can start now; NO when this went on with an alert and starts it (or not) itself.
- (BOOL)checkDLLsOf:(NSString*)program game:(WinPadGame*)game {
  self.dllsChecked = YES;
  // PROGRAM is the app's name for the run ("game"); the game's own program is its exe.
  NSArray<NSString*>* missing = WinPadMissingDLLsOf([Documents() stringByAppendingPathComponent:game.exe],
                                                    [Documents() stringByAppendingPathComponent:game.folder]);
  // Once DirectX is downloaded, what it lacks (xinput1_4...) another download would not bring.
  const BOOL have_directx = WinPadDirectXDLLs().count > 0;
  // Microsoft's DLLs the game's profile asks for (Proton's winetricks d3dx9_43...), which a game
  // may load by name, so its imports do not show them.
  NSArray* want_dx = [game.settings[@"nativeDirectX"] isKindOfClass:NSArray.class] ? game.settings[@"nativeDirectX"] : @[];
  if (!missing.count && (have_directx || !want_dx.count || [game.arch isEqualToString:@"64bit"])) return YES;
  // The download holds the 32-bit DirectX DLLs only: a 64-bit game gets none from it.
  const BOOL x64 = [game.arch isEqualToString:@"64bit"];
  __weak LibraryViewController* weak = self;
  // First the game's own installers (_CommonRedist, DirectX, vcredist...), with no download:
  // what they hold goes into the app's shared folder, then the check runs again.
  NSString* game_dir = [Documents() stringByAppendingPathComponent:game.folder];
  NSString* scanned_key = [@"installersScanned." stringByAppendingString:game.folder];
  if (missing.count && !x64 &&
      ![NSUserDefaults.standardUserDefaults boolForKey:scanned_key] &&
      ![NSUserDefaults.standardUserDefaults boolForKey:@"libraryTest"] && WinPadGameInstallers(game_dir).count) {
    UIAlertController* busy =
        [UIAlertController alertControllerWithTitle:@"Hledám chybějící DLL"
                                            message:[NSString stringWithFormat:@"Hra potřebuje %@. Hledám je "
                                                                               @"v instalačkách ve složce hry…",
                                                                               [missing componentsJoinedByString:@", "]]
                                     preferredStyle:UIAlertControllerStyleAlert];
    [self presentViewController:busy animated:YES completion:nil];
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      const int count = WinPadTakeDLLsFromGameInstallers(game_dir);
      dispatch_async(dispatch_get_main_queue(), ^{
        [NSUserDefaults.standardUserDefaults setBool:YES forKey:scanned_key];
        printf("WinPad Library: %d DLLs out of %s's installers\n", count, game.folder.UTF8String);
        [busy dismissViewControllerAnimated:YES completion:^{
          LibraryViewController* me = weak;
          me.dllsChecked = NO;
          [me startProgram:program game:game];
        }];
      });
    });
    return NO;
  }
  NSMutableArray<NSString*>* fetch = [NSMutableArray new];
  NSMutableArray<NSString*>* others = [NSMutableArray new];
  for (NSString* dll in missing) [WinPadDirectXProvides(dll) && !have_directx && !x64 ? fetch : others addObject:dll];
  if (!have_directx && !x64)
    for (id verb in want_dx)
      if ([verb isKindOfClass:NSString.class] && ![fetch containsObject:verb]) [fetch addObject:verb];
  printf("WinPad Library: %s lacks DLLs: %s\n", game.folder.UTF8String,
         [missing componentsJoinedByString:@", "].UTF8String);
  if ([NSUserDefaults.standardUserDefaults boolForKey:@"libraryTest"]) return YES;
  void (^start)(void) = ^{
    [weak startProgram:program game:game];
  };
  void (^cancel)(void) = ^{
    weak.dllsChecked = NO;
    weak.jitAsked = NO;
  };
  if (fetch.count && !WinPadDirectXDownloading()) {
    UIAlertController* busy = [UIAlertController
        alertControllerWithTitle:@"Stahuji chybějící DLL"
                         message:[NSString stringWithFormat:@"Hra potřebuje %@ z DirectX od Microsoftu. Stahuji ho "
                                                            @"přímo od Microsoftu (asi 95 MB)…",
                                                            [fetch componentsJoinedByString:@", "]]
                  preferredStyle:UIAlertControllerStyleAlert];
    NSString* intro = busy.message;
    [self presentViewController:busy animated:YES completion:nil];
    WinPadDirectXDownload(
        ^(double fraction) {
          busy.message = fraction < 1 ? [NSString stringWithFormat:@"%@\n%d %%", intro, (int)(fraction * 100)]
                                      : [intro stringByAppendingString:@"\nRozbaluji…"];
        },
        ^(NSString* error) {
          [busy dismissViewControllerAnimated:YES completion:^{
            LibraryViewController* me = weak;
            if (!me) return;
            NSMutableArray* still = [NSMutableArray new];
            for (NSString* dll in fetch)
              if (![WinPadDirectXDLLs() containsObject:dll] && !WinPadDirectXDLLsForVerbs(@[ dll ]).count)
                [still addObject:dll];
            [still addObjectsFromArray:others];
            if (!error && !still.count) {
              start();
              return;
            }
            // DirectX came, the rest may be Visual C++'s: the check runs again.
            if (!error) {
              BOOL vc = NO;
              for (NSString* dll in others)
                if (WinPadVCRedistYearOf(dll) &&
                    ![NSUserDefaults.standardUserDefaults
                        boolForKey:[NSString stringWithFormat:@"vcredist%d", WinPadVCRedistYearOf(dll)]])
                  vc = YES;
              if (vc) {
                me.dllsChecked = NO;
                start();
                return;
              }
            }
            NSString* text = error ? [NSString stringWithFormat:@"DirectX se nestáhl: %@\n\nChybí: %@", error,
                                                                [still componentsJoinedByString:@", "]]
                                   : [NSString stringWithFormat:@"Tyhle DLL nemá ani DirectX od Microsoftu: %@",
                                                                [still componentsJoinedByString:@", "]];
            [me askToStartWithout:text start:start cancel:cancel];
          }];
        });
    return NO;
  }
  if (!missing.count) return YES;
  // Microsoft's Visual C++ runtime (MFC above all, Wine has its own C runtimes): its installer
  // for the year of the first such DLL, once per year; then the check runs again.
  int year = 0;
  for (NSString* dll in missing) {
    const int y = x64 ? 0 : WinPadVCRedistYearOf(dll);
    if (y && ![NSUserDefaults.standardUserDefaults boolForKey:[NSString stringWithFormat:@"vcredist%d", y]]) {
      year = y;
      break;
    }
  }
  if (year && !WinPadDirectXDownloading()) {
    NSMutableArray* names = [NSMutableArray new];
    for (NSString* dll in missing)
      if (WinPadVCRedistYearOf(dll) == year) [names addObject:dll];
    UIAlertController* busy = [UIAlertController
        alertControllerWithTitle:@"Stahuji chybějící DLL"
                         message:[NSString stringWithFormat:@"Hra potřebuje %@ z Visual C++ %d. Stahuji ho přímo od "
                                                            @"Microsoftu…",
                                                            [names componentsJoinedByString:@", "], year]
                  preferredStyle:UIAlertControllerStyleAlert];
    NSString* intro = busy.message;
    [self presentViewController:busy animated:YES completion:nil];
    WinPadVCRedistDownload(
        year,
        ^(double fraction) {
          busy.message = fraction < 1 ? [NSString stringWithFormat:@"%@\n%d %%", intro, (int)(fraction * 100)]
                                      : [intro stringByAppendingString:@"\nRozbaluji…"];
        },
        ^(NSString* error) {
          [busy dismissViewControllerAnimated:YES completion:^{
            LibraryViewController* me = weak;
            if (!me) return;
            if (error) {
              [me askToStartWithout:[NSString stringWithFormat:@"Visual C++ %d se nestáhl: %@\n\nChybí: %@", year, error,
                                                               [names componentsJoinedByString:@", "]]
                              start:start
                             cancel:cancel];
              return;
            }
            me.dllsChecked = NO;
            start();
          }];
        });
    return NO;
  }
  // NVIDIA's PhysX runtime (PhysXLoader.dll...), which games of 2006-2010 import: its legacy
  // package from NVIDIA, once; then the check runs again.
  NSMutableArray* physx = [NSMutableArray new];
  for (NSString* dll in missing)
    if (WinPadPhysXProvides(dll)) [physx addObject:dll];
  if (physx.count && !x64 && ![NSUserDefaults.standardUserDefaults boolForKey:@"physxDownloaded"] &&
      !WinPadDirectXDownloading()) {
    UIAlertController* busy = [UIAlertController
        alertControllerWithTitle:@"Stahuji chybějící DLL"
                         message:[NSString stringWithFormat:@"Hra potřebuje %@ z PhysX. Stahuji ho přímo od NVIDIE…",
                                                            [physx componentsJoinedByString:@", "]]
                  preferredStyle:UIAlertControllerStyleAlert];
    NSString* intro = busy.message;
    [self presentViewController:busy animated:YES completion:nil];
    WinPadPhysXDownload(
        ^(double fraction) {
          busy.message = fraction < 1 ? [NSString stringWithFormat:@"%@\n%d %%", intro, (int)(fraction * 100)]
                                      : [intro stringByAppendingString:@"\nRozbaluji…"];
        },
        ^(NSString* error) {
          [busy dismissViewControllerAnimated:YES completion:^{
            LibraryViewController* me = weak;
            if (!me) return;
            if (error) {
              [me askToStartWithout:[NSString stringWithFormat:@"PhysX se nestáhl: %@\n\nChybí: %@", error,
                                                               [physx componentsJoinedByString:@", "]]
                              start:start
                             cancel:cancel];
              return;
            }
            me.dllsChecked = NO;
            start();
          }];
        });
    return NO;
  }
  // Only DLLs the app cannot get: said once for this game and these names.
  NSString* key = [@"dllsMissing." stringByAppendingString:game.folder];
  NSString* names = [missing componentsJoinedByString:@", "];
  if ([[NSUserDefaults.standardUserDefaults stringForKey:key] isEqualToString:names]) return YES;
  [NSUserDefaults.standardUserDefaults setObject:names forKey:key];
  NSString* why = [missing containsObject:@"mscoree.dll"]
                      ? @" Hra je pro .NET (mscoree.dll), a ten WinPad zatím neumí."
                      : @"";
  [self askToStartWithout:[NSString stringWithFormat:@"Hra importuje DLL, které WinPad nemá a neumí stáhnout: %@. "
                                                     @"Pokud je hra opravdu načte, nespustí se. Můžeš je nakopírovat "
                                                     @"do složky hry.%@",
                                                     names, why]
                    start:start
                   cancel:cancel];
  return NO;
}

// GAME's program is 64-bit: WinPad runs 32-bit Windows programs (64-bit ones are not done
// yet), so it would stop at once. Offers the folder's 32-bit program, which many games have
// next to the 64-bit one (and saves it as the game's own pick), or to try anyway.
- (void)ask64BitFor:(WinPadGame*)game program:(NSString*)program {
  NSString* dir = [Documents() stringByAppendingPathComponent:game.folder];
  NSString* other = Best32BitProgram(dir);
  NSString* text = other ? [NSString stringWithFormat:@"%@ je 64bitový program a ty WinPad zatím neumí. Hra má i "
                                                      @"32bitový %@: spustit ten?",
                                                      game.exe.lastPathComponent, other]
                         : [NSString stringWithFormat:@"%@ je 64bitový program a ty WinPad zatím neumí, takže hra "
                                                      @"nejspíš hned skončí. Zkus 32bitovou verzi hry, pokud nějaká je.",
                                                      game.exe.lastPathComponent];
  UIAlertController* ask = [UIAlertController alertControllerWithTitle:@"64bitová hra"
                                                               message:text
                                                        preferredStyle:UIAlertControllerStyleAlert];
  __weak LibraryViewController* weak = self;
  if (other)
    [ask addAction:[UIAlertAction actionWithTitle:[@"Spustit " stringByAppendingString:other.lastPathComponent]
                                            style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction* action) {
                                            LibraryViewController* me = weak;
                                            WinPadSetOwnGameSetting(game.folder, @"exe", other);
                                            [me reload];
                                            for (WinPadGame* g in me.games)
                                              if ([g.folder isEqualToString:game.folder]) {
                                                me.archChecked = YES;
                                                [me startProgram:program game:g];
                                              }
                                          }]];
  [ask addAction:[UIAlertAction actionWithTitle:@"Zkusit i tak"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction* action) {
                                          weak.archChecked = YES;
                                          [weak startProgram:program game:game];
                                        }]];
  [ask addAction:[UIAlertAction actionWithTitle:@"Zrušit" style:UIAlertActionStyleCancel handler:nil]];
  [self presentViewController:ask animated:YES completion:nil];
}

// Before a game starts: what its program is (WinPadProgramTraits) and the settings variant of
// this run (WinPadSettingsWithAuto: the one that worked, else the next to try), under the
// game's own settings. An installer or a .NET program is said first. YES when the start goes on.
- (BOOL)prepareAuto:(WinPadGame*)game program:(NSString*)program {
  NSDictionary* traits = WinPadProgramTraits([Documents() stringByAppendingPathComponent:game.exe]);
  game.traits = traits;
  NSDictionary* plain = game.plainSettings ?: game.settings ?: @{};
  game.plainSettings = plain;
  NSDictionary* variant = nil;
  game.settings = WinPadSettingsWithAuto(traits ?: @{}, game.exe.lastPathComponent, plain, WinPadOwnGameSettings(game.folder), &variant);
  game.autoVariant = variant;
  printf("WinPad Library: %s: graphics %s, automatic settings %s\n", game.folder.UTF8String,
         [(traits[@"graphics"] ?: @"?") UTF8String], [(variant[@"id"] ?: @"-") UTF8String]);
  if (self.installerAsked || [NSUserDefaults.standardUserDefaults boolForKey:@"libraryTest"]) return YES;
  NSString* installer = WinPadInstallerName(traits);
  const BOOL dotnet = [traits[@"uses"] containsObject:@"dotnet"];
  if (!installer && !dotnet) return YES;
  NSString* text =
      installer
          ? [NSString stringWithFormat:@"%@ je instalačka (%@), ne samotná hra. Instalačky na iPadu většinou nedoběhnou, protože "
                                       @"spouštějí další programy. Nainstaluj hru na počítači a nakopíruj sem nainstalovanou "
                                       @"složku, nebo hru z GOG nainstaluj přímo v aplikaci.",
                                       game.exe.lastPathComponent, installer]
          : [NSString stringWithFormat:@"%@ je program pro .NET. Ten WinPad zatím neumí (chybí mu Wine Mono), takže se "
                                       @"nejspíš nespustí.",
                                       game.exe.lastPathComponent];
  UIAlertController* ask = [UIAlertController alertControllerWithTitle:installer ? @"Instalačka hry" : @"Hra pro .NET"
                                                               message:text
                                                        preferredStyle:UIAlertControllerStyleAlert];
  __weak LibraryViewController* weak = self;
  if (installer && WinPadGamePrograms(game.folder).count > 1)
    [ask addAction:[UIAlertAction actionWithTitle:@"Vybrat jiný program"
                                            style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction* action) {
                                            [weak openGameSettingsFor:game];
                                          }]];
  [ask addAction:[UIAlertAction actionWithTitle:@"Spustit i tak"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction* action) {
                                          weak.installerAsked = YES;
                                          [weak startProgram:program game:game];
                                        }]];
  [ask addAction:[UIAlertAction actionWithTitle:@"Zrušit" style:UIAlertActionStyleCancel handler:nil]];
  [self presentViewController:ask animated:YES completion:nil];
  return NO;
}

// The last game run, once (WinPadJudgeLastRun): a start that worked keeps its settings variant
// for the game; one that failed (crashed, an error, next to nothing drawn in its first 20 s)
// moves on to the next variant and offers to start again. A missing DLL or a second program
// is offerDirectX's to say. YES when this showed something.
- (BOOL)judgeLastRun {
  NSDictionary* run = WinPadJudgeLastRun();
  if (!run) return NO;
  NSString* folder = run[@"folder"];
  NSDictionary* own = WinPadOwnGameSettings(folder);
  WinPadGame* game = nil;
  for (WinPadGame* g in self.games)
    if ([g.folder isEqualToString:folder]) game = g;
  printf("WinPad Library: last run of %s: %s (%lds, %ld frames, variant %s)\n", folder.UTF8String,
         [run[@"ok"] boolValue] ? "worked" : [run[@"why"] UTF8String], [run[@"seconds"] longValue],
         [run[@"frames"] longValue], [run[@"variant"] UTF8String]);
  if ([run[@"ok"] boolValue]) {
    if ([run[@"variant"] length] && ![own[@"autoWorked"] isEqual:run[@"variant"]]) {
      WinPadSetOwnGameSetting(folder, @"autoWorked", run[@"variant"]);
      WinPadSetOwnGameSetting(folder, @"autoVariant", nil);
    }
    self.judgeReport = [NSString stringWithFormat:@"judge: %@ | worked | %@", folder, run[@"variant"]];
    return NO;
  }
  // A variant that once worked stays: a later crash is the game's, not its setup's.
  if (!game || own[@"autoWorked"] || [own[@"autoExhausted"] boolValue]) return NO;
  if (![NSUserDefaults.standardUserDefaults boolForKey:@"libraryTest"] &&
      (WinPadMissingDLLOfLastRun() || WinPadFailedChildOfLastRun()))
    return NO;
  NSDictionary* traits = WinPadProgramTraits([Documents() stringByAppendingPathComponent:game.exe]);
  NSArray<NSDictionary*>* variants = WinPadAutoVariants(traits ?: @{}, game.exe.lastPathComponent, game.settings ?: @{});
  NSUInteger at = 0;
  for (NSUInteger i = 0; i < variants.count; i++)
    if ([variants[i][@"id"] isEqual:run[@"variant"]]) at = i;
  NSDictionary* next = at + 1 < variants.count ? variants[at + 1] : nil;
  WinPadSetOwnGameSetting(folder, @"autoVariant", next[@"id"]);
  if (!next) WinPadSetOwnGameSetting(folder, @"autoExhausted", @YES);
  self.judgeReport = [NSString stringWithFormat:@"judge: %@ | %@ | next %@", folder, run[@"why"], next[@"id"] ?: @"none"];
  if ([NSUserDefaults.standardUserDefaults boolForKey:@"libraryTest"]) return NO;
  NSString* text =
      next ? [NSString stringWithFormat:@"%@ %@. Zkusím ji spustit s jiným nastavením: %@.", game.title, run[@"why"], next[@"title"]]
           : [NSString stringWithFormat:@"%@ %@. Vyzkoušel jsem všech %lu automatických nastavení a žádné nepomohlo. "
                                        @"Podívej se do Nastavení › Poslední log, nebo v nastavení hry (podrž její dlaždici) "
                                        @"vyber jiný program.",
                                        game.title, run[@"why"], (unsigned long)variants.count];
  UIAlertController* ask = [UIAlertController alertControllerWithTitle:@"Hra se nespustila"
                                                               message:text
                                                        preferredStyle:UIAlertControllerStyleAlert];
  __weak LibraryViewController* weak = self;
  if (next) {
    [ask addAction:[UIAlertAction actionWithTitle:@"Později" style:UIAlertActionStyleCancel handler:nil]];
    [ask addAction:[UIAlertAction actionWithTitle:@"Spustit znovu"
                                            style:UIAlertActionStyleDefault
                                          handler:^(UIAlertAction* action) {
                                            LibraryViewController* me = weak;
                                            [me reload];
                                            for (WinPadGame* g in me.games)
                                              if ([g.folder isEqualToString:folder]) {
                                                [me focusFolder:folder];
                                                [me startProgram:@"game" game:g];
                                              }
                                          }]];
  } else {
    [ask addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
  }
  [self presentViewController:ask animated:YES completion:nil];
  return YES;
}

- (void)askToStartWithout:(NSString*)text start:(void (^)(void))start cancel:(void (^)(void))cancel {
  UIAlertController* ask = [UIAlertController alertControllerWithTitle:@"Chybí DLL"
                                                               message:text
                                                        preferredStyle:UIAlertControllerStyleAlert];
  [ask addAction:[UIAlertAction actionWithTitle:@"Zrušit"
                                          style:UIAlertActionStyleCancel
                                        handler:^(UIAlertAction* action) {
                                          cancel();
                                        }]];
  [ask addAction:[UIAlertAction actionWithTitle:@"Spustit i tak"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction* action) {
                                          start();
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

- (void)openGOG {
  if (self.presentedViewController || self.started) return;
  UINavigationController* nav = [[UINavigationController alloc] initWithRootViewController:[WinPadGOGViewController new]];
  nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
  nav.modalPresentationStyle = UIModalPresentationFormSheet;
  [self presentViewController:nav animated:YES completion:nil];
}

// A game came from GOG (GOG.m): the library shows it, focused.
- (void)gogInstalled:(NSNotification*)note {
  [self reload];
  if ([note.object isKindOfClass:NSString.class]) [self focusFolder:note.object];
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
