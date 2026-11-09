// SPDX-License-Identifier: MIT
// Game covers for the library, from the internet, found by the game's title:
//
//  - SteamGridDB (www.steamgriddb.com/api/v2): the best covers, made by its users, for nearly
//    any game, Steam or not. It needs a free API key (steamgriddb.com › Preferences › API), the
//    "steamGridDBKey" setting (Nastavení › Vzhled › Klíč SteamGridDB), so it is only used with one.
//  - The Steam store: storesearch by name (no key), the tall library picture of each game
//    found (library_600x900_2x.jpg, else header.jpg for some old games). With the game's Steam
//    app id (steam_appid.txt) that game comes first.
//  - Wikipedia: the picture of the article's infobox, which for a game is its box art
//    (pageimages with pilicense=any, as box art is not freely licensed).
//
// The library downloads a cover by itself for each game without one (WinPadAutoCovers), but
// only one whose name matches the game's title; any other is picked by the user in
// WinPadCoverPickerViewController (Obal under the game, or a long press on its tile).
#import "Covers.h"

#import "Library.h"

#import <PhotosUI/PhotosUI.h>

#include <ctype.h>

static NSString* Documents(void) {
  return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

@implementation WinPadCover
@end

static NSURLSession* Session(void) {
  static NSURLSession* session;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSURLSessionConfiguration* config = NSURLSessionConfiguration.defaultSessionConfiguration;
    config.timeoutIntervalForRequest = 15;
    config.HTTPAdditionalHeaders = @{@"User-Agent" : @"WinPad/1.0 (iPad game library; cover lookup)"};
    config.URLCache = [[NSURLCache alloc] initWithMemoryCapacity:8 << 20 diskCapacity:64 << 20 directoryURL:nil];
    session = [NSURLSession sessionWithConfiguration:config];
  });
  return session;
}

static NSString* Escape(NSString* s) {
  NSMutableCharacterSet* ok = [NSCharacterSet.alphanumericCharacterSet mutableCopy];
  [ok addCharactersInString:@"-._~"];
  return [s stringByAddingPercentEncodingWithAllowedCharacters:ok];
}

// GETs JSON from URL (with HEADERS); DONE(object or nil, error) on any thread.
static void GetJSON(NSString* url, NSDictionary* headers, void (^done)(id json, NSError* error)) {
  NSMutableURLRequest* request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:url]];
  [headers enumerateKeysAndObjectsUsingBlock:^(NSString* key, NSString* value, BOOL* stop) {
    [request setValue:value forHTTPHeaderField:key];
  }];
  [[Session() dataTaskWithRequest:request
                completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
                  const NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse*)response).statusCode : 0;
                  if (!error && status != 200)
                    error = [NSError errorWithDomain:@"WinPadCovers"
                                                code:status
                                            userInfo:@{NSLocalizedDescriptionKey : [NSString stringWithFormat:@"HTTP %ld", (long)status]}];
                  id json = data && !error ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
                  done([json isKindOfClass:NSDictionary.class] ? json : nil, error);
                }] resume];
}

static NSURL* SteamPicture(long app, NSString* name) {
  return [NSURL URLWithString:[NSString stringWithFormat:@"https://cdn.cloudflare.steamstatic.com/steam/apps/%ld/%@", app, name]];
}

static WinPadCover* SteamCover(long app, NSString* name) {
  WinPadCover* cover = [WinPadCover new];
  cover.name = name;
  cover.source = @"Steam";
  cover.urls = @[ SteamPicture(app, @"library_600x900_2x.jpg"), SteamPicture(app, @"library_600x900.jpg"), SteamPicture(app, @"header.jpg") ];
  cover.thumb = SteamPicture(app, @"library_600x900.jpg");
  return cover;
}

