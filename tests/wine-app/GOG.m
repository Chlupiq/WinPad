// SPDX-License-Identifier: MIT
// GOG in WinPad Wine: sign in, the account's games, a game installed from GOG's content
// system onto the iPad (GOG.h says how).
#import "GOG.h"

#import <CommonCrypto/CommonDigest.h>
#import <Security/Security.h>
#import <WebKit/WebKit.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#include <zlib.h>

NSNotificationName const WinPadGOGInstalledNotification = @"WinPadGOGInstalled";

// GOG Galaxy's own client, which GOG's login page knows (Heroic, gogdl and lgogdownloader sign
// in with it too): the code the login page hands to its redirect is exchanged for tokens.
static NSString* const ClientId = @"46899977096215655";
static NSString* const ClientSecret = @"9d85c43b1482497dbbce61f6e4aa173a433796eeae2ca8c5f6129f2dc4de46d9";
static NSString* const RedirectURI = @"https://embed.gog.com/on_login_success?origin=client";

static NSString* Documents(void) {
  return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

// GOG's HOST and PATH; with the "gogAPIBase" setting (CI) BASE/HOST/PATH, a local copy of it.
static NSURL* GOGURL(NSString* host, NSString* path) {
  NSString* base = [NSUserDefaults.standardUserDefaults stringForKey:@"gogAPIBase"];
  if (base.length) return [NSURL URLWithString:[NSString stringWithFormat:@"%@/%@%@", base, host, path]];
  return [NSURL URLWithString:[NSString stringWithFormat:@"https://%@%@", host, path]];
}

static NSString* Escaped(NSString* s) {
  NSMutableCharacterSet* ok = [NSCharacterSet.alphanumericCharacterSet mutableCopy];
  [ok addCharactersInString:@"-._~"];
  return [s stringByAddingPercentEncodingWithAllowedCharacters:ok];
}

static NSString* Str(id v) {
  if ([v isKindOfClass:NSString.class]) return v;
  if ([v isKindOfClass:NSNumber.class]) return [v stringValue];
  return nil;
}

static NSURLSession* Session(void) {
  static NSURLSession* session;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSURLSessionConfiguration* c = NSURLSessionConfiguration.defaultSessionConfiguration;
    c.timeoutIntervalForRequest = 60;
    c.HTTPMaximumConnectionsPerHost = 8;
    c.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    c.URLCache = nil;
    session = [NSURLSession sessionWithConfiguration:c];
  });
  return session;
}

// Gets URL (with TOKEN as the bearer, if any). DONE gets the body, or why not with the HTTP
// status (0 when the server was not reached). Runs on the session's queue.
static void FetchRange(NSURL* url, NSString* token, NSString* range, void (^done)(NSData* data, NSString* error, NSInteger status));

static void Fetch(NSURL* url, NSString* token, void (^done)(NSData* data, NSString* error, NSInteger status)) {
  FetchRange(url, token, nil, done);
}

// The same with a Range header (RANGE: "bytes=START-END"), for generation 1's main.bin.
static void FetchRange(NSURL* url, NSString* token, NSString* range, void (^done)(NSData* data, NSString* error, NSInteger status)) {
  if (!url) {
    done(nil, @"špatná adresa", 0);
    return;
  }
  NSMutableURLRequest* r = [NSMutableURLRequest requestWithURL:url];
  if (token) [r setValue:[@"Bearer " stringByAppendingString:token] forHTTPHeaderField:@"Authorization"];
  if (range) [r setValue:range forHTTPHeaderField:@"Range"];
  [[Session() dataTaskWithRequest:r
                completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
                  const NSInteger status =
                      [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse*)response).statusCode : 0;
                  if (error)
                    done(nil, error.localizedDescription, status);
                  else if (status && (status < 200 || status >= 300))
                    done(nil, [NSString stringWithFormat:@"%@ odpověděl %ld", url.host, (long)status], status);
                  else
                    done(data ?: [NSData data], nil, status);
                }] resume];
}

// The same, waiting for it (not on the main queue).
static NSData* FetchSync(NSURL* url, NSString* token, NSString** error, NSInteger* status) {
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  __block NSData* out = nil;
  __block NSString* why = nil;
  __block NSInteger code = 0;
  Fetch(url, token, ^(NSData* data, NSString* e, NSInteger s) {
    out = data;
    why = e;
    code = s;
    dispatch_semaphore_signal(sem);
  });
  dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
  if (error) *error = why;
  if (status) *status = code;
  return out;
}

// zlib data (GOG's chunks and manifests) inflated; EXPECT is its size if known, else 0.
static NSData* Inflate(NSData* in, size_t expect) {
  z_stream s = {0};
  if (inflateInit2(&s, 15 + 32) != Z_OK) return nil;  // zlib or gzip header
  NSMutableData* out = [NSMutableData dataWithLength:expect ? expect : MAX(in.length * 4, (NSUInteger)65536)];
  s.next_in = (Bytef*)in.bytes;
  s.avail_in = (uInt)in.length;
  int r;
  for (;;) {
    if (s.total_out >= out.length) [out setLength:out.length * 2];
    s.next_out = (Bytef*)out.mutableBytes + s.total_out;
    s.avail_out = (uInt)(out.length - s.total_out);
    r = inflate(&s, Z_NO_FLUSH);
    if (r == Z_STREAM_END) break;
    if (r == Z_OK || (r == Z_BUF_ERROR && s.avail_out == 0 && s.avail_in > 0)) continue;
    inflateEnd(&s);
    return nil;
  }
  [out setLength:s.total_out];
  inflateEnd(&s);
  return out;
}

// JSON that may be zlib-compressed (the content system's manifests are).
static id JSONMaybeZlib(NSData* data) {
  if (!data.length) return nil;
  id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (json) return json;
  NSData* plain = Inflate(data, 0);
  return plain ? [NSJSONSerialization JSONObjectWithData:plain options:0 error:nil] : nil;
}

static NSString* MD5Hex(NSData* data) {
  unsigned char d[CC_MD5_DIGEST_LENGTH];
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
  CC_MD5(data.bytes, (CC_LONG)data.length, d);  // GOG names chunks by MD5
#pragma clang diagnostic pop
  NSMutableString* hex = [NSMutableString stringWithCapacity:32];
  for (int i = 0; i < CC_MD5_DIGEST_LENGTH; i++) [hex appendFormat:@"%02x", d[i]];
  return hex;
}

// aa/bb/aabbcc...: where the content system keeps a hash's file.
static NSString* GalaxyPath(NSString* hash) {
  if (hash.length < 4) return hash;
  return [NSString stringWithFormat:@"%@/%@/%@", [hash substringToIndex:2], [hash substringWithRange:NSMakeRange(2, 2)], hash];
}

#pragma mark - The account's tokens

static NSString* TokenStore = @"none";

static NSDictionary* KeychainQuery(void) {
  return @{(id)kSecClass : (id)kSecClassGenericPassword, (id)kSecAttrService : @"WinPad GOG", (id)kSecAttrAccount : @"tokens"};
}

static NSDictionary* LoadTokens(void) {
  NSMutableDictionary* q = [KeychainQuery() mutableCopy];
  q[(id)kSecReturnData] = @YES;
  q[(id)kSecMatchLimit] = (id)kSecMatchLimitOne;
  CFTypeRef out = NULL;
  NSData* data = nil;
  if (SecItemCopyMatching((__bridge CFDictionaryRef)q, &out) == errSecSuccess) data = CFBridgingRelease(out);
#if TARGET_OS_SIMULATOR
  // A simulator app without a keychain entitlement may not have a keychain.
  if (!data) data = [NSUserDefaults.standardUserDefaults dataForKey:@"gogTokensSimulator"];
#endif
  id tokens = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
  return [tokens isKindOfClass:NSDictionary.class] && Str(tokens[@"access_token"]).length ? tokens : nil;
}

static BOOL SaveTokens(NSDictionary* tokens) {
  SecItemDelete((__bridge CFDictionaryRef)KeychainQuery());
#if TARGET_OS_SIMULATOR
  [NSUserDefaults.standardUserDefaults removeObjectForKey:@"gogTokensSimulator"];
#endif
  if (!tokens) return YES;
  NSData* data = [NSJSONSerialization dataWithJSONObject:tokens options:0 error:nil];
  NSMutableDictionary* add = [KeychainQuery() mutableCopy];
  add[(id)kSecValueData] = data;
  add[(id)kSecAttrAccessible] = (id)kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly;
  const OSStatus st = SecItemAdd((__bridge CFDictionaryRef)add, NULL);
  if (st == errSecSuccess) {
    TokenStore = @"keychain";
    return YES;
  }
  NSLog(@"WinPad GOG: Keychain said %d", (int)st);
#if TARGET_OS_SIMULATOR
  [NSUserDefaults.standardUserDefaults setObject:data forKey:@"gogTokensSimulator"];
  TokenStore = [NSString stringWithFormat:@"simulator settings (keychain %d)", (int)st];
  return YES;
#else
  return NO;
#endif
}

BOOL WinPadGOGSignedIn(void) {
  return LoadTokens() != nil;
}

void WinPadGOGSignOut(void) {
  SaveTokens(nil);
  // The login page's cookies too, so the next sign-in may be another account.
  WKWebsiteDataStore* store = WKWebsiteDataStore.defaultDataStore;
  [store fetchDataRecordsOfTypes:WKWebsiteDataStore.allWebsiteDataTypes
               completionHandler:^(NSArray<WKWebsiteDataRecord*>* records) {
                 NSMutableArray* gog = [NSMutableArray new];
                 for (WKWebsiteDataRecord* r in records)
                   if ([r.displayName.lowercaseString containsString:@"gog"]) [gog addObject:r];
                 [store removeDataOfTypes:WKWebsiteDataStore.allWebsiteDataTypes forDataRecords:gog completionHandler:^{}];
               }];
}

// auth.gog.com/token with QUERY: the new tokens saved, DONE (on the main queue) with the access token.
static void RequestTokens(NSString* query, void (^done)(NSString* token, NSString* error)) {
  NSURL* url = GOGURL(@"auth.gog.com", [@"/token?" stringByAppendingString:query]);
  Fetch(url, nil, ^(NSData* data, NSString* error, NSInteger status) {
    id j = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSString* access = [j isKindOfClass:NSDictionary.class] ? Str(j[@"access_token"]) : nil;
    NSString* why = error;
    if (access.length) {
      const double expires_in = [j[@"expires_in"] doubleValue];
      NSDictionary* tokens = @{
        @"access_token" : access,
        @"refresh_token" : Str(j[@"refresh_token"]) ?: @"",
        @"user_id" : Str(j[@"user_id"]) ?: @"",
        @"expires" : @(NSDate.date.timeIntervalSince1970 + (expires_in > 0 ? expires_in : 3600)),
      };
      if (!SaveTokens(tokens)) why = @"Přihlášení se nepodařilo uložit do klíčenky.";
    } else if (!why) {
      why = @"GOG nevrátil přihlašovací token.";
    }
    dispatch_async(dispatch_get_main_queue(), ^{
      done(why ? nil : access, why);
    });
  });
}

