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
// Which program it runs is the "program" setting (ProgramName): hello
// (hello.exe, the default) or window (tests/wine-i386/window.c, a window
// drawn with GDI, from its own AOT image Frameworks/fexaot-window.dylib).
// The window's frames show on screen; 2 s after it shows, the app taps it
// (as CI does), it changes colour and the program exits.
//
// When the bundle has DXMT (CI built it for the app), two more run with
// FEX's JIT, which needs a debugger attached (Run from Xcode): d3d9-cube
// (tests/wine-i386/d3d9-cube.c, the "WinPadWine D3D9" scheme), a 32-bit
// Direct3D 9 program drawing through DXMT and Metal, and game (the
// "WinPadWine Game" scheme): a game the user copied into Documents, the
// "game" setting naming its program there (NFSU2/SPEED2.EXE by default).
// The game starts in its own folder (winehost.c) and runs until it ends or
// the app is stopped. Their frames show on screen through a Metal layer,
// and a hardware keyboard's keys go to the game (HardwareKeyboard).
//
// Everything Wine and FEX print goes to Documents/wine.log, shown on screen
// while it runs. An x86 block missing from the image runs in FEX's IR
// interpreter (patches/fex-wow64/0019) and is written to the code map in
// Documents/fexcache/codemap/new, so a later image can have it. If the run
// stops the app, the next launch shows the log of that run.
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int winehost_main(int argc, char* argv[]);
void winehost_post_key(unsigned short vk, int down);
extern void (*winehost_frame_hook)(void* hwnd, int width, int height, int stride, const void* bits);

static NSString* const FinishedMarker = @"== finished";

static NSString* DocumentsPath(NSString* name) {
  NSString* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
  return [docs stringByAppendingPathComponent:name];
}

static NSString* ReadLog(void) {
  return [NSString stringWithContentsOfFile:DocumentsPath(@"wine.log") encoding:NSUTF8StringEncoding error:nil] ?: @"";
}