static void SteamCovers(NSString* query, long app, void (^done)(NSArray<WinPadCover*>*, NSError*)) {
  NSString* url = [NSString stringWithFormat:@"https://store.steampowered.com/api/storesearch/?term=%@&l=english&cc=US", Escape(query)];
  GetJSON(url, nil, ^(NSDictionary* json, NSError* error) {
    NSMutableArray<WinPadCover*>* covers = [NSMutableArray new];
    if (app) [covers addObject:SteamCover(app, query)];
    NSArray* items = [json[@"items"] isKindOfClass:NSArray.class] ? json[@"items"] : @[];
    for (NSDictionary* item in items) {
      if (![item isKindOfClass:NSDictionary.class] || ![item[@"id"] respondsToSelector:@selector(longValue)]) continue;
      const long app_id = [item[@"id"] longValue];
      if (app_id == app) {
        if ([item[@"name"] isKindOfClass:NSString.class]) covers.firstObject.name = item[@"name"];
        continue;
      }
      if ([item[@"type"] isKindOfClass:NSString.class] && ![item[@"type"] isEqualToString:@"app"]) continue;
      [covers addObject:SteamCover(app_id, [item[@"name"] isKindOfClass:NSString.class] ? item[@"name"] : @"?")];
      if (covers.count >= 8) break;
    }
    done(covers, covers.count ? nil : error);
  });
}

static void WikipediaCovers(NSString* query, void (^done)(NSArray<WinPadCover*>*, NSError*)) {
  NSString* url = [NSString stringWithFormat:@"https://en.wikipedia.org/w/api.php?action=query&format=json&formatversion=2"
                                             @"&generator=search&gsrsearch=%@&gsrlimit=6&gsrnamespace=0"
                                             @"&prop=pageimages&piprop=thumbnail&pithumbsize=600&pilicense=any",
                                             Escape([query stringByAppendingString:@" video game"])];
  GetJSON(url, nil, ^(NSDictionary* json, NSError* error) {
    NSDictionary* q = [json[@"query"] isKindOfClass:NSDictionary.class] ? json[@"query"] : nil;
    NSArray* pages = [q[@"pages"] isKindOfClass:NSArray.class] ? q[@"pages"] : @[];
    pages = [pages sortedArrayUsingComparator:^NSComparisonResult(NSDictionary* a, NSDictionary* b) {
      const long ia = [a isKindOfClass:NSDictionary.class] ? [a[@"index"] longValue] : 99;
      const long ib = [b isKindOfClass:NSDictionary.class] ? [b[@"index"] longValue] : 99;
      return ia < ib ? NSOrderedAscending : ia > ib ? NSOrderedDescending : NSOrderedSame;
    }];
    NSMutableArray<WinPadCover*>* covers = [NSMutableArray new];
    for (NSDictionary* page in pages) {
      if (![page isKindOfClass:NSDictionary.class]) continue;
      NSDictionary* thumb = [page[@"thumbnail"] isKindOfClass:NSDictionary.class] ? page[@"thumbnail"] : nil;
      NSString* src = [thumb[@"source"] isKindOfClass:NSString.class] ? thumb[@"source"] : nil;
      // Logos and screenshots are wider than tall; box art is not.
      if (!src || [thumb[@"width"] doubleValue] > 1.15 * [thumb[@"height"] doubleValue]) continue;
      WinPadCover* cover = [WinPadCover new];
      cover.name = [page[@"title"] isKindOfClass:NSString.class] ? page[@"title"] : @"?";
      cover.source = @"Wikipedie";
      NSURL* u = [NSURL URLWithString:src];
      if (!u) continue;
      cover.urls = @[ u ];
      [covers addObject:cover];
    }
    done(covers, covers.count ? nil : error);
  });
}

