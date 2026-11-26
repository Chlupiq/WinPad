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
// Direct3D 9 program drawing through DXMT and Metal (d3d11-triangle and
// d3d10-triangle, tests/wine-i386/d3d11-triangle.c, the same through
// Direct3D 11 and 10: schemes "WinPadWine D3D11" and "WinPadWine D3D10";
// gl-triangle, tests/wine-i386/gl-triangle.c, through OpenGL: "WinPadWine OpenGL"), and game (the
// "WinPadWine Game" scheme): a game the user copied into Documents, the
// "game" setting naming its program there (NFSU2/SPEED2.EXE by default).
// The game starts in its own folder (winehost.c) and runs until it ends or
// the app is stopped. Their frames show on screen through a Metal layer,
// and a hardware keyboard's keys go to the game (HardwareKeyboard), as do a
// game controller's or the touch controller's buttons (Gamepads). Until the
// game has a Metal layer, its first window's GDI frames show there instead
// (a launcher, a message box), and a status line above says how long it has
// run and how many frames it has drawn.
// An iPad with TXM runs no JIT code under Xcode's debugger, so the game
// runs with NoJIT from Frameworks/fexaot-game.dylib when the project has one
// (game-aot.sh builds it on the Mac with the game), FEX's interpreter running
// the blocks it lacks. With StikDebug attached (its universal.js script, which
// makes the JIT pool executable: JITPool.c, WinPadJIT.m) the game runs with
// FEX's JIT instead and needs no image.
//
// Everything Wine and FEX print goes to Documents/wine.log, shown on screen
// while it runs. An x86 block missing from the image runs in FEX's IR
// interpreter (patches/fex-wow64/0019) and is written to the code map in
// Documents/fexcache/<game folder>/codemap/new (the test programs:
// Documents/fexcache/codemap/new), so a later image can have it. If the run
// stops the app, the next launch shows the log of that run.
#include <os/proc.h>
#import <objc/message.h>
#import <AVFoundation/AVFoundation.h>
#import <GameController/GameController.h>
#import <QuartzCore/QuartzCore.h>
#import <UIKit/UIKit.h>

#import "Library.h"
#import "WinPadJIT.h"
#import "WinPadAuto.h"
#include "WiniosGamepad.h"  // Madeira's controller bridge to Wine (link-host.sh links it)
#include "JITPool.h"
#import "WinPadRedist.h"

#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <sys/stat.h>
#include <sys/sysctl.h>
#include <sys/time.h>
#include <unistd.h>

int winehost_main(int argc, char* argv[]);
void winehost_post_key(unsigned short vk, int down);
extern void (*winehost_frame_hook)(void* hwnd, int width, int height, int stride, const void* bits);

static NSString* const FinishedMarker = @"== finished";

// When the app started (main), for the log's [clock] lines.
static CFAbsoluteTime app_started;

// The frames of programs that draw with GDI (a DirectDraw game through wined3d's GDI
// renderer), for the run record (WinPadRunProgress) next to Metal's.
static volatile long gdi_frames;

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
    const long frames = metal_frames ? metal_frames() : 0;
    printf("[clock] %.1f s, %ld frames\n", CFAbsoluteTimeGetCurrent() - app_started, frames);
    // The game's run record, for the library's look at how it went (WinPadJudgeLastRun).
    static int tick;
    if (++tick % 2 == 0) WinPadRunProgress(frames + gdi_frames);
  });
  dispatch_resume(timer);
  static dispatch_source_t keep;
  keep = timer;
}
static BOOL gamepad_test;  // "gamepadTest": CI presses A on the touch controller (PressTestButton)
static void PressTestButton(void);
static BOOL mouse_test;  // "mouseTest": CI moves the mouse and clicks the window through winehost_post_mouse
static void ClickTest(void);

void WinPadLogLaunch(NSString* what) {
  static double started;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    struct kinfo_proc info;
    size_t size = sizeof info;
    int mib[4] = {CTL_KERN, KERN_PROC, KERN_PROC_PID, getpid()};
    struct timeval now;
    gettimeofday(&now, NULL);
    started = !sysctl(mib, 4, &info, &size, NULL, 0) && info.kp_proc.p_starttime.tv_sec
                  ? info.kp_proc.p_starttime.tv_sec + info.kp_proc.p_starttime.tv_usec / 1e6
                  : now.tv_sec + now.tv_usec / 1e6;
  });
  struct timeval now;
  gettimeofday(&now, NULL);
  NSLog(@"[launch] %@: %.0f ms since the process started", what, (now.tv_sec + now.tv_usec / 1e6 - started) * 1000);
}

static NSString* DocumentsPath(NSString* name) {
  NSString* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
  return [docs stringByAppendingPathComponent:name];
}

static NSString* ReadLog(void) {
  return [NSString stringWithContentsOfFile:DocumentsPath(@"wine.log") encoding:NSUTF8StringEncoding error:nil] ?: @"";
}

// The end of the log, KEEP bytes, for the screen: a game's log grows for as long as it runs.
static NSString* ReadLogEnd(unsigned long long keep) {
  NSFileHandle* f = [NSFileHandle fileHandleForReadingAtPath:DocumentsPath(@"wine.log")];
  if (!f) return @"";
  const unsigned long long size = [f seekToEndOfFile];
  [f seekToFileOffset:size > keep ? size - keep : 0];
  NSData* data = [f readDataToEndOfFile];
  [f closeFile];
  NSString* tail = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?:
                   [[NSString alloc] initWithData:data encoding:NSISOLatin1StringEncoding];
  return size > keep ? [@"…\n" stringByAppendingString:tail] : tail;
}

