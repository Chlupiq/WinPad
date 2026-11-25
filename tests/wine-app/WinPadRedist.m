// SPDX-License-Identifier: MIT
// Microsoft's DirectX DLLs for the games, see WinPadRedist.h and Redist.h.
#import "WinPadRedist.h"

#include "Redist.h"

static NSString* DocumentsFile(NSString* name) {
  NSString* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
  return [docs stringByAppendingPathComponent:name];
}

NSString* WinPadDirectXDir(void) {
  return DocumentsFile(@".redist/directx");
}

NSArray<NSString*>* WinPadDirectXDLLs(void) {
  NSMutableArray* dlls = [NSMutableArray new];
  for (NSString* name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:WinPadDirectXDir() error:nil])
    if ([name.pathExtension isEqualToString:@"dll"]) [dlls addObject:name];
  return [dlls sortedArrayUsingSelector:@selector(compare:)];
}

BOOL WinPadDirectXPreferred(void) {
  return [NSUserDefaults.standardUserDefaults boolForKey:@"msDirectX"];
}

void WinPadDirectXSetPreferred(BOOL on) {
  [NSUserDefaults.standardUserDefaults setBool:on forKey:@"msDirectX"];
}

BOOL WinPadDirectXProvides(NSString* dll) {
  NSString* name = dll.lowercaseString;
  if (![name hasSuffix:@".dll"]) return NO;
  for (NSString* prefix in @[ @"d3dx9_", @"d3dx10", @"d3dx11_", @"d3dcompiler_", @"d3dcsx_", @"xinput1_", @"xaudio2_",
                              @"x3daudio1_", @"xapofx1_", @"xactengine" ])
    if ([name hasPrefix:prefix]) return YES;
  return NO;
}

static NSString* LastRunLog(void) {
  NSFileManager* fm = NSFileManager.defaultManager;
  NSString* newest = nil;
  NSDate* newest_date = nil;
  for (NSString* name in @[ @"wine.log", @"wine.log.crashed" ]) {
    NSString* path = DocumentsFile(name);
    NSDate* date = [fm attributesOfItemAtPath:path error:nil].fileModificationDate;
    if (date && (!newest_date || [date compare:newest_date] == NSOrderedDescending)) {
      newest = path;
      newest_date = date;
    }
  }
  return newest ? [NSString stringWithContentsOfFile:newest encoding:NSUTF8StringEncoding error:nil] : nil;
}

NSString* WinPadFailedChildOfLastRun(void) {
  NSString* log = LastRunLog();
  const NSRange failed = log ? [log rangeOfString:@"BOOT FAILED at stage 'guest-window-reserve'"] : NSMakeRange(NSNotFound, 0);
  if (failed.location == NSNotFound) return nil;
  // NtCreateUserProcess: image=L"C:\\windows\\~e5.0001" cmdline=...: the last one before it.
  NSRegularExpression* re = [NSRegularExpression regularExpressionWithPattern:@"NtCreateUserProcess: image=L\"([^\"]*)\""
                                                                      options:0
                                                                        error:nil];
  NSArray<NSTextCheckingResult*>* found = [re matchesInString:log options:0 range:NSMakeRange(0, failed.location)];
  if (!found.count) return @"";
  NSString* image = [log substringWithRange:[found.lastObject rangeAtIndex:1]];
  image = [image stringByReplacingOccurrencesOfString:@"\\\\" withString:@"\\"];
  return [image componentsSeparatedByString:@"\\"].lastObject;
}