static NSString* SteamGridDBKey(void) {
  NSString* key = [[NSUserDefaults.standardUserDefaults stringForKey:@"steamGridDBKey"]
      stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  return key.length ? key : nil;
}

static void SteamGridDBCovers(NSString* query, void (^done)(NSArray<WinPadCover*>*, NSError*)) {
  NSString* key = SteamGridDBKey();
  if (!key) {
    done(@[], nil);
    return;
  }
  NSDictionary* auth = @{@"Authorization" : [@"Bearer " stringByAppendingString:key]};
  NSString* url = [@"https://www.steamgriddb.com/api/v2/search/autocomplete/" stringByAppendingString:Escape(query)];
  GetJSON(url, auth, ^(NSDictionary* json, NSError* error) {
    NSArray* found = [json[@"data"] isKindOfClass:NSArray.class] ? json[@"data"] : @[];
    NSMutableArray* games = [NSMutableArray new];
    for (NSDictionary* g in found)
      if ([g isKindOfClass:NSDictionary.class] && [g[@"id"] respondsToSelector:@selector(longValue)] && games.count < 3) [games addObject:g];
    if (!games.count) {
      done(@[], error);
      return;
    }
    // The grids of each game found, in the order found.
    NSMutableArray<NSMutableArray*>* each = [NSMutableArray new];
    for (NSUInteger i = 0; i < games.count; i++) [each addObject:[NSMutableArray new]];
    dispatch_group_t group = dispatch_group_create();
    for (NSUInteger i = 0; i < games.count; i++) {
      dispatch_group_enter(group);
      NSString* name = [games[i][@"name"] isKindOfClass:NSString.class] ? games[i][@"name"] : @"?";
      NSString* grids = [NSString stringWithFormat:@"https://www.steamgriddb.com/api/v2/grids/game/%ld?dimensions=600x900,342x482,660x930&types=static",
                                                   [games[i][@"id"] longValue]];
      GetJSON(grids, auth, ^(NSDictionary* json, NSError* e) {
        NSArray* data = [json[@"data"] isKindOfClass:NSArray.class] ? json[@"data"] : @[];
        for (NSDictionary* grid in data) {
          if (![grid isKindOfClass:NSDictionary.class] || ![grid[@"url"] isKindOfClass:NSString.class]) continue;
          NSURL* u = [NSURL URLWithString:grid[@"url"]];
          if (!u) continue;
          WinPadCover* cover = [WinPadCover new];
          cover.name = name;
          cover.source = @"SteamGridDB";
          cover.urls = @[ u ];
          if ([grid[@"thumb"] isKindOfClass:NSString.class]) cover.thumb = [NSURL URLWithString:grid[@"thumb"]];
          @synchronized(each) {
            if (each[i].count < (i ? 4 : 8)) [each[i] addObject:cover];
          }
        }
        dispatch_group_leave(group);
      });
    }
    dispatch_group_notify(group, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
      NSMutableArray* covers = [NSMutableArray new];
      for (NSArray* list in each) [covers addObjectsFromArray:list];
      done(covers, nil);
    });
  });
}