static NSString* ReadLogTail(void) {
  return ReadLogEnd(64 * 1024);
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
  gdi_frames++;
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
      if (mouse_test && !frame_view.image)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 2 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
          ClickTest();
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
static CALayer* game_layer;
// How the picture fills the screen (WinPadPictureScaling: fit, stretch or fill) and whether
// it stays out of an iPhone's camera cutout; set before the game starts.
static NSString* picture_scaling;
static BOOL picture_avoids_cutout;
static NSInteger picture_stretch;  // "custom": how much wider than its shape, in percent
static CGSize picture_laid_out;    // the drawable size the custom layout was made for

// DXMT presents frames of the game window's size (1024x768) into the layer; Core Animation
// scales them to the layer's frame as its contentsGravity says.
static void ScalePicture(CALayer* layer) {
  // "custom" sizes the layer itself (viewDidLayoutSubviews) and fills it.
  layer.contentsGravity = [picture_scaling isEqualToString:@"stretch"] || [picture_scaling isEqualToString:@"custom"]
                              ? kCAGravityResize
                          : [picture_scaling isEqualToString:@"fill"]  ? kCAGravityResizeAspectFill
                                                                       : kCAGravityResizeAspect;
  layer.masksToBounds = YES;
  layer.backgroundColor = UIColor.blackColor.CGColor;
}

__attribute__((used, visibility("default"))) void winehost_show_metal_layer(CALayer* layer) {
  // On the main thread (host/metal-display.m), so the layer is placed in the
  // same transaction that made it.
  void (^show)(void) = ^{
    CGRect b = metal_view.bounds;
    CGFloat w = MIN(b.size.width - 32, metal_fill ? (b.size.height - 96) * 4 / 3 : 640), h = w * 3 / 4;
    layer.frame = metal_fill ? game_rect : CGRectMake((b.size.width - w) / 2, 64, w, h);
    // A game's goes beneath every view, so the controls drawn over it stay
    // on top (the log is hidden then); the cube's goes over the log.
    if (metal_fill) [metal_view.layer insertSublayer:layer atIndex:0];
    else [metal_view.layer addSublayer:layer];
    if (metal_fill) {
      // From now on the game has the whole screen (viewDidLayoutSubviews).
      ScalePicture(layer);
      game_has_layer = YES;
      game_layer = layer;
      frame_view.hidden = YES;
      [metal_view setNeedsLayout];
      [metal_view.window.rootViewController setNeedsStatusBarAppearanceUpdate];
      [metal_view.window.rootViewController setNeedsUpdateOfHomeIndicatorAutoHidden];
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

// The mouse: the program gets it as a Windows mouse's input (winehost_post_mouse, looked up
// at run time: a winehost.o built before it, as a Mac's own project may have, has none). A
// paired mouse or trackpad (GCMouse) moves it by its own deltas, which mouse-look in a game like
// Call of Duty 4 needs; a finger on the picture does as the game's "touchMouse" says
// (WinPadMouseView); a controller's stick moves it with the game's "padMouse"; and a controller
// key 1, 2 or 4 (VK_LBUTTON, VK_RBUTTON, VK_MBUTTON) in its "padKeys" is a mouse button.
enum {
  MouseMove = 0x1, MouseLeftDown = 0x2, MouseLeftUp = 0x4, MouseRightDown = 0x8, MouseRightUp = 0x10,
  MouseMiddleDown = 0x20, MouseMiddleUp = 0x40, MouseWheel = 0x800, MouseAbsolute = 0x8000
};
static double mouse_speed = 1;  // the game's "mouseSpeed": how far a move goes, 1 as it came
static int pad_mouse_stick = -1;  // the game's "padMouse": PadLUp or PadRUp, the stick that moves the mouse
static CGPoint pad_stick[2];      // that stick's tilt on the controller and on the touch controller, up +y

static void PostMouse(float x, float y, unsigned flags, int data) {
  static void (*post)(float, float, unsigned, int);
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    post = (void (*)(float, float, unsigned, int))dlsym(RTLD_DEFAULT, "winehost_post_mouse");
    if (!post) printf("mouse: this winehost has no winehost_post_mouse, so the program gets no mouse\n");
  });
  if (post) post(x, y, flags, data);
}

// A relative move by DX, DY pixels (right, down); what is less than a pixel adds up.
static void MoveMouse(double dx, double dy) {
  static double rest_x, rest_y;
  rest_x += dx * mouse_speed;
  rest_y += dy * mouse_speed;
  const double x = trunc(rest_x), y = trunc(rest_y);
  if (!x && !y) return;
  rest_x -= x;
  rest_y -= y;
  PostMouse((float)x, (float)y, MouseMove, 0);
}

// Button 0 is the left one, 1 the right, 2 the middle.
static void MouseButton(int button, BOOL down) {
  static const unsigned flags[3][2] = {{MouseLeftUp, MouseLeftDown}, {MouseRightUp, MouseRightDown},
                                       {MouseMiddleUp, MouseMiddleDown}};
  if (button >= 0 && button < 3) PostMouse(0, 0, flags[button][down ? 1 : 0], 0);
}

// The mouse button a controller key is (VK_LBUTTON, VK_RBUTTON, VK_MBUTTON), or -1.
static int MouseButtonOfKey(unsigned short vk) {
  return vk == 0x01 ? 0 : vk == 0x02 ? 1 : vk == 0x04 ? 2 : -1;
}

static void HardwareMouse(void) {
  void (^attach)(GCMouse*) = ^(GCMouse* mouse) {
    GCMouseInput* input = mouse.mouseInput;
    printf("mouse: %s connected\n", (mouse.vendorName ?: @"a mouse").UTF8String);
    // GameController's y goes up, Windows' down.
    input.mouseMovedHandler = ^(GCMouseInput* in, float dx, float dy) {
      MoveMouse(dx, -dy);
    };
    input.leftButton.pressedChangedHandler = ^(GCControllerButtonInput* b, float v, BOOL pressed) {
      MouseButton(0, pressed);
    };
    input.rightButton.pressedChangedHandler = ^(GCControllerButtonInput* b, float v, BOOL pressed) {
      MouseButton(1, pressed);
    };
    input.middleButton.pressedChangedHandler = ^(GCControllerButtonInput* b, float v, BOOL pressed) {
      MouseButton(2, pressed);
    };
    // A notch of the wheel each time the scroll moves; up is away from the player in both.
    input.scroll.yAxis.valueChangedHandler = ^(GCControllerAxisInput* axis, float v) {
      if (v) PostMouse(0, 0, MouseWheel, v > 0 ? 120 : -120);
    };
    // With a mouse the game keeps the pointer (WineViewController prefersPointerLocked).
    [metal_view.window.rootViewController setNeedsUpdateOfPrefersPointerLocked];
  };
  for (GCMouse* mouse in GCMouse.mice) attach(mouse);
  [NSNotificationCenter.defaultCenter addObserverForName:GCMouseDidConnectNotification
                                                  object:nil
                                                   queue:NSOperationQueue.mainQueue
                                              usingBlock:^(NSNotification* note) {
                                                attach(note.object);
                                              }];
}

// A finger on the game's picture (beneath the touch controller, which takes the fingers on its
// own parts), as the game's "touchMouse" says: "direct" (the default) points where the finger
// is and holds the left button while it is down, as a touch screen does on Windows; "trackpad"
// is a laptop's touchpad for games that hide the cursor and turn the view with the mouse
// (Call of Duty 4): a finger moving moves the mouse by as much, a tap is a left click and a tap
// of two fingers a right one; "off" gives the program nothing.
@interface WinPadMouseView : UIView
@property(nonatomic) BOOL trackpad;
@end

@implementation WinPadMouseView {
  UITouch* _finger;  // the finger that points or moves
  CGPoint _last, _start;
  CFTimeInterval _began;
  BOOL _moved, _two;  // it went further than a tap; a second finger came down with it
}

// Where on the picture POINT is, as fractions of it (the program's main window), or NO if
// there is no picture yet.
static BOOL PictureFraction(UIView* view, CGPoint point, CGPoint* out) {
  CGRect frame, picture;
  CGSize content;
  if (game_has_layer && game_layer) {
    frame = game_layer.frame;
    content = [game_layer isKindOfClass:CAMetalLayer.class] ? ((CAMetalLayer*)game_layer).drawableSize : frame.size;
    NSString* gravity = game_layer.contentsGravity;
    if ([gravity isEqualToString:kCAGravityResize] || content.width <= 0 || content.height <= 0) {
      picture = frame;
    } else {
      const CGFloat fit = MIN(frame.size.width / content.width, frame.size.height / content.height),
                    fill = MAX(frame.size.width / content.width, frame.size.height / content.height);
      const CGFloat k = [gravity isEqualToString:kCAGravityResizeAspectFill] ? fill : fit;
      const CGSize size = CGSizeMake(content.width * k, content.height * k);
      picture = CGRectMake(CGRectGetMidX(frame) - size.width / 2, CGRectGetMidY(frame) - size.height / 2, size.width, size.height);
    }
  } else if (frame_view.image && !frame_view.hidden) {
    frame = frame_view.frame;
    content = frame_view.image.size;
    const CGFloat k = MIN(frame.size.width / content.width, frame.size.height / content.height);
    const CGSize size = CGSizeMake(content.width * k, content.height * k);
    picture = CGRectMake(CGRectGetMidX(frame) - size.width / 2, CGRectGetMidY(frame) - size.height / 2, size.width, size.height);
  } else {
    return NO;
  }
  if (picture.size.width <= 0 || picture.size.height <= 0) return NO;
  const CGPoint p = [view convertPoint:point toView:metal_view];
  *out = CGPointMake((p.x - picture.origin.x) / picture.size.width, (p.y - picture.origin.y) / picture.size.height);
  return YES;
}

// How many of the program's pixels a point of the screen is: the monitor Wine reports over the
// picture's width, so a finger across the picture moves the mouse across the screen.
static double PixelsPerPoint(UIView* view) {
  const char* w = getenv("MADEIRA_SCREEN_W");
  const double screen = w && atoi(w) > 0 ? atoi(w) : 1024;
  const CGFloat width = game_has_layer && game_layer ? game_layer.frame.size.width : view.bounds.size.width;
  return width > 0 ? screen / width : 1;
}

- (instancetype)initWithFrame:(CGRect)frame {
  if (!(self = [super initWithFrame:frame])) return nil;
  self.multipleTouchEnabled = YES;
  self.backgroundColor = UIColor.clearColor;
  return self;
}

// Only the picture takes fingers: before the game shows, the log beneath still scrolls.
- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent*)event {
  if (game_has_layer) return [super pointInside:point withEvent:event];
  return frame_view.image && !frame_view.hidden && CGRectContainsPoint([self convertRect:frame_view.frame fromView:metal_view], point);
}

// A paired mouse's clicks come as GCMouse's (HardwareMouse), not as touches too.
static BOOL IsFinger(UITouch* touch) {
  return touch.type == UITouchTypeDirect || touch.type == UITouchTypePencil;
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  for (UITouch* touch in touches) {
    if (!IsFinger(touch)) continue;
    if (_finger) {
      _two = YES;
      continue;
    }
    _finger = touch;
    _start = _last = [touch locationInView:self];
    _began = touch.timestamp;
    _moved = _two = NO;
    CGPoint at;
    if (!self.trackpad && PictureFraction(self, _start, &at)) {
      PostMouse(at.x, at.y, MouseMove | MouseAbsolute, 0);
      PostMouse(at.x, at.y, MouseMove | MouseLeftDown | MouseAbsolute, 0);
    }
  }
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  if (![touches containsObject:_finger]) return;
  const CGPoint p = [_finger locationInView:self];
  if (hypot(p.x - _start.x, p.y - _start.y) > 8) _moved = YES;
  if (self.trackpad) {
    if (_moved) {
      const double k = PixelsPerPoint(self);
      MoveMouse((p.x - _last.x) * k, (p.y - _last.y) * k);
    }
  } else {
    CGPoint at;
    if (PictureFraction(self, p, &at)) PostMouse(at.x, at.y, MouseMove | MouseAbsolute, 0);
  }
  _last = p;
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  if (![touches containsObject:_finger]) return;
  const CGPoint p = [_finger locationInView:self];
  if (self.trackpad) {
    // A tap: short, and the finger stayed where it was.
    if (!_moved && _finger.timestamp - _began < 0.35) {
      MouseButton(_two ? 1 : 0, YES);
      MouseButton(_two ? 1 : 0, NO);
    }
  } else {
    CGPoint at;
    if (PictureFraction(self, p, &at)) PostMouse(at.x, at.y, MouseLeftUp | MouseAbsolute, 0);
    else MouseButton(0, NO);
  }
  _finger = nil;
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  if (![touches containsObject:_finger]) return;
  if (!self.trackpad) MouseButton(0, NO);
  _finger = nil;
}
@end

// The stick that moves the mouse ("padMouse"), 60 times a second: as far as it is tilted, up to
// 1200 pixels a second, slow near the middle for aiming.
@interface WinPadStickMouse : NSObject
@end
@implementation WinPadStickMouse
- (void)tick:(CADisplayLink*)link {
  static CFTimeInterval last;
  const CFTimeInterval now = link.timestamp, dt = last ? MIN(now - last, 0.1) : 0;
  last = now;
  const CGPoint a = pad_stick[0], b = pad_stick[1];
  const CGPoint v = hypot(a.x, a.y) >= hypot(b.x, b.y) ? a : b;
  const double r = MIN(1.0, hypot(v.x, v.y)), dead = 0.12;
  if (r <= dead || dt <= 0) return;
  const double speed = 1200 * pow((r - dead) / (1 - dead), 2) / r;
  MoveMouse(v.x * speed * dt, -v.y * speed * dt);
}
@end
static WinPadStickMouse* stick_mouse;

// CI's check of the mouse, once the window shows: a move by 12,8 pixels (mouse-look's kind),
// then a click in the middle of the window, which closes it.
static void ClickTest(void) {
  printf("mouse: moving the mouse by 12,8 and clicking the middle of the window\n");
  MoveMouse(12, 8);
  PostMouse(0.5f, 0.5f, MouseMove | MouseAbsolute, 0);
  PostMouse(0.5f, 0.5f, MouseMove | MouseLeftDown | MouseAbsolute, 0);
  PostMouse(0.5f, 0.5f, MouseLeftUp | MouseAbsolute, 0);
}

// Game controllers: a Bluetooth or MFi one and, while the "touchControls"
// setting is on, one drawn on the screen (WinPadTouchPad), shown even with
// another one paired, which the player may not be holding. Their buttons and
// sticks become keys, which a game reads as it reads a keyboard's; its options
// can remap them. pad_keys is the mapping (WinPadPadKeys in Library.m: made for
// a racing game, triggers and the left stick drive, changed in the library's
// settings).
static unsigned short pad_keys[PadCount];
enum { PadFromController, PadFromTouch };
static BOOL pad_in[2][PadCount];  // what the controllers and the touch controller hold
static BOOL pad_down[256];        // the keys the controllers hold down
static BOOL pad_sent;             // a controller has sent a key

// A game that reads a controller itself (its "padMode", WinPadAuto.m for games that import
// XInput): the controllers go to it as one instead of as keys, through Madeira's bridge
// (WiniosGamepad.h). "xinput": an Xbox controller, which Wine's xinput reads through win32u
// (ios_gamepad_query), 32- and 64-bit. "hid": a generic HID game controller the wineserver
// serves (hidpad_ios.c, MADEIRA_HIDPAD), which DirectInput, hid.dll and Windows.Gaming.Input see.
enum { PadAsKeys, PadAsXInput, PadAsHID };
static int pad_native = PadAsKeys;
static struct winios_gamepad pad_sample;
static BOOL pad_sample_set;
static float pad_analog[6];       // the controller's left x, y, right x, y, left and right trigger
static BOOL pad_thumb[2];         // its stick buttons
static BOOL pad_controller;       // a controller is connected
static BOOL pad_touch;            // the touch controller is on the screen

static int16_t PadAxis(float value, BOOL minus, BOOL plus) {
  if (plus && !minus) return 32767;
  if (minus && !plus) return -32768;
  const float v = value > 1 ? 1 : value < -1 ? -1 : value;
  return (int16_t)(v < 0 ? v * 32768 : v * 32767);
}

// Gives the game the state of both controllers as one (ApplyPad's PAD_IN, with the
// controller's sticks and triggers as they are).
static void WritePad(void) {
  if (pad_native == PadAsKeys) return;
  const BOOL* c = pad_in[PadFromController];
  const BOOL* t = pad_in[PadFromTouch];
#define HELD(i) (c[i] || t[i])
  static const struct {
    int input;
    uint16_t bit;
  } map[] = {{PadUp, 0x0001},   {PadDown, 0x0002}, {PadLeft, 0x0004}, {PadRight, 0x0008}, {PadMenu, 0x0010},
             {PadOptions, 0x0020}, {PadL1, 0x0100}, {PadR1, 0x0200}, {PadA, 0x1000},   {PadB, 0x2000},
             {PadX, 0x4000},    {PadY, 0x8000}};
  struct winios_gamepad p = {0};
  p.connected = pad_controller || pad_touch;
  uint16_t buttons = 0;
  for (size_t i = 0; i < sizeof(map) / sizeof(map[0]); i++)
    if (HELD(map[i].input)) buttons |= map[i].bit;
  if (pad_thumb[0]) buttons |= 0x0040;
  if (pad_thumb[1]) buttons |= 0x0080;
  p.buttons = buttons;
  // The touch controller's sticks and triggers are all or nothing; a controller's as they are.
  p.lx = PadAxis(pad_analog[0], t[PadLLeft], t[PadLRight]);
  p.ly = PadAxis(pad_analog[1], t[PadLDown], t[PadLUp]);
  p.rx = PadAxis(pad_analog[2], t[PadRLeft], t[PadRRight]);
  p.ry = PadAxis(pad_analog[3], t[PadRDown], t[PadRUp]);
  p.left_trigger = t[PadL2] ? 255 : (uint8_t)(pad_analog[4] * 255);
  p.right_trigger = t[PadR2] ? 255 : (uint8_t)(pad_analog[5] * 255);
#undef HELD
  if (pad_sample_set && !memcmp(&p, &pad_sample, sizeof(p))) return;
  if (!pad_sample_set || p.buttons != pad_sample.buttons || p.connected != pad_sample.connected)
    printf("gamepad: %s buttons %#x%s\n", pad_native == PadAsHID ? "HID" : "XInput", p.buttons,
           p.connected ? "" : " (not connected)");
  pad_sample = p;
  pad_sample_set = YES;
  if (pad_native == PadAsXInput) {
    // The bridge numbers the samples (packet) itself.
    winios_gamepad_set_state(0, p.connected ? &p : NULL);
    return;
  }
  struct winios_hidpad h = {0};
  h.connected = p.connected;
  h.buttons = p.buttons;
  if (p.left_trigger > 30) h.buttons |= WINIOS_HIDPAD_L2;
  if (p.right_trigger > 30) h.buttons |= WINIOS_HIDPAD_R2;
  h.lx = p.lx, h.ly = p.ly, h.rx = p.rx, h.ry = p.ry;
  h.left_trigger = p.left_trigger, h.right_trigger = p.right_trigger;
  h.battery = WINIOS_HIDPAD_BATTERY_UNKNOWN;
  winios_hidpad_set_state(p.connected ? &h : NULL);
}

// Sends the keys whose state changed with this snapshot of a controller's
// inputs; a key is down while either controller holds an input that is it.
static void ApplyPad(int from, const BOOL in[PadCount]) {
  memcpy(pad_in[from], in, sizeof pad_in[from]);
  if (pad_native != PadAsKeys) {
    pad_sent = YES;
    WritePad();
    return;
  }
  BOOL want[256] = {NO};
  for (int i = 0; i < PadCount; i++) {
    // The stick that moves the mouse is no keys.
    if (pad_mouse_stick >= 0 && i >= pad_mouse_stick && i < pad_mouse_stick + 4) continue;
    if ((pad_in[PadFromController][i] || pad_in[PadFromTouch][i]) && pad_keys[i]) want[pad_keys[i]] = YES;
  }
  for (int vk = 0; vk < 256; vk++)
    if (want[vk] != pad_down[vk]) {
      pad_down[vk] = want[vk];
      pad_sent = YES;
      if (MouseButtonOfKey(vk) >= 0) MouseButton(MouseButtonOfKey(vk), want[vk]);
      else winehost_post_key(vk, want[vk]);
    }
}

// Exit (the touch controller's button between View and Menu, a controller's Xbox/Home
// button): asks whether to end the game (WineViewController askToExit). Wine runs once per
// process, so ending the game closes the app; opened again, it shows the game library.
// While the question shows, Exit or Home again or A ends the game, B goes back to it.
enum { PadExit = PadCount };  // the touch controller's Exit, which no key is
static void (^exit_asked)(void);   // set by the WineViewController running a game
static UIAlertController* exit_alert;
static void (^exit_now)(void);

static void RequestExit(void) {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (exit_alert && exit_now) exit_now();
    else if (exit_asked) exit_asked();
  });
}

