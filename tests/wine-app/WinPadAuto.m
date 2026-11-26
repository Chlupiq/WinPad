// SPDX-License-Identifier: MIT
// WinPadAuto.h: a game's settings from what its program is, and the variants tried after a
// start that failed.
#import "WinPadAuto.h"

#include <stdio.h>

#include "GameDetect.h"
#include "Redist.h"

static NSString* DocumentsFile(NSString* name) {
  return [NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject
      stringByAppendingPathComponent:name];
}

static void AddImport(const char* dll, void* ctx) {
  winpad_traits_add_import(ctx, dll);
}

static NSArray<NSString*>* UsesNames(unsigned uses) {
  static const struct {
    unsigned bit;
    const char* name;
  } names[] = {
      {WINPAD_USES_DINPUT, "dinput"}, {WINPAD_USES_XINPUT, "xinput"},  {WINPAD_USES_DSOUND, "dsound"},
      {WINPAD_USES_XAUDIO, "xaudio"}, {WINPAD_USES_OPENAL, "openal"},  {WINPAD_USES_DOTNET, "dotnet"},
      {WINPAD_USES_PHYSX, "physx"},   {WINPAD_USES_STEAM, "steam"},    {WINPAD_USES_D3DX, "d3dx"},
      {WINPAD_USES_VCRUNTIME, "vcruntime"}, {WINPAD_USES_DDRAW, "ddraw"},
  };
  NSMutableArray* out = [NSMutableArray new];
  for (size_t i = 0; i < sizeof(names) / sizeof(names[0]); i++)
    if (uses & names[i].bit) [out addObject:@(names[i].name)];
  return out;
}

// GameDetect.c's look at FILES (the program first): its header, all their imports, whether
// the program is an installer.
static NSDictionary* Read(NSString* exe, NSArray<NSString*>* files) {
  struct winpad_traits t = {0};
  if (winpad_pe_header(exe.fileSystemRepresentation, &t)) return nil;
  for (NSString* file in files) {
    char err[256];
    winpad_pe_imports(file.fileSystemRepresentation, AddImport, &t, err, sizeof(err));
  }
  NSMutableDictionary* out = [@{
    @"machine" : @(t.machine),
    @"subsystem" : @(t.subsystem),
    @"os" : @(t.os_major),
    @"linker" : @(t.linker_major),
    @"graphics" : @(winpad_graphics_name(t.graphics)),
    @"uses" : UsesNames(t.uses),
  } mutableCopy];
  char kind[32] = "";
  if (winpad_installer_kind(exe.fileSystemRepresentation, kind, sizeof(kind)) > 0) out[@"installer"] = @(kind);
  return out;
}

static NSString* FileKey(NSString* path) {
  NSDictionary* attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
  if (!attrs) return nil;
  return [NSString stringWithFormat:@"%@|%llu|%.0f", path.lastPathComponent, attrs.fileSize,
                                    attrs.fileModificationDate.timeIntervalSince1970];
}

NSDictionary* WinPadQuickTraits(NSString* exe) {
  static NSCache* cache;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    cache = [NSCache new];
  });
  NSString* key = FileKey(exe);
  if (!key) return nil;
  key = [exe stringByAppendingFormat:@"|%@", key];
  id had = [cache objectForKey:key];
  if (had) return had == NSNull.null ? nil : had;
  // A program of hundreds of MB (a game with its data inside) is a game, not a tool: not read.
  const unsigned long long size = [NSFileManager.defaultManager attributesOfItemAtPath:exe error:nil].fileSize;
  NSDictionary* t = size < 96ull * 1024 * 1024 ? Read(exe, @[ exe ]) : nil;
  [cache setObject:t ?: NSNull.null forKey:key];
  return t;
}

static NSString* DetectCachePath(void) {
  return DocumentsFile(@".winpad-games/.detect.json");
}