static void ExchangeCode(NSString* code, void (^done)(NSString* token, NSString* error)) {
  RequestTokens([NSString stringWithFormat:@"client_id=%@&client_secret=%@&grant_type=authorization_code&code=%@&redirect_uri=%@",
                                           ClientId, ClientSecret, Escaped(code), Escaped(RedirectURI)],
                done);
}

// A valid access token, refreshed when it is about to expire; DONE on the main queue. Calls
// made while one refresh runs wait for it (GOG hands out a new refresh token each time).
static void AccessToken(void (^done)(NSString* token, NSString* error)) {
  dispatch_async(dispatch_get_main_queue(), ^{
    static NSMutableArray* waiting;
    NSDictionary* tokens = LoadTokens();
    if (!tokens) {
      done(nil, @"Nejsi přihlášen ke GOG.");
      return;
    }
    if ([tokens[@"expires"] doubleValue] > NSDate.date.timeIntervalSince1970 + 120) {
      done(tokens[@"access_token"], nil);
      return;
    }
    if (waiting) {
      [waiting addObject:done];
      return;
    }
    waiting = [NSMutableArray arrayWithObject:done];
    RequestTokens([NSString stringWithFormat:@"client_id=%@&client_secret=%@&grant_type=refresh_token&refresh_token=%@", ClientId,
                                             ClientSecret, Escaped(Str(tokens[@"refresh_token"]) ?: @"")],
                  ^(NSString* token, NSString* error) {
                    NSArray* all = waiting;
                    waiting = nil;
                    NSString* why = error ? [@"Přihlášení ke GOG se nepodařilo obnovit (přihlas se znovu): " stringByAppendingString:error] : nil;
                    for (void (^d)(NSString*, NSString*) in all) d(token, why);
                  });
  });
}

static NSString* AccessTokenSync(NSString** error) {
  dispatch_semaphore_t sem = dispatch_semaphore_create(0);
  __block NSString* token = nil;
  __block NSString* why = nil;
  AccessToken(^(NSString* t, NSString* e) {
    token = t;
    why = e;
    dispatch_semaphore_signal(sem);
  });
  dispatch_semaphore_wait(sem, DISPATCH_TIME_FOREVER);
  if (error) *error = why;
  return token;
}

#pragma mark - The account's games

@implementation WinPadGOGProduct
@end

static void FetchPage(NSString* token, int page, NSMutableArray* games, void (^done)(NSArray* games, NSString* error)) {
  NSURL* url = GOGURL(@"embed.gog.com", [NSString stringWithFormat:@"/account/getFilteredProducts?mediaType=1&sortBy=title&page=%d", page]);
  Fetch(url, token, ^(NSData* data, NSString* error, NSInteger status) {
    id j = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (![j isKindOfClass:NSDictionary.class]) {
      done(nil, error ?: @"GOG poslal seznam her, kterému nerozumím.");
      return;
    }
    for (NSDictionary* p in j[@"products"]) {
      if (![p isKindOfClass:NSDictionary.class]) continue;
      NSDictionary* works = [p[@"worksOn"] isKindOfClass:NSDictionary.class] ? p[@"worksOn"] : nil;
      if (works && ![works[@"Windows"] boolValue]) continue;
      WinPadGOGProduct* game = [WinPadGOGProduct new];
      game.productId = [p[@"id"] longLongValue];
      game.title = Str(p[@"title"]) ?: [NSString stringWithFormat:@"%lld", game.productId];
      NSString* image = Str(p[@"image"]);
      if (image.length) {
        if ([image hasPrefix:@"//"]) image = [@"https:" stringByAppendingString:image];
        if (![image.pathExtension length]) image = [image stringByAppendingString:@"_196.jpg"];
        game.imageURL = [NSURL URLWithString:image];
      }
      if (game.productId > 0) [games addObject:game];
    }
    const int pages = [j[@"totalPages"] intValue];
    if (page < pages && page < 100)
      FetchPage(token, page + 1, games, done);
    else
      done(games, nil);
  });
}

void WinPadGOGOwnedGames(void (^done)(NSArray<WinPadGOGProduct*>* games, NSString* error)) {
  AccessToken(^(NSString* token, NSString* error) {
    if (!token) {
      done(nil, error);
      return;
    }
    FetchPage(token, 1, [NSMutableArray new], ^(NSArray* games, NSString* why) {
      NSArray* sorted = [games sortedArrayUsingComparator:^NSComparisonResult(WinPadGOGProduct* a, WinPadGOGProduct* b) {
        return [a.title localizedCaseInsensitiveCompare:b.title];
      }];
      dispatch_async(dispatch_get_main_queue(), ^{
        done(why ? nil : sorted, why);
      });
    });
  });
}

NSString* WinPadGOGInstalledFolder(long long productId) {
  NSFileManager* fm = NSFileManager.defaultManager;
  NSString* docs = Documents();
  NSString* info = [NSString stringWithFormat:@"goggame-%lld.info", productId];
  for (NSString* folder in [fm contentsOfDirectoryAtPath:docs error:nil]) {
    if ([folder hasPrefix:@"."]) continue;
    NSString* dir = [docs stringByAppendingPathComponent:folder];
    NSData* ours = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@".winpad-gog.json"]];
    id j = ours ? [NSJSONSerialization JSONObjectWithData:ours options:0 error:nil] : nil;
    if ([j isKindOfClass:NSDictionary.class] && [j[@"productId"] longLongValue] == productId) return folder;
    for (NSString* name in [fm contentsOfDirectoryAtPath:dir error:nil])
      if ([name caseInsensitiveCompare:info] == NSOrderedSame) return folder;
  }
  return nil;
}

#pragma mark - Installing a game

// A file of the game: its chunks, or a range of a depot's container of small files.
@interface GOGFile : NSObject
@property(nonatomic, copy) NSString* path;  // relative to the game's folder, "/" between folders
@property(nonatomic) long long size;
@property(nonatomic) long long productId;  // whose secure link its chunks come by
@property(nonatomic, copy) NSArray<NSDictionary*>* chunks;  // md5, size, compressedMd5, compressedSize
@property(nonatomic, strong) GOGFile* container;            // with sfcRef: the depot's container
@property(nonatomic) long long sfcOffset;
@property(nonatomic) BOOL isContainer;
// Generation 1: its bytes are a range of RANGENAME (main.bin) in the build's depot; its MD5.
@property(nonatomic, copy) NSString* rangeName;
@property(nonatomic, copy) NSString* md5;
@property(nonatomic) NSInteger pending;  // chunks not yet written
@property(nonatomic) int fd;
@end

@implementation GOGFile
- (instancetype)init {
  if ((self = [super init])) _fd = -1;
  return self;
}
@end

// A chunk to fetch: its file, where in it.
@interface GOGJob : NSObject
@property(nonatomic, strong) GOGFile* file;
@property(nonatomic, copy) NSDictionary* chunk;
@property(nonatomic) long long offset;
@end

@implementation GOGJob
@end

@interface WinPadGOGInstall ()
@property(nonatomic, readwrite) WinPadGOGProduct* product;
@property(nonatomic, readwrite) WinPadGOGState state;
@property(nonatomic, readwrite, copy) NSString* error;
@property(nonatomic, readwrite, copy) NSString* folder;
@property(nonatomic, readwrite, copy) NSString* language;
@property(nonatomic, readwrite) long long installSize;
@property(nonatomic, readwrite) long long downloadSize;
@property(nonatomic, readwrite) long long downloaded;
@property(nonatomic, readwrite) NSInteger fileCount;
@property(nonatomic, strong) dispatch_queue_t q;  // everything below
@property(nonatomic, copy) NSString* token;
@property(nonatomic, copy) NSString* buildId;
@property(nonatomic) int generation;           // 2 (Galaxy's chunks) or 1 (ranges of main.bin)
@property(nonatomic, copy) NSString* legacyBuildId;  // generation 1's build, in its paths
@property(nonatomic, copy) NSString* staging;
@property(nonatomic, strong) NSArray<GOGFile*>* files;
@property(nonatomic, strong) NSArray<NSString*>* directories;
@property(nonatomic, strong) NSDictionary<NSString*, NSString*>* links;  // path -> target
@property(nonatomic, strong) NSMutableDictionary<NSNumber*, NSArray<NSDictionary*>*>* endpoints;  // productId -> secure links
@property(nonatomic, strong) NSMutableSet<NSString*>* done;
@property(nonatomic, strong) NSMutableArray<GOGJob*>* jobs;
@property(nonatomic) NSUInteger next;
@property(nonatomic) NSInteger inFlight;
@property(nonatomic) BOOL stopping;
@property(nonatomic) BOOL cancelled;
@property(nonatomic) BOOL startWhenPlanned;
@property(nonatomic) NSTimeInterval lastNotified, lastSaved, linksFetched;
@property(nonatomic) UIBackgroundTaskIdentifier background;
@end

static NSMutableDictionary<NSNumber*, WinPadGOGInstall*>* Installs(void) {
  static NSMutableDictionary* installs;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    installs = [NSMutableDictionary new];
  });
  return installs;
}

// A depot's path made safe: "/" between folders, nothing that leaves the game's folder.
static NSString* SafePath(NSString* path) {
  NSMutableArray* parts = [NSMutableArray new];
  for (NSString* p in [[path stringByReplacingOccurrencesOfString:@"\\" withString:@"/"] componentsSeparatedByString:@"/"]) {
    if (!p.length || [p isEqualToString:@"."]) continue;
    if ([p isEqualToString:@".."]) return nil;
    [parts addObject:p];
  }
  return parts.count ? [parts componentsJoinedByString:@"/"] : nil;
}

// The folder name a game gets in Documents: GOG's installDirectory, as a folder name.
static NSString* FolderName(NSString* name, NSString* fallback) {
  NSString* n = [[name ?: @"" componentsSeparatedByCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"/\\:*?\"<>|"]]
      componentsJoinedByString:@" "];
  n = [n stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@" ."]];
  if (!n.length && fallback) return FolderName(fallback, nil);
  return n.length ? n : @"GOG Game";
}