void WinPadFindCovers(NSString* query, long steam_app_id, void (^done)(NSArray<WinPadCover*>*, NSError*)) {
  query = [query stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (!query.length && !steam_app_id) {
    done(@[], nil);
    return;
  }
  __block NSArray *grid = @[], *steam = @[], *wiki = @[];
  __block NSError* last = nil;
  dispatch_group_t group = dispatch_group_create();
  dispatch_group_enter(group);
  SteamGridDBCovers(query, ^(NSArray* covers, NSError* error) {
    @synchronized(group) {
      grid = covers;
      if (error) last = error;
    }
    dispatch_group_leave(group);
  });
  dispatch_group_enter(group);
  SteamCovers(query, steam_app_id, ^(NSArray* covers, NSError* error) {
    @synchronized(group) {
      steam = covers;
      if (error) last = error;
    }
    dispatch_group_leave(group);
  });
  dispatch_group_enter(group);
  WikipediaCovers(query, ^(NSArray* covers, NSError* error) {
    @synchronized(group) {
      wiki = covers;
      if (error) last = error;
    }
    dispatch_group_leave(group);
  });
  dispatch_group_notify(group, dispatch_get_main_queue(), ^{
    NSMutableArray* all = [NSMutableArray new];
    [all addObjectsFromArray:grid];
    [all addObjectsFromArray:steam];
    [all addObjectsFromArray:wiki];
    done(all, all.count ? nil : last);
  });
}

static void LoadFrom(NSArray<NSURL*>* urls, NSUInteger i, void (^done)(UIImage*, NSData*)) {
  if (i >= urls.count) {
    dispatch_async(dispatch_get_main_queue(), ^{
      done(nil, nil);
    });
    return;
  }
  [[Session() dataTaskWithURL:urls[i]
            completionHandler:^(NSData* data, NSURLResponse* response, NSError* error) {
              const NSInteger status = [response isKindOfClass:NSHTTPURLResponse.class] ? ((NSHTTPURLResponse*)response).statusCode : 0;
              UIImage* image = !error && status == 200 && data.length ? [UIImage imageWithData:data] : nil;
              if (!image) {
                LoadFrom(urls, i + 1, done);
                return;
              }
              dispatch_async(dispatch_get_main_queue(), ^{
                done(image, data);
              });
            }] resume];
}

void WinPadLoadCover(WinPadCover* cover, BOOL thumb, void (^done)(UIImage*, NSData*)) {
  NSMutableArray* urls = [NSMutableArray new];
  if (thumb && cover.thumb) [urls addObject:cover.thumb];
  [urls addObjectsFromArray:cover.urls ?: @[]];
  LoadFrom(urls, 0, done);
}

static NSString* GameDir(WinPadGame* game) {
  return [Documents() stringByAppendingPathComponent:game.folder];
}

BOOL WinPadSaveCover(WinPadGame* game, UIImage* image, NSError** error) {
  NSFileManager* fm = NSFileManager.defaultManager;
  NSString* dir = GameDir(game);
  NSData* jpeg = nil;
  if (image) {
    // At most 900 pixels tall: enough for the largest tile and the blurred backdrop.
    const CGFloat scale = MIN(1.0, 900.0 / MAX(1.0, image.size.height * image.scale));
    const CGSize size = CGSizeMake(round(image.size.width * image.scale * scale), round(image.size.height * image.scale * scale));
    UIGraphicsImageRendererFormat* format = [UIGraphicsImageRendererFormat preferredFormat];
    format.scale = 1;
    format.opaque = YES;
    UIImage* small = [[[UIGraphicsImageRenderer alloc] initWithSize:size format:format]
        imageWithActions:^(UIGraphicsImageRendererContext* ctx) {
          [image drawInRect:CGRectMake(0, 0, size.width, size.height)];
        }];
    jpeg = UIImageJPEGRepresentation(small, 0.88);
    if (!jpeg) {
      if (error) *error = [NSError errorWithDomain:@"WinPadCovers" code:1 userInfo:@{NSLocalizedDescriptionKey : @"Obrázek se nedá uložit."}];
      return NO;
    }
  }
  for (NSString* f in [fm contentsOfDirectoryAtPath:dir error:nil])
    if ([@[ @"cover.png", @"cover.jpg", @"cover.jpeg" ] containsObject:f.lowercaseString])
      [fm removeItemAtPath:[dir stringByAppendingPathComponent:f] error:nil];
  if (!jpeg) {
    game.cover = nil;
    return YES;
  }
  if (![jpeg writeToFile:[dir stringByAppendingPathComponent:@"cover.jpg"] options:NSDataWritingAtomic error:error]) return NO;
  game.cover = [UIImage imageWithData:jpeg];
  return YES;
}

NSString* WinPadCoverQuery(WinPadGame* game) {
  NSString* t = game.title ?: game.folder ?: @"";
  t = [t stringByReplacingOccurrencesOfString:@"_" withString:@" "];
  // Dots between words ("Need.for.Speed"), not in "2.0".
  NSRegularExpression* dots = [NSRegularExpression regularExpressionWithPattern:@"(?<=\\D)\\.|\\.(?=\\D)" options:0 error:nil];
  t = [dots stringByReplacingMatchesInString:t options:0 range:NSMakeRange(0, t.length) withTemplate:@" "];
  // What a copy's folder name adds: (GOG), [Steam], v1.2...
  NSRegularExpression* extra = [NSRegularExpression
      regularExpressionWithPattern:@"\\s*[\\(\\[][^\\)\\]]*[\\)\\]]|\\b(gog|steam|repack|portable|v\\d+(\\.\\d+)*)\\b"
                           options:NSRegularExpressionCaseInsensitive
                             error:nil];
  t = [extra stringByReplacingMatchesInString:t options:0 range:NSMakeRange(0, t.length) withTemplate:@""];
  NSRegularExpression* spaces = [NSRegularExpression regularExpressionWithPattern:@"\\s+" options:0 error:nil];
  t = [spaces stringByReplacingMatchesInString:t options:0 range:NSMakeRange(0, t.length) withTemplate:@" "];
  t = [t stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
  return t.length ? t : (game.title ?: @"");
}

long WinPadSteamAppId(WinPadGame* game) {
  id setting = game.settings[@"steamAppId"];
  if ([setting respondsToSelector:@selector(longValue)] && [setting longValue] > 0) return [setting longValue];
  NSString* text = [NSString stringWithContentsOfFile:[GameDir(game) stringByAppendingPathComponent:@"steam_appid.txt"]
                                             encoding:NSUTF8StringEncoding
                                                error:nil];
  const long app_id = text.integerValue;
  return app_id > 0 ? app_id : 0;
}

// The words of S in lower case, letters and digits only, without accents, roman numbers as
// digits ("Mafia II" = "mafia 2") and without "the", ":" and the like.
static NSString* Normal(NSString* s) {
  s = [[s stringByFoldingWithOptions:NSCaseInsensitiveSearch | NSDiacriticInsensitiveSearch locale:nil] lowercaseString];
  NSMutableArray* words = [NSMutableArray new];
  NSDictionary* roman = @{@"ii" : @"2", @"iii" : @"3", @"iv" : @"4", @"v" : @"5", @"vi" : @"6"};
  for (NSString* w in [s componentsSeparatedByCharactersInSet:NSCharacterSet.alphanumericCharacterSet.invertedSet]) {
    if (!w.length || [@[ @"the", @"a", @"of", @"video", @"game", @"edition" ] containsObject:w]) continue;
    [words addObject:roman[w] ?: w];
  }
  return [words componentsJoinedByString:@" "];
}

// A cover surely of the game: its name is the title, with at most a subtitle after it
// ("Mafia" for "Mafia: The City of Lost Heaven" is not sure; "Mafia: The City of Lost
// Heaven" for "Mafia" is). Wikipedia adds "(2004 video game)".
static BOOL SureMatch(NSString* title, WinPadCover* cover) {
  NSString* name = cover.name;
  if ([cover.source isEqualToString:@"Wikipedie"]) {
    NSRange paren = [name rangeOfString:@" ("];
    if (paren.location != NSNotFound) name = [name substringToIndex:paren.location];
  }
  NSString *t = Normal(title), *n = Normal(name);
  if (!t.length || !n.length) return NO;
  if ([t isEqualToString:n]) return YES;
  // The title and then a subtitle; a sequel number after it is not a subtitle.
  if ([n hasPrefix:[t stringByAppendingString:@" "]]) {
    NSString* rest = [n substringFromIndex:t.length + 1];
    return !isdigit((int)[rest characterAtIndex:0]) && ![rest hasPrefix:@"remaster"] && ![rest hasPrefix:@"definitive"];
  }
  return NO;
}

BOOL WinPadAutoCoversWanted(void) {
  id on = [NSUserDefaults.standardUserDefaults objectForKey:@"coverAuto"];
  return !on || [on boolValue];
}

// One search at a time: the library reloads each time the app comes back.
static BOOL auto_running;

static void AutoNext(NSMutableArray<WinPadGame*>* todo, void (^changed)(WinPadGame*)) {
  if (!todo.count) {
    auto_running = NO;
    return;
  }
  WinPadGame* game = todo.firstObject;
  [todo removeObjectAtIndex:0];
  NSString* query = WinPadCoverQuery(game);
  const long app = WinPadSteamAppId(game);
  void (^tried)(void) = ^{
    NSMutableArray* list = [[NSUserDefaults.standardUserDefaults stringArrayForKey:@"coverTried"] mutableCopy] ?: [NSMutableArray new];
    if (![list containsObject:game.folder]) [list addObject:game.folder];
    [NSUserDefaults.standardUserDefaults setObject:list forKey:@"coverTried"];
  };
  WinPadFindCovers(query, app, ^(NSArray<WinPadCover*>* covers, NSError* error) {
    if (error) {
      // No internet: the next launch tries again.
      NSLog(@"WinPad Wine: covers for %@: %@", game.folder, error.localizedDescription);
      auto_running = NO;
      return;
    }
    WinPadCover* pick = nil;
    for (WinPadCover* c in covers) {
      // Steam's own game by its app id is sure, else the first sure name.
      if ((app && c == covers.firstObject && [c.source isEqualToString:@"Steam"] && !SteamGridDBKey()) || SureMatch(query, c)) {
        pick = c;
        break;
      }
    }
    if (!pick) {
      NSLog(@"WinPad Wine: covers for %@: none sure among %lu", game.folder, (unsigned long)covers.count);
      tried();
      AutoNext(todo, changed);
      return;
    }
    WinPadLoadCover(pick, NO, ^(UIImage* image, NSData* data) {
      if (image && !game.cover && WinPadSaveCover(game, image, nil)) {
        NSLog(@"WinPad Wine: cover for %@: %@ (%@)", game.folder, pick.name, pick.source);
        if (changed) changed(game);
      }
      if (image) tried();
      AutoNext(todo, changed);
    });
  });
}


void WinPadAutoCovers(NSArray<WinPadGame*>* games, void (^changed)(WinPadGame*)) {
  if (!WinPadAutoCoversWanted() || auto_running) return;
  NSArray* tried = [NSUserDefaults.standardUserDefaults stringArrayForKey:@"coverTried"] ?: @[];
  NSMutableArray* todo = [NSMutableArray new];
  for (WinPadGame* g in games)
    if (!g.cover && ![tried containsObject:g.folder]) [todo addObject:g];
  auto_running = todo.count > 0;
  AutoNext(todo, changed);
}

// ---- The picker ----

@interface WinPadCoverCell : UICollectionViewCell
@property(nonatomic, strong) UIImageView* picture;
@property(nonatomic, strong) UILabel* label;
@property(nonatomic, strong) UIActivityIndicatorView* spinner;
@property(nonatomic, strong) WinPadCover* cover;
@end

@implementation WinPadCoverCell
- (instancetype)initWithFrame:(CGRect)frame {
  if (!(self = [super initWithFrame:frame])) return nil;
  self.picture = [UIImageView new];
  self.picture.contentMode = UIViewContentModeScaleAspectFill;
  self.picture.clipsToBounds = YES;
  self.picture.layer.cornerRadius = 6;
  self.picture.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
  [self.contentView addSubview:self.picture];
  self.label = [UILabel new];
  self.label.font = [UIFont systemFontOfSize:12];
  self.label.textColor = [UIColor colorWithWhite:0.86 alpha:1];
  self.label.numberOfLines = 2;
  [self.contentView addSubview:self.label];
  self.spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleMedium];
  [self.contentView addSubview:self.spinner];
  return self;
}

- (void)layoutSubviews {
  [super layoutSubviews];
  const CGRect b = self.contentView.bounds;
  self.picture.frame = CGRectMake(0, 0, b.size.width, b.size.height - 34);
  self.label.frame = CGRectMake(2, b.size.height - 32, b.size.width - 4, 32);
  self.spinner.center = self.picture.center;
}

- (void)setSelected:(BOOL)selected {
  [super setSelected:selected];
  self.picture.layer.borderWidth = selected ? 3 : 0;
  self.picture.layer.borderColor = UIColor.whiteColor.CGColor;
}
@end

@interface WinPadCoverPickerViewController () <UICollectionViewDataSource, UICollectionViewDelegate, UISearchBarDelegate,
                                               PHPickerViewControllerDelegate>
@property(nonatomic, strong) WinPadGame* game;
@property(nonatomic, strong) UISearchBar* search;
@property(nonatomic, strong) UICollectionView* grid;
@property(nonatomic, strong) UILabel* status;
@property(nonatomic, strong) UIActivityIndicatorView* busy;
@property(nonatomic, copy) NSArray<WinPadCover*>* covers;
@property(nonatomic, strong) NSCache<WinPadCover*, UIImage*>* thumbs;
@property(nonatomic) NSUInteger searchId;
- (void)find;
- (void)use:(UIImage*)image;
@end

@implementation WinPadCoverPickerViewController
- (instancetype)initWithGame:(WinPadGame*)game {
  if (!(self = [super initWithNibName:nil bundle:nil])) return nil;
  self.game = game;
  self.thumbs = [NSCache new];
  return self;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = [@"Obal: " stringByAppendingString:self.game.title];
  self.view.backgroundColor = [UIColor colorWithRed:0.04 green:0.06 blue:0.1 alpha:1];
  self.navigationItem.leftBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemCancel
                                                                                        target:self
                                                                                        action:@selector(close)];
  UIBarButtonItem* photos = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"photo.on.rectangle"]
                                                             style:UIBarButtonItemStylePlain
                                                            target:self
                                                            action:@selector(fromPhotos)];
  photos.accessibilityLabel = @"Obrázek z Fotek";
  UIBarButtonItem* remove = [[UIBarButtonItem alloc] initWithImage:[UIImage systemImageNamed:@"trash"]
                                                             style:UIBarButtonItemStylePlain
                                                            target:self
                                                            action:@selector(removeCover)];
  remove.accessibilityLabel = @"Odebrat obal";
  remove.enabled = self.game.cover != nil;
  self.navigationItem.rightBarButtonItems = @[ photos, remove ];

  self.search = [UISearchBar new];
  self.search.searchBarStyle = UISearchBarStyleMinimal;
  self.search.placeholder = @"Název hry";
  self.search.text = WinPadCoverQuery(self.game);
  self.search.delegate = self;
  self.search.returnKeyType = UIReturnKeySearch;
  [self.view addSubview:self.search];

  UICollectionViewFlowLayout* layout = [UICollectionViewFlowLayout new];
  layout.itemSize = CGSizeMake(140, 140 * 1.5 + 34);
  layout.minimumInteritemSpacing = 14;
  layout.minimumLineSpacing = 18;
  layout.sectionInset = UIEdgeInsetsMake(8, 16, 24, 16);
  self.grid = [[UICollectionView alloc] initWithFrame:CGRectZero collectionViewLayout:layout];
  self.grid.backgroundColor = UIColor.clearColor;
  self.grid.dataSource = self;
  self.grid.delegate = self;
  self.grid.keyboardDismissMode = UIScrollViewKeyboardDismissModeOnDrag;
  [self.grid registerClass:WinPadCoverCell.class forCellWithReuseIdentifier:@"cover"];
  [self.view addSubview:self.grid];

  self.status = [UILabel new];
  self.status.numberOfLines = 0;
  self.status.textAlignment = NSTextAlignmentCenter;
  self.status.textColor = [UIColor colorWithWhite:0.75 alpha:1];
  self.status.font = [UIFont systemFontOfSize:15];
  [self.view addSubview:self.status];
  self.busy = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleLarge];
  self.busy.hidesWhenStopped = YES;
  [self.view addSubview:self.busy];
  [self find];
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  const CGRect b = self.view.bounds;
  const UIEdgeInsets safe = self.view.safeAreaInsets;
  self.search.frame = CGRectMake(safe.left + 8, safe.top + 4, b.size.width - safe.left - safe.right - 16, 52);
  const CGFloat y = CGRectGetMaxY(self.search.frame) + 4;
  self.grid.frame = CGRectMake(safe.left, y, b.size.width - safe.left - safe.right, b.size.height - y);
  self.status.frame = CGRectMake(safe.left + 24, y + 40, b.size.width - safe.left - safe.right - 48, 120);
  self.busy.center = CGPointMake(CGRectGetMidX(b), y + 100);
}

