// SPDX-License-Identifier: MIT
// FEX's JIT in the app (WinPadJIT.h).
#import "WinPadJIT.h"

#import <NetworkExtension/NetworkExtension.h>
#import <UIKit/UIKit.h>

#include <dlfcn.h>

#include "JITPool.h"

// The private NSExtension API (ExtensionFoundation) that starts an app extension of the app's
// own by its bundle ID, as LiveContainer and Madeira start theirs.
@interface NSObject (WinPadNSExtension)
+ (id)extensionWithIdentifier:(NSString*)identifier error:(NSError**)error;
- (void)beginExtensionRequestWithInputItems:(NSArray*)items completion:(void (^)(NSUUID* request))completion;
- (void)setRequestCompletionBlock:(void (^)(NSUUID* request, NSArray* items))block;
- (void)setRequestCancellationBlock:(void (^)(NSUUID* request, NSError* error))block;
- (void)setRequestInterruptionBlock:(void (^)(NSUUID* request))block;
@end

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
  return WinPadJITCanTurnOn();
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

BOOL WinPadJITUsable(void) {
#if TARGET_OS_SIMULATOR
  return YES;
#else
  return WinPadJITWanted() && WinPadJITAttached();
#endif
}

BOOL WinPadJITStikDebugInstalled(void) {
  return [UIApplication.sharedApplication canOpenURL:[NSURL URLWithString:@"stikdebug://"]];
}

static NSString* const HelperFile = @"WinPadJITHelper.appex";

