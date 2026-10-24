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
// The app opens on its game library (Library.m), which starts a game the
// user copied in, or a test program from its settings. The "program" setting
// (ProgramName) skips the library: hello (hello.exe) or window
// (tests/wine-i386/window.c, a window drawn with GDI, from its own AOT image
// Frameworks/fexaot-window.dylib).
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
// and a hardware keyboard's keys go to the game (HardwareKeyboard), as do a
// game controller's or the touch controller's buttons (Gamepads). Until the
// game has a Metal layer, its first window's GDI frames show there instead
// (a launcher, a message box), and a status line above says how long it has
// run and how many frames it has drawn.
// An iPad with TXM runs no JIT code even under the debugger, so the game
// runs with NoJIT from Frameworks/fexaot-game.dylib when the project has one
// (game-aot.sh builds it on the Mac with the game), FEX's interpreter running
// the blocks it lacks.
//
// Everything Wine and FEX print goes to Documents/wine.log, shown on screen
// while it runs. An x86 block missing from the image runs in FEX's IR
// interpreter (patches/fex-wow64/0019) and is written to the code map in
// Documents/fexcache/codemap/new, so a later image can have it. If the run
// stops the app, the next launch shows the log of that run.
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#import "Library.h"

#include <dlfcn.h>
#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

int winehost_main(int argc, char* argv[]);
void winehost_post_key(unsigned short vk, int down);
extern void (*winehost_frame_hook)(void* hwnd, int width, int height, int stride, const void* bits);

static NSString* const FinishedMarker = @"== finished";

// When the app started (main), for the log's [clock] lines.
static CFAbsoluteTime app_started;

// Writes a [clock] line to the log every second from now on: the seconds since
// the app started and how many frames the program has drawn, so a log says how
// long each part of a start took.
static void StartLogClock(void) {
  printf("[clock] %.1f s since the app started: starting Wine\n", CFAbsoluteTimeGetCurrent() - app_started);
  dispatch_source_t timer =
      dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0));
  dispatch_source_set_timer(timer, dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), NSEC_PER_SEC, NSEC_PER_SEC / 10);
  dispatch_source_set_event_handler(timer, ^{
    // Looked up each time, as the status line does: the host may not be loaded yet.
    long (*metal_frames)(void) = (long (*)(void))dlsym(RTLD_DEFAULT, "winehost_metal_frames");
    printf("[clock] %.1f s, %ld frames\n", CFAbsoluteTimeGetCurrent() - app_started, metal_frames ? metal_frames() : 0);
  });
  dispatch_resume(timer);
  static dispatch_source_t keep;
  keep = timer;
}
static BOOL gamepad_test;  // "gamepadTest": CI presses A on the touch controller (PressTestButton)
static void PressTestButton(void);

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
// Program), or a launch argument "-program NAME". Without either, library:
// the game library picks it.
static NSString* ProgramName(void) {
  const char* env = getenv("WINPAD_PROGRAM");
  if (env && *env) return @(env);
  NSString* setting = [NSUserDefaults.standardUserDefaults stringForKey:@"program"];
  return setting.length ? setting : @"library";
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
      if (gamepad_test && !frame_view.image)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
          PressTestButton();
        });
      frame_view.image = image;
    });
}

// The view DXMT's Metal layers go on (host/metal-display.m looks this up):
// 640 wide at most for the cube, as large as fits for a game.
static UIView* metal_view;
static BOOL metal_fill;
// A game's picture: where its Metal layer goes (game_rect, set by the layout)
// and whether it has one yet.
static CGRect game_rect;
static BOOL game_has_layer;