// The end of the log, for the screen: a game's log grows for as long as it runs.
static NSString* ReadLogTail(void) {
  NSFileHandle* f = [NSFileHandle fileHandleForReadingAtPath:DocumentsPath(@"wine.log")];
  if (!f) return @"";
  const unsigned long long size = [f seekToEndOfFile], keep = 64 * 1024;
  [f seekToFileOffset:size > keep ? size - keep : 0];
  NSData* data = [f readDataToEndOfFile];
  [f closeFile];
  NSString* tail = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?:
                   [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
  return size > keep ? [@"…\n" stringByAppendingString:tail] : tail;
}

// The program to run: WINPAD_PROGRAM (set by an Xcode scheme), else the
// "program" user default: the Settings app (Settings → WinPad Wine →
// Program), or a launch argument "-program NAME". Without either, hello.
static NSString* ProgramName(void) {
  const char* env = getenv("WINPAD_PROGRAM");
  if (env && *env) return @(env);
  NSString* setting = [NSUserDefaults.standardUserDefaults stringForKey:@"program"];
  return setting.length ? setting : @"hello";
}

// Shows the newest frame of the program's window (winehost_frame_hook).
static UIImageView* frame_view;

static void ShowFrame(void* hwnd, int width, int height, int stride, const void* bits) {
  (void)hwnd;
  CFDataRef data = CFDataCreate(NULL, bits, (CFIndex)stride * height);
  CGDataProviderRef provider = CGDataProviderCreateWithCFData(data);
  CGColorSpaceRef rgb = CGColorSpaceCreateDeviceRGB();
  // BGRX in memory: a little-endian 32-bit XRGB word.
  CGImageRef cg = CGImageCreate(width, height, 8, 32, stride, rgb,
                                kCGBitmapByteOrder32Little | (CGBitmapInfo)kCGImageAlphaNoneSkipFirst, provider, NULL,
                                false, kCGRenderingIntentDefault);
  UIImage* image = cg ? [UIImage imageWithCGImage:cg] : nil;
  CGImageRelease(cg);
  CGColorSpaceRelease(rgb);
  CGDataProviderRelease(provider);
  CFRelease(data);
  if (image) dispatch_async(dispatch_get_main_queue(), ^{
      frame_view.image = image;
    });
}

// The view DXMT's Metal layers go on (host/metal-display.m looks this up):
// 640 wide at most for the cube, as large as fits for a game.
static UIView* metal_view;
static BOOL metal_fill;

__attribute__((used, visibility("default"))) void winehost_show_metal_layer(CALayer* layer) {
  dispatch_async(dispatch_get_main_queue(), ^{
    CGRect b = metal_view.bounds;
    CGFloat w = MIN(b.size.width - 32, metal_fill ? (b.size.height - 96) * 4 / 3 : 640), h = w * 3 / 4;
    layer.frame = CGRectMake((b.size.width - w) / 2, 64, w, h);
    [metal_view.layer addSublayer:layer];
  });
}

// The Windows virtual key of a key's USB HID usage (what GCKeyCode is), or 0.
// Modifiers keep their side; Wine's driver derives the scan code DirectInput
// reads from the virtual key (Madeira's docs/KEYBOARD_MOUSE.md).
static unsigned short VirtualKey(GCKeyCode code) {
  const CFIndex u = code;
  if (u >= 0x04 && u <= 0x1d) return 'A' + (u - 0x04);
  if (u >= 0x1e && u <= 0x26) return '1' + (u - 0x1e);
  if (u >= 0x3a && u <= 0x45) return 0x70 + (u - 0x3a);  // F1-F12
  static const struct { CFIndex usage; unsigned short vk; } keys[] = {
      {0x27, '0'},  {0x28, 0x0d}, {0x29, 0x1b}, {0x2a, 0x08}, {0x2b, 0x09}, {0x2c, 0x20},
      {0x2d, 0xbd}, {0x2e, 0xbb}, {0x2f, 0xdb}, {0x30, 0xdd}, {0x31, 0xdc}, {0x33, 0xba},
      {0x34, 0xde}, {0x35, 0xc0}, {0x36, 0xbc}, {0x37, 0xbe}, {0x38, 0xbf}, {0x39, 0x14},
      {0x49, 0x2d}, {0x4a, 0x24}, {0x4b, 0x21}, {0x4c, 0x2e}, {0x4d, 0x23}, {0x4e, 0x22},
      {0x4f, 0x27}, {0x50, 0x25}, {0x51, 0x28}, {0x52, 0x26}, {0xe0, 0xa2}, {0xe1, 0xa0},
      {0xe2, 0xa4}, {0xe4, 0xa3}, {0xe5, 0xa1}, {0xe6, 0xa5},
  };
  for (size_t i = 0; i < sizeof(keys) / sizeof(keys[0]); i++)
    if (keys[i].usage == u) return keys[i].vk;
  return 0;
}

// Sends every key of a hardware keyboard (Bluetooth, USB, Magic Keyboard) to
// the program, down and up, as GameController reports them.
static void HardwareKeyboard(void) {
  void (^attach)(GCKeyboard*) = ^(GCKeyboard* keyboard) {
    keyboard.keyboardInput.keyChangedHandler = ^(GCKeyboardInput* input, GCControllerButtonInput* key,
                                                 GCKeyCode code, BOOL pressed) {
      const unsigned short vk = VirtualKey(code);
      if (vk) winehost_post_key(vk, pressed);
    };
  };
  if (GCKeyboard.coalescedKeyboard) attach(GCKeyboard.coalescedKeyboard);
  [NSNotificationCenter.defaultCenter addObserverForName:GCKeyboardDidConnectNotification
                                                  object:nil
                                                   queue:NSOperationQueue.mainQueue
                                              usingBlock:^(NSNotification* note) {
                                                attach(note.object);
                                              }];
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
@property(nonatomic, copy) NSString* program;
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
  self.program = ProgramName();
  if ([self.program isEqualToString:@"window"]) {
    // The window on top, the log below it.
    frame_view = [UIImageView new];
    frame_view.contentMode = UIViewContentModeScaleAspectFit;
    frame_view.layer.magnificationFilter = kCAFilterNearest;
    frame_view.backgroundColor = UIColor.secondarySystemBackgroundColor;
    [self.view addSubview:frame_view];
    winehost_frame_hook = ShowFrame;
  }
  metal_view = self.view;
  metal_fill = [self.program isEqualToString:@"game"];
  if (metal_fill) HardwareKeyboard();

  NSString* previous = ReadLog();
  if (previous.length && ![previous containsString:FinishedMarker]) {
    [NSFileManager.defaultManager removeItemAtPath:DocumentsPath(@"wine.log.crashed") error:nil];
    [NSFileManager.defaultManager moveItemAtPath:DocumentsPath(@"wine.log")
                                          toPath:DocumentsPath(@"wine.log.crashed")
                                           error:nil];
    // A game is usually ended by stopping the app, so it starts again; its
    // last log stays in wine.log.crashed.
    if (![self.program isEqualToString:@"game"]) {
      self.text.text = [@"WinPad Wine: the last run stopped before it finished. Its log:\n\n" stringByAppendingString:previous];
      return;
    }
  }
  self.text.text = @"WinPad Wine: starting…";
  self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer* timer) {
    [self showLog];
  }];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    [self runWine];
  });
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  if (!frame_view) return;
  CGRect b = self.view.bounds;
  const CGFloat top = self.view.safeAreaInsets.top + 8, h = MIN(b.size.height * 0.45, 480);
  frame_view.frame = CGRectMake(16, top, b.size.width - 32, h);
  self.text.frame = CGRectMake(0, top + h, b.size.width, b.size.height - top - h);
  self.text.textContainerInset = UIEdgeInsetsMake(8, 16, 16, 16);
}