static void ReadPad(GCExtendedGamepad* pad) {
  static BOOL home_was;
  const BOOL home = pad.buttonHome.pressed;
  if (home && !home_was) RequestExit();
  home_was = home;
  // While the question is up the controller answers it and the game gets nothing.
  if (exit_alert) {
    static BOOL a_was, b_was;
    if (pad.buttonA.pressed && !a_was && exit_now) dispatch_async(dispatch_get_main_queue(), exit_now);
    if (pad.buttonB.pressed && !b_was)
      dispatch_async(dispatch_get_main_queue(), ^{
        [exit_alert dismissViewControllerAnimated:YES completion:nil];
        exit_alert = nil;
      });
    a_was = pad.buttonA.pressed;
    b_was = pad.buttonB.pressed;
    return;
  }
  const float tilt = 0.5f;  // how far a stick or trigger goes before its key is down
  GCControllerDirectionPad *dpad = pad.dpad, *stick = pad.leftThumbstick, *right = pad.rightThumbstick;
  const BOOL in[PadCount] = {
      [PadUp] = dpad.up.pressed,
      [PadDown] = dpad.down.pressed,
      [PadLeft] = dpad.left.pressed,
      [PadRight] = dpad.right.pressed,
      [PadLUp] = stick.yAxis.value > tilt,
      [PadLDown] = stick.yAxis.value < -tilt,
      [PadLLeft] = stick.xAxis.value < -tilt,
      [PadLRight] = stick.xAxis.value > tilt,
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
      [PadRUp] = right.yAxis.value > tilt,
      [PadRDown] = right.yAxis.value < -tilt,
      [PadRLeft] = right.xAxis.value < -tilt,
      [PadRRight] = right.xAxis.value > tilt,
  };
  pad_analog[0] = stick.xAxis.value;
  pad_analog[1] = stick.yAxis.value;
  pad_analog[2] = right.xAxis.value;
  pad_analog[3] = right.yAxis.value;
  pad_analog[4] = pad.leftTrigger.value;
  pad_analog[5] = pad.rightTrigger.value;
  if (@available(iOS 12.1, *)) {
    pad_thumb[0] = pad.leftThumbstickButton.pressed;
    pad_thumb[1] = pad.rightThumbstickButton.pressed;
  }
  GCControllerDirectionPad* mouse_stick = pad_mouse_stick == PadLUp ? stick : right;
  pad_stick[0] = CGPointMake(mouse_stick.xAxis.value, mouse_stick.yAxis.value);
  ApplyPad(PadFromController, in);
}

// One part of the touch controller: a button, a stick or the d-pad. A stick's
// or the d-pad's input is the first of its four directions (up, down, left,
// right are consecutive in the Pad enum).
typedef enum { TouchButton, TouchStick, TouchDpad } TouchKind;
@interface WinPadTouchPart : NSObject
@property(nonatomic) TouchKind kind;
@property(nonatomic) int input;
@property(nonatomic) CGPoint center;
@property(nonatomic) CGFloat radius;  // a stick's travel, a d-pad arm's length or half a button's width
@property(nonatomic, strong) UIView* view;
@property(nonatomic, strong) UIView* knob;  // a stick's
@property(nonatomic, strong) NSArray<UIView*>* arms;  // the d-pad's, in direction order
@end
@implementation WinPadTouchPart
@end

// The touch controller, laid out as an Xbox controller over the game: the left
// stick above the d-pad on the left, A B X Y above the right stick on the right,
// LT and LB in the top left corner, RT and RB in the top right one, View and
// Menu between them. In the PlayStation look (WinPadPadStyle) the d-pad is above
// the left stick and the buttons are ✕ ○ □ △, L1 L2 R1 R2, Create and Options;
// in Nintendo's B A Y X, L ZL R ZR, − and +. Its parts are see-through and take several
// fingers at once; a finger can slide from button to button. Touches
// elsewhere go to the views beneath it.
@interface WinPadTouchPad : UIView
- (void)press:(int)input down:(BOOL)down;
@end

@implementation WinPadTouchPad {
  NSArray<WinPadTouchPart*>* _parts;
  NSMapTable<UITouch*, WinPadTouchPart*>* _touches;
  BOOL _pressed[PadCount];  // press:down:, CI's
  BOOL _dpadOnTop;          // the PlayStation look: the d-pad above the left stick
  BOOL _exitHeld;           // a finger is on Exit
}

static UIView* TouchCircle(NSString* text, UIColor* color) {
  UILabel* label = [UILabel new];
  label.text = text;
  label.textAlignment = NSTextAlignmentCenter;
  label.textColor = color;
  label.backgroundColor = [UIColor colorWithWhite:1 alpha:0.15];
  label.layer.borderColor = [UIColor colorWithWhite:1 alpha:0.45].CGColor;
  label.layer.borderWidth = 2;
  label.clipsToBounds = YES;
  return label;
}

- (instancetype)initWithFrame:(CGRect)frame {
  if (!(self = [super initWithFrame:frame])) return nil;
  self.multipleTouchEnabled = YES;
  _touches = [NSMapTable strongToStrongObjectsMapTable];
  NSMutableArray* parts = [NSMutableArray new];
  WinPadTouchPart* (^add)(TouchKind, int, NSString*, UIColor*) = ^(TouchKind kind, int input, NSString* text, UIColor* color) {
    WinPadTouchPart* part = [WinPadTouchPart new];
    part.kind = kind;
    part.input = input;
    part.view = TouchCircle(kind == TouchButton ? text : nil, color);
    part.view.userInteractionEnabled = NO;
    [self addSubview:part.view];
    if (kind == TouchStick) {
      part.knob = TouchCircle(text, color);
      part.knob.backgroundColor = [UIColor colorWithWhite:1 alpha:0.3];
      [part.view addSubview:part.knob];
    } else if (kind == TouchDpad) {
      part.view.backgroundColor = UIColor.clearColor;
      part.view.layer.borderWidth = 0;
      NSMutableArray* arms = [NSMutableArray new];
      for (NSString* arrow in @[ @"▲", @"▼", @"◀", @"▶" ]) {
        UIView* arm = TouchCircle(arrow, UIColor.whiteColor);
        arm.layer.cornerRadius = 8;
        [part.view addSubview:arm];
        [arms addObject:arm];
      }
      part.arms = arms;
    }
    [parts addObject:part];
    return part;
  };
  NSString* style = WinPadPadStyle();
  _dpadOnTop = [style isEqualToString:@"playstation"];
  UIColor* white = UIColor.whiteColor;
  // The face buttons' colours: Xbox's green, red, blue, yellow; PlayStation's blue cross, red
  // circle, pink square, green triangle; Nintendo's are plain.
  const uint32_t faces[3][4] = {{0x73D94D, 0xF2594D, 0x4D99FF, 0xFFCC33},
                                {0x7FA8FF, 0xFF6666, 0xF08CD0, 0x4DD9A6},
                                {0xFFFFFF, 0xFFFFFF, 0xFFFFFF, 0xFFFFFF}};
  const int look = _dpadOnTop ? 1 : [style isEqualToString:@"nintendo"] ? 2 : 0;
  add(TouchStick, PadLUp, WinPadPadLabel(PadLUp, style), white);
  add(TouchDpad, PadUp, nil, white);
  add(TouchStick, PadRUp, WinPadPadLabel(PadRUp, style), white);
  for (int b = PadA; b <= PadY; b++) {
    const uint32_t c = faces[look][b - PadA];
    add(TouchButton, b, WinPadPadLabel(b, style),
        [UIColor colorWithRed:(c >> 16) / 255.0 green:(c >> 8 & 0xff) / 255.0 blue:(c & 0xff) / 255.0 alpha:1]);
  }
  for (int b = PadL1; b <= PadOptions; b++) add(TouchButton, b, WinPadPadLabel(b, style), white);
  add(TouchButton, PadExit, @"Exit", [UIColor colorWithRed:1 green:0.55 blue:0.5 alpha:1]);
  printf("gamepad: touch controller in the %s look\n", style.UTF8String);
  _parts = parts;
  return self;
}

- (WinPadTouchPart*)part:(int)input kind:(TouchKind)kind {
  for (WinPadTouchPart* part in _parts)
    if (part.input == input && part.kind == kind) return part;
  return nil;
}

// u is the size of a button: a 13th of the screen's short side.
- (void)layoutSubviews {
  [super layoutSubviews];
  const CGRect b = UIEdgeInsetsInsetRect(self.bounds, self.safeAreaInsets);
  const CGFloat u = MIN(b.size.width, b.size.height) / 13, m = 16;
  const CGFloat left = CGRectGetMinX(b) + m, right = CGRectGetMaxX(b) - m, top = CGRectGetMinY(b) + m,
                bottom = CGRectGetMaxY(b) - m, mid = CGRectGetMidX(b);
  void (^place)(WinPadTouchPart*, CGFloat, CGFloat, CGFloat, CGFloat) = ^(WinPadTouchPart* part, CGFloat x, CGFloat y,
                                                                         CGFloat w, CGFloat h) {
    part.center = CGPointMake(x, y);
    part.radius = w / 2;
    part.view.frame = CGRectMake(x - w / 2, y - h / 2, w, h);
    part.view.layer.cornerRadius = MIN(w, h) / 2;
    ((UILabel*)part.view).font = [UIFont systemFontOfSize:MIN(w, h) * 0.38 weight:UIFontWeightBold];
  };
  // The sticks: a base of 2.2 u, the knob 1.1 u.
  for (WinPadTouchPart* stick in @[ [self part:PadLUp kind:TouchStick], [self part:PadRUp kind:TouchStick] ]) {
    const BOOL l = stick.input == PadLUp;
    // The PlayStation look: the left stick low and further in, where the d-pad is in Xbox's.
    if (l && _dpadOnTop) place(stick, left + 3.7 * u, bottom - 1.3 * u, 2.2 * u, 2.2 * u);
    else place(stick, l ? left + 1.1 * u : right - 4.4 * u, l ? bottom - 3.0 * u : bottom - 1.3 * u, 2.2 * u, 2.2 * u);
    stick.radius = 1.1 * u;
    stick.knob.frame = CGRectMake(0.55 * u, 0.55 * u, 1.1 * u, 1.1 * u);
    stick.knob.layer.cornerRadius = 0.55 * u;
    ((UILabel*)stick.knob).font = [UIFont systemFontOfSize:0.4 * u weight:UIFontWeightBold];
  }
  WinPadTouchPart* dpad = [self part:PadUp kind:TouchDpad];
  if (_dpadOnTop) place(dpad, left + 1.35 * u, bottom - 3.4 * u, 2.7 * u, 2.7 * u);
  else place(dpad, left + 3.7 * u, bottom - 1.4 * u, 2.7 * u, 2.7 * u);
  dpad.radius = 1.35 * u;
  const CGFloat arm = 0.85 * u, c = 1.35 * u;
  const CGPoint arms[4] = {{c, c - 0.9 * u}, {c, c + 0.9 * u}, {c - 0.9 * u, c}, {c + 0.9 * u, c}};
  for (int d = 0; d < 4; d++) {
    dpad.arms[d].frame = CGRectMake(arms[d].x - arm / 2, arms[d].y - arm / 2, arm, arm);
    ((UILabel*)dpad.arms[d]).font = [UIFont systemFontOfSize:0.35 * u];
  }
  const CGFloat fx = right - 1.6 * u, fy = bottom - 2.6 * u, f = 1.05 * u;
  place([self part:PadA kind:TouchButton], fx, fy + f, u, u);
  place([self part:PadB kind:TouchButton], fx + f, fy, u, u);
  place([self part:PadX kind:TouchButton], fx - f, fy, u, u);
  place([self part:PadY kind:TouchButton], fx, fy - f, u, u);
  place([self part:PadL2 kind:TouchButton], left + u, top + 0.4 * u, 2 * u, 0.8 * u);
  place([self part:PadL1 kind:TouchButton], left + u, top + 1.4 * u, 2 * u, 0.8 * u);
  place([self part:PadR2 kind:TouchButton], right - u, top + 0.4 * u, 2 * u, 0.8 * u);
  place([self part:PadR1 kind:TouchButton], right - u, top + 1.4 * u, 2 * u, 0.8 * u);
  // View and Menu at the top in the middle, as on the controller: at the bottom
  // they would cover the right stick on a screen held upright.
  // Exit between them ends the game (RequestExit).
  place([self part:PadOptions kind:TouchButton], mid - 1.45 * u, top + 0.4 * u, 1.2 * u, 0.7 * u);
  place([self part:PadExit kind:TouchButton], mid, top + 0.4 * u, 1.2 * u, 0.7 * u);
  place([self part:PadMenu kind:TouchButton], mid + 1.45 * u, top + 0.4 * u, 1.2 * u, 0.7 * u);
  [self update];
}

// The part a finger at p is on: a button within its frame and a bit more, a
// stick or the d-pad within its reach.
- (WinPadTouchPart*)partAt:(CGPoint)p buttonsOnly:(BOOL)buttons {
  for (WinPadTouchPart* part in _parts) {
    if (part.kind == TouchButton) {
      if (CGRectContainsPoint(CGRectInset(part.view.frame, -6, -6), p)) return part;
    } else if (!buttons && hypot(p.x - part.center.x, p.y - part.center.y) < part.radius * 1.3) {
      return part;
    }
  }
  return nil;
}

- (BOOL)pointInside:(CGPoint)point withEvent:(UIEvent*)event {
  return [self partAt:point buttonsOnly:NO] != nil;
}

- (void)touchesBegan:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  for (UITouch* touch in touches) {
    WinPadTouchPart* part = [self partAt:[touch locationInView:self] buttonsOnly:NO];
    if (part) [_touches setObject:part forKey:touch];
  }
  [self update];
}

- (void)touchesMoved:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  for (UITouch* touch in touches) {
    id held = [_touches objectForKey:touch];  // NSNull: a finger that slid off the buttons
    if ([held isKindOfClass:WinPadTouchPart.class] && ((WinPadTouchPart*)held).kind != TouchButton) continue;
    // A finger on a button slides onto the next one, or off all of them.
    WinPadTouchPart* part = [self partAt:[touch locationInView:self] buttonsOnly:YES];
    if (part) [_touches setObject:part forKey:touch];
    else [_touches setObject:(id)NSNull.null forKey:touch];
  }
  [self update];
}

- (void)touchesEnded:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  for (UITouch* touch in touches) [_touches removeObjectForKey:touch];
  [self update];
}

- (void)touchesCancelled:(NSSet<UITouch*>*)touches withEvent:(UIEvent*)event {
  [self touchesEnded:touches withEvent:event];
}