// The language of the depots: the iPad's first language GOG has, else English, else the first.
static NSString* PickLanguage(NSOrderedSet<NSString*>* languages) {
  NSDictionary* names = @{
    @"cs" : @"czech", @"en" : @"english", @"de" : @"german", @"fr" : @"french", @"es" : @"spanish", @"pl" : @"polish",
    @"ru" : @"russian", @"it" : @"italian", @"pt" : @"portuguese", @"sk" : @"slovak", @"hu" : @"hungarian"
  };
  NSMutableArray* wanted = [NSMutableArray new];
  for (NSString* l in NSLocale.preferredLanguages) [wanted addObject:[l componentsSeparatedByString:@"-"].firstObject.lowercaseString];
  [wanted addObject:@"en"];
  for (NSString* code in wanted)
    for (NSString* l in languages) {
      NSString* lower = l.lowercaseString;
      if ([lower isEqualToString:code] || [lower hasPrefix:[code stringByAppendingString:@"-"]] ||
          (names[code] && [lower isEqualToString:names[code]]))
        return l;
    }
  return languages.firstObject;
}

static BOOL DepotHasLanguage(NSDictionary* depot, NSString* language) {
  NSArray* langs = [depot[@"languages"] isKindOfClass:NSArray.class] ? depot[@"languages"] : @[];
  if (!langs.count) return YES;
  for (id l in langs)
    if ([l isKindOfClass:NSString.class] && ([l isEqualToString:@"*"] || [l caseInsensitiveCompare:@"Neutral"] == NSOrderedSame || (language && [l caseInsensitiveCompare:language] == NSOrderedSame)))
      return YES;
  return NO;
}

@implementation WinPadGOGInstall

+ (instancetype)existingFor:(long long)productId {
  return Installs()[@(productId)];
}

+ (instancetype)installFor:(WinPadGOGProduct*)product {
  WinPadGOGInstall* install = Installs()[@(product.productId)];
  if (install) return install;
  install = [WinPadGOGInstall new];
  install.product = product;
  install.q = dispatch_queue_create("winpad.gog.install", DISPATCH_QUEUE_SERIAL);
  install.background = UIBackgroundTaskInvalid;
  install.staging = [Documents() stringByAppendingPathComponent:[NSString stringWithFormat:@".gog/%lld", product.productId]];
  Installs()[@(product.productId)] = install;
  [install plan];
  return install;
}

// STATE (and ERROR) set, said on the main queue; FORCE says it now, else at most 4 times a second.
- (void)setState:(WinPadGOGState)state error:(NSString*)error {
  self.state = state;
  if (error) self.error = error;
  [self notify:YES];
}

- (void)notify:(BOOL)force {
  const NSTimeInterval now = NSDate.timeIntervalSinceReferenceDate;
  if (!force && now - self.lastNotified < 0.25) return;
  self.lastNotified = now;
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.changed) self.changed(self);
  });
}

- (void)fail:(NSString*)why {
  NSLog(@"WinPad GOG: %@: %@", self.product.title, why);
  [self setState:WinPadGOGFailed error:why];
  [self endBackground];
}

- (void)plan {
  self.error = nil;
  [self setState:WinPadGOGPlanning error:nil];
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    NSString* why = [self planSync];
    dispatch_async(self.q, ^{
      if (self.state == WinPadGOGCancelled) return;
      if (why) {
        [self fail:why];
        return;
      }
      if (self.startWhenPlanned) {
        self.startWhenPlanned = NO;
        [self download];
      } else {
        [self setState:WinPadGOGPlanned error:nil];
      }
    });
  });
}

// The secure links (CDN addresses with a token) for PRODUCT's chunks, best first, or nil.
- (NSArray*)secureLinksFor:(long long)product error:(NSString**)error {
  NSURL* url = GOGURL(@"content-system.gog.com",
                      self.generation == 1
                          ? [NSString stringWithFormat:@"/products/%lld/secure_link?_version=2&type=depot&path=/windows/%@", product,
                                                       self.legacyBuildId ?: @""]
                          : [NSString stringWithFormat:@"/products/%lld/secure_link?_version=2&generation=2&path=/", product]);
  NSData* data = FetchSync(url, self.token, error, NULL);
  id j = JSONMaybeZlib(data);
  NSMutableArray* urls = [NSMutableArray new];
  for (NSDictionary* u in [j isKindOfClass:NSDictionary.class] ? j[@"urls"] : nil)
    if ([u isKindOfClass:NSDictionary.class] && Str(u[@"url_format"]) && [u[@"parameters"] isKindOfClass:NSDictionary.class])
      [urls addObject:u];
  [urls sortUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
    return [b[@"priority"] compare:a[@"priority"] ?: @0] ?: NSOrderedSame;
  }];
  if (!urls.count && error && !*error) *error = @"GOG nedal adresu ke stažení (vlastníš tu hru?).";
  return urls.count ? urls : nil;
}

// Reads the build's manifests: what is to be downloaded. Nil when done, else why not.
- (NSString*)planSync {
  NSString* why = nil;
  NSString* token = AccessTokenSync(&why);
  if (!token) return why;
  self.token = token;
  const long long pid = self.product.productId;

  // The newest public build of generation 2 (GOG Galaxy's format).
  NSURL* builds_url = GOGURL(@"content-system.gog.com", [NSString stringWithFormat:@"/products/%lld/os/windows/builds?generation=2", pid]);
  id builds = JSONMaybeZlib(FetchSync(builds_url, token, &why, NULL));
  if (![builds isKindOfClass:NSDictionary.class]) return why ?: @"GOG neposlal seznam verzí hry.";
  // The newest public build of generation 2, else of generation 1 (older games GOG never
  // repacked for Galaxy: whole files in one main.bin per build).
  NSDictionary* build = nil;
  NSDictionary* old = nil;
  for (NSDictionary* b in builds[@"items"]) {
    if (![b isKindOfClass:NSDictionary.class]) continue;
    const id branch = b[@"branch"];
    if (branch && branch != NSNull.null) continue;
    const int gen = [b[@"generation"] intValue];
    if (gen == 2) {
      build = b;
      break;
    }
    if (gen == 1 && !old) old = b;
  }
  if (!build && !old) {
    id builds1 = JSONMaybeZlib(FetchSync(
        GOGURL(@"content-system.gog.com", [NSString stringWithFormat:@"/products/%lld/os/windows/builds?generation=1", pid]), token, NULL, NULL));
    for (NSDictionary* b in [builds1 isKindOfClass:NSDictionary.class] ? builds1[@"items"] : nil)
      if ([b isKindOfClass:NSDictionary.class] && (!b[@"branch"] || b[@"branch"] == NSNull.null)) {
        old = b;
        break;
      }
  }
  if (!build && !old) return @"GOG pro tuhle hru nemá verzi pro Windows ke stažení.";

  // The DLCs the account owns (their depots are in the base game's manifest).
  NSMutableSet<NSNumber*>* owned = [NSMutableSet setWithObject:@(pid)];
  id user = JSONMaybeZlib(FetchSync(GOGURL(@"embed.gog.com", @"/user/data/games"), token, NULL, NULL));
  for (id o in [user isKindOfClass:NSDictionary.class] ? user[@"owned"] : nil)
    if ([o respondsToSelector:@selector(longLongValue)]) [owned addObject:@([o longLongValue])];
  if (!build) return [self planV1:old owned:owned];

  self.generation = 2;
  self.buildId = Str(build[@"build_id"]) ?: @"";
  id manifest = JSONMaybeZlib(FetchSync([NSURL URLWithString:Str(build[@"link"]) ?: @""], nil, &why, NULL));
  if (![manifest isKindOfClass:NSDictionary.class]) return why ?: @"Manifest hry od GOG je poškozený.";
  const long long base = [manifest[@"baseProductId"] longLongValue] ?: pid;
  [owned addObject:@(base)];
  self.folder = FolderName(Str(manifest[@"installDirectory"]), self.product.title);

  NSArray* depots = [manifest[@"depots"] isKindOfClass:NSArray.class] ? manifest[@"depots"] : @[];
  NSMutableOrderedSet* languages = [NSMutableOrderedSet new];
  BOOL has32 = NO;
  for (NSDictionary* d in depots) {
    if (![d isKindOfClass:NSDictionary.class]) continue;
    for (id l in [d[@"languages"] isKindOfClass:NSArray.class] ? d[@"languages"] : @[])
      if ([l isKindOfClass:NSString.class] && ![l isEqualToString:@"*"]) [languages addObject:l];
    if ([d[@"osBitness"] isKindOfClass:NSArray.class] && [d[@"osBitness"] containsObject:@"32"]) has32 = YES;
  }
  self.language = PickLanguage(languages);

  // Each depot's files, the later depot's file over an earlier one's of the same path.
  NSMutableDictionary<NSString*, GOGFile*>* files = [NSMutableDictionary new];
  NSMutableArray<GOGFile*>* order = [NSMutableArray new];
  NSMutableOrderedSet<NSString*>* dirs = [NSMutableOrderedSet new];
  NSMutableDictionary* links = [NSMutableDictionary new];
  NSMutableSet<NSNumber*>* products = [NSMutableSet new];
  int containers = 0;
  for (NSDictionary* d in depots) {
    if (![d isKindOfClass:NSDictionary.class]) continue;
    const long long depot_product = [d[@"productId"] longLongValue] ?: base;
    if (![owned containsObject:@(depot_product)]) continue;
    if (!DepotHasLanguage(d, self.language)) continue;
    NSArray* bits = [d[@"osBitness"] isKindOfClass:NSArray.class] ? d[@"osBitness"] : nil;
    if (has32 && bits.count && ![bits containsObject:@"32"]) continue;  // the 64-bit one of two
    NSString* hash = Str(d[@"manifest"]);
    if (!hash.length) continue;
    NSURL* meta_url = GOGURL(@"gog-cdn-fastly.gog.com", [@"/content-system/v2/meta/" stringByAppendingString:GalaxyPath(hash)]);
    id meta = JSONMaybeZlib(FetchSync(meta_url, nil, &why, NULL));
    NSDictionary* depot = [meta isKindOfClass:NSDictionary.class] && [meta[@"depot"] isKindOfClass:NSDictionary.class] ? meta[@"depot"] : nil;
    if (!depot) return why ?: @"Seznam souborů hry od GOG je poškozený.";
    GOGFile* container = nil;
    NSDictionary* sfc = [depot[@"smallFilesContainer"] isKindOfClass:NSDictionary.class] ? depot[@"smallFilesContainer"] : nil;
    if ([sfc[@"chunks"] isKindOfClass:NSArray.class]) {
      container = [GOGFile new];
      container.path = [NSString stringWithFormat:@".winpad-sfc-%d", containers++];
      container.chunks = sfc[@"chunks"];
      container.productId = depot_product;
      container.isContainer = YES;
      for (NSDictionary* c in container.chunks) container.size += [c[@"size"] longLongValue];
      [order addObject:container];
    }
    for (NSDictionary* item in [depot[@"items"] isKindOfClass:NSArray.class] ? depot[@"items"] : @[]) {
      if (![item isKindOfClass:NSDictionary.class]) continue;
      NSString* path = SafePath(Str(item[@"path"]) ?: @"");
      if (!path) continue;
      NSString* type = Str(item[@"type"]);
      if ([type isEqualToString:@"DepotDirectory"]) {
        [dirs addObject:path];
        continue;
      }
      if ([type isEqualToString:@"DepotLink"]) {
        NSString* target = SafePath(Str(item[@"target"]) ?: @"");
        if (target) links[path] = target;
        continue;
      }
      // Galaxy's support files (redistributables' installers, its scripts) stay out.
      if ([item[@"flags"] isKindOfClass:NSArray.class] && [item[@"flags"] containsObject:@"support"]) continue;
      GOGFile* f = [GOGFile new];
      f.path = path;
      f.productId = depot_product;
      f.chunks = [item[@"chunks"] isKindOfClass:NSArray.class] ? item[@"chunks"] : @[];
      for (NSDictionary* c in f.chunks) f.size += [c[@"size"] longLongValue];
      NSDictionary* ref = [item[@"sfcRef"] isKindOfClass:NSDictionary.class] ? item[@"sfcRef"] : nil;
      if (ref && container) {
        f.container = container;
        f.sfcOffset = [ref[@"offset"] longLongValue];
        f.size = [ref[@"size"] longLongValue];
        f.chunks = @[];
      }
      NSString* key = path.lowercaseString;
      if (files[key]) [order removeObjectIdenticalTo:files[key]];
      files[key] = f;
      [order addObject:f];
    }
    [products addObject:@(depot_product)];
  }
  if (!files.count) return @"V téhle hře GOG nenabízí žádné soubory pro Windows ve tvém jazyce.";
  return [self use:order directories:dirs.array links:links products:products];
}