__attribute__((used, visibility("default"))) void winehost_show_metal_layer(CALayer* layer) {
  // On the main thread (host/metal-display.m), so the layer is placed in the
  // same transaction that made it.
  void (^show)(void) = ^{
    CGRect b = metal_view.bounds;
    CGFloat w = MIN(b.size.width - 32, metal_fill ? (b.size.height - 96) * 4 / 3 : 640), h = w * 3 / 4;
    layer.frame = metal_fill ? game_rect : CGRectMake((b.size.width - w) / 2, 64, w, h);
    [metal_view.layer addSublayer:layer];
    if (metal_fill) {
      game_has_layer = YES;
      frame_view.hidden = YES;
    }
  };
  if (NSThread.isMainThread) show();
  else dispatch_async(dispatch_get_main_queue(), show);
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

// Game controllers: a Bluetooth or MFi one, or, when none is connected and
// the "touchControls" setting is on, one drawn on the screen
// (GCVirtualController). Their buttons and sticks become keys, which a game
// reads as it reads a keyboard's; its options can remap them. pad_keys is the
// mapping (WinPadPadKeys in Library.m: made for a racing game, triggers and the
// stick drive, changed in the library's settings).
static unsigned short pad_keys[PadCount];
static BOOL pad_down[256];  // the keys the controllers hold down
static BOOL pad_sent;       // a controller has sent a key
static GCVirtualController* touch_pad;

// Sends the keys whose state changed with this snapshot of a controller's inputs.
static void ApplyPad(const BOOL in[PadCount]) {
  BOOL want[256] = {NO};
  for (int i = 0; i < PadCount; i++)
    if (in[i] && pad_keys[i]) want[pad_keys[i]] = YES;
  for (int vk = 0; vk < 256; vk++)
    if (want[vk] != pad_down[vk]) {
      pad_down[vk] = want[vk];
      pad_sent = YES;
      winehost_post_key(vk, want[vk]);
    }
}

static void ReadPad(GCExtendedGamepad* pad) {
  const float tilt = 0.5f;  // how far a stick or trigger goes before its key is down
  GCControllerDirectionPad *dpad = pad.dpad, *stick = pad.leftThumbstick;
  const BOOL in[PadCount] = {
      [PadUp] = dpad.up.pressed || stick.yAxis.value > tilt,
      [PadDown] = dpad.down.pressed || stick.yAxis.value < -tilt,
      [PadLeft] = dpad.left.pressed || stick.xAxis.value < -tilt,
      [PadRight] = dpad.right.pressed || stick.xAxis.value > tilt,
      [PadA] = pad.buttonA.pressed,
      [PadB] = pad.buttonB.pressed,
      [PadX] = pad.buttonX.pressed,
      [PadY] = pad.buttonY.pressed,
      [PadL1] = pad.leftShoulder.pressed,
      [PadR1] = pad.rightShoulder.pressed,
      [PadL2] = pad.leftTrigger.value > tilt,
      [PadR2] = pad.rightTrigger.value > tilt,
      [PadMenu] = pad.buttonMenu.pressed,
      [PadOptions] = pad.buttonOptions.pressed,
  };
  ApplyPad(in);
}

static BOOL PhysicalPadConnected(void) {
  for (GCController* c in GCController.controllers)
    if (c.extendedGamepad && c != touch_pad.controller) return YES;
  return NO;
}

static void ShowTouchPad(void) {
  if (!touch_pad || PhysicalPadConnected()) return;
  [touch_pad connectWithReplyHandler:^(NSError* error) {
    if (error) printf("gamepad: the touch controller did not show: %s\n", error.localizedDescription.UTF8String);
  }];
}

static void Gamepads(BOOL touch) {
  WinPadPadKeys(pad_keys);
  void (^attach)(GCController*) = ^(GCController* c) {
    if (!c.extendedGamepad) return;
    const BOOL virtual = c == touch_pad.controller;
    printf("gamepad: %s connected\n", virtual ? "the touch controller" : (c.vendorName ?: @"a controller").UTF8String);
    c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad* pad, GCControllerElement* element) {
      ReadPad(pad);
    };
    if (!virtual && touch_pad) [touch_pad disconnect];  // a real one replaces the drawn one
  };
  if (touch) {
    GCVirtualControllerConfiguration* config = [GCVirtualControllerConfiguration new];
    config.elements = [NSSet setWithObjects:GCInputLeftThumbstick, GCInputButtonA, GCInputButtonB, GCInputButtonX,
                                            GCInputLeftTrigger, GCInputRightTrigger, nil];
    touch_pad = [[GCVirtualController alloc] initWithConfiguration:config];
  }
  for (GCController* c in GCController.controllers) attach(c);
  NSNotificationCenter* center = NSNotificationCenter.defaultCenter;
  [center addObserverForName:GCControllerDidConnectNotification
                      object:nil
                       queue:NSOperationQueue.mainQueue
                  usingBlock:^(NSNotification* note) {
                    attach(note.object);
                  }];
  [center addObserverForName:GCControllerDidDisconnectNotification
                      object:nil
                       queue:NSOperationQueue.mainQueue
                  usingBlock:^(NSNotification* note) {
                    const BOOL none[PadCount] = {NO};
                    ApplyPad(none);  // no key stays held by a controller that left
                    if (note.object != touch_pad.controller) ShowTouchPad();
                  }];
  ShowTouchPad();
}