- (void)showLog {
  NSString* summary = self.summary;
  self.text.text = [(summary ?: @"WinPad Wine: running…\n\n") stringByAppendingString:ReadLogTail()];
  if (summary) [self.timer invalidate];
}

- (void)runWine {
  NSString* name = self.program;
  const BOOL window = [name isEqualToString:@"window"];
  const BOOL cube = [name isEqualToString:@"d3d9-cube"], game = [name isEqualToString:@"game"];
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
  NSString* program = [bundle stringByAppendingPathComponent:[NSString stringWithFormat:@"i386-windows/%@.exe", name]];
  NSString* image = @"none (JIT)";
  if (game) {
    NSString* exe = [NSUserDefaults.standardUserDefaults stringForKey:@"game"];
    program = DocumentsPath(exe.length ? exe : @"NFSU2/SPEED2.EXE");
    // The Ultimate ASI Loader many games carry is a dinput8.dll of their own.
    setenv("WINEDLLOVERRIDES", "dinput8=n,b", 1);
  }
  if (!cube && !game) {
    // Each program has its own AOT image: hello's is fexaot.dylib, NAME's fexaot-NAME.dylib.
    image = [name isEqualToString:@"hello"] ? @"fexaot.dylib" : [NSString stringWithFormat:@"fexaot-%@.dylib", name];
    setenv("WINEHOST_AOT_IMAGE",
           [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:image].fileSystemRepresentation, 1);
    setenv("FEX_NOJIT", "1", 1);
    setenv("FEX_ENABLECODECACHINGWIP", "1", 1);
    setenv("FEX_ENABLECODECACHEVALIDATION", "0", 1);
    setenv("FEX_APP_CACHE_LOCATION", WindowsDir(cache).UTF8String, 1);
  }

  if (window) {
    // As CI's runs of the program, which its AOT image was built from: a tap
    // in the middle of the window 2 s after it shows, then it exits. Its newest
    // frame also goes to Documents/frames as a BMP.
    setenv("WINEHOST_WINDOW", "1", 1);
    setenv("WINEHOST_CLICK", "50,50", 1);
    setenv("WINEHOST_WAIT_EXIT", "1", 1);
    setenv("WINEHOST_FRAMES", DocumentsPath(@"frames").fileSystemRepresentation, 1);
    [NSFileManager.defaultManager removeItemAtPath:DocumentsPath(@"frames") error:nil];
  }
  printf("WinPad Wine: program %s, AOT image %s\n", name.UTF8String, image.UTF8String);

  if (game && ![NSFileManager.defaultManager fileExistsAtPath:program]) {
    printf("%s, exit 1\n", FinishedMarker.UTF8String);
    self.summary = [NSString stringWithFormat:@"FAILED: no game at %@. Copy the game's folder into WinPad Wine's "
                                              @"Documents (Finder → the iPad → Files), or name its program in "
                                              @"Settings → WinPad Wine → Game.\n\n", program];
    dispatch_async(dispatch_get_main_queue(), ^{
      [self showLog];
    });
    return;
  }
  // The cube spins for 8 s, exits with 43 and says how many frames it presented;
  // a game runs until it ends (a day at most).
  char* args[] = {"winehost", game ? "86400" : "60", (char*)program.fileSystemRepresentation, NULL};
  const int status = winehost_main(3, args);
  NSString* log = ReadLog();
  const BOOL ok = cube   ? [log containsString:@"MADEIRA-D3D9: done, frames presented = "] &&
                             [log containsString:@"winehost: Wine process exited with code 43"]
                  : game ? [log containsString:@"winehost: Wine process exited with code 0"]
                         : status == 0 && [log containsString:@"winehost: Wine process exited with code 0"] &&
                               (window ? [log containsString:@"winehost: window content changed after the click"]
                                       : [log containsString:@"Hello from x86"]);
  printf("%s, exit %d\n", FinishedMarker.UTF8String, ok ? 0 : 1);

  self.summary = !ok    ? [NSString stringWithFormat:@"FAILED (winehost %d)\n\n", status]
                 : cube ? @"OK: the 32-bit D3D9 cube presented its frames through DXMT and Metal.\n\n"
                 : game ? @"OK: the game ended with exit code 0.\n\n"
                 : window ? @"OK: the x86 program drew its window and took a tap in Wine from the AOT image, without a JIT.\n\n"
                          : @"OK: the x86 program ran in Wine from the AOT image, without a JIT.\n\n";
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