// Generation 1: the build's repository.json lists depots, a depot's manifest lists files, each
// a range of the build's main.bin (fetched in parts, the file checked by its MD5 at the end).
- (NSString*)planV1:(NSDictionary*)build owned:(NSMutableSet<NSNumber*>*)owned {
  NSString* why = nil;
  const long long pid = self.product.productId;
  self.generation = 1;
  self.legacyBuildId = Str(build[@"legacy_build_id"]) ?: Str(build[@"build_id"]) ?: @"";
  self.buildId = [@"v1-" stringByAppendingString:self.legacyBuildId];
  NSString* link = Str(build[@"link"]);
  NSURL* repo_url = link.length ? [NSURL URLWithString:link]
                                : GOGURL(@"cdn.gog.com", [NSString stringWithFormat:@"/content-system/v1/manifests/%lld/windows/%@/repository.json",
                                                                                    pid, self.legacyBuildId]);
  id repo = JSONMaybeZlib(FetchSync(repo_url, nil, &why, NULL));
  NSDictionary* product = [repo isKindOfClass:NSDictionary.class] && [repo[@"product"] isKindOfClass:NSDictionary.class] ? repo[@"product"] : nil;
  if (!product) return why ?: @"Manifest hry od GOG (generace 1) je poškozený.";
  const long long base = [product[@"rootGameID"] longLongValue] ?: pid;
  [owned addObject:@(base)];
  self.folder = FolderName(Str(product[@"installDirectory"]), self.product.title);
  NSArray* depots = [product[@"depots"] isKindOfClass:NSArray.class] ? product[@"depots"] : @[];
  NSMutableOrderedSet* languages = [NSMutableOrderedSet new];
  for (NSDictionary* d in depots) {
    if (![d isKindOfClass:NSDictionary.class] || d[@"redist"]) continue;
    for (id l in [d[@"languages"] isKindOfClass:NSArray.class] ? d[@"languages"] : @[])
      if ([l isKindOfClass:NSString.class] && ![l isEqualToString:@"*"] && [l caseInsensitiveCompare:@"Neutral"] != NSOrderedSame)
        [languages addObject:l];
  }
  self.language = PickLanguage(languages);
  const long long part = MAX(1024LL, [[NSUserDefaults.standardUserDefaults objectForKey:@"gogV1Part"] longLongValue] ?: 4LL * 1024 * 1024);

  NSMutableDictionary<NSString*, GOGFile*>* files = [NSMutableDictionary new];
  NSMutableArray<GOGFile*>* order = [NSMutableArray new];
  NSMutableOrderedSet<NSString*>* dirs = [NSMutableOrderedSet new];
  NSMutableSet<NSNumber*>* products = [NSMutableSet new];
  NSURL* dir = repo_url.URLByDeletingLastPathComponent;
  for (NSDictionary* d in depots) {
    if (![d isKindOfClass:NSDictionary.class] || d[@"redist"]) continue;  // redistributables' installers
    NSArray* systems = [d[@"systems"] isKindOfClass:NSArray.class] ? d[@"systems"] : nil;
    if (systems.count && ![systems containsObject:@"Windows"]) continue;
    if (!DepotHasLanguage(d, self.language)) continue;
    long long depot_product = 0;
    for (id g in [d[@"gameIDs"] isKindOfClass:NSArray.class] ? d[@"gameIDs"] : @[ @(base) ])
      if ([g respondsToSelector:@selector(longLongValue)] && [owned containsObject:@([g longLongValue])]) {
        depot_product = [g longLongValue];
        break;
      }
    if (!depot_product) continue;
    NSString* name = Str(d[@"manifest"]);
    if (!name.length || [name containsString:@"/"]) continue;
    id meta = JSONMaybeZlib(FetchSync([dir URLByAppendingPathComponent:name], nil, &why, NULL));
    NSDictionary* depot = [meta isKindOfClass:NSDictionary.class] && [meta[@"depot"] isKindOfClass:NSDictionary.class] ? meta[@"depot"] : nil;
    if (!depot) return why ?: @"Seznam souborů hry od GOG (generace 1) je poškozený.";
    for (NSDictionary* item in [depot[@"files"] isKindOfClass:NSArray.class] ? depot[@"files"] : @[]) {
      if (![item isKindOfClass:NSDictionary.class]) continue;
      NSString* path = SafePath(Str(item[@"path"]) ?: @"");
      if (!path) continue;
      if ([item[@"directory"] boolValue]) {
        [dirs addObject:path];
        continue;
      }
      if ([item[@"support"] boolValue]) continue;
      GOGFile* f = [GOGFile new];
      f.path = path;
      f.size = [item[@"size"] longLongValue];
      f.md5 = Str(item[@"hash"]);
      // "url": "PRODUCT/main.bin", whose secure link the range comes by.
      NSArray* url_parts = [Str(item[@"url"]) ?: @"" componentsSeparatedByString:@"/"];
      f.productId = url_parts.count > 1 && [url_parts.firstObject longLongValue] > 0 ? [url_parts.firstObject longLongValue] : depot_product;
      f.rangeName = url_parts.count && [url_parts.lastObject length] ? url_parts.lastObject : @"main.bin";
      const long long offset = [item[@"offset"] longLongValue];
      NSMutableArray* parts = [NSMutableArray new];
      for (long long at = 0; at < f.size; at += part) {
        const long long n = MIN(part, f.size - at);
        [parts addObject:@{@"range" : @(offset + at), @"size" : @(n), @"compressedSize" : @(n)}];
      }
      f.chunks = parts;
      NSString* key = path.lowercaseString;
      if (files[key]) [order removeObjectIdenticalTo:files[key]];
      files[key] = f;
      [order addObject:f];
      [products addObject:@(f.productId)];
    }
  }
  if (!files.count) return @"V téhle hře GOG nenabízí žádné soubory pro Windows ve tvém jazyce.";
  return [self use:order directories:dirs.array links:@{} products:products];
}

// The plan: secure links for each product, the sizes.
- (NSString*)use:(NSArray<GOGFile*>*)order
     directories:(NSArray<NSString*>*)dirs
           links:(NSDictionary*)links
        products:(NSSet<NSNumber*>*)products {
  NSString* why = nil;
  self.endpoints = [NSMutableDictionary new];
  for (NSNumber* p in products) {
    NSArray* urls = [self secureLinksFor:p.longLongValue error:&why];
    if (!urls) return why;
    self.endpoints[p] = urls;
  }
  self.linksFetched = NSDate.timeIntervalSinceReferenceDate;

  dispatch_sync(self.q, ^{
    self.files = order;
    self.directories = dirs;
    self.links = links;
    long long install = 0, download = 0;
    NSInteger count = 0;
    for (GOGFile* f in order) {
      if (!f.isContainer) {
        install += f.size;
        count++;
      }
      for (NSDictionary* c in f.chunks) download += [c[@"compressedSize"] longLongValue];
    }
    self.installSize = install;
    self.downloadSize = download;
    self.fileCount = count;
  });
  return nil;
}

- (void)start {
  dispatch_async(self.q, ^{
    switch (self.state) {
      case WinPadGOGPlanning:
        self.startWhenPlanned = YES;
        break;
      case WinPadGOGPlanned:
        [self download];
        break;
      case WinPadGOGFailed:
      case WinPadGOGCancelled:
        // Fresh tokens and secure links; the files already there stay.
        self.startWhenPlanned = YES;
        [self plan];
        break;
      default:
        break;
    }
  });
}

- (void)cancel {
  dispatch_async(self.q, ^{
    if (self.state == WinPadGOGDownloading) {
      self.cancelled = YES;
      self.stopping = YES;
      [self pump];
    } else if (self.state == WinPadGOGPlanned || self.state == WinPadGOGPlanning) {
      self.startWhenPlanned = NO;
      [Installs() removeObjectForKey:@(self.product.productId)];
      [self setState:WinPadGOGCancelled error:nil];
    }
  });
}

- (NSString*)statePath {
  return [self.staging stringByAppendingPathComponent:@".winpad-gog-state.json"];
}

- (void)saveState {
  NSDictionary* s = @{@"build" : self.buildId ?: @"", @"done" : self.done.allObjects};
  [[NSJSONSerialization dataWithJSONObject:s options:0 error:nil] writeToFile:[self statePath] atomically:YES];
  self.lastSaved = NSDate.timeIntervalSinceReferenceDate;
}

