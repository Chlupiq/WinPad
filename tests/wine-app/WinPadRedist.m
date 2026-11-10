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
  // The file at LOCATION is gone after this method returns: move it first.
  NSFileManager* fm = NSFileManager.defaultManager;
  NSString* exe = DocumentsFile(@".redist/directx_Jun2010_redist.exe");
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
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    Unpack(exe);
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
  current.session = [NSURLSession sessionWithConfiguration:NSURLSessionConfiguration.defaultSessionConfiguration
                                                  delegate:current
                                             delegateQueue:nil];
  [[current.session downloadTaskWithURL:[NSURL URLWithString:@WINPAD_DIRECTX_URL]] resume];
}
