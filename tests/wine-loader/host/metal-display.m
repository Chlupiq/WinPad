// SPDX-License-Identifier: MIT
// What DXMT needs from the app to present: a CAMetalLayer for a window.
// DXMT's winemetal_unix.c looks up Wine's mac driver functions with
// dlsym(RTLD_DEFAULT, "macdrv_functions"); Madeira's app answers with
// app/Madeira/IOSDisplayShim.m, whose macdrv_functions this follows. There
// the layer sits in the app's window; this host has no window on screen, so
// every HWND gets a layer of its own that is never shown, unless an app
// around the host (tests/wine-app) defines winehost_show_metal_layer.
// Presenting into it works the same: DXMT takes a drawable from it for each
// frame it presents, and the host counts those (-[CAMetalLayer nextDrawable]
// is wrapped). On the simulator it also stands in for MetalFX, which the
// simulator lacks. Linked into winehost by link-host.sh when DXMT's unix
// side is there.
#import <Foundation/Foundation.h>
#import <Metal/Metal.h>
#import <QuartzCore/CAMetalLayer.h>
#import <objc/runtime.h>
#include <dlfcn.h>
#include <pthread.h>
#include <stdint.h>
#include <stdio.h>
#include <TargetConditionals.h>

typedef struct opaque_HWND* HWND;
typedef void* macdrv_view;

// The layout winemetal_unix.c expects (struct macdrv_win_data,
// struct macdrv_functions_t there).
struct macdrv_win_data {
  HWND hwnd;
  void* cocoa_window;
  macdrv_view cocoa_view;
  macdrv_view client_cocoa_view;
};

struct macdrv_functions_t {
  void (*macdrv_init_display_devices)(int);
  struct macdrv_win_data* (*get_win_data)(HWND hwnd);
  void (*release_win_data)(struct macdrv_win_data* data);
  void* (*macdrv_get_cocoa_window)(HWND hwnd, int require_on_screen);
  void* (*macdrv_create_metal_device)(void);
  void (*macdrv_release_metal_device)(void* d);
  void* (*macdrv_view_create_metal_view)(macdrv_view v, void* d);
  void* (*macdrv_view_get_metal_layer)(void* v);
  void (*macdrv_view_release_metal_view)(void* v);
  void (*on_main_thread)(dispatch_block_t b);
};

// As in IOSDisplayShim.m: the client view field carries the HWND on to
// create_metal_view.
static struct macdrv_win_data win_data;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

static struct macdrv_win_data* get_win_data_impl(HWND hwnd) {
  pthread_mutex_lock(&lock);
  win_data.hwnd = hwnd;
  win_data.client_cocoa_view = (macdrv_view)hwnd;
  return &win_data;
}

static void release_win_data_impl(struct macdrv_win_data* data) {
  (void)data;
  pthread_mutex_unlock(&lock);
}

static void* create_metal_device(void) { return (void*)(uintptr_t)1; }
static void release_metal_device(void* d) { (void)d; }

static void* create_metal_view(macdrv_view v, void* d) {
  (void)d;
  CAMetalLayer* layer = [CAMetalLayer layer];
  layer.frame = CGRectMake(0, 0, 640, 480);
  fprintf(stderr, "winehost: Metal layer %p for window %p\n", (__bridge void*)layer, v);
  // An app around the host (tests/wine-app) shows the layer on screen.
  void (*show)(CAMetalLayer*) = (void (*)(CAMetalLayer*))dlsym(RTLD_DEFAULT, "winehost_show_metal_layer");
  if (show) show(layer);
  return (void*)CFBridgingRetain(layer);
}

static void* get_metal_layer(void* v) { return v; }

static void release_metal_view(void* v) {
  if (v) CFBridgingRelease(v);
}

static void on_main_thread(dispatch_block_t b) {
  if ([NSThread isMainThread]) b();
  else dispatch_async(dispatch_get_main_queue(), b);
}

__attribute__((used, visibility("default"))) struct macdrv_functions_t macdrv_functions = {
    .get_win_data = get_win_data_impl,
    .release_win_data = release_win_data_impl,
    .macdrv_create_metal_device = create_metal_device,
    .macdrv_release_metal_device = release_metal_device,
    .macdrv_view_create_metal_view = create_metal_view,
    .macdrv_view_get_metal_layer = get_metal_layer,
    .macdrv_view_release_metal_view = release_metal_view,
    .on_main_thread = on_main_thread,
};

// Every drawable DXMT takes to present a frame into.
static id (*next_drawable)(id, SEL);
static long drawables;