- (void)beginBackground {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (self.background == UIBackgroundTaskInvalid)
      self.background = [UIApplication.sharedApplication beginBackgroundTaskWithName:@"GOG"
                                                                   expirationHandler:^{
                                                                     [self endBackground];
                                                                   }];
    UIApplication.sharedApplication.idleTimerDisabled = YES;  // a sleeping iPad stops the download
  });
}

- (void)endBackground {
  dispatch_async(dispatch_get_main_queue(), ^{
    BOOL any = NO;
    for (WinPadGOGInstall* i in Installs().allValues)
      if (i != self && i.state == WinPadGOGDownloading) any = YES;
    if (!any) UIApplication.sharedApplication.idleTimerDisabled = NO;
    if (self.background != UIBackgroundTaskInvalid) [UIApplication.sharedApplication endBackgroundTask:self.background];
    self.background = UIBackgroundTaskInvalid;
  });
}

// On q: the files not yet there into jobs, then fetched.
- (void)download {
  NSFileManager* fm = NSFileManager.defaultManager;
  [fm createDirectoryAtPath:self.staging withIntermediateDirectories:YES attributes:nil error:nil];
  // What an earlier, stopped run of the same build left.
  self.done = [NSMutableSet new];
  NSData* saved = [NSData dataWithContentsOfFile:[self statePath]];
  id s = saved ? [NSJSONSerialization JSONObjectWithData:saved options:0 error:nil] : nil;
  if ([s isKindOfClass:NSDictionary.class] && [Str(s[@"build"]) isEqualToString:self.buildId])
    for (id p in s[@"done"])
      if ([p isKindOfClass:NSString.class]) [self.done addObject:p];

  self.jobs = [NSMutableArray new];
  self.next = 0;
  self.inFlight = 0;
  self.stopping = NO;
  self.cancelled = NO;
  self.error = nil;
  long long have = 0, need = 0;
  for (GOGFile* f in self.files) {
    long long compressed = 0;
    for (NSDictionary* c in f.chunks) compressed += [c[@"compressedSize"] longLongValue];
    NSString* full = [self.staging stringByAppendingPathComponent:f.path];
    NSDictionary* attrs = [fm attributesOfItemAtPath:full error:nil];
    if ([self.done containsObject:f.path] && attrs && attrs.fileSize == (unsigned long long)f.size) {
      have += compressed;
      continue;
    }
    [self.done removeObject:f.path];
    if (!f.isContainer) need += f.size;
    if (f.container) continue;  // out of its container at the end
    [fm createDirectoryAtPath:[full stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    if (!f.chunks.count) {
      [fm removeItemAtPath:full error:nil];
      [fm createFileAtPath:full contents:[NSData data] attributes:nil];
      [self.done addObject:f.path];
      continue;
    }
    f.pending = f.chunks.count;
    f.fd = -1;
    long long offset = 0;
    for (NSDictionary* c in f.chunks) {
      GOGJob* job = [GOGJob new];
      job.file = f;
      job.chunk = c;
      job.offset = offset;
      offset += [c[@"size"] longLongValue];
      [self.jobs addObject:job];
    }
    need += compressed;  // the container's chunks, and room while it is unpacked
  }
  self.downloaded = have;
  NSDictionary* fs = [[NSURL fileURLWithPath:Documents()] resourceValuesForKeys:@[ NSURLVolumeAvailableCapacityForImportantUsageKey ]
                                                                         error:nil];
  NSNumber* free_bytes = fs[NSURLVolumeAvailableCapacityForImportantUsageKey];
  if (free_bytes && free_bytes.longLongValue < need + 200LL * 1024 * 1024) {
    NSByteCountFormatter* f = [NSByteCountFormatter new];
    [self fail:[NSString stringWithFormat:@"Na iPadu není dost místa: hra potřebuje ještě %@, volné je %@.",
                                          [f stringFromByteCount:need], [f stringFromByteCount:free_bytes.longLongValue]]];
    return;
  }
  [self beginBackground];
  [self setState:WinPadGOGDownloading error:nil];
  [self pump];
}

- (NSURL*)urlFor:(GOGJob*)job endpoint:(NSUInteger)n {
  NSArray* urls = self.endpoints[@(job.file.productId)];
  if (!urls.count) return nil;
  NSDictionary* e = urls[n % urls.count];
  NSMutableDictionary* params = [e[@"parameters"] mutableCopy];
  NSString* path = Str(params[@"path"]) ?: @"";
  while ([path hasSuffix:@"/"]) path = [path substringToIndex:path.length - 1];
  params[@"path"] = job.file.rangeName ? [NSString stringWithFormat:@"%@/%@", path, job.file.rangeName]
                                       : [NSString stringWithFormat:@"%@/%@", path, GalaxyPath(Str(job.chunk[@"compressedMd5"]) ?: @"")];
  NSMutableString* url = [Str(e[@"url_format"]) mutableCopy];
  for (NSString* key in params) {
    NSString* value = Str(params[key]);
    if (value) [url replaceOccurrencesOfString:[NSString stringWithFormat:@"{%@}", key] withString:value options:0 range:NSMakeRange(0, url.length)];
  }
  return [NSURL URLWithString:url];
}

// On q: as many chunks in flight as there may be; the end once none are left.
- (void)pump {
  while (!self.stopping && self.inFlight < 6 && self.next < self.jobs.count) {
    GOGJob* job = self.jobs[self.next++];
    GOGFile* f = job.file;
    if (f.fd < 0) {
      NSString* part = [[self.staging stringByAppendingPathComponent:f.path] stringByAppendingString:@".winpad-part"];
      f.fd = open(part.fileSystemRepresentation, O_RDWR | O_CREAT | O_TRUNC, 0644);
      if (f.fd < 0 || ftruncate(f.fd, f.size) != 0) {
        [self stopWith:[NSString stringWithFormat:@"Soubor %@ nejde zapsat (%s).", f.path, strerror(errno)]];
        break;
      }
    }
    self.inFlight++;
    [self fetch:job attempt:0];
  }
  if (self.inFlight) return;
  if (self.stopping) {
    for (GOGFile* f in self.files)
      if (f.fd >= 0 && f.pending) {
        close(f.fd);
        f.fd = -1;
      }
    [self saveState];
    if (self.cancelled) {
      [Installs() removeObjectForKey:@(self.product.productId)];
      [self setState:WinPadGOGCancelled error:nil];
      [self endBackground];
    } else {
      [self fail:self.error ?: @"Stahování se zastavilo."];
    }
    return;
  }
  if (self.next >= self.jobs.count) [self finish];
}

- (void)stopWith:(NSString*)why {
  if (!self.stopping) self.error = why;
  self.stopping = YES;
}

- (void)fetch:(GOGJob*)job attempt:(int)attempt {
  NSURL* url = [self urlFor:job endpoint:(NSUInteger)attempt];
  NSNumber* range = job.chunk[@"range"];
  const long long range_size = [job.chunk[@"size"] longLongValue];
  NSString* header = range ? [NSString stringWithFormat:@"bytes=%lld-%lld", range.longLongValue, range.longLongValue + range_size - 1] : nil;
  FetchRange(url, nil, header, ^(NSData* data, NSString* error, NSInteger status) {
    // Inflating and checking off the install's queue; writing on it.
    NSString* why = error;
    NSData* plain = nil;
    if (data && range) {
      // A server that ignores Range sends the whole main.bin.
      if (status == 200 && (long long)data.length >= range.longLongValue + range_size && (long long)data.length != range_size)
        data = [data subdataWithRange:NSMakeRange((NSUInteger)range.longLongValue, (NSUInteger)range_size)];
      if ((long long)data.length == range_size)
        plain = data;
      else
        why = [NSString stringWithFormat:@"server poslal %lu bajtů místo %lld", (unsigned long)data.length, range_size];
    } else if (data) {
      NSString* zmd5 = Str(job.chunk[@"compressedMd5"]);
      const long long size = [job.chunk[@"size"] longLongValue];
      if (zmd5.length && ![MD5Hex(data) isEqualToString:zmd5.lowercaseString])
        why = @"poškozený blok";
      else if (!(plain = Inflate(data, (size_t)size)) || (long long)plain.length != size)
        why = @"blok nejde rozbalit";
      else if (Str(job.chunk[@"md5"]).length && ![MD5Hex(plain) isEqualToString:Str(job.chunk[@"md5"]).lowercaseString])
        why = @"rozbalený blok nesedí";
    }
    dispatch_async(self.q, ^{
      if (why) {
        if (self.stopping || attempt >= 5) {
          self.inFlight--;
          [self stopWith:[NSString stringWithFormat:@"Stahování %@ se nepodařilo: %@.", job.file.path, why]];
          [self pump];
          return;
        }
        // Secure links last a few hours: new ones once one is refused, then again.
        if ((status == 401 || status == 403) && NSDate.timeIntervalSinceReferenceDate - self.linksFetched > 60) {
          self.linksFetched = NSDate.timeIntervalSinceReferenceDate;
          dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSString* e = nil;
            self.token = AccessTokenSync(&e) ?: self.token;
            NSArray* urls = [self secureLinksFor:job.file.productId error:&e];
            dispatch_async(self.q, ^{
              if (urls) self.endpoints[@(job.file.productId)] = urls;
              [self fetch:job attempt:attempt + 1];
            });
          });
          return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)((1 << attempt) * NSEC_PER_SEC)), self.q, ^{
          [self fetch:job attempt:attempt + 1];
        });
        return;
      }
      self.inFlight--;
      GOGFile* f = job.file;
      if (f.fd < 0 || pwrite(f.fd, plain.bytes, plain.length, job.offset) != (ssize_t)plain.length) {
        [self stopWith:[NSString stringWithFormat:@"Soubor %@ nejde zapsat (%s).", f.path, strerror(errno)]];
        [self pump];
        return;
      }
      self.downloaded += [job.chunk[@"compressedSize"] longLongValue];
      if (--f.pending == 0) {
        close(f.fd);
        f.fd = -1;
        NSString* full = [self.staging stringByAppendingPathComponent:f.path];
        NSString* part = [full stringByAppendingString:@".winpad-part"];
        if (f.md5.length && f.size <= 256LL * 1024 * 1024) {
          NSData* whole = [NSData dataWithContentsOfFile:part options:NSDataReadingMappedIfSafe error:nil];
          if (![MD5Hex(whole ?: [NSData data]) isEqualToString:f.md5.lowercaseString]) {
            [self stopWith:[NSString stringWithFormat:@"Soubor %@ se stáhl poškozený (MD5 nesedí), zkus to znovu.", f.path]];
            [self notify:NO];
            [self pump];
            return;
          }
        }
        [NSFileManager.defaultManager removeItemAtPath:full error:nil];
        if (rename([[full stringByAppendingString:@".winpad-part"] fileSystemRepresentation], full.fileSystemRepresentation) != 0) {
          [self stopWith:[NSString stringWithFormat:@"Soubor %@ nejde uložit (%s).", f.path, strerror(errno)]];
        } else {
          [self.done addObject:f.path];
          if (NSDate.timeIntervalSinceReferenceDate - self.lastSaved > 2) [self saveState];
        }
      }
      [self notify:NO];
      [self pump];
    });
  });
}

