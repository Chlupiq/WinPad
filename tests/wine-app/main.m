// SPDX-License-Identifier: MIT
// WinPad Wine app: runs a 32-bit x86 Windows program (tests/wine-i386/hello.c)
// in Wine on an iPad, through WoW64 and FEX, with NoJIT. FEX runs only the x86
// code linked into Frameworks/fexaot.dylib (tests/fex-wow64/build-aot-image.sh)
// and every Wine module runs from its dylib, so no memory is ever made
// executable: no debugger, no JIT entitlement.
//
// Wine is the command-line host of tests/wine-loader (host/winehost.c), linked
// in: wineserver and one Wine process in this process. The bundle is laid
// out like Madeira's: aarch64-windows, i386-windows, nls and fonts next to
// the executable, where Madeira's ntdll looks for them.
//
// Everything Wine and FEX print goes to Documents/wine.log, shown on screen
// while it runs. If the run stops the app (FEX aborts on an x86 block
// missing from the image), the next launch shows the log of that run.
#import <UIKit/UIKit.h>

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int winehost_main(int argc, char* argv[]);

static NSString* const FinishedMarker = @"== finished";

static NSString* DocumentsPath(NSString* name) {
  NSString* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
  return [docs stringByAppendingPathComponent:name];
}

static NSString* ReadLog(void) {
  return [NSString stringWithContentsOfFile:DocumentsPath(@"wine.log") encoding:NSUTF8StringEncoding error:nil] ?: @"";
}

// Windows path of a directory for FEX: Z: is the root, with a trailing backslash.
static NSString* WindowsDir(NSString* path) {
  return [NSString stringWithFormat:@"Z:%@\\", [path stringByReplacingOccurrencesOfString:@"/" withString:@"\\"]];
}

// A fresh Wine prefix on every launch, as in CI. A 32-bit process's system32
// is C:\windows\syswow64, with the i386 DLLs; wow64.dll and xtajit.dll are
// loaded by their C:\windows\system32 paths (madeira_link_syswow64 in
// Madeira's WineProcessBridge.m). The links point into the bundle, whose
// path changes with every install.
static NSString* MakePrefix(NSString* bundle) {
  NSFileManager* fm = NSFileManager.defaultManager;
  NSString* prefix = DocumentsPath(@"prefix");
  [fm removeItemAtPath:prefix error:nil];
  NSDictionary* farms = @{@"syswow64" : @"i386-windows", @"system32" : @"aarch64-windows"};
  for (NSString* farm in farms) {
    NSString* dir = [prefix stringByAppendingPathComponent:[@"drive_c/windows" stringByAppendingPathComponent:farm]];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    NSString* src = [bundle stringByAppendingPathComponent:farms[farm]];
    for (NSString* name in [fm contentsOfDirectoryAtPath:src error:nil]) {
      if ([farm isEqualToString:@"syswow64"] && ![name.pathExtension.lowercaseString isEqualToString:@"dll"]) continue;
      [fm createSymbolicLinkAtPath:[dir stringByAppendingPathComponent:name]
               withDestinationPath:[src stringByAppendingPathComponent:name]
                             error:nil];
    }
  }
  return prefix;
}

@interface WineViewController : UIViewController
@property(nonatomic, strong) UITextView* text;
@property(nonatomic, strong) NSTimer* timer;
@property(atomic, copy) NSString* summary;
@end

@implementation WineViewController
- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  self.text = [[UITextView alloc] initWithFrame:self.view.bounds];
  self.text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.text.editable = NO;
  self.text.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
  self.text.textContainerInset = UIEdgeInsetsMake(48, 16, 16, 16);
  [self.view addSubview:self.text];

  NSString* previous = ReadLog();
  if (previous.length && ![previous containsString:FinishedMarker]) {
    self.text.text = [@"WinPad Wine: the last run stopped before it finished. Its log:\n\n" stringByAppendingString:previous];
    [NSFileManager.defaultManager moveItemAtPath:DocumentsPath(@"wine.log")
                                          toPath:DocumentsPath(@"wine.log.crashed")
                                           error:nil];
    return;
  }
  self.text.text = @"WinPad Wine: starting…";
  self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer* timer) {
    [self showLog];
  }];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    [self runWine];
  });
}