- (void)close {
  [self dismissViewControllerAnimated:YES completion:nil];
}

- (void)find {
  const NSUInteger mine = ++self.searchId;
  self.covers = @[];
  [self.grid reloadData];
  self.status.text = @"";
  [self.busy startAnimating];
  NSString* query = self.search.text;
  // The game's app id only while it is searched by its own title.
  const long app = [query isEqualToString:WinPadCoverQuery(self.game)] ? WinPadSteamAppId(self.game) : 0;
  __weak WinPadCoverPickerViewController* weak = self;
  WinPadFindCovers(query, app, ^(NSArray<WinPadCover*>* covers, NSError* error) {
    WinPadCoverPickerViewController* me = weak;
    if (!me || me.searchId != mine) return;
    [me.busy stopAnimating];
    me.covers = covers;
    [me.grid reloadData];
    if (error)
      me.status.text = [NSString stringWithFormat:@"Obaly se nepodařilo najít (%@). Je iPad připojený k internetu?", error.localizedDescription];
    else if (!covers.count)
      me.status.text = @"Pro tenhle název se nic nenašlo. Zkus ho napsat jinak, třeba celý anglický název hry.";
    else
      me.status.text = @"";
  });
}

- (void)searchBarSearchButtonClicked:(UISearchBar*)searchBar {
  [searchBar resignFirstResponder];
  [self find];
}