NSString* WinPadMissingDLLOfLastRun(void) {
  NSFileManager* fm = NSFileManager.defaultManager;
  NSString* newest = nil;
  NSDate* newest_date = nil;
  for (NSString* name in @[ @"wine.log", @"wine.log.crashed" ]) {
    NSString* path = DocumentsFile(name);
    NSDate* date = [fm attributesOfItemAtPath:path error:nil].fileModificationDate;
    if (date && (!newest_date || [date compare:newest_date] == NSOrderedDescending)) {
      newest = path;
      newest_date = date;
    }
  }
  NSString* log = newest ? [NSString stringWithContentsOfFile:newest encoding:NSUTF8StringEncoding error:nil] : nil;
  if (!log) return nil;
  // err:module:import_dll Library d3dx9_30.dll (which is needed by L"Z:\\...\\NFSC.exe") not found
  NSRegularExpression* re = [NSRegularExpression regularExpressionWithPattern:@"Library ([^ ()]+\\.dll) \\(which is needed by [^\\n]*\\) not found"
                                                                      options:NSRegularExpressionCaseInsensitive
                                                                        error:nil];
  NSTextCheckingResult* m = [re firstMatchInString:log options:0 range:NSMakeRange(0, log.length)];
  return m ? [log substringWithRange:[m rangeAtIndex:1]].lowercaseString : nil;
}

static void AddImport(const char* dll, void* ctx) {
  [(__bridge NSMutableSet*)ctx addObject:[NSString stringWithUTF8String:dll].lowercaseString];
}

// The lowercase names of the files in DIR (none when it is not there).
static NSSet<NSString*>* LowercaseNames(NSString* dir) {
  NSMutableSet* names = [NSMutableSet new];
  for (NSString* name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:dir error:nil])
    [names addObject:name.lowercaseString];
  return names;
}

NSArray<NSString*>* WinPadMissingDLLsOf(NSString* exe, NSString* gameFolder) {
  NSString* exe_dir = exe.stringByDeletingLastPathComponent;
  NSMutableSet* have = [NSMutableSet new];
  [have unionSet:LowercaseNames(exe_dir)];
  if (gameFolder) [have unionSet:LowercaseNames(gameFolder)];
  [have unionSet:LowercaseNames([NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"i386-windows"])];
  // A 64-bit game's system DLLs: the ARM64EC set (main.m MakePrefix).
  [have unionSet:LowercaseNames([NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"arm64ec-windows"])];
  [have unionSet:LowercaseNames(DocumentsFile(@"prefix/drive_c/windows/syswow64"))];
  [have unionSet:LowercaseNames(WinPadDirectXDir())];
  [have unionSet:LowercaseNames(WinPadExtraDir())];
  // The executable and the game's own modules next to it (a DLL only the game loads by name,
  // with LoadLibrary, is not seen: the run's log still names it, WinPadMissingDLLOfLastRun).
  NSMutableArray* files = [NSMutableArray arrayWithObject:exe];
  for (NSString* name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:exe_dir error:nil]) {
    NSString* ext = name.pathExtension.lowercaseString;
    if ([ext isEqualToString:@"dll"] || [ext isEqualToString:@"asi"])
      [files addObject:[exe_dir stringByAppendingPathComponent:name]];
  }
  NSMutableSet* imports = [NSMutableSet new];
  for (NSString* file in files) {
    char err[256];
    if (winpad_pe_imports(file.fileSystemRepresentation, AddImport, (__bridge void*)imports, err, sizeof(err)))
      NSLog(@"WinPad: imports of %@ not read: %s", file.lastPathComponent, err);
  }
  NSMutableArray* missing = [NSMutableArray new];
  for (NSString* dll in imports) {
    if ([dll hasPrefix:@"api-ms-win-"] || [dll hasPrefix:@"ext-ms-win-"] || [have containsObject:dll]) continue;
    // Some import names lack the extension (KERNEL32): Windows adds .dll.
    if (!dll.pathExtension.length && [have containsObject:[dll stringByAppendingString:@".dll"]]) continue;
    [missing addObject:dll];
  }
  return [missing sortedArrayUsingSelector:@selector(compare:)];
}