- (void)press:(int)input down:(BOOL)down {
  if (input < 0 || input >= PadCount) return;
  _pressed[input] = down;
  [self update];
}

// What the fingers hold, sent as the touch controller's inputs and shown.
- (void)update {
  BOOL in[PadCount];
  memcpy(in, _pressed, sizeof in);
  CGPoint touch_stick = CGPointZero;
  NSMutableSet* held = [NSMutableSet new];
  NSMapTable* knobs = [NSMapTable strongToStrongObjectsMapTable];
  for (UITouch* touch in _touches) {
    WinPadTouchPart* part = [_touches objectForKey:touch];
    if (![part isKindOfClass:WinPadTouchPart.class]) continue;
    [held addObject:part];
    if (part.kind == TouchButton) {
      if (part.input < PadCount) in[part.input] = YES;
      continue;
    }
    const CGPoint p = [touch locationInView:self];
    CGFloat dx = (p.x - part.center.x) / part.radius, dy = (p.y - part.center.y) / part.radius;
    const CGFloat length = hypot(dx, dy);
    if (length > 1) dx /= length, dy /= length;
    // A stick's key is down past half its travel, as a controller's stick
    // (ReadPad); the d-pad takes a diagonal when the finger is near one.
    const CGFloat dead = part.kind == TouchStick ? 0.5 : 0.25, slant = part.kind == TouchStick ? 0 : 0.4;
    in[part.input + 0] |= dy < -dead && -dy >= fabs(dx) * slant;
    in[part.input + 1] |= dy > dead && dy >= fabs(dx) * slant;
    in[part.input + 2] |= dx < -dead && -dx >= fabs(dy) * slant;
    in[part.input + 3] |= dx > dead && dx >= fabs(dy) * slant;
    if (part.kind == TouchStick) [knobs setObject:[NSValue valueWithCGPoint:CGPointMake(dx, dy)] forKey:part];
    if (part.kind == TouchStick && part.input == pad_mouse_stick) touch_stick = CGPointMake(dx, -dy);
  }
  pad_stick[1] = touch_stick;
  for (WinPadTouchPart* part in _parts) {
    const BOOL down = [held containsObject:part] || (part.kind == TouchButton && part.input < PadCount && _pressed[part.input]);
    if (part.input == PadExit && part.kind == TouchButton) {
      if (down && !_exitHeld) RequestExit();
      _exitHeld = down;
    }
    if (part.kind == TouchButton) {
      part.view.backgroundColor = [UIColor colorWithWhite:1 alpha:down ? 0.45 : 0.15];
    } else if (part.kind == TouchStick) {
      const CGPoint d = [[knobs objectForKey:part] CGPointValue];
      const CGFloat r = part.radius;
      part.knob.center = CGPointMake(r + d.x * r * 0.6, r + d.y * r * 0.6);
      part.knob.backgroundColor = [UIColor colorWithWhite:1 alpha:down ? 0.5 : 0.3];
    } else {
      for (int d = 0; d < 4; d++)
        part.arms[d].backgroundColor = [UIColor colorWithWhite:1 alpha:in[part.input + d] ? 0.45 : 0.15];
    }
  }
  ApplyPad(PadFromTouch, in);
}
@end

static WinPadTouchPad* touch_pad;

// Starts the controllers; the touch controller goes on view (nil: none).
static void Gamepads(UIView* view, NSDictionary* settings) {
  WinPadPadKeys(pad_keys);
  // The game's own keys (its winpad.json or profile "padKeys": input name -> virtual key).
  if ([settings[@"padKeys"] isKindOfClass:NSDictionary.class])
    for (NSString* name in settings[@"padKeys"]) {
      const int input = WinPadPadInput(name);
      id key = settings[@"padKeys"][name];
      if (input >= 0 && [key isKindOfClass:NSNumber.class]) pad_keys[input] = (unsigned short)([key intValue] & 0xff);
    }
  void (^attach)(GCController*) = ^(GCController* c) {
    if (!c.extendedGamepad) return;
    printf("gamepad: %s connected\n", (c.vendorName ?: @"a controller").UTF8String);
    pad_controller = YES;
    WritePad();
    // The Xbox/Home button ends the game (RequestExit) instead of opening the system's menu.
    if (@available(iOS 14.0, *)) c.extendedGamepad.buttonHome.preferredSystemGestureState = GCSystemGestureStateDisabled;
    c.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad* pad, GCControllerElement* element) {
      ReadPad(pad);
    };
  };
  if (view) {
    touch_pad = [[WinPadTouchPad alloc] initWithFrame:view.bounds];
    touch_pad.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    [view addSubview:touch_pad];
    printf("gamepad: the touch controller connected\n");
    pad_touch = YES;
    WritePad();
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
                    BOOL any = NO;
                    for (GCController* c in GCController.controllers)
                      if (c.extendedGamepad && c != note.object) any = YES;
                    pad_controller = any;
                    memset(pad_analog, 0, sizeof(pad_analog));
                    pad_thumb[0] = pad_thumb[1] = NO;
                    ApplyPad(PadFromController, none);  // no key stays held by a controller that left
                  }];
}

// CI's check of the controllers, once the window shows: A on the touch
// controller, which is Enter unless the padKeys setting changed it. Without a
// touch controller, or if it sent no key, A goes in through pad_keys
// directly, and the log says so.
static void PressTestButton(void) {
  printf("gamepad: pressing A on the touch controller (%s)\n", touch_pad ? "connected" : "not connected");
  [touch_pad press:PadA down:YES];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
    [touch_pad press:PadA down:NO];
    if (pad_sent) return;
    printf("gamepad: no key from the touch controller; pressing A through the mapping\n");
    BOOL in[PadCount] = {NO};
    in[PadA] = YES;
    ApplyPad(PadFromController, in);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 200 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
      const BOOL none[PadCount] = {NO};
      ApplyPad(PadFromController, none);
    });
  });
}

// The Machine field of a Windows program's PE header (0x14c i386, 0x8664 x86-64), or 0.
static unsigned PEMachine(NSString* path) {
  NSFileHandle* f = [NSFileHandle fileHandleForReadingAtPath:path];
  NSData* head = [f readDataOfLength:4096];
  [f closeFile];
  if (head.length < 64) return 0;
  const uint8_t* b = head.bytes;
  const uint32_t pe = b[0x3c] | b[0x3d] << 8 | b[0x3e] << 16 | (uint32_t)b[0x3f] << 24;
  if (pe > head.length - 6 || memcmp(b + pe, "PE\0\0", 4)) return 0;
  return b[pe + 4] | b[pe + 5] << 8;
}

// Windows path of a directory for FEX: Z: is the root, with a trailing backslash.
static NSString* WindowsDir(NSString* path) {
  return [NSString stringWithFormat:@"Z:%@\\", [path stringByReplacingOccurrencesOfString:@"/" withString:@"\\"]];
}

// A game's launcher that starts the game: a 32-bit program cannot start another here, so
// Wine hands the start over to the app (patches/madeira/0014-handoff-child-program): it
// writes HandoffFile() and the app, next launch, starts that program of the game itself.
static NSString* HandoffFile(void) { return DocumentsPath(@".winpad-handoff.txt"); }
static NSString* HandoffNext(void) { return DocumentsPath(@".winpad-handoff.json"); }

// What follows the program in a Windows command line, as arguments ("a b" stays one).
static NSArray<NSString*>* CommandLineArgs(NSString* cmdline) {
  NSMutableArray<NSString*>* args = [NSMutableArray new];
  NSMutableString* cur = nil;
  BOOL quoted = NO;
  for (NSUInteger i = 0; i <= cmdline.length; i++) {
    const unichar c = i < cmdline.length ? [cmdline characterAtIndex:i] : ' ';
    if (c == '"') {
      quoted = !quoted;
      if (!cur) cur = [NSMutableString new];
    } else if ((c == ' ' || c == '\t') && !quoted) {
      if (cur) [args addObject:cur];
      cur = nil;
    } else {
      if (!cur) cur = [NSMutableString new];
      [cur appendFormat:@"%C", c];
    }
  }
  if (args.count) [args removeObjectAtIndex:0];  // the program
  return args;
}

// The handed-over start (HandoffFile) as the game folder's program: {folder, exe, args}, or nil
// when the program is not in that folder.
static NSDictionary* ReadHandoff(NSString* folder) {
  NSString* text = [NSString stringWithContentsOfFile:HandoffFile() encoding:NSUTF8StringEncoding error:nil];
  if (!text) return nil;
  NSMutableDictionary* lines = [NSMutableDictionary new];
  for (NSString* line in [text componentsSeparatedByString:@"\n"]) {
    const NSRange eq = [line rangeOfString:@"="];
    if (eq.location != NSNotFound) lines[[line substringToIndex:eq.location]] = [line substringFromIndex:eq.location + 1];
  }
  NSString* image = lines[@"image"];
  NSString* docs = WindowsDir(DocumentsPath(folder));
  if (image.length <= docs.length || [image rangeOfString:docs options:NSCaseInsensitiveSearch | NSAnchoredSearch].location == NSNotFound)
    return nil;
  NSString* rel = [[image substringFromIndex:docs.length] stringByReplacingOccurrencesOfString:@"\\" withString:@"/"];
  // The file in the folder as it is named there (Wine compares without case).
  NSString* dir = DocumentsPath(folder);
  NSMutableArray* parts = [NSMutableArray new];
  for (NSString* part in rel.pathComponents) {
    NSString* found = part;
    for (NSString* name in [NSFileManager.defaultManager contentsOfDirectoryAtPath:[dir stringByAppendingPathComponent:[parts componentsJoinedByString:@"/"]] error:nil])
      if ([name caseInsensitiveCompare:part] == NSOrderedSame) found = name;
    [parts addObject:found];
  }
  rel = [parts componentsJoinedByString:@"/"];
  if (![NSFileManager.defaultManager fileExistsAtPath:[dir stringByAppendingPathComponent:rel]]) return nil;
  return @{@"folder" : folder, @"exe" : rel, @"args" : CommandLineArgs(lines[@"cmdline"] ?: @"")};
}

// The Wine prefix, kept from launch to launch: what programs write there, such
// as a game's saves and settings in C:\users and the registry (*.reg), stays.
// A 32-bit process's system32 is C:\windows\syswow64, with the i386 DLLs;
// wow64.dll and xtajit.dll are loaded by their C:\windows\system32 paths
// (madeira_link_syswow64 in Madeira's WineProcessBridge.m). The links point
// into the bundle, whose path changes with every install, so they are made
// anew on every launch.
// The DirectX DLLs from Microsoft MakePrefix linked in place of Wine's (d3dx9_30...).
static NSArray<NSString*>* directx_native;