// CI's check of the controllers, once the window shows: A on the touch
// controller, which is Enter unless the padKeys setting changed it. The
// simulator may give no touch controller or not run its handler for a value
// set from code; then A goes in through pad_keys directly, and the log says so.
static void PressTestButton(void) {
  GCControllerButtonInput* a = touch_pad.controller.extendedGamepad.buttonA;
  printf("gamepad: pressing A on the touch controller (%s)\n", a ? "connected" : "not connected");
  [a setValue:1];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    [a setValue:0];
    if (pad_sent) return;
    printf("gamepad: no key from the touch controller; pressing A through the mapping\n");
    BOOL in[PadCount] = {NO};
    in[PadA] = YES;
    ApplyPad(in);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
      const BOOL none[PadCount] = {NO};
      ApplyPad(none);
    });
  });
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
  // The registry Wine's wineboot would have made: the builtin COM classes
  // the games need, such as DirectSound's audio device enumerator
  // (tests/wine-loader/prefix/system.reg, the same as run-host.sh's prefix).
  // Without it DirectSound has no device, and a game whose video player keeps
  // time by its sound shows nothing for minutes.
  [fm copyItemAtPath:[bundle stringByAppendingPathComponent:@"system.reg"]
              toPath:[prefix stringByAppendingPathComponent:@"system.reg"]
               error:nil];
  return prefix;
}

@interface WineViewController : UIViewController
@property(nonatomic, strong) UITextView* text;
@property(nonatomic, strong) NSTimer* timer;
@property(atomic, copy) NSString* summary;
@property(nonatomic, copy) NSString* program;
@property(nonatomic, strong) WinPadGame* game;  // the game the library started, or nil
@property(nonatomic, strong) UILabel* status;
@property(nonatomic, strong) NSDate* started;
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
  if (!self.program) self.program = ProgramName();
  const BOOL game = [self.program isEqualToString:@"game"];
  if ([self.program isEqualToString:@"window"] || game) {
    // The window on top, the log below it. (A game's picture, with a status line above.)
    frame_view = [UIImageView new];
    frame_view.contentMode = UIViewContentModeScaleAspectFit;
    frame_view.layer.magnificationFilter = kCAFilterNearest;
    frame_view.backgroundColor = UIColor.secondarySystemBackgroundColor;
    [self.view addSubview:frame_view];
    winehost_frame_hook = ShowFrame;
  }
  if (game) {
    frame_view.backgroundColor = UIColor.blackColor;
    self.status = [UILabel new];
    self.status.font = [UIFont monospacedDigitSystemFontOfSize:15 weight:UIFontWeightSemibold];
    self.status.text = @"Starting the game…";
    [self.view addSubview:self.status];
  }
  metal_view = self.view;
  metal_fill = [self.program isEqualToString:@"game"];
  if (metal_fill) HardwareKeyboard();
  gamepad_test = [self.program isEqualToString:@"window"] && [NSUserDefaults.standardUserDefaults boolForKey:@"gamepadTest"];

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

// The touch controller goes on the window, so the controllers start once it shows.
- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  static BOOL started;
  if (started || !([self.program isEqualToString:@"game"] || gamepad_test)) return;
  started = YES;
  id touch = [NSUserDefaults.standardUserDefaults objectForKey:@"touchControls"];
  Gamepads(gamepad_test || !touch || [touch boolValue]);
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  if (!frame_view) return;
  CGRect b = self.view.bounds;
  if (self.status) {
    // The game's picture as large as fits at 4:3 above a few lines of the log.
    const CGFloat top = self.view.safeAreaInsets.top + 8;
    self.status.frame = CGRectMake(16, top, b.size.width - 32, 24);
    const CGFloat w = MIN(b.size.width - 32, (b.size.height - top - 32 - 120) * 4 / 3), h = w * 3 / 4;
    game_rect = CGRectMake((b.size.width - w) / 2, top + 32, w, h);
    frame_view.frame = game_rect;
    self.text.frame = CGRectMake(0, top + 32 + h, b.size.width, b.size.height - top - 32 - h);
    self.text.textContainerInset = UIEdgeInsetsMake(8, 16, 16, 16);
    return;
  }
  const CGFloat top = self.view.safeAreaInsets.top + 8, h = MIN(b.size.height * 0.45, 480);
  frame_view.frame = CGRectMake(16, top, b.size.width - 32, h);
  self.text.frame = CGRectMake(0, top + h, b.size.width, b.size.height - top - h);
  self.text.textContainerInset = UIEdgeInsetsMake(8, 16, 16, 16);
}