NSArray<NSString*>* WinPadDirectXLink(NSString* syswow64, NSString* bundleI386) {
  NSFileManager* fm = NSFileManager.defaultManager;
  NSMutableArray* native = [NSMutableArray new];
  const BOOL preferred = WinPadDirectXPreferred();
  NSString* dir = WinPadDirectXDir();
  for (NSString* name in WinPadDirectXDLLs()) {
    const BOOL wine_has = [fm fileExistsAtPath:[bundleI386 stringByAppendingPathComponent:name]];
    if (wine_has && !preferred) continue;
    NSString* path = [syswow64 stringByAppendingPathComponent:name];
    NSDictionary* attrs = [fm attributesOfItemAtPath:path error:nil];
    // Only a link the app made (to Wine's DLL, by MakePrefix); a file a program put there stays.
    if (attrs && ![attrs.fileType isEqualToString:NSFileTypeSymbolicLink]) continue;
    [fm removeItemAtPath:path error:nil];
    if (![fm createSymbolicLinkAtPath:path withDestinationPath:[dir stringByAppendingPathComponent:name] error:nil]) continue;
    if (wine_has) [native addObject:name.stringByDeletingPathExtension];
  }
  return native;
}

// The download, with its progress.
@interface WinPadDirectXDownloader : NSObject <NSURLSessionDownloadDelegate>
@property(nonatomic, copy) void (^progress)(double);
// Where the download is kept until UNPACK (on a background queue) has done with it.
@property(nonatomic, copy) NSString* file;
@property(nonatomic, copy) void (^unpack)(NSString* file);
// A link that redirects (aka.ms): only a Microsoft host may serve the file.
@property(nonatomic) BOOL microsoftOnly;
@property(nonatomic, copy) void (^done)(NSString* _Nullable);
@property(nonatomic, strong) NSURLSession* session;
@end

static WinPadDirectXDownloader* current;

BOOL WinPadDirectXDownloading(void) {
  return current != nil;
}

static void Finish(NSString* _Nullable error) {
  dispatch_async(dispatch_get_main_queue(), ^{
    WinPadDirectXDownloader* d = current;
    current = nil;
    [d.session finishTasksAndInvalidate];
    if (d.done) d.done(error);
  });
}

// Checks and unpacks the downloaded installer at EXE (on a background queue).
static void Unpack(NSString* exe) {
  NSFileManager* fm = NSFileManager.defaultManager;
  char err[512] = "", hex[65] = "";
  NSString* error = nil;
  if (winpad_redist_sha256(exe.fileSystemRepresentation, hex, err, sizeof(err))) {
    error = [NSString stringWithFormat:@"Stažený soubor nejde přečíst: %s", err];
  } else if (strcmp(hex, WINPAD_DIRECTX_SHA256)) {
    error = @"Stažený soubor není instalačka DirectX od Microsoftu (nesedí jeho SHA-256).";
  } else {
    NSString* dir = WinPadDirectXDir();
    NSString* tmp = [dir stringByAppendingString:@".new"];
    [fm removeItemAtPath:tmp error:nil];
    [fm createDirectoryAtPath:tmp withIntermediateDirectories:YES attributes:nil error:nil];
    int count = 0;
    if (winpad_redist_extract_directx(exe.fileSystemRepresentation, tmp.fileSystemRepresentation, &count, err,
                                      sizeof(err))) {
      error = [NSString stringWithFormat:@"Rozbalení se nepovedlo: %s", err];
      [fm removeItemAtPath:tmp error:nil];
    } else {
      [fm removeItemAtPath:dir error:nil];
      [fm moveItemAtPath:tmp toPath:dir error:nil];
      // Downloaded again whenever needed: no need to back it up.
      [[NSURL fileURLWithPath:DocumentsFile(@".redist")] setResourceValue:@YES
                                                                   forKey:NSURLIsExcludedFromBackupKey
                                                                    error:nil];
      printf("WinPad Wine: DirectX from Microsoft: %d DLLs in %s\n", count, dir.UTF8String);
    }
  }
  [fm removeItemAtPath:exe error:nil];
  Finish(error);
}

@implementation WinPadDirectXDownloader
- (void)URLSession:(NSURLSession*)session
                 downloadTask:(NSURLSessionDownloadTask*)task
                 didWriteData:(int64_t)written
            totalBytesWritten:(int64_t)total
    totalBytesExpectedToWrite:(int64_t)expected {
  if (expected <= 0) return;
  const double fraction = (double)total / (double)expected;
  void (^progress)(double) = self.progress;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (progress) progress(fraction < 1 ? fraction : 1);
  });
}