- (NSInteger)collectionView:(UICollectionView*)view numberOfItemsInSection:(NSInteger)section {
  return (NSInteger)self.covers.count;
}

- (UICollectionViewCell*)collectionView:(UICollectionView*)view cellForItemAtIndexPath:(NSIndexPath*)path {
  WinPadCoverCell* cell = [view dequeueReusableCellWithReuseIdentifier:@"cover" forIndexPath:path];
  WinPadCover* cover = self.covers[(NSUInteger)path.item];
  cell.cover = cover;
  cell.label.text = [NSString stringWithFormat:@"%@\n%@", cover.name, cover.source];
  UIImage* thumb = [self.thumbs objectForKey:cover];
  cell.picture.image = thumb;
  if (thumb) {
    [cell.spinner stopAnimating];
    return cell;
  }
  [cell.spinner startAnimating];
  __weak WinPadCoverCell* weak_cell = cell;
  __weak WinPadCoverPickerViewController* weak = self;
  WinPadLoadCover(cover, YES, ^(UIImage* image, NSData* data) {
    if (image) [weak.thumbs setObject:image forKey:cover];
    WinPadCoverCell* c = weak_cell;
    if (c.cover != cover) return;
    [c.spinner stopAnimating];
    c.picture.image = image;
    if (!image) c.label.text = [NSString stringWithFormat:@"%@\n%@ · obrázek není", cover.name, cover.source];
  });
  return cell;
}