NSDictionary* WinPadProgramTraits(NSString* exe) {
  NSFileManager* fm = NSFileManager.defaultManager;
  NSString* dir = exe.stringByDeletingLastPathComponent;
  NSMutableArray* files = [NSMutableArray arrayWithObject:exe];
  NSMutableString* key = [NSMutableString stringWithString:exe];
  NSString* own = FileKey(exe);
  if (!own) return nil;
  [key appendFormat:@"|%@", own];
  BOOL asi = NO;
  for (NSString* name in [[fm contentsOfDirectoryAtPath:dir error:nil] sortedArrayUsingSelector:@selector(compare:)]) {
    NSString* ext = name.pathExtension.lowercaseString;
    if (![ext isEqualToString:@"dll"] && ![ext isEqualToString:@"asi"]) continue;
    if ([name.lowercaseString isEqualToString:@"dinput8.dll"]) asi = YES;
    NSString* path = [dir stringByAppendingPathComponent:name];
    [files addObject:path];
    [key appendFormat:@"|%@", FileKey(path) ?: name];
  }
  NSString* cache_path = DetectCachePath();
  NSData* json = [NSData dataWithContentsOfFile:cache_path];
  NSMutableDictionary* cache = nil;
  id obj = json ? [NSJSONSerialization JSONObjectWithData:json options:NSJSONReadingMutableContainers error:nil] : nil;
  if ([obj isKindOfClass:NSMutableDictionary.class]) cache = obj;
  NSDictionary* entry = [cache[exe] isKindOfClass:NSDictionary.class] ? cache[exe] : nil;
  if ([entry[@"key"] isEqual:key] && [entry[@"traits"] isKindOfClass:NSDictionary.class]) return entry[@"traits"];
  NSMutableDictionary* t = [Read(exe, files) mutableCopy];
  if (!t) return nil;
  if (asi) t[@"asiLoader"] = @YES;
  if (!cache) cache = [NSMutableDictionary new];
  cache[exe] = @{@"key" : key, @"traits" : t};
  [fm createDirectoryAtPath:cache_path.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
  [[NSJSONSerialization dataWithJSONObject:cache options:0 error:nil] writeToFile:cache_path atomically:YES];
  printf("WinPad: %s: %s\n", exe.lastPathComponent.UTF8String,
         [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:t options:NSJSONWritingSortedKeys error:nil]
                               encoding:NSUTF8StringEncoding]
             .UTF8String);
  return t;
}

static BOOL Uses(NSDictionary* traits, NSString* what) {
  return [traits[@"uses"] isKindOfClass:NSArray.class] && [traits[@"uses"] containsObject:what];
}

BOOL WinPadTraitsLookLikeGame(NSDictionary* traits) {
  if (!traits) return NO;
  return ![traits[@"graphics"] isEqual:@"unknown"] || Uses(traits, @"dinput") || Uses(traits, @"xinput");
}

NSString* WinPadInstallerName(NSDictionary* traits) {
  NSString* kind = traits[@"installer"];
  if (![kind isKindOfClass:NSString.class]) return nil;
  return @{
    @"inno" : @"Inno Setup",
    @"nsis" : @"NSIS",
    @"installshield" : @"InstallShield",
    @"wise" : @"Wise",
    @"wixburn" : @"WiX",
    @"setupfactory" : @"Setup Factory",
    @"cab" : @"samorozbalovací archiv",
    @"msi" : @"Windows Installer",
    @"7zsfx" : @"7-Zip",
  }[kind] ?: kind;
}

NSString* WinPadGraphicsName(NSDictionary* traits) {
  return @{
    @"glide" : @"3dfx Glide",
    @"ddraw" : @"DirectDraw",
    @"opengl" : @"OpenGL",
    @"vulkan" : @"Vulkan",
    @"d3d8" : @"DirectX 8",
    @"d3d9" : @"DirectX 9",
    @"d3d10" : @"DirectX 10",
    @"d3d11" : @"DirectX 11",
    @"d3d12" : @"DirectX 12",
  }[traits[@"graphics"] ?: @""];
}