// On q: the small files out of their containers, the folder in Documents, the library told.
- (void)finish {
  [self setState:WinPadGOGFinishing error:nil];
  NSFileManager* fm = NSFileManager.defaultManager;
  NSMutableDictionary<NSString*, NSFileHandle*>* handles = [NSMutableDictionary new];
  for (GOGFile* f in self.files) {
    if (!f.container || [self.done containsObject:f.path]) continue;
    NSString* cpath = [self.staging stringByAppendingPathComponent:f.container.path];
    NSFileHandle* h = handles[cpath] ?: [NSFileHandle fileHandleForReadingAtPath:cpath];
    if (!h) {
      [self fail:@"Kontejner malých souborů hry chybí, stáhni ji znovu."];
      return;
    }
    handles[cpath] = h;
    [h seekToFileOffset:(unsigned long long)f.sfcOffset];
    NSData* data = [h readDataOfLength:(NSUInteger)f.size];
    NSString* full = [self.staging stringByAppendingPathComponent:f.path];
    [fm createDirectoryAtPath:[full stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    if ((long long)data.length != f.size || ![data writeToFile:full atomically:NO]) {
      [self fail:[NSString stringWithFormat:@"Soubor %@ nejde vybalit.", f.path]];
      return;
    }
    [self.done addObject:f.path];
  }
  for (NSFileHandle* h in handles.allValues) [h closeFile];
  for (GOGFile* f in self.files)
    if (f.isContainer) [fm removeItemAtPath:[self.staging stringByAppendingPathComponent:f.path] error:nil];
  for (NSString* d in self.directories)
    [fm createDirectoryAtPath:[self.staging stringByAppendingPathComponent:d] withIntermediateDirectories:YES attributes:nil error:nil];
  for (NSString* link in self.links) {
    NSString* full = [self.staging stringByAppendingPathComponent:link];
    [fm createDirectoryAtPath:[full stringByDeletingLastPathComponent] withIntermediateDirectories:YES attributes:nil error:nil];
    [fm createSymbolicLinkAtPath:full withDestinationPath:[self.staging stringByAppendingPathComponent:self.links[link]] error:nil];
  }
  [fm removeItemAtPath:[self statePath] error:nil];

  // The goggame-ID.info GOG's installers leave (the library matches its GOG profiles by it),
  // if the depots had none, and what this app knows of the install.
  const long long pid = self.product.productId;
  NSString* info = [NSString stringWithFormat:@"goggame-%lld.info", pid];
  BOOL has_info = NO;
  for (NSString* name in [fm contentsOfDirectoryAtPath:self.staging error:nil])
    if ([name caseInsensitiveCompare:info] == NSOrderedSame) has_info = YES;
  if (!has_info) {
    NSDictionary* j = @{@"gameId" : [NSString stringWithFormat:@"%lld", pid], @"rootGameId" : [NSString stringWithFormat:@"%lld", pid],
                        @"name" : self.product.title};
    [[NSJSONSerialization dataWithJSONObject:j options:0 error:nil] writeToFile:[self.staging stringByAppendingPathComponent:info] atomically:YES];
  }
  NSDictionary* ours = @{
    @"productId" : @(pid),
    @"title" : self.product.title,
    @"build" : self.buildId ?: @"",
    @"language" : self.language ?: @"",
    @"installed" : [NSISO8601DateFormatter stringFromDate:NSDate.date timeZone:NSTimeZone.localTimeZone formatOptions:NSISO8601DateFormatWithInternetDateTime]
  };
  [[NSJSONSerialization dataWithJSONObject:ours options:NSJSONWritingPrettyPrinted error:nil]
      writeToFile:[self.staging stringByAppendingPathComponent:@".winpad-gog.json"] atomically:YES];

  // Into Documents, beside what is there (an older copy of the game stays, with its saves).
  NSString* folder = self.folder;
  for (int n = 2; [fm fileExistsAtPath:[Documents() stringByAppendingPathComponent:folder]]; n++)
    folder = [NSString stringWithFormat:@"%@ %d", self.folder, n];
  NSError* error = nil;
  if (![fm moveItemAtPath:self.staging toPath:[Documents() stringByAppendingPathComponent:folder] error:&error]) {
    [self fail:[@"Složku hry nejde přesunout do Dokumentů: " stringByAppendingString:error.localizedDescription]];
    return;
  }
  self.folder = folder;
  self.downloaded = self.downloadSize;
  [self setState:WinPadGOGDone error:nil];
  [self endBackground];
  dispatch_async(dispatch_get_main_queue(), ^{
    [NSNotificationCenter.defaultCenter postNotificationName:WinPadGOGInstalledNotification object:folder];
  });
}

@end

#pragma mark - Signing in

// GOG's login page; DONE with nil once signed in, else why not (nil, nil: closed).
// Google's and Facebook's sign-in open as pop-ups (window.open), shown over the page; Google
// refuses a page that says it is an embedded web view, so it says it is Safari. Where it still
// refuses, "Přes Safari" signs in in Safari and takes the address GOG ends on, pasted back.
@interface WinPadGOGLoginViewController : UIViewController <WKNavigationDelegate, WKUIDelegate>
@property(nonatomic, copy) void (^done)(NSString* error);
@property(nonatomic, strong) WKWebView* web;
@property(nonatomic, strong) NSMutableArray<WKWebView*>* popups;
@property(nonatomic) BOOL exchanging;
@end

static NSString* const SafariAgent = @"Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) "
                                     @"Version/18.0 Safari/605.1.15";

static NSURL* LoginURL(void) {
  return [NSURL URLWithString:[NSString stringWithFormat:@"https://auth.gog.com/auth?client_id=%@&redirect_uri=%@&response_type=code&layout=client2",
                                                         ClientId, Escaped(RedirectURI)]];
}

// The login code in TEXT: an on_login_success address (?code=...), or the code itself.
static NSString* LoginCode(NSString* text) {
  text = [text stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!text.length) return nil;
  NSURLComponents* c = [NSURLComponents componentsWithString:text];
  if (c.queryItems) {
    for (NSURLQueryItem* item in c.queryItems)
      if ([item.name isEqualToString:@"code"] && item.value.length) return item.value;
    return nil;
  }
  return [text rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@" /:?&"]].location == NSNotFound ? text : nil;
}

// Sign-in in Safari: GOG's login page there, then the address it ended on pasted back here;
// GOT runs with the login code in it.
static void SignInViaSafari(UIViewController* host, void (^got)(NSString* code)) {
  [UIApplication.sharedApplication openURL:LoginURL() options:@{} completionHandler:nil];
  UIAlertController* ask = [UIAlertController
      alertControllerWithTitle:@"Přihlášení přes Safari"
                       message:@"V Safari se přihlas ke GOG (i přes Google). Skončíš na prázdné stránce embed.gog.com. Zkopíruj její adresu "
                               @"(podrž adresní řádek › Kopírovat), vrať se sem a vlož ji."
                preferredStyle:UIAlertControllerStyleAlert];
  [ask addTextFieldWithConfigurationHandler:^(UITextField* field) {
    field.placeholder = @"https://embed.gog.com/on_login_success?…";
    field.keyboardType = UIKeyboardTypeURL;
    field.autocorrectionType = UITextAutocorrectionTypeNo;
    field.autocapitalizationType = UITextAutocapitalizationTypeNone;
  }];
  [ask addAction:[UIAlertAction actionWithTitle:@"Zrušit" style:UIAlertActionStyleCancel handler:nil]];
  __weak UIViewController* weak = host;
  __weak UIAlertController* weak_ask = ask;
  [ask addAction:[UIAlertAction actionWithTitle:@"Přihlásit"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction* a) {
                                          NSString* text = weak_ask.textFields.firstObject.text;
                                          if (!text.length && UIPasteboard.generalPasteboard.hasStrings) text = UIPasteboard.generalPasteboard.string;
                                          NSString* code = LoginCode(text);
                                          if (code) {
                                            got(code);
                                            return;
                                          }
                                          UIAlertController* bad = [UIAlertController
                                              alertControllerWithTitle:@"V adrese není přihlašovací kód"
                                                               message:@"Zkopíruj celou adresu stránky, na které přihlášení v Safari skončilo "
                                                                       @"(obsahuje code=)."
                                                        preferredStyle:UIAlertControllerStyleAlert];
                                          [bad addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
                                          [weak presentViewController:bad animated:YES completion:nil];
                                        }]];
  // Back from Safari: the alert is waiting, with the copied address already in it when it is one.
  [host presentViewController:ask
                     animated:YES
                   completion:^{
                     __block id observer = [NSNotificationCenter.defaultCenter
                         addObserverForName:UIApplicationDidBecomeActiveNotification
                                     object:nil
                                      queue:NSOperationQueue.mainQueue
                                 usingBlock:^(NSNotification* note) {
                                   [NSNotificationCenter.defaultCenter removeObserver:observer];
                                   UITextField* field = weak_ask.textFields.firstObject;
                                   NSString* pasted = UIPasteboard.generalPasteboard.hasStrings ? UIPasteboard.generalPasteboard.string : nil;
                                   if (field && !field.text.length && [pasted containsString:@"on_login_success"]) field.text = pasted;
                                 }];
                   }];
}

@implementation WinPadGOGLoginViewController

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Přihlášení ke GOG";
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  self.popups = [NSMutableArray new];
  self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                                                        target:self
                                                                                        action:@selector(close)];
  self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithTitle:@"Přes Safari"
                                                                            style:UIBarButtonItemStylePlain
                                                                           target:self
                                                                           action:@selector(viaSafari)];
  WKWebViewConfiguration* config = [WKWebViewConfiguration new];
  config.preferences.javaScriptCanOpenWindowsAutomatically = YES;
  self.web = [self webViewWith:config];
  [self.view addSubview:self.web];
  self.web.translatesAutoresizingMaskIntoConstraints = NO;
  UILayoutGuide* safe = self.view.safeAreaLayoutGuide;
  [NSLayoutConstraint activateConstraints:@[
    [self.web.topAnchor constraintEqualToAnchor:safe.topAnchor],
    [self.web.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor],
    [self.web.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor],
    [self.web.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor]
  ]];
  [self.web loadRequest:[NSURLRequest requestWithURL:LoginURL()]];
}