- (void)URLSession:(NSURLSession*)session downloadTask:(NSURLSessionDownloadTask*)task didFinishDownloadingToURL:(NSURL*)location {
  NSHTTPURLResponse* response = (NSHTTPURLResponse*)task.response;
  if ([response isKindOfClass:NSHTTPURLResponse.class] && response.statusCode != 200) {
    Finish([NSString stringWithFormat:@"Microsoft odpověděl chybou %ld.", (long)response.statusCode]);
    return;
  }
  NSString* host = response.URL.host.lowercaseString;
  if (self.microsoftOnly && !([host isEqualToString:@"microsoft.com"] || [host hasSuffix:@".microsoft.com"])) {
    Finish([NSString stringWithFormat:@"Soubor nepřišel od Microsoftu (%@).", host ?: @"?"]);
    return;
  }
  // The file at LOCATION is gone after this method returns: move it first.
  NSFileManager* fm = NSFileManager.defaultManager;
  NSString* exe = self.file;
  [fm createDirectoryAtPath:exe.stringByDeletingLastPathComponent withIntermediateDirectories:YES attributes:nil error:nil];
  [fm removeItemAtPath:exe error:nil];
  NSError* error = nil;
  if (![fm moveItemAtURL:location toURL:[NSURL fileURLWithPath:exe] error:&error]) {
    Finish([NSString stringWithFormat:@"Stažený soubor nejde uložit: %@", error.localizedDescription]);
    return;
  }
  void (^progress)(double) = self.progress;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (progress) progress(1);
  });
  void (^unpack)(NSString*) = self.unpack;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    unpack(exe);
  });
}

- (void)URLSession:(NSURLSession*)session task:(NSURLSessionTask*)task didCompleteWithError:(NSError*)error {
  if (error) Finish([NSString stringWithFormat:@"Stahování se nepovedlo: %@", error.localizedDescription]);
}
@end

void WinPadDirectXDownload(void (^progress)(double fraction), void (^done)(NSString* _Nullable error)) {
  if (current) return;
  current = [WinPadDirectXDownloader new];
  current.progress = progress;
  current.done = done;
  current.file = DocumentsFile(@".redist/directx_Jun2010_redist.exe");
  current.unpack = ^(NSString* file) {
    Unpack(file);
  };
  current.session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration
                                                  delegate:current
                                             delegateQueue:nil];
  [[current.session downloadTaskWithURL:[NSURL URLWithString:@WINPAD_DIRECTX_URL]] resume];
}

NSArray<NSString*>* WinPadDirectXDLLsForVerbs(NSArray* verbs) {
  NSArray<NSString*>* have = WinPadDirectXDLLs();
  NSMutableOrderedSet<NSString*>* out = [NSMutableOrderedSet new];
  for (id item in verbs) {
    if (![item isKindOfClass:NSString.class]) continue;
    NSString* verb = [item lowercaseString];
    if ([verb hasSuffix:@".dll"]) verb = verb.stringByDeletingPathExtension;
    // A family (d3dx9: d3dx9_24 ... d3dx9_43), or one DLL (d3dx9_43).
    NSArray<NSString*>* prefixes = [verb isEqualToString:@"d3dx9"]    ? @[ @"d3dx9_" ]
                                   : [verb isEqualToString:@"d3dx10"] ? @[ @"d3dx10" ]
                                   : [verb isEqualToString:@"xinput"] ? @[ @"xinput1_" ]
                                   : [verb hasPrefix:@"xact"]         ? @[ @"xactengine", @"x3daudio", @"xapofx", @"xaudio2_" ]
                                   : [verb isEqualToString:@"x3daudio"] ? @[ @"x3daudio" ]
                                                                        : nil;
    for (NSString* dll in have) {
      NSString* stem = dll.stringByDeletingPathExtension;
      BOOL take = [stem isEqualToString:verb];
      for (NSString* prefix in prefixes) take = take || [stem hasPrefix:prefix];
      if (take) [out addObject:dll];
    }
  }
  return out.array;
}