// A 64-bit x86 program (x64 == YES) runs in an ARM64EC session instead: system32 (and
// sysx64, as Madeira links it) is Madeira's arm64ec-windows set, whose ntdll hands the x86-64
// code to FEX's ARM64EC module xtajit64.dll; syswow64 stays for the 32-bit programs it starts.
static NSString* MakePrefix(NSString* bundle, BOOL x64) {
  NSFileManager* fm = NSFileManager.defaultManager;
  NSString* prefix = DocumentsPath(@"prefix");
  const BOOL has_ec = [fm fileExistsAtPath:[bundle stringByAppendingPathComponent:@"arm64ec-windows/ntdll.dll"]];
  NSDictionary* farms = x64 && has_ec ? @{@"syswow64" : @"i386-windows", @"system32" : @"arm64ec-windows", @"sysx64" : @"arm64ec-windows"}
                                      : @{@"syswow64" : @"i386-windows", @"system32" : @"aarch64-windows"};
  for (NSString* farm in farms) {
    NSString* dir = [prefix stringByAppendingPathComponent:[@"drive_c/windows" stringByAppendingPathComponent:farm]];
    [fm createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    for (NSString* name in [fm contentsOfDirectoryAtPath:dir error:nil]) {
      NSString* path = [dir stringByAppendingPathComponent:name];
      if ([[fm attributesOfItemAtPath:path error:nil].fileType isEqualToString:NSFileTypeSymbolicLink])
        [fm removeItemAtPath:path error:nil];
    }
    NSString* src = [bundle stringByAppendingPathComponent:farms[farm]];
    for (NSString* name in [fm contentsOfDirectoryAtPath:src error:nil]) {
      if ([farm isEqualToString:@"syswow64"] && ![name.pathExtension.lowercaseString isEqualToString:@"dll"]) continue;
      [fm createSymbolicLinkAtPath:[dir stringByAppendingPathComponent:name]
               withDestinationPath:[src stringByAppendingPathComponent:name]
                             error:nil];
    }
  }
  // Microsoft's DirectX DLLs, when the app downloaded them (WinPadRedist.m): the ones Wine
  // lacks, and with the setting also those it has, loaded native first (ApplyGameSettings).
  directx_native = WinPadDirectXLink([prefix stringByAppendingPathComponent:@"drive_c/windows/syswow64"],
                                     [bundle stringByAppendingPathComponent:@"i386-windows"]);
  // DLLs out of the game's own installers and Microsoft's Visual C++ (WinPadRedist.m): those Wine lacks.
  WinPadExtraLink([prefix stringByAppendingPathComponent:@"drive_c/windows/syswow64"],
                  [bundle stringByAppendingPathComponent:@"i386-windows"]);
  // The registry Wine's wineboot would have made: the builtin COM classes
  // the games need, such as DirectSound's audio device enumerator
  // (tests/wine-loader/prefix/system.reg, the same as run-host.sh's prefix).
  // Without it DirectSound has no device, and a game whose video player keeps
  // time by its sound shows nothing for minutes.
  // It is copied only into a new prefix, or when the app brings a changed one
  // (system.reg.app, the copy it last brought): the registry keeps what the
  // programs wrote to HKEY_LOCAL_MACHINE.
  NSString* reg = [bundle stringByAppendingPathComponent:@"system.reg"];
  NSString* brought = [prefix stringByAppendingPathComponent:@"system.reg.app"];
  if (![fm fileExistsAtPath:[prefix stringByAppendingPathComponent:@"system.reg"]] ||
      ![fm contentsEqualAtPath:reg andPath:brought]) {
    if ([fm fileExistsAtPath:brought]) printf("WinPad Wine: the app brings a new system.reg; HKEY_LOCAL_MACHINE starts anew\n");
    for (NSString* path in @[ [prefix stringByAppendingPathComponent:@"system.reg"], brought ]) {
      [fm removeItemAtPath:path error:nil];
      [fm copyItemAtPath:reg toPath:path error:nil];
    }
  }
  return prefix;
}

// Gives the owner write access to the game's folder and everything in it where it lacks
// it, so the game can save its settings and progress there. Files copied off a disc or an
// installer often come read-only (r--r--r--), which Wine reports to the game as a read-only
// file, so its saves fail. Returns how many it changed.
static NSUInteger MakeWritable(NSString* folder) {
  NSUInteger changed = 0;
  NSFileManager* fm = NSFileManager.defaultManager;
  NSMutableArray<NSString*>* paths = [NSMutableArray arrayWithObject:folder];
  for (NSString* rel in [fm enumeratorAtPath:folder]) [paths addObject:[folder stringByAppendingPathComponent:rel]];
  for (NSString* path in paths) {
    struct stat st;
    if (lstat(path.fileSystemRepresentation, &st) || S_ISLNK(st.st_mode)) continue;
    const mode_t want = st.st_mode | S_IWUSR | (S_ISDIR(st.st_mode) ? S_IXUSR | S_IRUSR : S_IRUSR);
    if (want == st.st_mode) continue;
    if (!chmod(path.fileSystemRepresentation, want & 07777)) changed++;
  }
  return changed;
}

// A game's settings from its winpad.json (WinPadGameSettings in Library.m: a game profile
// of WinPad Translator, with the user's own keys over it).

// A registry key or value name as Wine's *.reg files write it: \ and " escaped.
static NSString* RegEscape(NSString* text) {
  return [[text stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"]
      stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
}

// "name"=data for value V: text (printable ASCII as it is, else REG_SZ as UTF-16 bytes), a
// number (REG_DWORD) or {"hex": "00ff"} (REG_BINARY); nil for anything else.
static NSString* RegValueLine(NSString* name, id v) {
  NSString* lhs = name.length ? [NSString stringWithFormat:@"\"%@\"", RegEscape(name)] : @"@";
  if ([v isKindOfClass:NSString.class]) {
    NSString* text = v;
    BOOL plain = YES;
    for (NSUInteger i = 0; i < text.length && plain; i++) {
      const unichar c = [text characterAtIndex:i];
      plain = c >= 0x20 && c < 0x7f;
    }
    if (plain) return [NSString stringWithFormat:@"%@=\"%@\"", lhs, RegEscape(text)];
    NSMutableString* hex = [NSMutableString stringWithString:@"hex(1):"];
    for (NSUInteger i = 0; i <= text.length; i++) {
      const unichar c = i < text.length ? [text characterAtIndex:i] : 0;
      [hex appendFormat:@"%s%02x,%02x", i ? "," : "", c & 0xff, c >> 8];
    }
    return [NSString stringWithFormat:@"%@=%@", lhs, hex];
  }
  if ([v isKindOfClass:NSNumber.class] && CFGetTypeID((__bridge CFTypeRef)v) != CFBooleanGetTypeID()) {
    const long long n = [v longLongValue];
    if (n < 0 || n > 0xffffffffLL) return nil;
    return [NSString stringWithFormat:@"%@=dword:%08llx", lhs, n];
  }
  NSString* bytes = [v isKindOfClass:NSDictionary.class] ? v[@"hex"] : nil;
  if ([bytes isKindOfClass:NSString.class] && bytes.length % 2 == 0) {
    NSMutableArray* pairs = [NSMutableArray new];
    for (NSUInteger i = 0; i < bytes.length; i += 2) {
      NSString* pair = [bytes substringWithRange:NSMakeRange(i, 2)].lowercaseString;
      if ([pair rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"0123456789abcdef"].invertedSet]
              .location != NSNotFound)
        return nil;
      [pairs addObject:pair];
    }
    return [NSString stringWithFormat:@"%@=hex:%@", lhs, [pairs componentsJoinedByString:@","]];
  }
  return nil;
}

// Puts REGISTRY's values ({"HKLM\Software\...": {"name": value}}) into the prefix's
// system.reg (HKLM) and user.reg (HKCU) where the key does not have them yet, so a game
// that changes one (its resolution...) keeps its own. Wine reads a key that is in the file
// twice as one; its server writes the file anew when it saves. A 32-bit game sees
// HKLM\Software through Wow6432Node. Returns what it did, for the log.
// With FORCE (the values the app's automatic settings own, WinPadAuto.m's "registryForce": a
// game's renderer, its Windows version) a value is written also when the key has it: Wine
// takes the last one in the file.
static NSArray<NSString*>* AddRegistryDefaults(NSString* prefix, NSDictionary* registry, BOOL wow64, BOOL force) {
  NSMutableArray<NSString*>* said = [NSMutableArray new];
  if (![registry isKindOfClass:NSDictionary.class]) return said;
  const long stamp = (long)NSDate.date.timeIntervalSince1970;
  NSMutableDictionary<NSString*, NSMutableString*>* added = [NSMutableDictionary new];
  NSMutableDictionary<NSString*, NSString*>* files = [NSMutableDictionary new];
  for (NSString* full in [registry.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
    NSDictionary* values = registry[full];
    const NSRange slash = [full rangeOfString:@"\\"];
    if (![values isKindOfClass:NSDictionary.class] || slash.location == NSNotFound ||
        [full rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@"[]\"\n"]].location != NSNotFound) {
      [said addObject:[NSString stringWithFormat:@"registry: skipped key %@", full]];
      continue;
    }
    NSString* root = [full substringToIndex:slash.location].uppercaseString;
    NSString* path = [full substringFromIndex:slash.location + 1];
    NSString* file;
    if ([@[ @"HKLM", @"HKEY_LOCAL_MACHINE" ] containsObject:root]) {
      file = @"system.reg";
      NSString* lower = path.lowercaseString;
      if (wow64 && [lower hasPrefix:@"software\\"] && ![lower containsString:@"wow6432node"]) {
        path = [lower hasPrefix:@"software\\classes\\"]
                   ? [@"Software\\Classes\\Wow6432Node\\" stringByAppendingString:[path substringFromIndex:17]]
                   : [@"Software\\Wow6432Node\\" stringByAppendingString:[path substringFromIndex:9]];
      }
    } else if ([@[ @"HKCU", @"HKEY_CURRENT_USER" ] containsObject:root]) {
      file = @"user.reg";
    } else {
      [said addObject:[NSString stringWithFormat:@"registry: skipped key %@ (only HKLM and HKCU)", full]];
      continue;
    }
    if (!files[file])
      files[file] = [NSString stringWithContentsOfFile:[prefix stringByAppendingPathComponent:file]
                                              encoding:NSUTF8StringEncoding
                                                 error:nil] ?: @"";
    // The key's section in the file, if it is there: from its [line] to the next one.
    NSString* header = [NSString stringWithFormat:@"[%@]", RegEscape(path)].lowercaseString;
    NSMutableSet<NSString*>* have = [NSMutableSet new];
    BOOL inside = NO;
    for (NSString* line in [files[file] componentsSeparatedByString:@"\n"]) {
      NSString* l = line.lowercaseString;
      if ([l hasPrefix:@"["]) inside = [l isEqualToString:header] || [l hasPrefix:[header stringByAppendingString:@" "]];
      else if (inside) {
        const NSRange eq = [l rangeOfString:@"\"="];
        if ([l hasPrefix:@"@="]) [have addObject:@"@"];
        else if ([l hasPrefix:@"\""] && eq.location != NSNotFound) [have addObject:[l substringToIndex:eq.location + 1]];
      }
    }
    NSMutableString* lines = [NSMutableString new];
    for (NSString* name in [values.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
      NSString* line = RegValueLine(name, values[name]);
      NSString* key = name.length ? [NSString stringWithFormat:@"\"%@\"", RegEscape(name)].lowercaseString : @"@";
      if (!line) {
        [said addObject:[NSString stringWithFormat:@"registry: skipped %@\\%@ (not text, a number or hex)", full, name]];
      } else if ([have containsObject:key] && !force) {
        [said addObject:[NSString stringWithFormat:@"registry: %@\\%@ kept as it is", full, name]];
      } else {
        [lines appendFormat:@"%@\n", line];
        [said addObject:[NSString stringWithFormat:@"registry%@: %@ in %@ [%@]", force ? @" (auto)" : @"", line, file, path]];
      }
    }
    if (!lines.length) continue;
    if (!added[file]) added[file] = [NSMutableString new];
    [added[file] appendFormat:@"\n[%@] %ld\n%@", RegEscape(path), stamp, lines];
  }
  for (NSString* file in added) {
    NSString* text = files[file];
    if (!text.length) {
      // A new prefix's user.reg, before Wine's server first wrote it.
      text = [file isEqualToString:@"user.reg"]
                 ? @"WINE REGISTRY Version 2\n;; All keys relative to \\\\User\\\\S-1-5-21-0-0-0-1000\n\n#arch=win64\n"
                 : @"WINE REGISTRY Version 2\n;; All keys relative to \\\\Machine\n\n#arch=win64\n";
    }
    if (![text hasSuffix:@"\n"]) text = [text stringByAppendingString:@"\n"];
    NSError* error = nil;
    if (![[text stringByAppendingString:added[file]] writeToFile:[prefix stringByAppendingPathComponent:file]
                                                      atomically:YES
                                                        encoding:NSUTF8StringEncoding
                                                           error:&error])
      [said addObject:[NSString stringWithFormat:@"registry: writing %@ failed: %@", file, error.localizedDescription]];
  }
  return said;
}

// Applies GAME's settings to the run about to start: WINEDLLOVERRIDES (after the app's own
// dinput8=n,b, for the Ultimate ASI Loader many games carry), the environment (not the
// variables the app sets itself), the program's arguments (into ARGS) and the registry's
// values. Returns what it did, for the log.
static NSArray<NSString*>* ApplyGameSettings(WinPadGame* game, NSString* prefix, NSMutableArray<NSString*>* args) {
  NSMutableArray<NSString*>* said = [NSMutableArray new];
  NSDictionary* s = game.settings ?: @{};
  if (game.profile) [said addObject:[NSString stringWithFormat:@"game profile %@", game.profile]];
  // What the library read of the program and the automatic settings it picked (WinPadAuto.m).
  if (game.traits)
    [said addObject:[NSString stringWithFormat:@"detected %@, graphics %@, uses %@%@", [game.traits[@"machine"] integerValue] == 0x8664 ? @"64-bit" : @"32-bit",
                                               game.traits[@"graphics"], [game.traits[@"uses"] componentsJoinedByString:@" "] ?: @"",
                                               game.traits[@"installer"] ? [@", installer " stringByAppendingString:game.traits[@"installer"]] : @""]];
  if (game.autoVariant)
    [said addObject:[NSString stringWithFormat:@"automatic settings: variant %@ (%@)", game.autoVariant[@"id"], game.autoVariant[@"title"]]];
  NSMutableDictionary* dlls = [@{@"dinput8" : @"n,b"} mutableCopy];
  for (NSString* dll in directx_native) dlls[dll] = @"n,b";
  if (directx_native.count)
    [said addObject:[NSString stringWithFormat:@"DirectX from Microsoft in place of Wine's: %@",
                                               [directx_native componentsJoinedByString:@" "]]];
  // Microsoft's DLLs the game's profile asks for (Proton's winetricks d3dx9_43 ...), native
  // first even where Wine has its own; the library downloaded DirectX for them.
  NSArray* want_dx = [s[@"nativeDirectX"] isKindOfClass:NSArray.class] ? s[@"nativeDirectX"] : @[];
  NSArray<NSString*>* profile_dx = WinPadDirectXLinkNative(
      [prefix stringByAppendingPathComponent:@"drive_c/windows/syswow64"], WinPadDirectXDLLsForVerbs(want_dx));
  for (NSString* dll in profile_dx) dlls[dll] = @"n,b";
  if (profile_dx.count)
    [said addObject:[NSString stringWithFormat:@"DirectX from Microsoft for the game's profile: %@",
                                               [profile_dx componentsJoinedByString:@" "]]];
  else if (want_dx.count)
    [said addObject:[NSString stringWithFormat:@"the game's profile wants DirectX from Microsoft (%@), which is not "
                                               @"downloaded",
                                               [want_dx componentsJoinedByString:@" "]]];
  // A game that reads a controller itself (padMode "xinput" or "hid"): the controllers go to
  // it through Madeira's bridge instead of as keys (WritePad). The wineserver serves the HID
  // controller only when MADEIRA_HIDPAD is set before it starts.
  NSString* pad_mode = [s[@"padMode"] isKindOfClass:NSString.class] ? s[@"padMode"] : @"keys";
  unsetenv("MADEIRA_HIDPAD");
  memset(&pad_sample, 0, sizeof(pad_sample));
  pad_sample_set = NO;
  if ([pad_mode isEqualToString:@"xinput"]) {
    pad_native = PadAsXInput;
    [said addObject:@"controller: as an Xbox controller (XInput)"];
  } else if ([pad_mode isEqualToString:@"hid"]) {
    pad_native = PadAsHID;
    setenv("MADEIRA_HIDPAD", "generic", 1);
    setenv("MADEIRA_HIDPAD_NAME", "WinPad Controller", 1);
    [said addObject:@"controller: as a HID game controller (DirectInput)"];
  } else {
    pad_native = PadAsKeys;
    [said addObject:@"controller: as keys"];
  }
  WritePad();
  NSCharacterSet* bad_dll = [NSCharacterSet characterSetWithCharactersInString:@"=;,\" "];
  NSCharacterSet* bad_order = [NSCharacterSet characterSetWithCharactersInString:@"nbd, "].invertedSet;
  if ([s[@"dllOverrides"] isKindOfClass:NSDictionary.class]) {
    for (NSString* dll in s[@"dllOverrides"]) {
      id order = s[@"dllOverrides"][dll];
      if (![dll isKindOfClass:NSString.class] || !dll.length || [dll rangeOfCharacterFromSet:bad_dll].location != NSNotFound ||
          ![order isKindOfClass:NSString.class] || [order rangeOfCharacterFromSet:bad_order].location != NSNotFound) {
        [said addObject:[NSString stringWithFormat:@"skipped DLL override %@", dll]];
        continue;
      }
      dlls[dll.lowercaseString] = [order stringByReplacingOccurrencesOfString:@" " withString:@""];
    }
  }
  NSMutableArray* parts = [NSMutableArray new];
  for (NSString* dll in [dlls.allKeys sortedArrayUsingSelector:@selector(compare:)])
    [parts addObject:[NSString stringWithFormat:@"%@=%@", dll, dlls[dll]]];
  NSString* overrides = [parts componentsJoinedByString:@";"];
  setenv("WINEDLLOVERRIDES", overrides.UTF8String, 1);
  [said addObject:[@"WINEDLLOVERRIDES=" stringByAppendingString:overrides]];
  if ([s[@"env"] isKindOfClass:NSDictionary.class]) {
    for (NSString* name in [[s[@"env"] allKeys] sortedArrayUsingSelector:@selector(compare:)]) {
      id value = s[@"env"][name];
      const BOOL own = [name hasPrefix:@"WINE"] || [name hasPrefix:@"FEX_"] || [name hasPrefix:@"DYLD_"] ||
                       [@[ @"HOME", @"TMPDIR", @"MADEIRA_WOW_MIN_FREE_GB", @"MADEIRA_WIN32U", @"MADEIRA_DESKTOP" ]
                           containsObject:name];
      if (own || ![value isKindOfClass:NSString.class] || !name.length || [name containsString:@"="]) {
        [said addObject:[NSString stringWithFormat:@"skipped environment variable %@ (the app sets it)", name]];
        continue;
      }
      setenv(name.UTF8String, [value UTF8String], 1);
      [said addObject:[NSString stringWithFormat:@"%@=%@", name, value]];
    }
  }
  if ([s[@"args"] isKindOfClass:NSArray.class]) {
    for (id arg in s[@"args"])
      if ([arg isKindOfClass:NSString.class]) [args addObject:arg];
    if (args.count) [said addObject:[@"arguments: " stringByAppendingString:[args componentsJoinedByString:@" "]]];
  }
  // The Windows version the game's profile wants (Proton's winetricks win7, winxp ...), for its
  // program only: Wine's AppDefaults\PROGRAM.exe\Version.
  NSDictionary* registry = [s[@"registry"] isKindOfClass:NSDictionary.class] ? s[@"registry"] : @{};
  NSString* winver = [s[@"windowsVersion"] isKindOfClass:NSString.class] ? s[@"windowsVersion"] : nil;
  NSSet* winvers = [NSSet setWithArray:@[ @"win95", @"win98", @"win2k", @"winxp", @"vista", @"win7", @"win8", @"win81",
                                          @"win10", @"win11" ]];
  if ([winvers containsObject:winver] && game.exe.lastPathComponent.length) {
    NSMutableDictionary* merged = [registry mutableCopy];
    NSString* key = [@"HKCU\\Software\\Wine\\AppDefaults\\" stringByAppendingString:game.exe.lastPathComponent];
    NSMutableDictionary* values = [([merged[key] isKindOfClass:NSDictionary.class] ? merged[key] : @{}) mutableCopy];
    if (!values[@"Version"]) values[@"Version"] = winver;
    merged[key] = values;
    registry = merged;
  }
  [said addObjectsFromArray:AddRegistryDefaults(prefix, registry, [game.arch isEqualToString:@"32bit"], NO)];
  if ([s[@"registryForce"] isKindOfClass:NSDictionary.class])
    [said addObjectsFromArray:AddRegistryDefaults(prefix, s[@"registryForce"], [game.arch isEqualToString:@"32bit"], YES)];
  // Empty folders the game writes into (Mafia's Maps): copying a game often leaves them out,
  // and then its saves fail with "path not found".
  if ([s[@"folders"] isKindOfClass:NSArray.class] && game.folder.length) {
    NSString* root = DocumentsPath(game.folder);
    for (id name in s[@"folders"]) {
      if (![name isKindOfClass:NSString.class] || ![name length] || [name hasPrefix:@"/"] ||
          [[name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"].pathComponents containsObject:@".."])
        continue;
      NSString* path = [root stringByAppendingPathComponent:[name stringByReplacingOccurrencesOfString:@"\\" withString:@"/"]];
      BOOL dir = NO;
      if ([NSFileManager.defaultManager fileExistsAtPath:path isDirectory:&dir]) continue;
      if ([NSFileManager.defaultManager createDirectoryAtPath:path withIntermediateDirectories:YES attributes:nil error:nil])
        [said addObject:[NSString stringWithFormat:@"made the game's folder %@", name]];
    }
  }
  return said;
}

@interface WineViewController : UIViewController
@property(nonatomic, strong) UITextView* text;
@property(nonatomic, strong) NSTimer* timer;
@property(nonatomic) BOOL handoffShown;  // the launcher's start of the game was offered
@property(atomic, copy) NSString* summary;
@property(nonatomic, copy) NSString* program;
@property(nonatomic, strong) WinPadGame* game;  // the game the library started, or nil
@property(nonatomic, strong) UILabel* status;
@property(nonatomic, strong) NSDate* started;
@property(nonatomic, strong) UILabel* fps;  // the FPS overlay over the game, if Settings has it on
@property(nonatomic, strong) CADisplayLink* fpsLink;
// WinPad Translator's "Play and record" on a Mac (-recordGame FOLDER, simulator only): the game runs
// with FEX's JIT, not its image, and FEX writes every block it compiles to the game's code maps.
@property(nonatomic) BOOL record;
@property(nonatomic) CGSize display;  // the screen's size in points, for WinPadGameScreen
@property(nonatomic, strong) WinPadMouseView* mouse;  // a finger on the picture as the mouse
- (void)askToExit;
@end

// The FPS overlay: the display link looks at Metal's frame count every screen
// refresh and keeps when the last frames came, so a hitch shows up as a long frame.
enum { FpsTimes = 256 };
static CFTimeInterval fps_times[FpsTimes];
static long fps_count, fps_seen;
static CFTimeInterval fps_shown;

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
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"fpsOverlay"]) {
      self.fps = [UILabel new];
      self.fps.font = [UIFont monospacedDigitSystemFontOfSize:13 weight:UIFontWeightSemibold];
      self.fps.textColor = UIColor.systemYellowColor;
      self.fps.backgroundColor = [UIColor colorWithWhite:0 alpha:0.55];
      self.fps.hidden = YES;
      [self.view addSubview:self.fps];
      self.fpsLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(countFrames:)];
      [self.fpsLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    }
  }
  metal_view = self.view;
  metal_fill = [self.program isEqualToString:@"game"];
  picture_scaling = WinPadPictureScaling(self.game.settings);
  picture_avoids_cutout = WinPadPictureAvoidsCutout();
  picture_stretch = WinPadPictureStretch(self.game.settings);
  // The monitor Wine reports to the program (runWine): the display's size is read here, on the
  // main thread.
  for (UIScene* scene in UIApplication.sharedApplication.connectedScenes)
    if ([scene isKindOfClass:UIWindowScene.class]) {
      self.display = ((UIWindowScene*)scene).screen.bounds.size;
      break;
    }
  if (metal_fill) {
    HardwareKeyboard();
    // The game's mouse settings (WinPadMouseView, WinPadStickMouse).
    NSDictionary* settings = self.game.settings;
    id speed = settings[@"mouseSpeed"];
    if ([speed isKindOfClass:NSNumber.class] && [speed doubleValue] > 0 && [speed doubleValue] <= 10) mouse_speed = [speed doubleValue];
    id stick = settings[@"padMouse"];
    pad_mouse_stick = [stick isEqual:@"right"] ? PadRUp : [stick isEqual:@"left"] ? PadLUp : -1;
    HardwareMouse();
  }
  gamepad_test = [self.program isEqualToString:@"window"] && [NSUserDefaults.standardUserDefaults boolForKey:@"gamepadTest"];
  mouse_test = [self.program isEqualToString:@"window"] && !gamepad_test &&
               [NSUserDefaults.standardUserDefaults boolForKey:@"mouseTest"];

  // Whether the last run finished: its log's end has the marker (only the end is read: a game's
  // log can be large, and this is on the main thread before the game starts).
  NSString* previous = ReadLogEnd(1 << 20);
  if (previous.length && ![previous containsString:FinishedMarker]) {
    if (![self.program isEqualToString:@"game"]) previous = ReadLog();
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
  __weak WineViewController* weak = self;
  exit_asked = ^{
    [weak askToExit];
  };
  self.text.text = @"WinPad Wine: starting…";
  self.timer = [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:YES block:^(NSTimer* timer) {
    [self showLog];
  }];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    [self runWine];
  });
}

// The game's launcher started the game (HandoffFile): Wine runs one program per app run, so
// the app remembers it (HandoffNext), closes, and its next launch starts it.
- (void)handOff {
  NSDictionary* next = ReadHandoff(self.game.folder);
  printf("WinPad Wine: the program starts %s in the game folder: %s\n",
         next ? [next[@"exe"] UTF8String] : "a program outside", next ? "handed over to the next launch" : "not handed over");
  fflush(stdout);
  // A program outside the game folder: nothing to hand over, and a later start may be.
  [NSFileManager.defaultManager removeItemAtPath:HandoffFile() error:nil];
  if (!next) {
    self.handoffShown = NO;
    return;
  }
  NSMutableDictionary* saved = [next mutableCopy];
  saved[@"time"] = @(NSDate.date.timeIntervalSince1970);
  [[NSJSONSerialization dataWithJSONObject:saved options:0 error:nil] writeToFile:HandoffNext() atomically:YES];
  UIAlertController* tell = [UIAlertController
      alertControllerWithTitle:[NSString stringWithFormat:@"Spustit %@", [next[@"exe"] lastPathComponent]]
                       message:@"Program spouští hru jako další program, a to WinPad neumí současně. Aplikace se "
                               @"zavře; až ji znovu otevřeš, spustí se rovnou hra."
                preferredStyle:UIAlertControllerStyleAlert];
  [tell addAction:[UIAlertAction actionWithTitle:@"Zavřít a spustit hru"
                                           style:UIAlertActionStyleDefault
                                         handler:^(UIAlertAction* action) {
                                           WinPadRunEnded(@"handoff", 0);
                                           printf("WinPad Wine: closing for the handed-over program\n%s, exit 0\n",
                                                  FinishedMarker.UTF8String);
                                           fflush(stdout);
                                           UIApplication* app = UIApplication.sharedApplication;
                                           const SEL suspend = NSSelectorFromString(@"suspend");
                                           if ([app respondsToSelector:suspend]) ((void (*)(id, SEL))objc_msgSend)(app, suspend);
                                           dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC),
                                                          dispatch_get_main_queue(), ^{
                                                            exit(0);
                                                          });
                                         }]];
  [tell addAction:[UIAlertAction actionWithTitle:@"Zůstat"
                                           style:UIAlertActionStyleCancel
                                         handler:^(UIAlertAction* action) {
                                           [NSFileManager.defaultManager removeItemAtPath:HandoffNext() error:nil];
                                           [NSFileManager.defaultManager removeItemAtPath:HandoffFile() error:nil];
                                           self.handoffShown = NO;
                                         }]];
  [self presentViewController:tell animated:YES completion:nil];
}