static NSString* Documents(void) {
  return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

NSString* WinPadJITPairingPath(void) {
  return [Documents() stringByAppendingPathComponent:@"StikJIT/pairingFile.plist"];
}

static BOOL LooksLikePairing(NSString* name) {
  NSString* lower = name.lowercaseString;
  return [lower.pathExtension isEqualToString:@"mobiledevicepairing"] ||
         ([lower.pathExtension isEqualToString:@"plist"] && [lower containsString:@"pair"]);
}

BOOL WinPadJITImportPairing(NSURL* url, NSString** error) {
  const BOOL scoped = [url startAccessingSecurityScopedResource];
  NSData* data = [NSData dataWithContentsOfURL:url];
  if (scoped) [url stopAccessingSecurityScopedResource];
  // A pairing file is a property list with the host's certificate and keys.
  id plist = data ? [NSPropertyListSerialization propertyListWithData:data options:0 format:NULL error:nil] : nil;
  if (![plist isKindOfClass:NSDictionary.class] || (!plist[@"HostID"] && !plist[@"DeviceCertificate"])) {
    if (error) *error = @"Tohle není párovací soubor (chybí v něm HostID a certifikát).";
    return NO;
  }
  NSString* path = WinPadJITPairingPath();
  [NSFileManager.defaultManager createDirectoryAtPath:path.stringByDeletingLastPathComponent
                          withIntermediateDirectories:YES
                                           attributes:nil
                                                error:nil];
  if (![data writeToFile:path atomically:YES]) {
    if (error) *error = @"Párovací soubor se nepodařilo uložit.";
    return NO;
  }
  return YES;
}

BOOL WinPadJITHasPairing(void) {
  NSFileManager* files = NSFileManager.defaultManager;
  for (NSString* name in [files contentsOfDirectoryAtPath:Documents() error:nil]) {
    if (!LooksLikePairing(name)) continue;
    NSString* path = [Documents() stringByAppendingPathComponent:name];
    if (WinPadJITImportPairing([NSURL fileURLWithPath:path], nil)) [files removeItemAtPath:path error:nil];
  }
  return [files fileExistsAtPath:WinPadJITPairingPath()];
}

// The value of one of the app's own entitlements, or NULL (to release). Security's SecTask
// calls are not in the iOS SDK's headers.
static CFTypeRef CopyEntitlement(CFStringRef name, int* known) {
  *known = 0;
  void* security = dlopen("/System/Library/Frameworks/Security.framework/Security", RTLD_LAZY);
  void* (*create)(CFAllocatorRef) = security ? dlsym(security, "SecTaskCreateFromSelf") : NULL;
  CFTypeRef (*copy)(void*, CFStringRef, CFErrorRef*) = security ? dlsym(security, "SecTaskCopyValueForEntitlement") : NULL;
  if (!create || !copy) return NULL;
  void* task = create(NULL);
  if (!task) return NULL;
  *known = 1;
  CFTypeRef value = copy(task, name, NULL);
  CFRelease(task);
  return value;
}

// get-task-allow: a debugger may attach to the app at all (a development signature; SideStore,
// AltStore and Xcode keep it). -1 when it cannot tell.
static int HasGetTaskAllow(void) {
  int known = 0;
  CFTypeRef value = CopyEntitlement(CFSTR("get-task-allow"), &known);
  const int allowed = value == kCFBooleanTrue;
  if (value) CFRelease(value);
  return known ? allowed : -1;
}

static NSString* HelperIdentifier(void) {
  NSURL* url = [NSBundle.mainBundle.builtInPlugInsURL URLByAppendingPathComponent:HelperFile];
  return url ? [NSBundle bundleWithURL:url].bundleIdentifier : nil;
}

NSString* WinPadJITBuiltInUnavailableReason(void) {
#if TARGET_OS_SIMULATOR
  return @"Vestavěný JIT funguje jen na skutečném iPadu nebo iPhonu.";
#else
  if (getenv("LC_HOME_PATH")) return @"V LiveContainer vestavěný JIT nejde: použij StikDebug.";
  if (!HelperIdentifier()) return @"V téhle instalaci chybí pomocník JITu (WinPadJITHelper.appex).";
  if (HasGetTaskAllow() == 0)
    return @"Aplikace je podepsaná bez get-task-allow: nainstaluj ji z Xcode, SideStore nebo AltStore.";
  return nil;
#endif
}

BOOL WinPadJITCanTurnOn(void) {
  return (!WinPadJITBuiltInUnavailableReason() && WinPadJITHasPairing()) || WinPadJITStikDebugInstalled();
}

// Requests that have started and not finished, kept alive until they do.
static NSMutableSet* running;

void WinPadJITBuiltInSend(NSString* operation, void (^done)(BOOL ok, NSString* message)) {
  void (^finish)(BOOL, NSString*) = ^(BOOL ok, NSString* message) {
    NSLog(@"WinPad Wine: JIT helper %@: %@ %@", operation, ok ? @"ok" : @"failed", message);
    dispatch_async(dispatch_get_main_queue(), ^{
      if (done) done(ok, message);
    });
  };
  NSString* reason = WinPadJITBuiltInUnavailableReason();
  if (reason) { finish(NO, reason); return; }
  NSData* pairing = [NSData dataWithContentsOfFile:WinPadJITPairingPath()];
  if (!pairing.length) { finish(NO, @"Chybí párovací soubor."); return; }
  if (!NSClassFromString(@"NSExtension"))
    dlopen("/System/Library/Frameworks/ExtensionFoundation.framework/ExtensionFoundation", RTLD_NOW);
  Class factory = NSClassFromString(@"NSExtension");
  if (!factory) { finish(NO, @"iOS nedává rozhraní, které pomocník JITu potřebuje."); return; }
  NSError* error = nil;
  id extension = [factory extensionWithIdentifier:HelperIdentifier() error:&error];
  if (!extension)
    { finish(NO, [NSString stringWithFormat:@"Pomocník JITu se nenašel: %@", error.localizedDescription]); return; }
  NSDictionary* request = @{
    @"operation" : operation,
    @"pid" : @(getpid()),
    @"pairing" : [pairing base64EncodedStringWithOptions:0],
    @"txm" : @(winpad_jit_has_txm() != 0),
  };
  NSData* json = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
  if (!running) running = [NSMutableSet new];
  [running addObject:extension];
  __block BOOL over = NO;
  void (^end)(BOOL, NSString*) = ^(BOOL ok, NSString* message) {
    @synchronized(running) {
      if (over) return;
      over = YES;
      [running removeObject:extension];
    }
    finish(ok, message);
  };
  [extension setRequestCompletionBlock:^(NSUUID* uuid, NSArray* items) {
    NSExtensionItem* item = items.firstObject;
    NSData* payload = [item isKindOfClass:NSExtensionItem.class] ? item.userInfo[@"winpad-jit-response"] : nil;
    NSDictionary* answer = payload ? [NSJSONSerialization JSONObjectWithData:payload options:0 error:nil] : nil;
    if (![answer isKindOfClass:NSDictionary.class]) { end(NO, @"Pomocník JITu skončil bez odpovědi."); return; }
    end([answer[@"success"] boolValue], [answer[@"message"] description]);
  }];
  [extension setRequestCancellationBlock:^(NSUUID* uuid, NSError* cancelled) {
    end(NO, [NSString stringWithFormat:@"Pomocník JITu skončil: %@", cancelled.localizedDescription ?: @"zrušeno"]);
  }];
  [extension setRequestInterruptionBlock:^(NSUUID* uuid) {
    end(NO, @"Pomocník JITu nečekaně skončil.");
  }];
  NSExtensionItem* item = [NSExtensionItem new];
  item.userInfo = @{@"winpad-jit-request" : json};
  [extension beginExtensionRequestWithInputItems:@[ item ]
                                      completion:^(NSUUID* uuid) {
                                        if (!uuid) end(NO, @"Pomocník JITu se nespustil.");
                                      }];
}

static NSString* VPNIdentifier(void) {
  NSURL* url = [NSBundle.mainBundle.builtInPlugInsURL URLByAppendingPathComponent:@"WinPadVPN.appex"];
  return url ? [NSBundle bundleWithURL:url].bundleIdentifier : nil;
}

BOOL WinPadVPNBuiltIn(void) {
#if TARGET_OS_SIMULATOR
  return NO;
#else
  if (!VPNIdentifier()) return NO;
  int known = 0;
  CFTypeRef value = CopyEntitlement(CFSTR("com.apple.developer.networking.networkextension"), &known);
  const BOOL tunnel = value && CFGetTypeID(value) == CFArrayGetTypeID() &&
                      [(__bridge NSArray*)value containsObject:@"packet-tunnel-provider"];
  if (value) CFRelease(value);
  return tunnel;
#endif
}

// Starts the app's own VPN (its configuration made on first use: iOS asks the user once) and
// calls DONE on the main thread once it is connected, or with why not. The VPN that was
// already on stays on; one this started is stopped by StopVPN.
static NETunnelProviderManager* started_vpn;

static void StartVPN(void (^done)(BOOL ok, NSString* message)) {
  void (^finish)(BOOL, NSString*) = ^(BOOL ok, NSString* message) {
    NSLog(@"WinPad Wine: VPN %@: %@", ok ? @"on" : @"failed", message);
    dispatch_async(dispatch_get_main_queue(), ^{
      done(ok, message);
    });
  };
  NSString* identifier = VPNIdentifier();
  [NETunnelProviderManager loadAllFromPreferencesWithCompletionHandler:^(NSArray<NETunnelProviderManager*>* managers,
                                                                         NSError* error) {
    NETunnelProviderManager* manager = nil;
    for (NETunnelProviderManager* m in managers)
      if ([((NETunnelProviderProtocol*)m.protocolConfiguration).providerBundleIdentifier isEqualToString:identifier])
        manager = m;
    if (manager.connection.status == NEVPNStatusConnected) {
      finish(YES, @"už byla zapnutá");
      return;
    }
    if (!manager) {
      manager = [NETunnelProviderManager new];
      NETunnelProviderProtocol* protocol = [NETunnelProviderProtocol new];
      protocol.providerBundleIdentifier = identifier;
      protocol.serverAddress = @"WinPad Wine (jen v iPadu)";
      manager.protocolConfiguration = protocol;
      manager.localizedDescription = @"WinPad JIT";
    }
    manager.enabled = YES;
    [manager saveToPreferencesWithCompletionHandler:^(NSError* saved) {
      if (saved) {
        finish(NO, [NSString stringWithFormat:@"VPN se nepodařilo nastavit: %@", saved.localizedDescription]);
        return;
      }
      [manager loadFromPreferencesWithCompletionHandler:^(NSError* loaded) {
        NSError* failed = nil;
        if (loaded || ![manager.connection startVPNTunnelAndReturnError:&failed]) {
          finish(NO, [NSString stringWithFormat:@"VPN se nezapnula: %@", (loaded ?: failed).localizedDescription]);
          return;
        }
        started_vpn = manager;
        // Connected within a few seconds, or not at all.
        __block int waited = 0;
        __block void (^check)(void);
        check = ^{
          if (manager.connection.status == NEVPNStatusConnected) {
            finish(YES, @"zapnutá");
            check = nil;
          } else if (++waited > 40) {
            finish(NO, @"VPN se nepřipojila.");
            check = nil;
          } else {
            void (^again)(void) = check;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 250 * NSEC_PER_MSEC), dispatch_get_main_queue(), again);
          }
        };
        dispatch_async(dispatch_get_main_queue(), check);
      }];
    }];
  }];
}