NSArray<NSString*>* WinPadDirectXLinkNative(NSString* syswow64, NSArray<NSString*>* dlls) {
  NSFileManager* fm = NSFileManager.defaultManager;
  NSMutableArray* native = [NSMutableArray new];
  NSString* dir = WinPadDirectXDir();
  for (NSString* name in dlls) {
    NSString* path = [syswow64 stringByAppendingPathComponent:name];
    NSString* target = [dir stringByAppendingPathComponent:name];
    NSDictionary* attrs = [fm attributesOfItemAtPath:path error:nil];
    // Only a link the app made; a file a program put there stays (and is native anyway).
    if (attrs && ![attrs.fileType isEqualToString:NSFileTypeSymbolicLink]) continue;
    if (![[fm destinationOfSymbolicLinkAtPath:path error:nil] isEqualToString:target]) {
      [fm removeItemAtPath:path error:nil];
      if (![fm createSymbolicLinkAtPath:path withDestinationPath:target error:nil]) continue;
    }
    [native addObject:name.stringByDeletingPathExtension];
  }
  return native;
}

NSString* WinPadExtraDir(void) {
  return DocumentsFile(@".redist/extra");
}

NSArray<NSString*>* WinPadExtraLink(NSString* syswow64, NSString* bundleI386) {
  NSFileManager* fm = NSFileManager.defaultManager;
  NSMutableArray* linked = [NSMutableArray new];
  NSString* dir = WinPadExtraDir();
  for (NSString* name in [fm contentsOfDirectoryAtPath:dir error:nil]) {
    if (![name.pathExtension isEqualToString:@"dll"]) continue;
    // Wine's own stays (a game that wants Microsoft's says so in its profile's overrides), and
    // so does a DirectX DLL the download linked.
    if ([fm fileExistsAtPath:[bundleI386 stringByAppendingPathComponent:name]]) continue;
    NSString* path = [syswow64 stringByAppendingPathComponent:name];
    NSDictionary* attrs = [fm attributesOfItemAtPath:path error:nil];
    if (attrs) continue;
    if ([fm createSymbolicLinkAtPath:path withDestinationPath:[dir stringByAppendingPathComponent:name] error:nil])
      [linked addObject:name.stringByDeletingPathExtension];
  }
  return linked;
}

// A folder whose installers are Microsoft's runtimes (Library.m's RedistFolder has more
// words, for picking the game's program).
static BOOL InstallerFolder(NSString* name) {
  NSString* lower = name.lowercaseString;
  for (NSString* word in @[ @"redist", @"directx", @"dxsetup", @"vcredist", @"vc_redist", @"msvc", @"support", @"prereq",
                            @"installer", @"3rdparty", @"__installer" ])
    if ([lower containsString:word]) return YES;
  return NO;
}

NSArray<NSString*>* WinPadGameInstallers(NSString* gameFolder) {
  NSFileManager* fm = NSFileManager.defaultManager;
  NSDirectoryEnumerator* walk = [fm enumeratorAtPath:gameFolder];
  NSMutableArray* found = [NSMutableArray new];
  NSUInteger seen = 0;
  for (NSString* path; (path = walk.nextObject) && seen < 20000; seen++) {
    NSString* name = path.lastPathComponent;
    if ([walk.fileAttributes.fileType isEqualToString:NSFileTypeDirectory]) {
      if ([name hasPrefix:@"."] || walk.level >= 5) [walk skipDescendants];
      continue;
    }
    NSString* lower = name.lowercaseString;
    NSString* ext = lower.pathExtension;
    const unsigned long long size = walk.fileAttributes.fileSize;
    if (size < 1024 || size > 600ull * 1024 * 1024) continue;
    BOOL in_installers = NO;
    for (NSString* part in path.stringByDeletingLastPathComponent.pathComponents)
      if (InstallerFolder(part)) in_installers = YES;
    const BOOL redist_name = [lower containsString:@"vcredist"] || [lower containsString:@"vc_redist"] ||
                             [lower containsString:@"directx"] || [lower hasPrefix:@"dxsetup"];
    // DirectX's cabinets (Jun2010_d3dx9_43_x86.cab...), .msi files and programs, in an installer
    // folder or named like one; not the game's own data cabinets (some are hundreds of MB).
    const BOOL package = [ext isEqualToString:@"cab"] || [ext isEqualToString:@"msi"] || [ext isEqualToString:@"exe"];
    if (package && (redist_name || in_installers || [lower hasSuffix:@"_x86.cab"]))
      [found addObject:[gameFolder stringByAppendingPathComponent:path]];
  }
  return found;
}