- (void)showLog {
  NSString* summary = self.summary;
  self.text.text = [(summary ?: @"WinPad Wine: running…\n\n") stringByAppendingString:ReadLog()];
  if (summary) [self.timer invalidate];
}

- (void)runWine {
  NSString* bundle = NSBundle.mainBundle.bundlePath;
  NSString* prefix = MakePrefix(bundle);
  NSString* cache = DocumentsPath(@"fexcache");
  [NSFileManager.defaultManager createDirectoryAtPath:[cache stringByAppendingPathComponent:@"codemap/new"]
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:nil];
  // Wine, FEX and the program write with stdio and to fds 1 and 2: both go
  // to the log file. The log also goes to the original stderr at the end:
  // Xcode's console.
  const int console = dup(fileno(stderr));
  freopen(DocumentsPath(@"wine.log").fileSystemRepresentation, "w", stdout);
  dup2(fileno(stdout), fileno(stderr));
  setvbuf(stdout, NULL, _IONBF, 0);
  setvbuf(stderr, NULL, _IONBF, 0);

  // The same environment as CI's NoJIT run of the program
  // (tests/wine-loader/run-host.sh): the AOT image only holds the x86 code
  // that run took, and trace channels change which code ntdll runs.
  setenv("WINEPREFIX", prefix.fileSystemRepresentation, 1);
  setenv("WINEDLLPATH", bundle.fileSystemRepresentation, 1);
  setenv("WINEHOST_NLS", [bundle stringByAppendingPathComponent:@"nls"].fileSystemRepresentation, 1);
  setenv("WINEDEBUG", "+loaddll", 1);
  setenv("MADEIRA_WIN32U", "1", 1);
  setenv("MADEIRA_DESKTOP", "1", 1);
  // An app without the extended virtual addressing entitlement gets about 8 GB of address
  // space on an iPad. The 32-bit program's 4 GB guest window fits, but not with the 8 GB
  // Madeira wants left over by default.
  setenv("MADEIRA_WOW_MIN_FREE_GB", "2", 1);
  setenv("WINEHOST_RETURN", "1", 1);
  setenv("WINEHOST_AOT_IMAGE",
         [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"fexaot.dylib"].fileSystemRepresentation, 1);
  setenv("FEX_NOJIT", "1", 1);
  setenv("FEX_ENABLECODECACHINGWIP", "1", 1);
  setenv("FEX_ENABLECODECACHEVALIDATION", "0", 1);
  setenv("FEX_APP_CACHE_LOCATION", WindowsDir(cache).UTF8String, 1);

  NSString* program = [bundle stringByAppendingPathComponent:@"i386-windows/hello.exe"];
  char* args[] = {"winehost", "60", (char*)program.fileSystemRepresentation, NULL};
  const int status = winehost_main(3, args);
  NSString* log = ReadLog();
  const BOOL ok = status == 0 && [log containsString:@"Hello from x86"] &&
                  [log containsString:@"winehost: Wine process exited with code 0"];
  printf("%s, exit %d\n", FinishedMarker.UTF8String, ok ? 0 : 1);

  self.summary = ok ? @"OK: the x86 program ran in Wine from the AOT image, without a JIT.\n\n"
                    : [NSString stringWithFormat:@"FAILED (winehost %d)\n\n", status];
  NSData* data = [[self.summary stringByAppendingString:ReadLog()] dataUsingEncoding:NSUTF8StringEncoding];
  write(console, data.bytes, data.length);
  dispatch_async(dispatch_get_main_queue(), ^{
    [self showLog];
  });
}
@end

// Apps built with the iOS 27 SDK must use the scene life cycle.
@interface WineSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow* window;
@end

@implementation WineSceneDelegate
- (void)scene:(UIScene*)scene willConnectToSession:(UISceneSession*)session options:(UISceneConnectionOptions*)options {
  self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
  self.window.rootViewController = [WineViewController new];
  [self.window makeKeyAndVisible];
}
@end

@interface WineAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation WineAppDelegate
- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)options {
  return YES;
}

- (UISceneConfiguration*)application:(UIApplication*)application
    configurationForConnectingSceneSession:(UISceneSession*)session
                                   options:(UISceneConnectionOptions*)options {
  UISceneConfiguration* config = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
  config.delegateClass = [WineSceneDelegate class];
  return config;
}
@end

int main(int argc, char* argv[]) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([WineAppDelegate class]));
  }
}