static void StopVPN(void) {
  [started_vpn.connection stopVPNTunnel];
  started_vpn = nil;
}

void WinPadJITTurnOn(void (^done)(BOOL ok, NSString* message)) {
  __block BOOL over = NO;
  __block NSTimer* timer = nil;
  void (^end)(BOOL, NSString*) = ^(BOOL ok, NSString* message) {
    if (over) return;
    over = YES;
    [timer invalidate];
    if (done) done(ok, message);
  };
  // Once a debugger is attached, the JIT pool right away, while its script waits for it
  // (the app's own main thread: the brk stops it until the script has answered).
  const CFAbsoluteTime begin = CFAbsoluteTimeGetCurrent();
  const BOOL builtin = !WinPadJITBuiltInUnavailableReason() && WinPadJITHasPairing();
  // The built-in helper may first download and mount the Developer Disk Image.
  const double limit = builtin ? 300 : 90;
  timer = [NSTimer scheduledTimerWithTimeInterval:0.25
                                          repeats:YES
                                          block:^(NSTimer* t) {
                                            if (WinPadJITAttached()) {
                                              NSString* note = nil;
                                              const BOOL ok = WinPadJITPrepare(&note);
                                              end(ok, note);
                                            } else if (CFAbsoluteTimeGetCurrent() - begin > limit) {
                                              end(NO, builtin ? @"Pomocník JITu se nepřipojil včas (je zapnutá LocalDevVPN?)."
                                                              : @"StikDebug se nepřipojil včas.");
                                            }
                                          }];
  if (builtin) {
    void (^send)(void) = ^{
      WinPadJITBuiltInSend(@"enable", ^(BOOL ok, NSString* message) {
        // The helper is done with the debug tunnel: the app's own VPN can go.
        StopVPN();
        // Success arrives after the pool (the timer); a failure before it ends the wait.
        if (!ok) end(NO, message);
      });
    };
    // The app's own VPN first, where it has one; else LocalDevVPN is the user's.
    if (WinPadVPNBuiltIn())
      StartVPN(^(BOOL ok, NSString* message) {
        if (ok)
          send();
        else
          end(NO, message);
      });
    else
      send();
    return;
  }
  WinPadJITAskStikDebug(^(BOOL opened) {
    if (!opened) end(NO, @"StikDebug se nepodařilo otevřít.");
  });
}