int WinPadTakeDLLsFromGameInstallers(NSString* gameFolder) {
  NSString* dir = WinPadExtraDir();
  [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
  [[NSURL fileURLWithPath:DocumentsFile(@".redist")] setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];
  int total = 0;
  for (NSString* file in WinPadGameInstallers(gameFolder)) {
    char err[512] = "";
    int count = 0;
    if (winpad_redist_extract_dlls(file.fileSystemRepresentation, dir.fileSystemRepresentation, 0x14c, &count, err,
                                   sizeof(err)))
      printf("WinPad Wine: %s: %s\n", file.lastPathComponent.UTF8String, err);
    else if (count)
      printf("WinPad Wine: %d DLLs out of the game's %s\n", count, file.lastPathComponent.UTF8String);
    total += count;
  }
  return total;
}

int WinPadVCRedistYearOf(NSString* dll) {
  return winpad_vcredist_year_of(dll.UTF8String);
}

void WinPadVCRedistDownload(int year, void (^progress)(double fraction), void (^done)(NSString* _Nullable error)) {
  const struct winpad_vcredist* vc = winpad_vcredist_for_year(year);
  if (!vc) {
    done([NSString stringWithFormat:@"Visual C++ %d neznám.", year]);
    return;
  }
  if (current) return;
  current = [WinPadDirectXDownloader new];
  current.progress = progress;
  current.done = done;
  current.file = DocumentsFile([NSString stringWithFormat:@".redist/vcredist%d_x86.exe", year]);
  current.microsoftOnly = YES;
  NSString* sha = vc->sha256 ? @(vc->sha256) : nil;
  current.unpack = ^(NSString* file) {
    NSFileManager* fm = NSFileManager.defaultManager;
    char err[512] = "", hex[65] = "";
    NSString* error = nil;
    if (sha && winpad_redist_sha256(file.fileSystemRepresentation, hex, err, sizeof(err))) {
      error = [NSString stringWithFormat:@"Stažený soubor nejde přečíst: %s", err];
    } else if (sha && ![sha isEqualToString:[NSString stringWithUTF8String:hex]]) {
      error = [NSString stringWithFormat:@"Stažený soubor není instalačka Visual C++ %d od Microsoftu (nesedí jeho SHA-256).", year];
    } else {
      NSString* dir = WinPadExtraDir();
      [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
      int count = 0;
      if (winpad_redist_extract_dlls(file.fileSystemRepresentation, dir.fileSystemRepresentation, 0x14c, &count, err,
                                     sizeof(err)))
        error = [NSString stringWithFormat:@"Rozbalení se nepovedlo: %s", err];
      else
        printf("WinPad Wine: Visual C++ %d from Microsoft: %d new DLLs in %s\n", year, count, dir.UTF8String);
      // Done once per year: what it lacks, another download would not bring.
      [NSUserDefaults.standardUserDefaults setBool:YES forKey:[NSString stringWithFormat:@"vcredist%d", year]];
    }
    [fm removeItemAtPath:file error:nil];
    Finish(error);
  };
  current.session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration
                                                  delegate:current
                                             delegateQueue:nil];
  [[current.session downloadTaskWithURL:[NSURL URLWithString:@(vc->url)]] resume];
}