static id counting_next_drawable(id self, SEL sel) {
  id<CAMetalDrawable> drawable = next_drawable(self, sel);
  long n = __atomic_add_fetch(&drawables, 1, __ATOMIC_RELAXED);
  if (n <= 3 || n % 60 == 0) {
    id<MTLTexture> t = drawable.texture;
    fprintf(stderr, "winehost: drawable %ld of Metal layer %p: %lux%lu, pixel format %lu, device %s\n",
            n, (__bridge void*)self, (unsigned long)t.width, (unsigned long)t.height,
            (unsigned long)t.pixelFormat, [[((CAMetalLayer*)self).device name] UTF8String]);
  }
  return drawable;
}

// For the app's status line: how many frames the program has drawn through Metal so far.
__attribute__((used, visibility("default"))) long winehost_metal_frames(void) {
  return __atomic_load_n(&drawables, __ATOMIC_RELAXED);
}

// The first command buffers committed and how each one ends. (The
// simulator SDK has no presented handlers for drawables.)
static void (*commit_buffer)(id, SEL);
static long commits;

static void logging_commit(id self, SEL sel) {
  long n = __atomic_add_fetch(&commits, 1, __ATOMIC_RELAXED);
  if (n <= 8) {
    fprintf(stderr, "winehost: command buffer %ld committed\n", n);
    [(id<MTLCommandBuffer>)self addCompletedHandler:^(id<MTLCommandBuffer> cb) {
      fprintf(stderr, "winehost: command buffer %ld completed, status %ld%s%s\n", n, (long)cb.status,
              cb.error ? ", " : "", cb.error ? [[cb.error description] UTF8String] : "");
    }];
  }
  commit_buffer(self, sel);
}

void madeira_set_vsync_locked(int mode);  // DXMT's winemetal_unix.c

__attribute__((constructor)) static void wrap_next_drawable(void) {
  Method m = class_getInstanceMethod([CAMetalLayer class], @selector(nextDrawable));
  next_drawable = (id (*)(id, SEL))method_setImplementation(m, (IMP)counting_next_drawable);
#if TARGET_OS_SIMULATOR
  // DXMT caps presents at 60 per second by default with
  // presentDrawable:afterMinimumDuration:, which the simulator's command
  // buffers (MTLSimCommandBuffer) do not implement; mode 0 presents each
  // frame with presentDrawable:.
  madeira_set_vsync_locked(0);
#endif
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  fprintf(stderr, "winehost: Metal device %s\n", device ? [[device name] UTF8String] : "none");
  // What DXMT's draws rely on: Metal 3 bindless resources, written into
  // tier 2 argument buffers (GPU addresses and resource IDs).
  if (device)
    fprintf(stderr, "winehost: Metal device %s: argument buffers tier %d, Metal 3 family: %s, Apple 7: %s\n",
            [[device name] UTF8String], device.argumentBuffersSupport == MTLArgumentBuffersTier2 ? 2 : 1,
            [device supportsFamily:MTLGPUFamilyMetal3] ? "yes" : "no",
            [device supportsFamily:MTLGPUFamilyApple7] ? "yes" : "no");
  id<MTLCommandBuffer> cb = [[device newCommandQueue] commandBuffer];
  if (cb) {
    Method c = class_getInstanceMethod([cb class], @selector(commit));
    commit_buffer = (void (*)(id, SEL))method_setImplementation(c, (IMP)logging_commit);
  }
}

#if TARGET_OS_SIMULATOR
// The simulator has no MetalFX, so DXMT's references to its classes have
// nothing to bind to. These stand-ins say that no MetalFX scaler or frame
// interpolator is supported, which turns those features off in DXMT.
@interface MTLFXSpatialScalerDescriptor : NSObject
@end
@implementation MTLFXSpatialScalerDescriptor
+ (BOOL)supportsDevice:(id)device { return NO; }
@end
@interface MTLFXTemporalScalerDescriptor : NSObject
@end
@implementation MTLFXTemporalScalerDescriptor
+ (BOOL)supportsDevice:(id)device { return NO; }
@end
@interface MTLFXFrameInterpolatorDescriptor : NSObject
@end
@implementation MTLFXFrameInterpolatorDescriptor
+ (BOOL)supportsDevice:(id)device { return NO; }
@end
// Nor textures shared across processes (DXMT's shared resources): no
// handle can be made from a mach port.
@interface MTLSharedTextureHandle : NSObject
@end
@implementation MTLSharedTextureHandle
- (instancetype)initWithMachPort:(unsigned int)port { return nil; }
- (unsigned int)createMachPort { return 0; }
@end
#endif