// Exit or the controller's Home button (RequestExit): asks, then ends the game and the app.
- (void)askToExit {
  if (exit_alert) return;
  UIAlertController* ask = [UIAlertController
      alertControllerWithTitle:@"Ukončit hru?"
                       message:@"Neuložený postup se ztratí. Aplikace se zavře a po dalším otevření ukáže "
                               @"knihovnu her.\n\nNa ovladači: A ukončit, B zpět do hry."
                preferredStyle:UIAlertControllerStyleAlert];
  exit_now = ^{
    // The log ends as a finished run, not one that crashed (wine.log.crashed).
    WinPadRunEnded(@"player", 0);
    printf("WinPad Wine: the player ended the game (Exit)\n%s, exit 0\n", FinishedMarker.UTF8String);
    fflush(stdout);
    exit_alert = nil;
    // To the home screen first, as when the player leaves the app, then gone: Wine cannot
    // start a second game in this process.
    UIApplication* app = UIApplication.sharedApplication;
    const SEL suspend = NSSelectorFromString(@"suspend");
    if ([app respondsToSelector:suspend]) ((void (*)(id, SEL))objc_msgSend)(app, suspend);
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 400 * NSEC_PER_MSEC), dispatch_get_main_queue(), ^{
      exit(0);
    });
  };
  [ask addAction:[UIAlertAction actionWithTitle:@"Zpět do hry"
                                          style:UIAlertActionStyleCancel
                                        handler:^(UIAlertAction* action) {
                                          exit_alert = nil;
                                        }]];
  [ask addAction:[UIAlertAction actionWithTitle:@"Ukončit hru"
                                          style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction* action) {
                                          exit_now();
                                        }]];
  exit_alert = ask;
  UIViewController* top = self;
  while (top.presentedViewController) top = top.presentedViewController;
  [top presentViewController:ask animated:YES completion:nil];
}