- (WKWebView*)webViewWith:(WKWebViewConfiguration*)config {
  WKWebView* web = [[WKWebView alloc] initWithFrame:self.view.bounds configuration:config];
  web.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  web.customUserAgent = SafariAgent;
  web.navigationDelegate = self;
  web.UIDelegate = self;
  return web;
}

- (void)close {
  [self dismissViewControllerAnimated:YES completion:nil];
}

// A pop-up the page opens (Google's sign-in): over the page until it closes itself.
- (WKWebView*)webView:(WKWebView*)webView
    createWebViewWithConfiguration:(WKWebViewConfiguration*)configuration
               forNavigationAction:(WKNavigationAction*)action
                    windowFeatures:(WKWindowFeatures*)features {
  WKWebView* popup = [self webViewWith:configuration];
  [self.view addSubview:popup];
  [self.popups addObject:popup];
  return popup;
}

- (void)webViewDidClose:(WKWebView*)webView {
  if (webView == self.web) return;
  [webView removeFromSuperview];
  [self.popups removeObject:webView];
}

- (void)viaSafari {
  __weak WinPadGOGLoginViewController* weak = self;
  SignInViaSafari(self, ^(NSString* code) {
    [weak exchange:code];
  });
}

- (void)exchange:(NSString*)code {
  if (self.exchanging) return;
  self.exchanging = YES;
  __weak WinPadGOGLoginViewController* weak = self;
  ExchangeCode(code, ^(NSString* token, NSString* error) {
    WinPadGOGLoginViewController* me = weak;
    if (!me) return;
    void (^done)(NSString*) = me.done;
    [me dismissViewControllerAnimated:YES
                           completion:^{
                             if (done) done(error);
                           }];
  });
}

- (void)webView:(WKWebView*)webView
    decidePolicyForNavigationAction:(WKNavigationAction*)action
                    decisionHandler:(void (^)(WKNavigationActionPolicy))decisionHandler {
  NSURLComponents* c = [NSURLComponents componentsWithURL:action.request.URL resolvingAgainstBaseURL:NO];
  if (![c.host isEqualToString:@"embed.gog.com"] || ![c.path isEqualToString:@"/on_login_success"]) {
    decisionHandler(WKNavigationActionPolicyAllow);
    return;
  }
  decisionHandler(WKNavigationActionPolicyCancel);
  NSString* code = LoginCode(action.request.URL.absoluteString);
  if (code) [self exchange:code];
}

@end

#pragma mark - The GOG screen

@interface WinPadGOGViewController () <UISearchResultsUpdating>
@property(nonatomic, strong) NSArray<WinPadGOGProduct*>* games;
@property(nonatomic, strong) NSArray<WinPadGOGProduct*>* shown;
@property(nonatomic, copy) NSString* message;
@property(nonatomic) BOOL loading;
@property(nonatomic, strong) NSCache<NSURL*, UIImage*>* thumbs;
@property(nonatomic, strong) UISearchController* search;
@end

@implementation WinPadGOGViewController

- (instancetype)init {
  return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"GOG";
  self.thumbs = [NSCache new];
  self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                         target:self
                                                                                         action:@selector(close)];
  self.search = [[UISearchController alloc] initWithSearchResultsController:nil];
  self.search.searchResultsUpdater = self;
  self.search.obscuresBackgroundDuringPresentation = NO;
  self.search.searchBar.placeholder = @"Hledat ve hrách";
  self.navigationItem.searchController = self.search;
  self.navigationItem.hidesSearchBarWhenScrolling = NO;
  self.refreshControl = [UIRefreshControl new];
  [self.refreshControl addTarget:self action:@selector(reloadGames) forControlEvents:UIControlEventValueChanged];
  self.tableView.rowHeight = 64;
  [self reloadGames];
}