- (void)collectionView:(UICollectionView*)view didSelectItemAtIndexPath:(NSIndexPath*)path {
  WinPadCover* cover = self.covers[(NSUInteger)path.item];
  [self.busy startAnimating];
  self.view.userInteractionEnabled = NO;
  __weak WinPadCoverPickerViewController* weak = self;
  WinPadLoadCover(cover, NO, ^(UIImage* image, NSData* data) {
    WinPadCoverPickerViewController* me = weak;
    if (!me) return;
    [me.busy stopAnimating];
    me.view.userInteractionEnabled = YES;
    if (!image) {
      me.status.text = @"Tenhle obrázek se nepodařilo stáhnout, zkus jiný.";
      return;
    }
    [me use:image];
  });
}

- (void)use:(UIImage*)image {
  NSError* error = nil;
  if (!WinPadSaveCover(self.game, image, &error)) {
    self.status.text = [@"Obal se nepodařilo uložit: " stringByAppendingString:error.localizedDescription ?: @"?"];
    return;
  }
  void (^saved)(void) = self.saved;
  [self dismissViewControllerAnimated:YES completion:^{
    if (saved) saved();
  }];
}

- (void)removeCover {
  [self use:nil];
}

- (void)fromPhotos {
  PHPickerConfiguration* config = [PHPickerConfiguration new];
  config.filter = PHPickerFilter.imagesFilter;
  config.selectionLimit = 1;
  PHPickerViewController* picker = [[PHPickerViewController alloc] initWithConfiguration:config];
  picker.delegate = self;
  [self presentViewController:picker animated:YES completion:nil];
}

- (void)picker:(PHPickerViewController*)picker didFinishPicking:(NSArray<PHPickerResult*>*)results {
  [picker dismissViewControllerAnimated:YES completion:nil];
  NSItemProvider* item = results.firstObject.itemProvider;
  if (![item canLoadObjectOfClass:UIImage.class]) return;
  __weak WinPadCoverPickerViewController* weak = self;
  [item loadObjectOfClass:UIImage.class
        completionHandler:^(id<NSItemProviderReading> object, NSError* error) {
          if (![(NSObject*)object isKindOfClass:UIImage.class]) return;
          dispatch_async(dispatch_get_main_queue(), ^{
            [weak use:(UIImage*)object];
          });
        }];
}
@end