// The touch controller goes on the window, so the controllers start once it shows.
- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  static BOOL started;
  if (started || !([self.program isEqualToString:@"game"] || gamepad_test)) return;
  started = YES;
  id touch = [NSUserDefaults.standardUserDefaults objectForKey:@"touchControls"];
  // A finger on the picture is the mouse (beneath the touch controller), unless the game's
  // "touchMouse" is "off".
  NSString* touch_mouse = [self.game.settings[@"touchMouse"] isKindOfClass:NSString.class] ? self.game.settings[@"touchMouse"] : @"direct";
  if (![touch_mouse isEqualToString:@"off"] && !gamepad_test) {
    WinPadMouseView* mouse = [[WinPadMouseView alloc] initWithFrame:self.view.bounds];
    mouse.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
    mouse.trackpad = [touch_mouse isEqualToString:@"trackpad"];
    [self.view addSubview:mouse];
    self.mouse = mouse;
  }
  printf("mouse: a finger on the picture is %s; %s moves the mouse; speed %.2f\n",
         [touch_mouse isEqualToString:@"off"] ? "nothing" : touch_mouse.UTF8String,
         pad_mouse_stick == PadRUp ? "the right stick" : pad_mouse_stick == PadLUp ? "the left stick" : "no stick", mouse_speed);
  // A Mac has a keyboard, a mouse and maybe a controller: no touch controller unless asked for.
  const BOOL touch_default = !winpad_jit_on_mac();
  Gamepads(gamepad_test || (touch ? [touch boolValue] : touch_default) ? self.view : nil, self.game.settings);
  if (pad_mouse_stick >= 0) {
    stick_mouse = [WinPadStickMouse new];
    [[CADisplayLink displayLinkWithTarget:stick_mouse selector:@selector(tick:)] addToRunLoop:NSRunLoop.mainRunLoop
                                                                                  forMode:NSRunLoopCommonModes];
  }
  [self setNeedsUpdateOfPrefersPointerLocked];
}

// A paired mouse stays with the game, as a game on a PC keeps it in its window: iPadOS hides
// its pointer and GCMouse gets every move (HardwareMouse).
- (BOOL)prefersPointerLocked {
  return metal_fill && GCMouse.mice.count > 0;
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  if (!frame_view) return;
  CGRect b = self.view.bounds;
  if (self.mouse) [self.view bringSubviewToFront:self.mouse];
  [self.view bringSubviewToFront:touch_pad];
  if (self.fps) [self.view bringSubviewToFront:self.fps];
  if (self.status && game_has_layer) {
    // Once the game draws through Metal its layer takes the whole screen, the status line
    // and the log hidden (the log stays in Documents/wine.log); the picture fills it as the
    // settings say (ScalePicture): in its own shape, stretched, or cut to the screen's shape.
    // With "Mimo výřez displeje" it leaves out an iPhone's camera cutout and rounded corners
    // at the sides (the home indicator hides by itself, so not the bottom).
    const UIEdgeInsets safe = self.view.safeAreaInsets;
    game_rect = picture_avoids_cutout ? UIEdgeInsetsInsetRect(b, UIEdgeInsetsMake(0, safe.left, 0, safe.right)) : b;
    self.view.backgroundColor = UIColor.blackColor;
    self.status.hidden = YES;
    self.text.hidden = YES;
    CGRect frame = game_rect;
    if ([picture_scaling isEqualToString:@"custom"]) {
      // The picture in its own shape (4:3 until DXMT sized the drawable), then wider by
      // picture_stretch percent, at most as wide as the screen; black at the sides.
      const CGSize d = [game_layer isKindOfClass:CAMetalLayer.class] ? ((CAMetalLayer*)game_layer).drawableSize : CGSizeZero;
      const CGFloat aspect = d.width > 0 && d.height > 0 ? d.width / d.height : 4.0 / 3;
      const CGFloat h = MIN(game_rect.size.height, game_rect.size.width / aspect);
      const CGFloat w = MIN(game_rect.size.width, h * aspect * (1 + picture_stretch / 100.0));
      frame = CGRectMake(CGRectGetMidX(game_rect) - w / 2, CGRectGetMidY(game_rect) - h / 2, w, h);
      picture_laid_out = d;
    }
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    game_layer.frame = frame;
    [CATransaction commit];
    [self placeFps];
    return;
  }
  if (self.status) {
    // The game's picture as large as fits at 4:3 above a few lines of the log.
    const CGFloat top = self.view.safeAreaInsets.top + 8;
    self.status.frame = CGRectMake(16, top, b.size.width - 32, 24);
    const CGFloat w = MIN(b.size.width - 32, (b.size.height - top - 32 - 120) * 4 / 3), h = w * 3 / 4;
    game_rect = CGRectMake((b.size.width - w) / 2, top + 32, w, h);
    frame_view.frame = game_rect;
    self.text.frame = CGRectMake(0, top + 32 + h, b.size.width, b.size.height - top - 32 - h);
    self.text.textContainerInset = UIEdgeInsetsMake(8, 16, 16, 16);
    [self placeFps];
    return;
  }
  const CGFloat top = self.view.safeAreaInsets.top + 8, h = MIN(b.size.height * 0.45, 480);
  frame_view.frame = CGRectMake(16, top, b.size.width - 32, h);
  self.text.frame = CGRectMake(0, top + h, b.size.width, b.size.height - top - h);
  self.text.textContainerInset = UIEdgeInsetsMake(8, 16, 16, 16);
}

- (void)placeFps {
  if (!self.fps) return;
  const CGSize size = [self.fps sizeThatFits:CGSizeMake(CGFLOAT_MAX, CGFLOAT_MAX)];
  // In the picture's corner, but never under an iPhone's cutout.
  const UIEdgeInsets safe = self.view.safeAreaInsets;
  self.fps.frame = CGRectMake(MAX(game_rect.origin.x, safe.left) + 6, MAX(game_rect.origin.y, safe.top) + 6,
                              size.width + 12, size.height + 6);
  self.fps.textAlignment = NSTextAlignmentCenter;
}

// Every screen refresh: note the time of each new frame the game drew, and twice
// a second show the frames of the last second, the longest of them and the size.
- (void)countFrames:(CADisplayLink*)link {
  static long (*metal_frames)(void), (*frame_size)(void);
  if (!metal_frames) {
    metal_frames = (long (*)(void))dlsym(RTLD_DEFAULT, "winehost_metal_frames");
    frame_size = (long (*)(void))dlsym(RTLD_DEFAULT, "winehost_metal_frame_size");
  }
  const long frames = metal_frames ? metal_frames() : 0;
  const CFTimeInterval now = link.timestamp;
  // Frames that came between two refreshes count with this refresh's time.
  for (; fps_seen < frames; fps_seen++) fps_times[fps_count++ % FpsTimes] = now;
  if (now - fps_shown < 0.5 || !frames) return;
  fps_shown = now;
  long in_second = 0;
  CFTimeInterval longest = 0, later = now;
  for (long i = fps_count - 1; i >= 0 && i >= fps_count - FpsTimes; i--) {
    const CFTimeInterval t = fps_times[i % FpsTimes];
    if (now - t > 1) {
      longest = MAX(longest, later - t);  // the frame that spans the second's start
      break;
    }
    in_second++;
    longest = MAX(longest, later - t);
    later = t;
  }
  const long size = frame_size ? frame_size() : 0;
  self.fps.text = size ? [NSString stringWithFormat:@"%ld FPS · max %.0f ms · %ld×%ld", in_second, longest * 1000,
                                                    size >> 32, size & 0xffffffff]
                       : [NSString stringWithFormat:@"%ld FPS · max %.0f ms", in_second, longest * 1000];
  self.fps.hidden = NO;
  [self placeFps];
}

- (BOOL)prefersStatusBarHidden {
  return game_has_layer;
}

- (BOOL)prefersHomeIndicatorAutoHidden {
  return game_has_layer;
}