- (void)close {
  [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)updateBar {
  self.navigationItem.leftBarButtonItem =
      WinPadGOGSignedIn() ? [[UIBarButtonItem alloc] initWithTitle:@"Odhlásit" style:UIBarButtonItemStylePlain target:self action:@selector(signOut)]
                          : nil;
}

- (void)reloadGames {
  [self updateBar];
  if (!WinPadGOGSignedIn()) {
    self.games = nil;
    [self filter];
    [self.refreshControl endRefreshing];
    return;
  }
  self.loading = YES;
  self.message = @"Načítám tvoje hry z GOG…";
  [self.tableView reloadData];
  __weak WinPadGOGViewController* weak = self;
  WinPadGOGOwnedGames(^(NSArray<WinPadGOGProduct*>* games, NSString* error) {
    WinPadGOGViewController* me = weak;
    me.loading = NO;
    me.games = games;
    me.message = error ? error
                       : games.count ? [NSString stringWithFormat:@"%lu her pro Windows. Hry z GOG jsou bez DRM; ty, které ke hraní potřebují "
                                                                  @"klienta GOG Galaxy (jen multiplayer), poběží bez něj.",
                                                                  (unsigned long)games.count]
                                     : @"Na tomhle účtu GOG nemáš žádné hry pro Windows.";
    [me filter];
    [me.refreshControl endRefreshing];
    [me updateBar];
  });
}

- (void)filter {
  NSString* q = self.search.searchBar.text;
  if (!q.length) {
    self.shown = self.games;
  } else {
    NSMutableArray* m = [NSMutableArray new];
    for (WinPadGOGProduct* g in self.games)
      if ([g.title rangeOfString:q options:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch].location != NSNotFound) [m addObject:g];
    self.shown = m;
  }
  [self.tableView reloadData];
}

- (void)updateSearchResultsForSearchController:(UISearchController*)searchController {
  [self filter];
}

- (void)signOut {
  UIAlertController* ask = [UIAlertController alertControllerWithTitle:@"Odhlásit se od GOG?"
                                                               message:@"Nainstalované hry zůstanou v knihovně."
                                                        preferredStyle:UIAlertControllerStyleAlert];
  [ask addAction:[UIAlertAction actionWithTitle:@"Zrušit" style:UIAlertActionStyleCancel handler:nil]];
  __weak WinPadGOGViewController* weak = self;
  [ask addAction:[UIAlertAction actionWithTitle:@"Odhlásit"
                                          style:UIAlertActionStyleDestructive
                                        handler:^(UIAlertAction* a) {
                                          WinPadGOGSignOut();
                                          weak.message = nil;
                                          [weak reloadGames];
                                        }]];
  [self presentViewController:ask animated:YES completion:nil];
}

- (void)signIn {
  WinPadGOGLoginViewController* login = [WinPadGOGLoginViewController new];
  __weak WinPadGOGViewController* weak = self;
  login.done = ^(NSString* error) {
    if (error) weak.message = error;
    [weak reloadGames];
  };
  UINavigationController* nav = [[UINavigationController alloc] initWithRootViewController:login];
  nav.modalPresentationStyle = UIModalPresentationPageSheet;
  [self presentViewController:nav animated:YES completion:nil];
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
  return WinPadGOGSignedIn() ? (NSInteger)self.shown.count : 2;
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
  if (!WinPadGOGSignedIn())
    return [@"Přihlas se svým účtem GOG: uvidíš svoje hry a nainstaluješ je rovnou do iPadu, bez počítače. Přihlášení zůstane v "
            @"klíčence iPadu. WinPad mluví s GOG stejně jako GOG Galaxy; GOG to oficiálně nepodporuje, takže se to může změnit."
        stringByAppendingString:self.message ? [@"\n\n" stringByAppendingString:self.message] : @""];
  return self.message;
}

static NSString* Status(WinPadGOGInstall* install, long long productId) {
  NSByteCountFormatter* f = [NSByteCountFormatter new];
  f.countStyle = NSByteCountFormatterCountStyleFile;
  switch (install ? install.state : -1) {
    case WinPadGOGPlanning:
      return @"Zjišťuji, co stáhnout…";
    case WinPadGOGPlanned:
      return [NSString stringWithFormat:@"Připraveno: %@ ke stažení", [f stringFromByteCount:install.downloadSize]];
    case WinPadGOGDownloading:
      return [NSString stringWithFormat:@"Stahuji %.0f %% (%@ z %@), klepni pro zastavení",
                                        install.downloadSize ? 100.0 * install.downloaded / install.downloadSize : 0,
                                        [f stringFromByteCount:install.downloaded], [f stringFromByteCount:install.downloadSize]];
    case WinPadGOGFinishing:
      return @"Ukládám do knihovny…";
    case WinPadGOGDone:
      return [NSString stringWithFormat:@"V knihovně (%@)", install.folder];
    case WinPadGOGFailed:
      return [NSString stringWithFormat:@"Zastaveno: %@ Klepni pro pokračování.", install.error ?: @""];
    default: {
      NSString* folder = WinPadGOGInstalledFolder(productId);
      return folder ? [NSString stringWithFormat:@"V knihovně (%@)", folder] : @"Klepni pro instalaci";
    }
  }
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)indexPath {
  UITableViewCell* cell = [tableView dequeueReusableCellWithIdentifier:@"game"]
                              ?: [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleSubtitle reuseIdentifier:@"game"];
  cell.detailTextLabel.numberOfLines = 2;
  cell.detailTextLabel.textColor = UIColor.secondaryLabelColor;
  if (!WinPadGOGSignedIn()) {
    const BOOL safari = indexPath.row == 1;
    cell.textLabel.text = safari ? @"Přihlásit se přes Safari" : @"Přihlásit se ke GOG";
    cell.textLabel.textColor = self.view.tintColor;
    cell.detailTextLabel.text = safari ? @"Pro přihlášení přes Google, když ho přihlašovací okno odmítne" : nil;
    cell.imageView.image = [UIImage systemImageNamed:safari ? @"safari" : @"person.crop.circle"];
    return cell;
  }
  WinPadGOGProduct* game = self.shown[indexPath.row];
  cell.textLabel.text = game.title;
  cell.textLabel.textColor = UIColor.labelColor;
  WinPadGOGInstall* install = [WinPadGOGInstall existingFor:game.productId];
  cell.detailTextLabel.text = Status(install, game.productId);
  if (install) {
    __weak WinPadGOGViewController* weak = self;
    install.changed = ^(WinPadGOGInstall* i) {
      [weak changed:i];
    };
  }
  UIImage* thumb = game.imageURL ? [self.thumbs objectForKey:game.imageURL] : nil;
  cell.imageView.image = thumb ?: [UIImage systemImageNamed:@"gamecontroller"];
  if (!thumb && game.imageURL) {
    NSURL* url = game.imageURL;
    __weak WinPadGOGViewController* weak = self;
    Fetch(url, nil, ^(NSData* data, NSString* error, NSInteger status) {
      UIImage* image = data ? [UIImage imageWithData:data] : nil;
      if (!image) return;
      // A 16:9 tile, small enough for a row.
      const CGSize size = CGSizeMake(80, 45);
      UIImage* small = [[[UIGraphicsImageRenderer alloc] initWithSize:size] imageWithActions:^(UIGraphicsImageRendererContext* ctx) {
        [image drawInRect:(CGRect){CGPointZero, size}];
      }];
      dispatch_async(dispatch_get_main_queue(), ^{
        WinPadGOGViewController* me = weak;
        [me.thumbs setObject:small forKey:url];
        const NSUInteger row = [me.shown indexOfObject:game];
        if (row != NSNotFound && row < (NSUInteger)[me.tableView numberOfRowsInSection:0])
          [me.tableView reloadRowsAtIndexPaths:@[ [NSIndexPath indexPathForRow:(NSInteger)row inSection:0] ]
                              withRowAnimation:UITableViewRowAnimationNone];
      });
    });
  }
  return cell;
}

- (void)changed:(WinPadGOGInstall*)install {
  const NSUInteger row = [self.shown indexOfObject:install.product];
  if (row != NSNotFound) {
    UITableViewCell* cell = [self.tableView cellForRowAtIndexPath:[NSIndexPath indexPathForRow:(NSInteger)row inSection:0]];
    cell.detailTextLabel.text = Status(install, install.product.productId);
  }
  if (install.state == WinPadGOGPlanned && self.view.window && !self.presentedViewController) [self confirm:install];
}

- (void)confirm:(WinPadGOGInstall*)install {
  NSByteCountFormatter* f = [NSByteCountFormatter new];
  NSString* text = [NSString stringWithFormat:@"Stáhne se %@ (%ld souborů, na iPadu %@), jazyk %@. Hra se objeví v knihovně, až bude celá stažená. "
                                              @"Nech iPad zapnutý a aplikaci otevřenou.",
                                              [f stringFromByteCount:install.downloadSize], (long)install.fileCount,
                                              [f stringFromByteCount:install.installSize], install.language ?: @"?"];
  UIAlertController* ask = [UIAlertController alertControllerWithTitle:install.product.title
                                                               message:text
                                                        preferredStyle:UIAlertControllerStyleAlert];
  [ask addAction:[UIAlertAction actionWithTitle:@"Zrušit"
                                          style:UIAlertActionStyleCancel
                                        handler:^(UIAlertAction* a) {
                                          [install cancel];
                                        }]];
  [ask addAction:[UIAlertAction actionWithTitle:@"Stáhnout"
                                          style:UIAlertActionStyleDefault
                                        handler:^(UIAlertAction* a) {
                                          [install start];
                                        }]];
  [self presentViewController:ask animated:YES completion:nil];
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)indexPath {
  [tableView deselectRowAtIndexPath:indexPath animated:YES];
  if (!WinPadGOGSignedIn()) {
    if (indexPath.row == 0) {
      [self signIn];
      return;
    }
    __weak WinPadGOGViewController* weak = self;
    SignInViaSafari(self, ^(NSString* code) {
      weak.message = @"Přihlašuji…";
      [weak.tableView reloadData];
      ExchangeCode(code, ^(NSString* token, NSString* error) {
        weak.message = error;
        [weak reloadGames];
      });
    });
    return;
  }
  WinPadGOGProduct* game = self.shown[indexPath.row];
  WinPadGOGInstall* install = [WinPadGOGInstall existingFor:game.productId];
  __weak WinPadGOGViewController* weak = self;
  if (!install) {
    NSString* folder = WinPadGOGInstalledFolder(game.productId);
    if (folder) {
      UIAlertController* ask = [UIAlertController
          alertControllerWithTitle:game.title
                           message:[NSString stringWithFormat:@"Hra už je v knihovně ve složce %@. Stáhnout ji znovu do nové složky?", folder]
                    preferredStyle:UIAlertControllerStyleAlert];
      [ask addAction:[UIAlertAction actionWithTitle:@"Ne" style:UIAlertActionStyleCancel handler:nil]];
      [ask addAction:[UIAlertAction actionWithTitle:@"Stáhnout znovu"
                                              style:UIAlertActionStyleDefault
                                            handler:^(UIAlertAction* a) {
                                              [weak plan:game];
                                            }]];
      [self presentViewController:ask animated:YES completion:nil];
      return;
    }
    [self plan:game];
    return;
  }
  switch (install.state) {
    case WinPadGOGPlanned:
      [self confirm:install];
      break;
    case WinPadGOGDownloading: {
      UIAlertController* ask = [UIAlertController alertControllerWithTitle:game.title
                                                                   message:@"Zastavit stahování? Co už je stažené, zůstane; příště se pokračuje."
                                                            preferredStyle:UIAlertControllerStyleAlert];
      [ask addAction:[UIAlertAction actionWithTitle:@"Stahovat dál" style:UIAlertActionStyleCancel handler:nil]];
      [ask addAction:[UIAlertAction actionWithTitle:@"Zastavit"
                                              style:UIAlertActionStyleDestructive
                                            handler:^(UIAlertAction* a) {
                                              [install cancel];
                                            }]];
      [self presentViewController:ask animated:YES completion:nil];
      break;
    }
    case WinPadGOGFailed:
      [install start];
      break;
    case WinPadGOGDone:
      [self close];
      break;
    default:
      break;
  }
}

- (void)plan:(WinPadGOGProduct*)game {
  WinPadGOGInstall* install = [WinPadGOGInstall installFor:game];
  __weak WinPadGOGViewController* weak = self;
  install.changed = ^(WinPadGOGInstall* i) {
    [weak changed:i];
  };
  [self changed:install];
}

@end

#pragma mark - CI

// CI: installs GAMES[I...] one after another, says what each did, then FINISH.
static void TestInstalls(NSArray<WinPadGOGProduct*>* games, NSUInteger i, NSMutableString* report, void (^finish)(void)) {
  if (i >= games.count) {
    finish();
    return;
  }
  const long long productId = games[i].productId;
  void (^next)(void) = ^{
    TestInstalls(games, i + 1, report, finish);
  };
  WinPadGOGInstall* install = [WinPadGOGInstall installFor:games[i]];
  __block BOOL planned = NO;
  install.changed = ^(WinPadGOGInstall* inst) {
    if (inst.state == WinPadGOGPlanned && !planned) {
      planned = YES;
      [report appendFormat:@"plan: %@ | language %@ | %ld files | install %lld | download %lld\n", inst.folder, inst.language,
                           (long)inst.fileCount, inst.installSize, inst.downloadSize];
      [inst start];
    } else if (inst.state == WinPadGOGDone) {
      inst.changed = nil;
      [report appendFormat:@"installed: %@ | downloaded %lld\n", inst.folder, inst.downloaded];
      NSString* dir = [Documents() stringByAppendingPathComponent:inst.folder];
      NSDirectoryEnumerator* e = [NSFileManager.defaultManager enumeratorAtPath:dir];
      NSMutableArray* lines = [NSMutableArray new];
      for (NSString* rel in e) {
        BOOL is_dir = NO;
        [NSFileManager.defaultManager fileExistsAtPath:[dir stringByAppendingPathComponent:rel] isDirectory:&is_dir];
        if (is_dir) {
          [lines addObject:[NSString stringWithFormat:@"dir: %@\n", rel]];
          continue;
        }
        NSData* data = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:rel]];
        [lines addObject:[NSString stringWithFormat:@"file: %@ | %lu | %@\n", rel, (unsigned long)data.length, MD5Hex(data ?: [NSData data])]];
      }
      [lines sortUsingSelector:@selector(compare:)];
      for (NSString* l in lines) [report appendString:l];
      [report appendFormat:@"installed folder found: %@\n", WinPadGOGInstalledFolder(productId) ?: @"none"];
      next();
    } else if (inst.state == WinPadGOGFailed || inst.state == WinPadGOGCancelled) {
      inst.changed = nil;
      [report appendFormat:@"failed: %@ | %@\n", inst.folder ?: inst.product.title, inst.error ?: @"cancelled"];
      next();
    }
  };
}

void WinPadGOGTest(NSString* productIds) {
  NSMutableArray<NSNumber*>* wanted = [NSMutableArray new];
  for (NSString* id_ in [productIds componentsSeparatedByString:@","])
    if (id_.longLongValue > 0) [wanted addObject:@(id_.longLongValue)];
  NSMutableString* report = [NSMutableString new];
  NSString* path = [Documents() stringByAppendingPathComponent:@"gog.txt"];
  void (^write)(void) = ^{
    [report writeToFile:path atomically:YES encoding:NSUTF8StringEncoding error:nil];
  };
  void (^finish)(void) = ^{
    WinPadGOGSignOut();
    [report appendFormat:@"signed in after sign out: %@\n", WinPadGOGSignedIn() ? @"YES" : @"NO"];
    [report appendString:@"== finished\n"];
    write();
  };
  WinPadGOGSignOut();
  ExchangeCode(@"test", ^(NSString* token, NSString* error) {
    [report appendFormat:@"signin: %@ (%@)\n", token ? @"ok" : error, TokenStore];
    write();
    if (!token) {
      finish();
      return;
    }
    WinPadGOGOwnedGames(^(NSArray<WinPadGOGProduct*>* games, NSString* error) {
      [report appendFormat:@"games: %lu%@\n", (unsigned long)games.count, error ? [@" " stringByAppendingString:error] : @""];
      NSMutableArray<WinPadGOGProduct*>* picks = [NSMutableArray new];
      for (NSNumber* want in wanted)
        for (WinPadGOGProduct* g in games)
          if (g.productId == want.longLongValue) [picks addObject:g];
      for (WinPadGOGProduct* g in games)
        [report appendFormat:@"game: %lld | %@ | %@\n", g.productId, g.title, g.imageURL.lastPathComponent ?: @"-"];
      write();
      TestInstalls(picks, 0, report, finish);
    });
  });
}

