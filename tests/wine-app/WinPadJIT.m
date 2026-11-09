// SPDX-License-Identifier: MIT
// FEX's JIT in the app (WinPadJIT.h).
#import "WinPadJIT.h"

#import <UIKit/UIKit.h>

#include "JITPool.h"

// The pool FEX writes its code into: as winehost.c's own (WINEHOST_JIT_POOL_MB overrides it).
static size_t PoolSize(void) {
  const char* mb = getenv("WINEHOST_JIT_POOL_MB");
  return (mb && atoi(mb) > 0 ? (size_t)atoi(mb) : 512) << 20;
}

// Written just before the check that code in the pool runs, removed after it (JITPool.c).
static NSString* Marker(void) {
  NSString* docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
  return [docs stringByAppendingPathComponent:@".jit-check"];
}

static BOOL Setting(NSString* key) {
  id value = [NSUserDefaults.standardUserDefaults objectForKey:key];
  return !value || [value boolValue];
}

BOOL WinPadJITWanted(void) { return Setting(@"jit"); }
BOOL WinPadJITAskWanted(void) { return Setting(@"jitStikDebug"); }

static BOOL failed_before_checked, failed_before;

BOOL WinPadJITPrepare(NSString** note) {
  char why[256];
  // Once per launch: the check of the launch before this one stopped the app.
  if (!failed_before_checked) {
    failed_before_checked = YES;
    failed_before = winpad_jit_failed_before(Marker().fileSystemRepresentation);
  }
  const enum winpad_jit_kind kind = winpad_jit_kind(why, sizeof(why));
  NSString* line = @(why);
  BOOL ready = NO;
  if (kind == WINPAD_JIT_SIMULATOR || kind == WINPAD_JIT_NONE) {
    ready = NO;
  } else if (!WinPadJITWanted()) {
    line = [line stringByAppendingString:@"; the JIT is off in the settings"];
  } else if (kind == WINPAD_JIT_DEBUGGED) {
    ready = YES;
  } else if (failed_before && !winpad_jit_pool_ready()) {
    line = @"the JIT check stopped the app last time: this launch runs without the JIT";
  } else {
    ready = !winpad_jit_prepare_pool(PoolSize(), Marker().fileSystemRepresentation, why, sizeof(why));
    line = @(why);
  }
  if (note) *note = line;
  return ready;
}

NSString* WinPadJITStatus(void) {
  char why[256];
  const enum winpad_jit_kind kind = winpad_jit_kind(why, sizeof(why));
  switch (kind) {
    case WINPAD_JIT_SIMULATOR: return @"Simulátor: JIT bez debuggeru";
    case WINPAD_JIT_DEBUGGED: return @"Zapnutý (debugger, bez TXM)";
    case WINPAD_JIT_TXM_SCRIPT: return winpad_jit_pool_ready() ? @"Zapnutý (StikDebug)" : @"StikDebug připojen";
    case WINPAD_JIT_NONE:
      if (winpad_jit_has_txm() && winpad_jit_traced() && winpad_jit_under_xcode()) return @"Xcode: na TXM bez JITu";
      return @"Vypnutý: hry běží z AOT obrazu";
  }
  return @"?";
}

BOOL WinPadJITAttached(void) {
  const enum winpad_jit_kind kind = winpad_jit_kind(NULL, 0);
  return kind == WINPAD_JIT_DEBUGGED || kind == WINPAD_JIT_TXM_SCRIPT;
}

static NSURL* StikDebugURL(void) {
  NSURLComponents* url = [NSURLComponents componentsWithString:@"stikdebug://enable-jit"];
  NSMutableArray* items = [NSMutableArray arrayWithObjects:
      [NSURLQueryItem queryItemWithName:@"bundle-id" value:NSBundle.mainBundle.bundleIdentifier],
      [NSURLQueryItem queryItemWithName:@"pid" value:@(getpid()).stringValue], nil];
  // With TXM the attach alone does not make memory executable: StikDebug runs its universal.js
  // script, which answers JITPool.c's breakpoints. Without TXM it attaches and leaves.
  if (winpad_jit_has_txm()) [items addObject:[NSURLQueryItem queryItemWithName:@"script-name" value:@"universal.js"]];
  url.queryItems = items;
  return url.URL;
}

BOOL WinPadJITShouldAskStikDebug(void) {
#if TARGET_OS_SIMULATOR
  return NO;
#else
  if (!WinPadJITWanted() || !WinPadJITAskWanted() || WinPadJITAttached() || winpad_jit_under_xcode()) return NO;
  if (winpad_jit_pool_ready()) return NO;
  return [UIApplication.sharedApplication canOpenURL:[NSURL URLWithString:@"stikdebug://"]];
#endif
}

void WinPadJITAskStikDebug(void (^done)(BOOL opened)) {
  NSURL* url = StikDebugURL();
  NSLog(@"WinPad Wine: asking StikDebug for the JIT: %@", url);
  [UIApplication.sharedApplication openURL:url
                                   options:@{}
                         completionHandler:^(BOOL success) {
                           if (done) done(success);
                         }];
}