- (void)showLog {
  NSString* summary = self.summary;
  if (self.game && !self.handoffShown && [NSFileManager.defaultManager fileExistsAtPath:HandoffFile()]) {
    self.handoffShown = YES;
    [self handOff];
  }
  // The custom stretch follows the game's resolution as it changes it.
  if (game_has_layer && [picture_scaling isEqualToString:@"custom"] && [game_layer isKindOfClass:CAMetalLayer.class] &&
      !CGSizeEqualToSize(((CAMetalLayer*)game_layer).drawableSize, picture_laid_out))
    [self.view setNeedsLayout];
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
  // The Direct3D test programs (tests/wine-i386/d3d9-cube.c, d3d11-triangle.c): JIT, no image.
  NSDictionary<NSString*, NSString*>* d3d_tests =
      @{@"d3d9-cube" : @"MADEIRA-D3D9", @"d3d11-triangle" : @"WINPAD-D3D11", @"d3d10-triangle" : @"WINPAD-D3D10",
        @"gl-triangle" : @"WINPAD-GL"};
  NSString* d3d_tag = d3d_tests[name];
  const BOOL cube = d3d_tag != nil, game = [name isEqualToString:@"game"];
  NSString* bundle = NSBundle.mainBundle.resourcePath;
  // A 64-bit game (PE machine AMD64) runs through ARM64EC (MakePrefix), always with the JIT.
  NSString* game_exe = game ? DocumentsPath((self.game ? self.game.exe : [NSUserDefaults.standardUserDefaults stringForKey:@"game"]) ?: @"")
                            : nil;
  const BOOL x64 = game_exe && PEMachine(game_exe) == 0x8664;
  NSString* prefix = MakePrefix(bundle, x64);
  // Each game of the library keeps its code maps apart, in fexcache/<its folder>: one folder
  // per game to copy off for WinPad Translator. The test programs use fexcache itself.
  NSString* cache = self.game ? DocumentsPath([@"fexcache" stringByAppendingPathComponent:self.game.folder])
                              : DocumentsPath(@"fexcache");
  [NSFileManager.defaultManager createDirectoryAtPath:[cache stringByAppendingPathComponent:@"codemap/new"]
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:nil];
  // This iPad's CPU features next to the code maps it records: WinPad Translator compiles the
  // game's image for them.
  // Not when recording in a simulator: those are the Mac's features, not an iPad's.
  if (!self.record)
    setenv("WINEHOST_HOSTPROBE_FILE",
           [cache stringByAppendingPathComponent:@"codemap/new/hostprobe.txt"].fileSystemRepresentation, 1);
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
  // A 32-bit program's read-write-execute memory stays plain read-write memory on the host:
  // FEX translates its x86 code, so the host never runs those pages. Shared with the JIT
  // pool instead, a page is physically read-only and only its alias takes writes, which a
  // file read into it (NFS Carbon's race data) does not use. A game's winpad.json can still
  // set it to 0.
  setenv("MADEIRA_WOW_RWX_PLAIN", "1", 1);
  setenv("WINEHOST_RETURN", "1", 1);
  // The monitor Wine's display driver and DXMT report (Madeira's sysparams_ios.c ios_screen_size,
  // DXMT's wsi_monitor_headless.cpp): 1024x768 unless "Širokoúhlý monitor" or the game's
  // winpad.json asks for another. Its modes are the standard ones up to that many pixels, so a
  // game that lists them can pick a wide one. Set before the game's winpad.json env, which may
  // still change it.
  const CGSize screen = WinPadGameScreen(self.game.settings, self.display);
  if (screen.width > 0) {
    setenv("MADEIRA_SCREEN_W", [NSString stringWithFormat:@"%.0f", screen.width].UTF8String, 1);
    setenv("MADEIRA_SCREEN_H", [NSString stringWithFormat:@"%.0f", screen.height].UTF8String, 1);
    setenv("MADEIRA_SCREEN_SRC", "WinPad", 1);
    printf("WinPad Wine: monitor %.0fx%.0f for the program (display %.0fx%.0f points)\n", screen.width, screen.height,
           self.display.width, self.display.height);
  }
  if (game)
    printf("WinPad Wine: picture %s%s%s\n", picture_scaling.UTF8String,
           [picture_scaling isEqualToString:@"custom"] ? [NSString stringWithFormat:@" +%ld %%", (long)picture_stretch].UTF8String : "",
           picture_avoids_cutout ? ", out of the cutout" : "");
  NSString* program = [bundle stringByAppendingPathComponent:[NSString stringWithFormat:@"i386-windows/%@.exe", name]];
  NSString* image = @"none (JIT)";
  NSMutableArray<NSString*>* game_args = [NSMutableArray new];
  if (game) {
    NSString* exe = self.game ? self.game.exe : [NSUserDefaults.standardUserDefaults stringForKey:@"game"];
    program = DocumentsPath(exe.length ? exe : @"NFSU2/SPEED2.EXE");
    // The game saves into its own folder (savegame\...): make it writable.
    NSString* game_folder = self.game ? DocumentsPath(self.game.folder) : program.stringByDeletingLastPathComponent;
    const NSUInteger writable = MakeWritable(game_folder);
    if (writable) printf("WinPad Wine: made %lu read-only files and folders of the game writable\n", (unsigned long)writable);
    // Folders the copy of the game lacks (empty ones) are made when the game creates a file in
    // them (patches/madeira/0009-game-dir-missing-folders).
    setenv("WINE_IOS_GAME_DIR", game_folder.fileSystemRepresentation, 1);
    // A launcher's start of a program in Documents (the game) comes back to the app.
    [NSFileManager.defaultManager removeItemAtPath:HandoffFile() error:nil];
    if (self.game) {
      setenv("WINPAD_HANDOFF_FILE", HandoffFile().fileSystemRepresentation, 1);
      setenv("WINPAD_HANDOFF_DIR", WindowsDir(DocumentsPath(@"")).UTF8String, 1);
    }
    // The Ultimate ASI Loader many games carry is a dinput8.dll of their own; the game's
    // winpad.json (its profile) may add more.
    for (NSString* line in ApplyGameSettings(self.game, prefix, game_args))
      printf("WinPad Wine: %s\n", line.UTF8String);
    // How this run goes, for the library's next look (a start that failed tries the next
    // variant of the automatic settings).
    if (self.game && !self.record) WinPadRunStarted(self.game.folder, self.game.autoVariant[@"id"], self.game.autoVariant[@"title"]);
  }
  // The game has an AOT image only where game-aot.sh put one into the
  // project on the Mac it was built on; without it the game runs with the JIT.
  // The library picked a game's own image (Library.m), else fexaot-game.dylib.
  NSString* frameworks = NSBundle.mainBundle.privateFrameworksPath;
  NSString* game_image = self.game ? self.game.image : [frameworks stringByAppendingPathComponent:@"fexaot-game.dylib"];
  // With the JIT (StikDebug attached, WinPadJIT.m) the game runs from FEX's JIT and needs no
  // image: what it has not run yet is translated as it runs, at the JIT's speed instead of the
  // interpreter's. Without it, its image and the interpreter, as before.
  if (game && !self.record) {
    NSString* jit_note = nil;
    const BOOL jit = WinPadJITPrepare(&jit_note);
    if (jit_note) printf("WinPad Wine: JIT: %s\n", jit_note.UTF8String);
    if (jit) {
      game_image = nil;
      printf("WinPad Wine: the game runs with FEX's JIT, not an AOT image\n");
    }
  }
  if (x64) {
    // FEX's ARM64EC module has no AOT images yet: a 64-bit game needs the JIT.
    game_image = nil;
    printf("WinPad Wine: 64-bit x86 program, running it through ARM64EC (arm64ec-windows) with FEX's JIT\n");
  }
  if (game_image && self.game.folderImageNote) printf("WinPad Wine: %s\n", self.game.folderImageNote.UTF8String);
  // An image in the game folder loads only if it is signed by the app's team; else the bundle's.
  if (!self.record && game_image && self.game.imageInFolder && !dlopen(game_image.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL)) {
    printf("WinPad Wine: the game folder's image did not load (%s), taking %s\n", dlerror(),
           self.game.bundleImage ? self.game.bundleImage.lastPathComponent.UTF8String : "none");
    game_image = self.game.bundleImage;
  }
  if (game_image && ![NSFileManager.defaultManager fileExistsAtPath:game_image]) game_image = nil;
  if (self.record) {
    // FEX's JIT (a simulator runs it without a debugger), recording each block it compiles into
    // Documents/fexcache/<game>/codemap/new, as tests/wine-loader/run-host.sh's
    // WINEHOST_FEX_CODEMAP=1 does: the code map is written as it grows and at the game's end.
    game_image = nil;
    setenv("FEX_ENABLECODECACHINGWIP", "1", 1);
    setenv("FEX_APP_CACHE_LOCATION", WindowsDir(cache).UTF8String, 1);
    printf("WinPad Wine: recording the game's code maps with the JIT into %s\n",
           [cache stringByAppendingPathComponent:@"codemap/new"].UTF8String);
  }
  // The Mac Catalyst app carries no AOT images: its test programs run with FEX's JIT, which
  // winehost.c maps itself as in a simulator.
  const BOOL catalyst_jit = TARGET_OS_MACCATALYST && !game;
  if (catalyst_jit) printf("WinPad Wine: Mac Catalyst: the program runs with FEX's JIT, no AOT image\n");
  if (!cube && !catalyst_jit && (!game || game_image)) {
    // Each program has its own AOT image: hello's is fexaot.dylib, NAME's fexaot-NAME.dylib.
    NSString* path = game ? game_image
                          : [frameworks stringByAppendingPathComponent:[name isEqualToString:@"hello"]
                                                                           ? @"fexaot.dylib"
                                                                           : [NSString stringWithFormat:@"fexaot-%@.dylib", name]];
    image = [path hasPrefix:frameworks] ? path.lastPathComponent
                                        : [self.game.folder stringByAppendingPathComponent:path.lastPathComponent];
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
    // With gamepadTest the touch controller's A (Enter) closes it instead, with mouseTest the
    // app's own click (ClickTest).
    if (!gamepad_test && !mouse_test) setenv("WINEHOST_CLICK", "50,50", 1);
    setenv("WINEHOST_WAIT_EXIT", "1", 1);
    setenv("WINEHOST_FRAMES", DocumentsPath(@"frames").fileSystemRepresentation, 1);
    [NSFileManager.defaultManager removeItemAtPath:DocumentsPath(@"frames") error:nil];
  }
  printf("WinPad Wine: program %s, AOT image %s\n", name.UTF8String, image.UTF8String);

  // Wine's sound goes to a RemoteIO unit, which plays in the app's audio session. Its default
  // category (solo ambient) is silenced by the iPad's silent mode, so a game's sound was mixed and
  // played without being heard. Playback is the category games use: it plays in silent mode too.
  NSError* audio_error = nil;
  AVAudioSession* audio = AVAudioSession.sharedInstance;
  if ([audio setCategory:AVAudioSessionCategoryPlayback error:&audio_error] && [audio setActive:YES error:&audio_error])
    printf("WinPad Wine: audio session playback, output %s, volume %.2f\n",
           audio.currentRoute.outputs.firstObject.portType.UTF8String ?: "none", audio.outputVolume);
  else
    printf("WinPad Wine: audio session failed: %s\n", audio_error.localizedDescription.UTF8String);

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
  // winehost passes what follows the program on to it (at most 60 arguments).
  char* args[64] = {"winehost", game ? "86400" : "60", (char*)program.fileSystemRepresentation};
  int argc = 3;
  for (NSString* arg in game_args)
    if (argc < 63) args[argc++] = strdup(arg.UTF8String);
  args[argc] = NULL;
  const int status = winehost_main(argc, args);
  NSString* log = ReadLog();
  if (game) {
    NSRegularExpression* re = [NSRegularExpression regularExpressionWithPattern:@"winehost: Wine process exited with code (-?\\w+)"
                                                                        options:0
                                                                          error:nil];
    NSTextCheckingResult* m = [re matchesInString:log options:0 range:NSMakeRange(0, log.length)].lastObject;
    unsigned code = status ? (unsigned)status : 0;
    if (m) {
      NSString* text = [log substringWithRange:[m rangeAtIndex:1]];
      code = (unsigned)strtoul(text.UTF8String, NULL, 0);
    }
    WinPadRunEnded(@"exited", (int)code);
  }
  const BOOL ok = cube   ? [log containsString:[d3d_tag stringByAppendingString:@": done, frames presented = "]] &&
                             [log containsString:@"winehost: Wine process exited with code 43"]
                  : game ? [log containsString:@"winehost: Wine process exited with code 0"]
                         : status == 0 && [log containsString:@"winehost: Wine process exited with code 0"] &&
                               (window && gamepad_test ? [log containsString:[NSString stringWithFormat:@"winehost: key %#x down", pad_keys[PadA]]]
                                : window && mouse_test ? [log containsString:@"winehost: mouse flags 0x8003"]
                                : window ? [log containsString:@"winehost: window content changed after the click"]
                                       : [log containsString:@"Hello from x86"]);
  printf("%s, exit %d\n", FinishedMarker.UTF8String, ok ? 0 : 1);

  self.summary = !ok    ? [NSString stringWithFormat:@"FAILED (winehost %d)\n\n", status]
                 : cube ? [NSString stringWithFormat:@"OK: the 32-bit %@ program presented its frames through %@.\n\n",
                                                     [d3d_tag componentsSeparatedByString:@"-"].lastObject,
                                                     [d3d_tag isEqualToString:@"WINPAD-GL"] ? @"gl4es and OpenGL ES"
                                                                                           : @"DXMT and Metal"]
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
  WinPadLogLaunch(@"scene");
  self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
  if (![ProgramName() isEqualToString:@"library"]) {
    self.window.rootViewController = [WineViewController new];
    [self.window makeKeyAndVisible];
    return;
  }
  // The library hands over to Wine, which runs once per process: the app is
  // started again for the next game. With libraryTest (CI) it only says what
  // it would run.
  // WinPad Translator's "Play and record" (record.py) starts a game straight away: -recordGame
  // FOLDER. Only a simulator runs FEX's JIT without a debugger.
  NSString* record = [NSUserDefaults.standardUserDefaults stringForKey:@"recordGame"];
  if (record.length) {
#if TARGET_OS_SIMULATOR
    for (WinPadGame* game in WinPadFindGames())
      if ([game.folder caseInsensitiveCompare:record] == NSOrderedSame) {
        WineViewController* wine = [WineViewController new];
        wine.program = @"game";
        wine.game = game;
        wine.record = YES;
        self.window.rootViewController = wine;
        [self.window makeKeyAndVisible];
        return;
      }
    NSLog(@"WinPad Wine: no game folder %@ in Documents to record", record);
#else
    NSLog(@"WinPad Wine: recording code maps needs the JIT: only in a simulator");
#endif
  }
  // A game's launcher started the game in the last run (handOff): the library starts it, once,
  // through Spustit's checks (StikDebug's JIT); the file goes when a program starts.
  NSData* handoff = [NSData dataWithContentsOfFile:HandoffNext()];
  NSDictionary* next = handoff ? [NSJSONSerialization JSONObjectWithData:handoff options:0 error:nil] : nil;
  WinPadGame* handed_over = nil;
  if ([next isKindOfClass:NSDictionary.class] && [next[@"folder"] isKindOfClass:NSString.class] &&
      [next[@"exe"] isKindOfClass:NSString.class] && NSDate.date.timeIntervalSince1970 - [next[@"time"] doubleValue] < 600 &&
      ![NSUserDefaults.standardUserDefaults boolForKey:@"libraryTest"])
    for (WinPadGame* game in WinPadFindGames())
      if ([game.folder isEqualToString:next[@"folder"]]) {
        game.exe = [game.folder stringByAppendingPathComponent:next[@"exe"]];
        NSMutableDictionary* settings = [(game.settings ?: @{}) mutableCopy];
        if ([next[@"args"] isKindOfClass:NSArray.class]) settings[@"args"] = next[@"args"];
        game.settings = settings;
        NSLog(@"WinPad Wine: starting %@, which the game's launcher started", game.exe);
        handed_over = game;
        break;
      }
  if (!handed_over) [NSFileManager.defaultManager removeItemAtPath:HandoffNext() error:nil];
  LibraryViewController* library = [LibraryViewController new];
  library.handedOver = handed_over;
  __weak UIWindow* window = self.window;
  library.start = ^(NSString* program, WinPadGame* game) {
    [NSFileManager.defaultManager removeItemAtPath:HandoffNext() error:nil];
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"libraryTest"]) {
      NSString* path = DocumentsPath(@"library.txt");
      NSString* report = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil] ?: @"";
      report = [report stringByAppendingFormat:@"start: %@ %@, image %@\n", program, game.exe ?: @"-",
                                               game.image.lastPathComponent ?: @"none"];
      // What the game would be started with (its winpad.json): the registry values go into the
      // prefix for real, so that the runs after this one load them.
      NSMutableArray<NSString*>* game_args = [NSMutableArray new];
      for (NSString* line in ApplyGameSettings(game, MakePrefix(NSBundle.mainBundle.resourcePath, [game.arch isEqualToString:@"64bit"]), game_args))
        report = [report stringByAppendingFormat:@"settings: %@\n", line];
      report = [report stringByAppendingFormat:@"%@\n", FinishedMarker];
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
  // Started by opening a WinPad package (.winpad) from AirDrop or Files.
  [self scene:scene openURLContexts:options.URLContexts];
}

// A WinPad package (.winpad, Info.plist's document type) opened from AirDrop, Files or a
// share sheet: the library unpacks it into a game folder. While a game runs, the package
// waits in Documents for the library's next start.
- (void)scene:(UIScene*)scene openURLContexts:(NSSet<UIOpenURLContext*>*)contexts {
  NSMutableArray<NSURL*>* urls = [NSMutableArray new];
  for (UIOpenURLContext* context in contexts)
    if (context.URL.isFileURL && [context.URL.pathExtension.lowercaseString isEqualToString:@"winpad"])
      [urls addObject:context.URL];
  if (!urls.count) return;
  UIViewController* root = self.window.rootViewController;
  if ([root isKindOfClass:LibraryViewController.class]) {
    [(LibraryViewController*)root openPackages:urls];
    return;
  }
  NSString* docs = DocumentsPath(@"");
  for (NSURL* url in urls) {
    if ([url.path.stringByResolvingSymlinksInPath hasPrefix:docs.stringByResolvingSymlinksInPath]) continue;
    const BOOL scoped = [url startAccessingSecurityScopedResource];
    [NSFileManager.defaultManager copyItemAtPath:url.path
                                          toPath:[docs stringByAppendingPathComponent:url.lastPathComponent]
                                           error:nil];
    if (scoped) [url stopAccessingSecurityScopedResource];
  }
}
@end

@interface WineAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation WineAppDelegate
- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)options {
  // How much memory iPadOS lets the app have (more with the increased memory limit
  // entitlement, WINPAD_MEMORY in WinPad.xcconfig): games' RAM and video memory share it.
  printf("WinPad Wine: memory available to the app: %llu MB of %llu MB\n",
         (unsigned long long)os_proc_available_memory() >> 20, NSProcessInfo.processInfo.physicalMemory >> 20);
  // StikDebug started the app with its script attached: the JIT pool is made now, while the
  // script waits for it (WinPadJIT.m).
  if (WinPadJITAttached()) {
    NSString* note = nil;
    WinPadJITPrepare(&note);
    NSLog(@"WinPad Wine: JIT at launch: %@", note);
  }
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
    WinPadLogLaunch(@"main");
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([WineAppDelegate class]));
  }
}