- (void)showLog {
  NSString* summary = self.summary;
  if (self.status) {
    if (!self.started) self.started = [NSDate date];
    // host/metal-display.m counts them; the bundle has it only when it has DXMT.
    static long (*metal_frames)(void);
    if (!metal_frames) metal_frames = (long (*)(void))dlsym(RTLD_DEFAULT, "winehost_metal_frames");
    const long seconds = (long)-[self.started timeIntervalSinceNow], frames = metal_frames ? metal_frames() : 0;
    self.status.text = summary ? [summary stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet]
                       : [NSString stringWithFormat:@"%@ %ld:%02ld · %@", frames ? @"Running" : @"Starting", seconds / 60,
                                                    seconds % 60,
                                                    frames            ? [NSString stringWithFormat:@"%ld frames drawn", frames]
                                                    : game_has_layer  ? @"Direct3D window open, no frame yet"
                                                    : frame_view.image ? @"a window is shown"
                                                                       : @"no window yet"];
  }
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
  StartLogClock();

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
    NSString* exe = self.game ? self.game.exe : [NSUserDefaults.standardUserDefaults stringForKey:@"game"];
    program = DocumentsPath(exe.length ? exe : @"NFSU2/SPEED2.EXE");
    // The Ultimate ASI Loader many games carry is a dinput8.dll of their own.
    setenv("WINEDLLOVERRIDES", "dinput8=n,b", 1);
  }
  // The game has an AOT image only where game-aot.sh put one into the
  // project on the Mac it was built on; without it the game runs with the JIT.
  // The library picked a game's own image (Library.m), else fexaot-game.dylib.
  NSString* frameworks = NSBundle.mainBundle.privateFrameworksPath;
  NSString* game_image = self.game ? self.game.image : [frameworks stringByAppendingPathComponent:@"fexaot-game.dylib"];
  if (game_image && ![NSFileManager.defaultManager fileExistsAtPath:game_image]) game_image = nil;
  if (!cube && (!game || game_image)) {
    // Each program has its own AOT image: hello's is fexaot.dylib, NAME's fexaot-NAME.dylib.
    NSString* path = game ? game_image
                          : [frameworks stringByAppendingPathComponent:[name isEqualToString:@"hello"]
                                                                           ? @"fexaot.dylib"
                                                                           : [NSString stringWithFormat:@"fexaot-%@.dylib", name]];
    image = path.lastPathComponent;
    setenv("WINEHOST_AOT_IMAGE", path.fileSystemRepresentation, 1);
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
    // With gamepadTest the touch controller's A (Enter) closes it instead.
    if (!gamepad_test) setenv("WINEHOST_CLICK", "50,50", 1);
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
                               (window && gamepad_test ? [log containsString:[NSString stringWithFormat:@"winehost: key %#x down", pad_keys[PadA]]]
                                : window ? [log containsString:@"winehost: window content changed after the click"]
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
  if (![ProgramName() isEqualToString:@"library"]) {
    self.window.rootViewController = [WineViewController new];
    [self.window makeKeyAndVisible];
    return;
  }
  // The library hands over to Wine, which runs once per process: the app is
  // started again for the next game. With libraryTest (CI) it only says what
  // it would run.
  LibraryViewController* library = [LibraryViewController new];
  __weak UIWindow* window = self.window;
  library.start = ^(NSString* program, WinPadGame* game) {
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"libraryTest"]) {
      NSString* path = DocumentsPath(@"library.txt");
      NSString* report = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
      report = [report stringByAppendingFormat:@"start: %@ %@, image %@\n%@\n", program, game.exe ?: @"-",
                                               game.image.lastPathComponent ?: @"none", FinishedMarker];
      [report writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
      return;
    }
    WineViewController* wine = [WineViewController new];
    wine.program = program;
    wine.game = game;
    window.rootViewController = wine;
  };
  self.window.rootViewController = library;
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
  app_started = CFAbsoluteTimeGetCurrent();
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([WineAppDelegate class]));
  }
}