// SETTINGS[KEY] as a dictionary, or empty.
static NSDictionary* Dict(NSDictionary* settings, NSString* key) {
  return [settings[key] isKindOfClass:NSDictionary.class] ? settings[key] : @{};
}

static NSDictionary* Merge(NSDictionary* base, NSDictionary* top) {
  NSMutableDictionary* out = [base mutableCopy];
  for (NSString* key in top) {
    id mine = top[key], theirs = out[key];
    if ([@[ @"dllOverrides", @"env", @"registry", @"registryForce", @"padKeys" ] containsObject:key] &&
        [mine isKindOfClass:NSDictionary.class] && [theirs isKindOfClass:NSDictionary.class]) {
      NSMutableDictionary* merged = [theirs mutableCopy];
      for (NSString* k in mine) {
        if ([key hasPrefix:@"registry"] && [mine[k] isKindOfClass:NSDictionary.class] &&
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

// Whether SETTINGS' registry has the value NAME of KEY (any case).
static BOOL HasRegistryValue(NSDictionary* settings, NSString* key, NSString* name) {
  for (NSString* k in Dict(settings, @"registry"))
    if ([k caseInsensitiveCompare:key] == NSOrderedSame)
      for (NSString* n in Dict(Dict(settings, @"registry"), k))
        if ([n caseInsensitiveCompare:name] == NSOrderedSame) return YES;
  return NO;
}

NSArray<NSDictionary*>* WinPadAutoVariants(NSDictionary* traits, NSString* exeName, NSDictionary* settings) {
  if (!traits.count) return @[ @{@"id" : @"base", @"title" : @"Výchozí", @"settings" : @{}} ];
  const BOOL x86 = [traits[@"machine"] integerValue] == 0x14c;
  NSString* graphics = traits[@"graphics"];
  NSString* app_key = [@"HKCU\\Software\\Wine\\AppDefaults\\" stringByAppendingString:exeName];
  NSString* d3d_key = [app_key stringByAppendingString:@"\\Direct3D"];
  NSMutableDictionary* base = [NSMutableDictionary new];
  NSMutableDictionary* force = [NSMutableDictionary new];
  NSMutableArray<NSString*>* said = [NSMutableArray new];
  // DirectDraw without Direct3D draws through wined3d: its GDI renderer needs no OpenGL and
  // suits 2D games (StarCraft, Diablo, Age of Empires...); a variant tries OpenGL.
  const BOOL ddraw = [graphics isEqual:@"ddraw"] && !HasRegistryValue(settings, d3d_key, @"renderer");
  if (ddraw) {
    force[d3d_key] = @{@"renderer" : @"gdi"};
    [said addObject:@"DirectDraw přes GDI"];
  }
  // The Windows version: Wine's own unless a variant says another (written each run, so a
  // variant that did not work does not stay in the registry).
  const BOOL winver = !settings[@"windowsVersion"] && !HasRegistryValue(settings, app_key, @"Version");
  if (winver) force[app_key] = @{@"Version" : @"win10"};
  // A game of Direct3D 9 and newer lists the monitor's modes: a monitor of the display's shape.
  const BOOL wide = [@[ @"d3d9", @"d3d10", @"d3d11", @"d3d12", @"vulkan" ] containsObject:graphics] && !settings[@"screen"];
  if (wide) {
    base[@"autoScreen"] = @"wide";
    [said addObject:@"širokoúhlý monitor"];
  }
  // A game without DirectInput and XInput reads the keyboard and the mouse as windows do: the
  // controller's right stick moves the mouse.
  if (![graphics isEqual:@"unknown"] && !Uses(traits, @"dinput") && !Uses(traits, @"xinput") && !settings[@"padMouse"]) {
    base[@"padMouse"] = @"right";
    [said addObject:@"pravá páčka ovládá myš"];
  }
  // A game that reads an Xbox controller gets the controllers as one (Wine's xinput through
  // Madeira's bridge, main.m), not as keys. DirectInput alone says nothing of a joystick
  // (most games read the keyboard with it), so those keep the keys; the game's settings
  // can make it a HID controller ("hid").
  if (Uses(traits, @"xinput") && !settings[@"padMode"]) {
    base[@"padMode"] = @"xinput";
    [said addObject:@"ovladač jako Xbox"];
  }
  if (force.count) base[@"registryForce"] = force;
  NSMutableArray* variants = [NSMutableArray new];
  [variants addObject:@{
    @"id" : @"base",
    @"title" : said.count ? [@"Výchozí: " stringByAppendingString:[said componentsJoinedByString:@", "]] : @"Výchozí",
    @"settings" : base
  }];
  void (^add)(NSString*, NSString*, NSDictionary*) = ^(NSString* vid, NSString* title, NSDictionary* delta) {
    [variants addObject:@{@"id" : vid, @"title" : title, @"settings" : Merge(base, delta)}];
  };
  // The Ultimate ASI Loader (a dinput8.dll of the game's) and its plugins: off.
  if ([traits[@"asiLoader"] boolValue] && !Dict(settings, @"dllOverrides")[@"dinput8"])
    add(@"no-asi", @"Bez pluginů ASI (dinput8.dll ze složky hry vypnutá)", @{@"dllOverrides" : @{@"dinput8" : @"b"}});
  // Microsoft's DirectX DLLs in place of Wine's (downloaded first, 32-bit only).
  NSMutableArray* verbs = [NSMutableArray new];
  if (Uses(traits, @"d3dx") || [graphics isEqual:@"d3d9"]) [verbs addObject:@"d3dx9"];
  if (Uses(traits, @"xaudio")) [verbs addObject:@"xact"];
  // Not xinput: Microsoft's sees no controller here, Wine's gets the iPad's.
  if (x86 && verbs.count && !settings[@"nativeDirectX"])
    add(@"ms-directx", @"DirectX od Microsoftu místo Wine", @{@"nativeDirectX" : verbs});
  if (ddraw) add(@"ddraw-gl", @"DirectDraw přes OpenGL", @{@"registryForce" : @{d3d_key : @{@"renderer" : @"gl"}}});
  if (wide) add(@"screen-4-3", @"Monitor 4:3 (1024×768)", @{@"autoScreen" : @"4:3"});
  if (x86 && !Dict(settings, @"env")[@"MADEIRA_WOW_RWX_PLAIN"])
    add(@"rwx", @"Jiné mapování spustitelné paměti", @{@"env" : @{@"MADEIRA_WOW_RWX_PLAIN" : @"0"}});
  // Programs of the Windows 9x and XP days (linked for Windows 4 or 5) as on Windows XP, newer
  // ones as on Windows 7.
  if (winver) {
    const BOOL old = [traits[@"os"] integerValue] > 0 && [traits[@"os"] integerValue] <= 5;
    add(old ? @"winxp" : @"win7", old ? @"Jako Windows XP" : @"Jako Windows 7",
        @{@"registryForce" : @{app_key : @{@"Version" : old ? @"winxp" : @"win7"}}});
  }
  return variants;
}

NSDictionary* WinPadSettingsWithAuto(NSDictionary* traits, NSString* exeName, NSDictionary* settings, NSDictionary* state,
                                     NSDictionary** variant) {
  NSArray<NSDictionary*>* variants = WinPadAutoVariants(traits, exeName, settings);
  NSDictionary* pick = variants.firstObject;
  NSString* worked = [state[@"autoWorked"] isKindOfClass:NSString.class] ? state[@"autoWorked"] : nil;
  NSString* next = [state[@"autoVariant"] isKindOfClass:NSString.class] ? state[@"autoVariant"] : nil;
  for (NSDictionary* v in variants)
    if ([v[@"id"] isEqual:worked ?: next]) pick = v;
  if (variant) *variant = pick;
  return Merge(pick[@"settings"], settings);
}

static NSString* RunPath(void) {
  return DocumentsFile(@".winpad-lastrun.json");
}

static NSMutableDictionary* run;

static void SaveRun(void) {
  if (!run) return;
  [[NSJSONSerialization dataWithJSONObject:run options:0 error:nil] writeToFile:RunPath() atomically:YES];
}

void WinPadRunStarted(NSString* folder, NSString* variant, NSString* variantTitle) {
  @synchronized(NSFileManager.class) {
    run = [@{
      @"folder" : folder,
      @"variant" : variant ?: @"",
      @"variantTitle" : variantTitle ?: @"",
      @"started" : @(NSDate.date.timeIntervalSince1970),
      @"seconds" : @0,
      @"frames" : @0,
      @"state" : @"running",
    } mutableCopy];
    SaveRun();
  }
}

void WinPadRunProgress(long frames) {
  @synchronized(NSFileManager.class) {
    if (!run || ![run[@"state"] isEqual:@"running"]) return;
    run[@"seconds"] = @((long)(NSDate.date.timeIntervalSince1970 - [run[@"started"] doubleValue]));
    run[@"frames"] = @(frames);
    SaveRun();
  }
}

void WinPadRunEnded(NSString* how, int exitCode) {
  @synchronized(NSFileManager.class) {
    if (!run || ![run[@"state"] isEqual:@"running"]) return;
    run[@"seconds"] = @((long)(NSDate.date.timeIntervalSince1970 - [run[@"started"] doubleValue]));
    run[@"state"] = how;
    run[@"exitCode"] = @(exitCode);
    SaveRun();
  }
}

NSDictionary* WinPadJudgeLastRun(void) {
  NSData* json = [NSData dataWithContentsOfFile:RunPath()];
  id obj = json ? [NSJSONSerialization JSONObjectWithData:json options:NSJSONReadingMutableContainers error:nil] : nil;
  if (![obj isKindOfClass:NSMutableDictionary.class] || [obj[@"judged"] boolValue]) return nil;
  NSMutableDictionary* rec = obj;
  rec[@"judged"] = @YES;
  [[NSJSONSerialization dataWithJSONObject:rec options:0 error:nil] writeToFile:RunPath() atomically:YES];
  NSString* state = rec[@"state"];
  if ([state isEqual:@"handoff"] || ![rec[@"folder"] isKindOfClass:NSString.class]) return nil;
  const long seconds = [rec[@"seconds"] longValue], frames = [rec[@"frames"] longValue];
  const int code = [rec[@"exitCode"] intValue];
  // A game is ended by Exit, by closing the app or by itself. It did not work when it stopped
  // with an error within a minute and a half, or within 20 s having drawn next to nothing (a
  // black screen the player left, a message box and out).
  NSString* why = nil;
  if ([state isEqual:@"exited"] && code != 0 && seconds < 90)
    why = [NSString stringWithFormat:@"skončila s chybou %#x po %ld s", code, seconds];
  else if (seconds < 20 && frames < 30)
    why = [state isEqual:@"running"]    ? [NSString stringWithFormat:@"spadla po %ld s", seconds]
          : [state isEqual:@"player"] ? [NSString stringWithFormat:@"ukončil jsi ji po %ld s bez obrazu", seconds]
                                      : [NSString stringWithFormat:@"skončila po %ld s", seconds];
  NSMutableDictionary* out = [@{
    @"folder" : rec[@"folder"],
    @"variant" : rec[@"variant"] ?: @"",
    @"variantTitle" : rec[@"variantTitle"] ?: @"",
    @"ok" : @(why == nil),
    @"seconds" : @(seconds),
    @"frames" : @(frames),
  } mutableCopy];
  if (why) out[@"why"] = why;
  return out;
}
