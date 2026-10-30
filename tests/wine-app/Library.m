// SPDX-License-Identifier: MIT
// WinPad Wine's game library: the screen the app opens on, like a console's.
// It lists the games copied into the app's Documents (Finder → the iPad →
// Files → WinPad Wine), one per folder: the folder's winpad.json may name the
// game ("title") and its program ("exe"), else the folder's name is the title
// and its largest .exe that is no installer or helper is the program. Its
// cover is cover.png or cover.jpg in the folder. A game's AOT image is
// Frameworks/fexaot-FOLDER.dylib (WinPadGameImage), else fexaot-game.dylib,
// the one tests/wine-app/game-aot.sh makes. So one app holds the images of
// any number of games (WinPad Translator's library writes them into one IPA).
// An image in the game folder itself, fexaot.dylib, comes first: WinPad
// Translator signs it on the Mac with the developer identity the app is
// signed with (--sign-identity), so a game is added without installing the
// app again. It is used only when its fexaot.build names this build of the
// app (winpad-build.txt in the bundle), and main.m falls back to the bundle's
// image if iOS refuses to load it.
//
// It looks like a console's home screen: a row of square tiles, the focused
// one large with a white frame and its title, tags and Spustit below, on a
// backdrop picked in the settings (Nastavení › Vzhled: four glows, the
// focused game's cover blurred, or a picture of the user's own, with or
// without the waves). On an iPhone, which runs it on its side, everything is
// smaller. A game controller (the d-pad or left stick picks, A starts, Y
// opens the settings, B closes them), a hardware keyboard (arrows, Enter) or
// a tap picks and starts one. Wine runs once per process, so a game starts in
// place of the library (main.m) and the app is started again for the next.
//
// With the "libraryTest" setting (CI, tests/wine-app/build-xcode.sh) the
// library writes the games it found to Documents/library.txt, then presses
// right and A.
#import "Library.h"

#import <GameController/GameController.h>
#import <PhotosUI/PhotosUI.h>

#include <math.h>
#include <string.h>

static NSString* Documents(void) {
  return NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
}

static UIColor* Hex(uint32_t rgb) {
  return [UIColor colorWithRed:((rgb >> 16) & 255) / 255.0 green:((rgb >> 8) & 255) / 255.0 blue:(rgb & 255) / 255.0 alpha:1];
}

@implementation WinPadGame
@end

// Frameworks/fexaot-FOLDER.dylib, FOLDER in lower case with each run of other
// characters than letters and digits one "-"; else fexaot-game.dylib; else nil.
static NSString* WinPadGameImage(NSString* folder) {
  NSString* lower = folder.lowercaseString;
  NSMutableString* slug = [NSMutableString new];
  BOOL dash = NO;
  for (NSUInteger i = 0; i < lower.length; i++) {
    const unichar c = [lower characterAtIndex:i];
    if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')) {
      if (dash && slug.length) [slug appendString:@"-"];
      dash = NO;
      [slug appendFormat:@"%C", c];
    } else {
      dash = YES;
    }
  }
  NSString* frameworks = NSBundle.mainBundle.privateFrameworksPath;
  for (NSString* name in @[ [NSString stringWithFormat:@"fexaot-%@.dylib", slug], @"fexaot-game.dylib" ]) {
    NSString* path = [frameworks stringByAppendingPathComponent:name];
    if ([NSFileManager.defaultManager fileExistsAtPath:path]) return path;
  }
  return nil;
}

// The build of this app (build-xcode.sh's winpad-build.txt), or nil.
static NSString* AppBuild(void) {
  NSString* path = [NSBundle.mainBundle.bundlePath stringByAppendingPathComponent:@"winpad-build.txt"];
  NSString* build = [NSString stringWithContentsOfFile:path encoding:NSUTF8StringEncoding error:nil];
  build = [build stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  return build.length ? build : nil;
}

// The game folder's own image, if it is for this build of the app; else nil, with why in *note.
static NSString* FolderImage(NSString* dir, NSString** note) {
  NSString* image = [dir stringByAppendingPathComponent:@"fexaot.dylib"];
  if (![NSFileManager.defaultManager fileExistsAtPath:image]) return nil;
  NSString* app = AppBuild();
  NSString* made = [NSString stringWithContentsOfFile:[dir stringByAppendingPathComponent:@"fexaot.build"]
                                             encoding:NSUTF8StringEncoding
                                                error:nil];
  made = [made stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
  if (app && ![made isEqualToString:app]) {
    *note = [NSString stringWithFormat:@"fexaot.dylib is for app build %@, this is %@", made.length ? made : @"?", app];
    return nil;
  }
  return image;
}

// An installer, an uninstaller, a settings tool and the like, by its name.
static BOOL HelperProgram(NSString* name) {
  NSString* lower = name.lowercaseString;
  for (NSString* word in @[ @"setup", @"unins", @"install", @"config", @"crash", @"update", @"redist", @"register", @"patch" ])
    if ([lower containsString:word]) return YES;
  return NO;
}

// "32bit" or "64bit" from a Windows program's PE header, or nil.
static NSString* ProgramArch(NSString* path) {
  NSFileHandle* f = [NSFileHandle fileHandleForReadingAtPath:path];
  NSData* head = [f readDataOfLength:4096];
  [f closeFile];
  if (head.length < 64) return nil;
  const uint8_t* b = head.bytes;
  const uint32_t pe = b[0x3c] | b[0x3d] << 8 | b[0x3e] << 16 | (uint32_t)b[0x3f] << 24;
  if (pe > head.length - 6 || memcmp(b + pe, "PE\0\0", 4)) return nil;
  const uint16_t machine = b[pe + 4] | b[pe + 5] << 8;
  return machine == 0x14c ? @"32bit" : machine == 0x8664 ? @"64bit" : nil;
}

NSArray<WinPadGame*>* WinPadFindGames(void) {
  NSFileManager* fm = NSFileManager.defaultManager;
  NSString* docs = Documents();
  NSMutableArray<WinPadGame*>* games = [NSMutableArray new];
  NSArray* folders = [[fm contentsOfDirectoryAtPath:docs error:nil] sortedArrayUsingSelector:@selector(localizedCaseInsensitiveCompare:)];
  for (NSString* folder in folders) {
    // The app's own folders (main.m): the Wine prefix, FEX's caches, the window's frames.
    if ([folder hasPrefix:@"."] || [@[ @"prefix", @"fexcache", @"frames" ] containsObject:folder]) continue;
    NSString* dir = [docs stringByAppendingPathComponent:folder];
    BOOL is_dir = NO;
    if (![fm fileExistsAtPath:dir isDirectory:&is_dir] || !is_dir) continue;
    NSArray* files = [fm contentsOfDirectoryAtPath:dir error:nil];
    NSDictionary* info = nil;
    NSData* json = [NSData dataWithContentsOfFile:[dir stringByAppendingPathComponent:@"winpad.json"]];
    if (json) {
      id obj = [NSJSONSerialization JSONObjectWithData:json options:0 error:nil];
      if ([obj isKindOfClass:NSDictionary.class]) info = obj;
    }
    NSString* exe = [info[@"exe"] isKindOfClass:NSString.class] ? info[@"exe"] : nil;
    if (exe && ([exe containsString:@".."] || ![fm fileExistsAtPath:[dir stringByAppendingPathComponent:exe]])) exe = nil;
    if (!exe) {
      unsigned long long best = 0;
      BOOL best_helper = YES;
      for (NSString* f in files) {
        if (![f.pathExtension.lowercaseString isEqualToString:@"exe"]) continue;
        const unsigned long long size = [fm attributesOfItemAtPath:[dir stringByAppendingPathComponent:f] error:nil].fileSize;
        const BOOL helper = HelperProgram(f);
        if (!exe || (best_helper && !helper) || (helper == best_helper && size > best)) {
          exe = f;
          best = size;
          best_helper = helper;
        }
      }
    }
    if (!exe) continue;
    WinPadGame* game = [WinPadGame new];
    game.folder = folder;
    game.exe = [folder stringByAppendingPathComponent:exe];
    NSString* title = [info[@"title"] isKindOfClass:NSString.class] ? info[@"title"] : nil;
    game.title = title.length ? title : folder;
    game.arch = ProgramArch([docs stringByAppendingPathComponent:game.exe]);
    game.bundleImage = WinPadGameImage(folder);
    NSString* note = nil;
    NSString* own = FolderImage(dir, &note);
    game.image = own ?: game.bundleImage;
    game.imageInFolder = own != nil;
    game.folderImageNote = note;
    for (NSString* f in files) {
      if ([@[ @"cover.png", @"cover.jpg", @"cover.jpeg" ] containsObject:f.lowercaseString]) {
        game.cover = [UIImage imageWithContentsOfFile:[dir stringByAppendingPathComponent:f]];
        break;
      }
    }
    [games addObject:game];
  }
  return games;
}

// The controller's inputs, named as on an Xbox controller: their names in the settings and in the
// "padKeys" setting (the first names, kept from before), and the keys they are by default: the
// left stick and d-pad steer, RT accelerates and LT brakes; the right stick is no key.
static NSString* const PadTitles[PadCount] = {
    @"Nahoru", @"Dolů", @"Doleva", @"Doprava", @"A", @"B", @"X", @"Y", @"LB", @"RB", @"LT", @"RT", @"Menu", @"View",
    @"Pravá páčka nahoru", @"Pravá páčka dolů", @"Pravá páčka doleva", @"Pravá páčka doprava"};
static NSString* const PadIds[PadCount] = {@"up", @"down", @"left", @"right", @"a",  @"b",    @"x",       @"y",
                                           @"l1", @"r1",   @"l2",   @"r2",    @"menu", @"options", @"rup", @"rdown",
                                           @"rleft", @"rright"};
static const unsigned short PadDefaults[PadCount] = {0x26, 0x28, 0x25, 0x27, 0x0d, 0x1b, 0x20, 'C', 'Z',
                                                     'A',  0x28, 0x26, 0x1b, 0x0d, 0,    0,    0,    0};

void WinPadPadKeys(unsigned short keys[PadCount]) {
  NSDictionary* saved = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"padKeys"];
  for (int i = 0; i < PadCount; i++) {
    id key = saved[PadIds[i]];
    keys[i] = [key respondsToSelector:@selector(intValue)] ? (unsigned short)([key intValue] & 0xff) : PadDefaults[i];
  }
}

static void SavePadKey(int input, unsigned short vk) {
  NSMutableDictionary* saved = [[NSUserDefaults.standardUserDefaults dictionaryForKey:@"padKeys"] mutableCopy] ?: [NSMutableDictionary new];
  saved[PadIds[input]] = @(vk);
  [NSUserDefaults.standardUserDefaults setObject:saved forKey:@"padKeys"];
}

// The keys an input can be: those a game is most likely to use.
static NSArray<NSNumber*>* KeyChoices(void) {
  NSMutableArray* keys = [@[ @0x26, @0x28, @0x25, @0x27, @0x0d, @0x1b, @0x20, @0x10, @0x11, @0x12, @0x09, @0x08 ] mutableCopy];
  for (int c = 'A'; c <= 'Z'; c++) [keys addObject:@(c)];
  for (int c = '0'; c <= '9'; c++) [keys addObject:@(c)];
  for (int f = 0; f < 12; f++) [keys addObject:@(0x70 + f)];
  [keys addObject:@0];
  return keys;
}

static NSString* KeyName(unsigned short vk) {
  switch (vk) {
    case 0: return @"Nic";
    case 0x26: return @"Šipka nahoru";
    case 0x28: return @"Šipka dolů";
    case 0x25: return @"Šipka doleva";
    case 0x27: return @"Šipka doprava";
    case 0x0d: return @"Enter";
    case 0x1b: return @"Esc";
    case 0x20: return @"Mezerník";
    case 0x10: return @"Shift";
    case 0x11: return @"Ctrl";
    case 0x12: return @"Alt";
    case 0x09: return @"Tab";
    case 0x08: return @"Backspace";
  }
  if ((vk >= 'A' && vk <= 'Z') || (vk >= '0' && vk <= '9')) return [NSString stringWithFormat:@"%c", vk];
  if (vk >= 0x70 && vk < 0x7c) return [NSString stringWithFormat:@"F%d", vk - 0x70 + 1];
  return [NSString stringWithFormat:@"Klávesa 0x%02x", vk];
}

// Picks the key of one input.
@interface WinPadKeyPickerViewController : UITableViewController
@property(nonatomic) int input;
@end

@implementation WinPadKeyPickerViewController
- (instancetype)init {
  return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = PadTitles[self.input];
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
  return (NSInteger)KeyChoices().count;
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)path {
  UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
  unsigned short keys[PadCount];
  WinPadPadKeys(keys);
  const unsigned short vk = KeyChoices()[path.row].unsignedShortValue;
  cell.textLabel.text = KeyName(vk);
  cell.accessoryType = vk == keys[self.input] ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
  return cell;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)path {
  SavePadKey(self.input, KeyChoices()[path.row].unsignedShortValue);
  [self.navigationController popViewControllerAnimated:YES];
}
@end

// A label with room around its text: the game's tags.
@interface WinPadTag : UILabel
@end

@implementation WinPadTag
- (CGSize)intrinsicContentSize {
  const CGSize s = super.intrinsicContentSize;
  return CGSizeMake(s.width + 24, s.height + 12);
}

- (void)drawTextInRect:(CGRect)rect {
  [super drawTextInRect:UIEdgeInsetsInsetRect(rect, UIEdgeInsetsMake(6, 12, 6, 12))];
}
@end

static WinPadTag* Tag(NSString* text, uint32_t fg, uint32_t bg) {
  WinPadTag* tag = [WinPadTag new];
  tag.text = text;
  tag.font = [UIFont systemFontOfSize:15];
  tag.textColor = Hex(fg);
  tag.backgroundColor = Hex(bg);
  tag.layer.cornerRadius = 8;
  tag.layer.masksToBounds = YES;
  return tag;
}

// A cover: the game's picture, else its title on a plain panel.
static void ShowCover(UIImageView* view, UILabel* placeholder, WinPadGame* game) {
  view.image = game.cover;
  placeholder.hidden = game.cover != nil;
  placeholder.text = game.title;
}

static UIImageView* CoverView(UILabel** placeholder, CGFloat font) {
  UIImageView* view = [UIImageView new];
  view.contentMode = UIViewContentModeScaleAspectFill;
  view.clipsToBounds = YES;
  view.backgroundColor = Hex(0x1E2633);
  UILabel* label = [UILabel new];
  label.textColor = Hex(0xB4BDCA);
  label.font = [UIFont systemFontOfSize:font weight:UIFontWeightSemibold];
  label.textAlignment = NSTextAlignmentCenter;
  label.numberOfLines = 0;
  label.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  [view addSubview:label];
  *placeholder = label;
  return view;
}

// The backgrounds the library and the settings can have (Nastavení › Vzhled, the "background"
// setting): a glow from the top left in three shades, the focused game's cover blurred, or
// the user's own picture, Documents/background.jpg (from Photos in the settings, or copied in).
typedef struct {
  const char* id;
  const char* name;
  uint32_t glow, mid, edge;
} WinPadBackground;
static const WinPadBackground Backgrounds[] = {
    {"blue", "Modrá vlna", 0x1B4F9C, 0x0B2A63, 0x04122E},
    {"midnight", "Půlnoc", 0x2A3142, 0x12161F, 0x06080C},
    {"dusk", "Fialový soumrak", 0x6A35A0, 0x2E1858, 0x0E0620},
    {"emerald", "Smaragd", 0x1F7A5A, 0x0E3D2E, 0x04140F},
    {"cover", "Obal vybrané hry", 0x3B4250, 0x1A1E26, 0x0A0E16},
    {"custom", "Vlastní obrázek", 0x3A3F4A, 0x1A1D24, 0x0A0C10},
};
enum { BackgroundCount = sizeof(Backgrounds) / sizeof(Backgrounds[0]) };

static NSString* CustomBackgroundPath(void) {
  return [Documents() stringByAppendingPathComponent:@"background.jpg"];
}

static const WinPadBackground* CurrentBackground(void) {
  NSString* saved = [NSUserDefaults.standardUserDefaults stringForKey:@"background"];
  for (int i = 0; i < BackgroundCount; i++)
    if ([saved isEqualToString:@(Backgrounds[i].id)]) return &Backgrounds[i];
  return &Backgrounds[0];
}

static BOOL BackgroundWaves(void) {
  id waves = [NSUserDefaults.standardUserDefaults objectForKey:@"backgroundWaves"];
  return !waves || [waves boolValue];
}

// The background itself; it follows the settings as they change.
@interface WinPadBackdrop : UIView
@property(nonatomic, strong) UIImage* cover;  // the focused game's cover, for the "cover" background
@end

@interface WinPadBackdrop ()
@property(nonatomic, strong) CAGradientLayer* glow;
@property(nonatomic, strong) UIImageView* picture;
@property(nonatomic, strong) UIVisualEffectView* blur;
@property(nonatomic, strong) UIView* dim;
@property(nonatomic, strong) CAShapeLayer* wave1;
@property(nonatomic, strong) CAShapeLayer* wave2;
@property(nonatomic, strong) id observer;
- (void)refresh;
@end

@implementation WinPadBackdrop
- (instancetype)initWithFrame:(CGRect)frame {
  self = [super initWithFrame:frame];
  self.userInteractionEnabled = NO;
  self.clipsToBounds = YES;
  self.glow = [CAGradientLayer layer];
  self.glow.type = kCAGradientLayerRadial;
  self.glow.startPoint = CGPointMake(0.2, 0);
  self.glow.endPoint = CGPointMake(1.4, 0.9);
  self.glow.locations = @[ @0, @0.45, @1 ];
  [self.layer addSublayer:self.glow];
  self.picture = [UIImageView new];
  self.picture.contentMode = UIViewContentModeScaleAspectFill;
  [self addSubview:self.picture];
  self.blur = [[UIVisualEffectView alloc] initWithEffect:[UIBlurEffect effectWithStyle:UIBlurEffectStyleDark]];
  [self addSubview:self.blur];
  self.dim = [UIView new];
  self.dim.backgroundColor = [UIColor colorWithWhite:0 alpha:0.45];
  [self addSubview:self.dim];
  self.wave1 = [CAShapeLayer layer];
  self.wave2 = [CAShapeLayer layer];
  for (CAShapeLayer* wave in @[ self.wave1, self.wave2 ]) {
    wave.fillColor = UIColor.clearColor.CGColor;
    wave.lineWidth = 2;
    [self.layer addSublayer:wave];
  }
  self.wave1.strokeColor = [Hex(0x7FB2FF) colorWithAlphaComponent:0.18].CGColor;
  self.wave2.strokeColor = [Hex(0x7FB2FF) colorWithAlphaComponent:0.10].CGColor;
  __weak WinPadBackdrop* weak = self;
  self.observer = [NSNotificationCenter.defaultCenter addObserverForName:NSUserDefaultsDidChangeNotification
                                                                  object:nil
                                                                   queue:NSOperationQueue.mainQueue
                                                              usingBlock:^(NSNotification* note) {
                                                                [weak refresh];
                                                              }];
  [self refresh];
  return self;
}

- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self.observer];
}

- (void)setCover:(UIImage*)cover {
  _cover = cover;
  [self refresh];
}

- (void)refresh {
  const WinPadBackground* bg = CurrentBackground();
  self.glow.colors = @[ (id)Hex(bg->glow).CGColor, (id)Hex(bg->mid).CGColor, (id)Hex(bg->edge).CGColor ];
  UIImage* picture = nil;
  if (!strcmp(bg->id, "cover")) picture = self.cover;
  if (!strcmp(bg->id, "custom")) picture = [UIImage imageWithContentsOfFile:CustomBackgroundPath()];
  self.picture.image = picture;
  self.picture.hidden = self.dim.hidden = !picture;
  // A cover is blurred to a backdrop; the user's own picture shows as it is, a little darker.
  self.blur.hidden = !picture || strcmp(bg->id, "cover");
  self.wave1.hidden = self.wave2.hidden = !BackgroundWaves();
}

- (void)layoutSubviews {
  [super layoutSubviews];
  const CGRect b = self.bounds;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  self.glow.frame = b;
  const CGFloat w = b.size.width, h = b.size.height;
  for (int i = 0; i < 2; i++) {
    const CGFloat y = h * (0.70 + 0.04 * i);
    UIBezierPath* path = [UIBezierPath bezierPath];
    [path moveToPoint:CGPointMake(0, y)];
    [path addCurveToPoint:CGPointMake(w * 0.66, y + h * 0.01) controlPoint1:CGPointMake(w * 0.23, y - h * 0.08)
            controlPoint2:CGPointMake(w * 0.45, y + h * 0.12)];
    [path addCurveToPoint:CGPointMake(w, y - h * 0.02) controlPoint1:CGPointMake(w * 0.85, y - h * 0.08)
            controlPoint2:CGPointMake(w * 0.95, y - h * 0.05)];
    (i ? self.wave2 : self.wave1).path = path.CGPath;
  }
  [CATransaction commit];
  self.picture.frame = self.blur.frame = self.dim.frame = b;
}
@end

// Picks the background: one of Backgrounds, a picture from Photos for "custom".
@interface WinPadBackgroundViewController : UITableViewController <PHPickerViewControllerDelegate>
@end

@implementation WinPadBackgroundViewController
- (instancetype)init {
  return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Pozadí";
  self.tableView.backgroundView = [WinPadBackdrop new];
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
  return BackgroundCount;
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
  return @"Vlastní obrázek vybereš z Fotek, nebo ho nahraj jako background.jpg do Soubory › WinPad Wine.";
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)path {
  UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleDefault reuseIdentifier:nil];
  const WinPadBackground* bg = &Backgrounds[path.row];
  cell.textLabel.text = @(bg->name);
  cell.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
  // A swatch of its colours.
  UIGraphicsImageRenderer* r = [[UIGraphicsImageRenderer alloc] initWithSize:CGSizeMake(44, 30)];
  cell.imageView.image = [r imageWithActions:^(UIGraphicsImageRendererContext* ctx) {
    CGColorSpaceRef space = CGColorSpaceCreateDeviceRGB();
    CGGradientRef g = CGGradientCreateWithColors(
        space, (__bridge CFArrayRef) @[ (id)Hex(bg->glow).CGColor, (id)Hex(bg->mid).CGColor, (id)Hex(bg->edge).CGColor ], NULL);
    [[UIBezierPath bezierPathWithRoundedRect:CGRectMake(0, 0, 44, 30) cornerRadius:5] addClip];
    CGContextDrawRadialGradient(ctx.CGContext, g, CGPointMake(8, 0), 0, CGPointMake(8, 0), 52, kCGGradientDrawsAfterEndLocation);
    CGGradientRelease(g);
    CGColorSpaceRelease(space);
  }];
  cell.accessoryType = bg == CurrentBackground() ? UITableViewCellAccessoryCheckmark : UITableViewCellAccessoryNone;
  return cell;
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)path {
  [tableView deselectRowAtIndexPath:path animated:YES];
  const WinPadBackground* bg = &Backgrounds[path.row];
  if (!strcmp(bg->id, "custom")) {
    PHPickerConfiguration* config = [PHPickerConfiguration new];
    config.filter = PHPickerFilter.imagesFilter;
    config.selectionLimit = 1;
    PHPickerViewController* picker = [[PHPickerViewController alloc] initWithConfiguration:config];
    picker.delegate = self;
    [self presentViewController:picker animated:YES completion:nil];
    return;
  }
  [NSUserDefaults.standardUserDefaults setObject:@(bg->id) forKey:@"background"];
  [tableView reloadData];
}

- (void)picker:(PHPickerViewController*)picker didFinishPicking:(NSArray<PHPickerResult*>*)results {
  [picker dismissViewControllerAnimated:YES completion:nil];
  NSItemProvider* item = results.firstObject.itemProvider;
  if (![item canLoadObjectOfClass:UIImage.class]) return;
  __weak WinPadBackgroundViewController* weak = self;
  [item loadObjectOfClass:UIImage.class
        completionHandler:^(id<NSItemProviderReading> object, NSError* error) {
          NSData* jpeg = [object isKindOfClass:UIImage.class] ? UIImageJPEGRepresentation((UIImage*)object, 0.9) : nil;
          dispatch_async(dispatch_get_main_queue(), ^{
            if (![jpeg writeToFile:CustomBackgroundPath() atomically:YES]) return;
            [NSUserDefaults.standardUserDefaults setObject:@"custom" forKey:@"background"];
            [weak.tableView reloadData];
          });
        }];
}
@end

// The settings: touch controls, the controller's keys, the last log, the test programs.
@interface WinPadLogViewController : UIViewController
@end

@implementation WinPadLogViewController
- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Poslední log";
  UITextView* text = [[UITextView alloc] initWithFrame:self.view.bounds];
  text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  text.editable = NO;
  text.font = [UIFont monospacedSystemFontOfSize:12 weight:UIFontWeightRegular];
  NSMutableString* all = [NSMutableString new];
  // main.m keeps the log of a run that stopped the app as wine.log.crashed.
  for (NSString* name in @[ @"wine.log", @"wine.log.crashed" ]) {
    NSString* log = [NSString stringWithContentsOfFile:[Documents() stringByAppendingPathComponent:name]
                                              encoding:NSUTF8StringEncoding
                                                 error:nil];
    if (log.length) [all appendFormat:@"== %@\n\n%@\n\n", name, log.length > 200000 ? [log substringFromIndex:log.length - 200000] : log];
  }
  text.text = all.length ? all : @"Zatím žádný log.";
  [self.view addSubview:text];
}
@end

// The settings' section 0 is the look; the others follow it, numbered from 0 after it in the code.
enum { AppearanceSection = 0 };

@interface WinPadSettingsViewController : UITableViewController
@property(nonatomic, copy) void (^run)(NSString* program);
@end

@implementation WinPadSettingsViewController
- (instancetype)init {
  return [super initWithStyle:UITableViewStyleInsetGrouped];
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.title = @"Nastavení";
  self.tableView.backgroundView = [WinPadBackdrop new];
  self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithBarButtonSystemItem:UIBarButtonSystemItemDone
                                                                                         target:self
                                                                                         action:@selector(done)];
}

// Back from a picker, which changed a key.
- (void)viewWillAppear:(BOOL)animated {
  [super viewWillAppear:animated];
  [self.tableView reloadData];
}

- (void)done {
  [self dismissViewControllerAnimated:YES completion:nil];
}

- (BOOL)hasWindowProgram {
  return [NSFileManager.defaultManager
      fileExistsAtPath:[NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"fexaot-window.dylib"]];
}

- (NSInteger)numberOfSectionsInTableView:(UITableView*)tableView {
  return 5;
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
  if (section == AppearanceSection) return 2;
  section -= 1;
  return section == 0 ? 2 : section == 1 ? PadCount + 1 : section == 2 ? (self.hasWindowProgram ? 4 : 3) : 2;
}

- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section {
  return @[ @"Vzhled", @"Ovládání", @"Mapování tlačítek", @"Diagnostika", @"O aplikaci" ][section];
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
  if (section == AppearanceSection) return @"Pozadí knihovny a nastavení, na iPadu i iPhonu.";
  section -= 1;
  if (section == 0) return @"Ovladač na obrazovce se ukáže jen tehdy, když není připojený herní ovladač.";
  if (section == 1)
    return @"Klávesa, kterou hra dostane za každé tlačítko ovladače. Nahoru až doprava jsou křížový ovladač "
           @"i levá páčka. Platí pro všechny hry.";
  if (section == 2)
    return @"Ukazatel FPS ukáže ve hře snímky za sekundu, nejdelší snímek za poslední sekundu a rozlišení. "
           @"Testovací programy spustí Wine místo hry; pro další hru aplikaci spusť znovu.";
  return @"Hry se přidávají ve Finderu: iPad → Soubory → WinPad Wine, každá ve své složce.";
}

- (UITableViewCell*)tableView:(UITableView*)tableView cellForRowAtIndexPath:(NSIndexPath*)path {
  UITableViewCell* cell = [[UITableViewCell alloc] initWithStyle:UITableViewCellStyleValue1 reuseIdentifier:nil];
  cell.backgroundColor = [UIColor colorWithWhite:0 alpha:0.35];
  if (path.section == AppearanceSection && path.row == 0) {
    cell.textLabel.text = @"Pozadí";
    cell.detailTextLabel.text = @(CurrentBackground()->name);
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
    return cell;
  }
  if (path.section == AppearanceSection) {
    cell.textLabel.text = @"Vlny na pozadí";
    UISwitch* toggle = [UISwitch new];
    toggle.on = BackgroundWaves();
    [toggle addTarget:self action:@selector(wavesChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
    return cell;
  }
  path = [NSIndexPath indexPathForRow:path.row inSection:path.section - 1];
  if (path.section == 0 && path.row == 0) {
    cell.textLabel.text = @"Dotykové ovládání";
    UISwitch* toggle = [UISwitch new];
    id touch = [NSUserDefaults.standardUserDefaults objectForKey:@"touchControls"];
    toggle.on = !touch || [touch boolValue];
    [toggle addTarget:self action:@selector(touchChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
  } else if (path.section == 0) {
    cell.textLabel.text = @"Herní ovladač";
    GCController* pad = GCController.controllers.firstObject;
    cell.detailTextLabel.text = pad ? (pad.vendorName ?: @"Připojen") : @"Nepřipojen";
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
  } else if (path.section == 1 && path.row < PadCount) {
    unsigned short keys[PadCount];
    WinPadPadKeys(keys);
    cell.textLabel.text = PadTitles[path.row];
    cell.detailTextLabel.text = KeyName(keys[path.row]);
    cell.accessoryType = UITableViewCellAccessoryDisclosureIndicator;
  } else if (path.section == 1) {
    cell.textLabel.text = @"Obnovit výchozí mapování";
    cell.textLabel.textColor = UIColor.systemRedColor;
  } else if (path.section == 2 && path.row == 0) {
    cell.textLabel.text = @"Ukazatel FPS";
    UISwitch* toggle = [UISwitch new];
    toggle.on = [NSUserDefaults.standardUserDefaults boolForKey:@"fpsOverlay"];
    [toggle addTarget:self action:@selector(fpsChanged:) forControlEvents:UIControlEventValueChanged];
    cell.accessoryView = toggle;
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
  } else if (path.section == 2) {
    cell.textLabel.text = @[ @"Poslední log", @"Spustit hello.exe", @"Spustit window.exe" ][path.row - 1];
    cell.accessoryType = path.row == 1 ? UITableViewCellAccessoryDisclosureIndicator : UITableViewCellAccessoryNone;
  } else {
    NSDictionary* info = NSBundle.mainBundle.infoDictionary;
    cell.textLabel.text = path.row == 0 ? @"Verze" : @"Hry";
    cell.detailTextLabel.text = path.row == 0 ? [NSString stringWithFormat:@"%@ (%@)", info[@"CFBundleShortVersionString"] ?: @"?",
                                                                           info[@"CFBundleVersion"] ?: @"?"]
                                              : [NSString stringWithFormat:@"%lu", (unsigned long)WinPadFindGames().count];
    cell.selectionStyle = UITableViewCellSelectionStyleNone;
  }
  return cell;
}

- (void)wavesChanged:(UISwitch*)toggle {
  [NSUserDefaults.standardUserDefaults setBool:toggle.on forKey:@"backgroundWaves"];
}

- (void)touchChanged:(UISwitch*)toggle {
  [NSUserDefaults.standardUserDefaults setBool:toggle.on forKey:@"touchControls"];
}

- (void)fpsChanged:(UISwitch*)toggle {
  [NSUserDefaults.standardUserDefaults setBool:toggle.on forKey:@"fpsOverlay"];
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)path {
  [tableView deselectRowAtIndexPath:path animated:YES];
  if (path.section == AppearanceSection) {
    if (path.row == 0) [self.navigationController pushViewController:[WinPadBackgroundViewController new] animated:YES];
    return;
  }
  path = [NSIndexPath indexPathForRow:path.row inSection:path.section - 1];
  if (path.section == 1 && path.row < PadCount) {
    WinPadKeyPickerViewController* picker = [WinPadKeyPickerViewController new];
    picker.input = (int)path.row;
    [self.navigationController pushViewController:picker animated:YES];
    return;
  }
  if (path.section == 1) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"padKeys"];
    [tableView reloadSections:[NSIndexSet indexSetWithIndex:2] withRowAnimation:UITableViewRowAnimationNone];
    return;
  }
  if (path.section != 2 || path.row == 0) return;
  if (path.row == 1) {
    [self.navigationController pushViewController:[WinPadLogViewController new] animated:YES];
    return;
  }
  NSString* program = path.row == 2 ? @"hello" : @"window";
  void (^run)(NSString*) = self.run;
  [self dismissViewControllerAnimated:YES completion:^{
    if (run) run(program);
  }];
}
@end

@interface LibraryViewController ()
@property(nonatomic, strong) NSArray<WinPadGame*>* games;
@property(nonatomic) NSInteger focus;
@property(nonatomic, strong) WinPadBackdrop* backdrop;
@property(nonatomic, strong) UIButton* settings;
@property(nonatomic, strong) UILabel* clock;
@property(nonatomic, strong) NSTimer* clockTimer;
@property(nonatomic, strong) UILabel* heroTitle;
@property(nonatomic, strong) UIStackView* tags;
@property(nonatomic, strong) UIButton* play;
@property(nonatomic, strong) UIView* info;
@property(nonatomic, strong) UILabel* infoText;
@property(nonatomic, strong) UIScrollView* row;
@property(nonatomic, strong) NSMutableArray<UIButton*>* cards;
@property(nonatomic, strong) UILabel* addGame;
@property(nonatomic, strong) UILabel* empty;
@property(nonatomic, strong) UILabel* hints;
@property(nonatomic, strong) NSMutableArray* observers;
@property(nonatomic) unsigned pad;  // the controller buttons held at the last change (Nav*)
@property(nonatomic) BOOL started;
@property(nonatomic, readonly) BOOL compact;  // an iPhone's height: smaller, no hints or info card
- (void)reload;
- (void)showFocus;
- (void)tick;
- (void)moveFocusBy:(NSInteger)by;
- (void)startFocused;
- (void)startProgram:(NSString*)program game:(WinPadGame*)game;
- (void)openSettings;
- (void)attach:(GCController*)controller;
- (void)readPad:(GCExtendedGamepad*)pad;
@end

enum { NavLeft = 1, NavRight = 2, NavA = 4, NavB = 8, NavY = 16 };
// A card's cover; the card's own tag is the game's index.
enum { CoverTag = 1001 };

// The game's tags: on the backdrop they are light and see-through.
static WinPadTag* LightTag(NSString* text, uint32_t fg, UIColor* bg) {
  WinPadTag* tag = Tag(text, fg, 0);
  tag.backgroundColor = bg;
  tag.layer.cornerRadius = 4;
  return tag;
}

@implementation LibraryViewController
// The look of a console's home screen: a row of square tiles at the top, the focused one
// larger with a white frame, its title, tags and Spustit below, on the chosen backdrop. On
// an iPhone (on its side) everything is smaller, without the hints and the info card.
- (BOOL)compact {
  return self.view.bounds.size.height < 500;
}

- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = Hex(0x04122E);
  self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;

  self.backdrop = [WinPadBackdrop new];
  [self.view addSubview:self.backdrop];

  self.settings = [UIButton buttonWithType:UIButtonTypeSystem];
  [self.settings setImage:[UIImage systemImageNamed:@"slider.horizontal.3"] forState:UIControlStateNormal];
  self.settings.tintColor = UIColor.whiteColor;
  self.settings.backgroundColor = [UIColor colorWithWhite:1 alpha:0.12];
  self.settings.accessibilityLabel = @"Nastavení";
  [self.settings addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:self.settings];

  self.clock = [UILabel new];
  self.clock.textColor = Hex(0xDCE8FF);
  self.clock.textAlignment = NSTextAlignmentRight;
  [self.view addSubview:self.clock];
  [self tick];
  __weak LibraryViewController* clock_owner = self;
  self.clockTimer = [NSTimer scheduledTimerWithTimeInterval:10
                                                    repeats:YES
                                                      block:^(NSTimer* timer) {
                                                        [clock_owner tick];
                                                      }];

  self.row = [UIScrollView new];
  self.row.showsHorizontalScrollIndicator = NO;
  self.row.clipsToBounds = NO;
  [self.view addSubview:self.row];

  self.addGame = [UILabel new];
  self.addGame.text = @"Přidat hru\n\nPřelož ji na Macu a složku zkopíruj do Soubory › WinPad Wine";
  self.addGame.numberOfLines = 0;
  self.addGame.textAlignment = NSTextAlignmentCenter;
  self.addGame.textColor = Hex(0xDCE8FF);
  self.addGame.backgroundColor = [UIColor colorWithWhite:1 alpha:0.08];
  self.addGame.layer.cornerRadius = 6;
  self.addGame.layer.masksToBounds = YES;
  [self.row addSubview:self.addGame];

  self.heroTitle = [UILabel new];
  self.heroTitle.textColor = UIColor.whiteColor;
  self.heroTitle.adjustsFontSizeToFitWidth = YES;
  self.heroTitle.minimumScaleFactor = 0.5;
  [self.view addSubview:self.heroTitle];

  self.tags = [UIStackView new];
  self.tags.axis = UILayoutConstraintAxisHorizontal;
  self.tags.spacing = 10;
  self.tags.alignment = UIStackViewAlignmentLeading;
  [self.view addSubview:self.tags];

  UIButtonConfiguration* config = [UIButtonConfiguration filledButtonConfiguration];
  config.baseBackgroundColor = UIColor.whiteColor;
  config.baseForegroundColor = Hex(0x0B2A63);
  config.cornerStyle = UIButtonConfigurationCornerStyleFixed;
  config.background.cornerRadius = 4;
  config.image = [UIImage systemImageNamed:@"play.fill"];
  config.imagePadding = 10;
  config.title = @"Spustit";
  config.contentInsets = NSDirectionalEdgeInsetsMake(14, 32, 14, 40);
  self.play = [UIButton buttonWithConfiguration:config primaryAction:nil];
  [self.play addTarget:self action:@selector(startFocused) forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:self.play];

  self.info = [UIView new];
  self.info.backgroundColor = [Hex(0x04122E) colorWithAlphaComponent:0.55];
  self.info.layer.cornerRadius = 6;
  self.infoText = [UILabel new];
  self.infoText.numberOfLines = 0;
  [self.info addSubview:self.infoText];
  [self.view addSubview:self.info];

  self.empty = [UILabel new];
  self.empty.text = @"Zatím tu není žádná hra.\n\nPřelož hru na Macu a její složku zkopíruj přes Finder → iPad → "
                    @"Soubory → WinPad Wine. Knihovna ji pak sama ukáže.";
  self.empty.numberOfLines = 0;
  self.empty.textAlignment = NSTextAlignmentCenter;
  self.empty.font = [UIFont systemFontOfSize:20];
  self.empty.textColor = Hex(0xDCE8FF);
  [self.view addSubview:self.empty];

  self.hints = [UILabel new];
  self.hints.text = @"Ⓐ Spustit     ◀ ▶ Vybrat     Ⓨ Nastavení     Ťuknutím vybereš, druhým spustíš";
  self.hints.font = [UIFont systemFontOfSize:16];
  self.hints.textColor = Hex(0xDCE8FF);
  self.hints.textAlignment = NSTextAlignmentRight;
  [self.view addSubview:self.hints];

  self.cards = [NSMutableArray new];
  self.observers = [NSMutableArray new];
  __weak LibraryViewController* weak = self;
  // Games copied in from Finder while the app was in the background.
  [self.observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:UIApplicationWillEnterForegroundNotification
                                                                            object:nil
                                                                             queue:NSOperationQueue.mainQueue
                                                                        usingBlock:^(NSNotification* note) {
                                                                          [weak reload];
                                                                        }]];
  [self.observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:GCControllerDidConnectNotification
                                                                            object:nil
                                                                             queue:NSOperationQueue.mainQueue
                                                                        usingBlock:^(NSNotification* note) {
                                                                          [weak attach:note.object];
                                                                        }]];
  for (GCController* pad in GCController.controllers) [self attach:pad];
  [self reload];
}

- (void)viewDidAppear:(BOOL)animated {
  [super viewDidAppear:animated];
  [self becomeFirstResponder];
  static BOOL tested;
  if (tested || ![NSUserDefaults.standardUserDefaults boolForKey:@"libraryTest"]) return;
  tested = YES;
  NSMutableString* report = [NSMutableString stringWithFormat:@"library: %lu games\n", (unsigned long)self.games.count];
  for (WinPadGame* game in self.games)
    [report appendFormat:@"library: %@ | %@ | %@ | image %@%@\n", game.title, game.exe, game.arch ?: @"?",
                         game.image.lastPathComponent ?: @"none", game.imageInFolder ? @" (game folder)" : @""];
  [report writeToFile:[Documents() stringByAppendingPathComponent:@"library.txt"] atomically:YES encoding:NSUTF8StringEncoding error:nil];
  dispatch_after(dispatch_time(DISPATCH_TIME_NOW, NSEC_PER_SEC), dispatch_get_main_queue(), ^{
    [self moveFocusBy:1];
    [self startFocused];
  });
}

- (BOOL)canBecomeFirstResponder {
  return YES;
}

- (void)viewWillDisappear:(BOOL)animated {
  [super viewWillDisappear:animated];
  if (self.started) [self.clockTimer invalidate];
}

- (void)tick {
  NSDateFormatter* f = [NSDateFormatter new];
  f.timeStyle = NSDateFormatterShortStyle;
  f.dateStyle = NSDateFormatterNoStyle;
  self.clock.text = [f stringFromDate:NSDate.date];
}

- (void)reload {
  if (self.started) return;
  NSString* focused = self.games.count ? self.games[self.focus].folder : [NSUserDefaults.standardUserDefaults stringForKey:@"lastGame"];
  self.games = WinPadFindGames();
  self.focus = 0;
  for (NSUInteger i = 0; i < self.games.count; i++)
    if ([self.games[i].folder isEqualToString:focused]) self.focus = (NSInteger)i;

  for (UIButton* card in self.cards) [card removeFromSuperview];
  [self.cards removeAllObjects];
  for (NSUInteger i = 0; i < self.games.count; i++) {
    UIButton* card = [UIButton buttonWithType:UIButtonTypeCustom];
    card.tag = (NSInteger)i;
    card.accessibilityLabel = self.games[i].title;
    UILabel* placeholder;
    UIImageView* cover = CoverView(&placeholder, 15);
    cover.layer.cornerRadius = 6;
    cover.tag = CoverTag;
    cover.userInteractionEnabled = NO;
    ShowCover(cover, placeholder, self.games[i]);
    [card addSubview:cover];
    [card addTarget:self action:@selector(tapCard:) forControlEvents:UIControlEventTouchUpInside];
    [self.row addSubview:card];
    [self.cards addObject:card];
  }
  const BOOL none = self.games.count == 0;
  for (UIView* v in @[ self.heroTitle, self.tags, self.play, self.info ]) v.hidden = none;
  self.empty.hidden = !none;
  [self showFocus];
  [self.view setNeedsLayout];
}

- (void)showFocus {
  for (UIButton* card in self.cards) {
    UIView* cover = [card viewWithTag:CoverTag];
    const BOOL on = card.tag == self.focus;
    cover.layer.borderWidth = on ? 4 : 0;
    cover.layer.borderColor = UIColor.whiteColor.CGColor;
    cover.alpha = on ? 1 : 0.9;
  }
  [UIView animateWithDuration:0.18
                   animations:^{
                     [self.view setNeedsLayout];
                     [self.view layoutIfNeeded];
                   }];
  if (!self.games.count) {
    self.backdrop.cover = nil;
    return;
  }
  WinPadGame* game = self.games[self.focus];
  self.backdrop.cover = game.cover;
  self.heroTitle.text = game.title;
  for (UIView* tag in self.tags.arrangedSubviews) [tag removeFromSuperview];
  UIColor* plain = [UIColor colorWithWhite:1 alpha:0.12];
  UIColor* good = [Hex(0x7DDC9A) colorWithAlphaComponent:0.18];
  UIColor* warn = [Hex(0xF2C46D) colorWithAlphaComponent:0.18];
  [self.tags addArrangedSubview:LightTag(game.arch ? [@"Windows · " stringByAppendingString:game.arch] : @"Windows", 0xDCE8FF, plain)];
  [self.tags addArrangedSubview:game.imageInFolder ? LightTag(@"Přeloženo (obraz ve složce hry)", 0x9BEDB5, good)
                                 : game.image      ? LightTag(@"Přeloženo", 0x9BEDB5, good)
                                                   : LightTag(@"Nepřeloženo", 0xF2C46D, warn)];
  if (game.folderImageNote) [self.tags addArrangedSubview:LightTag(@"Obraz ve složce je pro jiné sestavení", 0xF2C46D, warn)];
  NSString* state = game.image ? @"Hra běží z přeloženého obrazu. Kód, který v něm chybí, doplní příští překlad z code map."
                               : @"Hra zatím nemá přeložený obraz: poběží pomalu v interpretu a zapíše code mapy pro překlad.";
  NSMutableAttributedString* text = [NSMutableAttributedString new];
  [text appendAttributedString:[[NSAttributedString alloc]
                                   initWithString:@"STAV PŘEKLADU\n"
                                       attributes:@{NSFontAttributeName : [UIFont systemFontOfSize:13 weight:UIFontWeightSemibold],
                                                    NSForegroundColorAttributeName : Hex(0x9DB9E8)}]];
  [text appendAttributedString:[[NSAttributedString alloc]
                                   initWithString:[NSString stringWithFormat:@"%@\nSložka %@ · %@", state, game.folder,
                                                                             game.exe.lastPathComponent]
                                       attributes:@{NSFontAttributeName : [UIFont systemFontOfSize:15],
                                                    NSForegroundColorAttributeName : Hex(0xDCE8FF)}]];
  self.infoText.attributedText = text;
  if (self.focus < (NSInteger)self.cards.count) {
    const CGRect card = self.cards[self.focus].frame;
    [self.row scrollRectToVisible:CGRectInset(card, -24, 0) animated:YES];
  }
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  const CGRect b = self.view.bounds;
  const UIEdgeInsets safe = self.view.safeAreaInsets;
  const BOOL compact = self.compact;
  self.backdrop.frame = b;
  const CGFloat m = MAX(safe.left, safe.right) + (compact ? 16 : 64), top = safe.top + (compact ? 12 : 36);
  const CGFloat w = b.size.width - 2 * m, button = compact ? 44 : 48;
  self.settings.frame = CGRectMake(m, top, button, button);
  self.settings.layer.cornerRadius = button / 2;
  self.clock.font = [UIFont systemFontOfSize:compact ? 18 : 26 weight:UIFontWeightLight];
  self.clock.frame = CGRectMake(m + w - 200, top, 200, button);

  // The row: the focused tile large, the others smaller, all on one bottom line.
  const CGFloat big = compact ? 150 : 260, small = compact ? 100 : 170, gap = compact ? 12 : 18;
  const CGFloat row_y = top + button + (compact ? 14 : 36);
  self.row.frame = CGRectMake(0, row_y, b.size.width, big);
  self.row.contentInset = UIEdgeInsetsMake(0, m, 0, m);
  CGFloat x = 0;
  for (UIButton* card in self.cards) {
    const CGFloat side = card.tag == self.focus ? big : small;
    card.frame = CGRectMake(x, big - side, side, side);
    [card viewWithTag:CoverTag].frame = card.bounds;
    x += side + gap;
  }
  self.addGame.font = [UIFont systemFontOfSize:compact ? 11 : 14];
  self.addGame.frame = CGRectMake(x, big - small, small, small);
  self.row.contentSize = CGSizeMake(x + small, big);

  // The focused game.
  CGFloat y = row_y + big + (compact ? 12 : 36);
  self.heroTitle.font = [UIFont systemFontOfSize:compact ? 24 : 44 weight:UIFontWeightLight];
  const CGFloat title_h = compact ? 30 : 54;
  const CGSize play = [self.play sizeThatFits:CGSizeMake(w, 60)];
  if (compact) {
    // Title and tags on the left, Spustit on the right, side by side.
    const CGFloat pw = MAX(play.width, 140);
    self.heroTitle.frame = CGRectMake(m, y, w - pw - 16, title_h);
    self.tags.frame = CGRectMake(m, y + title_h + 8, w - pw - 16, 26);
    self.play.frame = CGRectMake(m + w - pw, y + 6, pw, 48);
    self.info.hidden = self.hints.hidden = YES;
  } else {
    self.heroTitle.frame = CGRectMake(m, y, MIN(w, 900), title_h);
    y += title_h + 14;
    self.tags.frame = CGRectMake(m, y, w, 32);
    y += 32 + 26;
    self.play.frame = CGRectMake(m, y, MAX(play.width, 180), 56);
    y += 56 + 36;
    self.info.hidden = !self.games.count;
    self.info.frame = CGRectMake(m, y, MIN(w, 440), 120);
    self.infoText.frame = CGRectInset(self.info.bounds, 20, 14);
    self.hints.hidden = NO;
    self.hints.frame = CGRectMake(m, b.size.height - safe.bottom - 56, w, 32);
  }
  self.empty.frame = CGRectMake(m, row_y, w, MAX(120, b.size.height - row_y - safe.bottom - 40));
}

- (void)moveFocusBy:(NSInteger)by {
  if (!self.games.count) return;
  self.focus = MAX(0, MIN((NSInteger)self.games.count - 1, self.focus + by));
  [self showFocus];
}

- (void)tapCard:(UIButton*)card {
  if (card.tag == self.focus) {
    [self startFocused];
    return;
  }
  self.focus = card.tag;
  [self showFocus];
}

- (void)startFocused {
  if (!self.games.count) return;
  [self startProgram:@"game" game:self.games[self.focus]];
}

- (void)startProgram:(NSString*)program game:(WinPadGame*)game {
  if (self.started) return;
  self.started = YES;
  if (game) [NSUserDefaults.standardUserDefaults setObject:game.folder forKey:@"lastGame"];
  // The game reads the controllers itself (main.m's Gamepads).
  for (id observer in self.observers) [NSNotificationCenter.defaultCenter removeObserver:observer];
  [self.observers removeAllObjects];
  for (GCController* pad in GCController.controllers) pad.extendedGamepad.valueChangedHandler = nil;
  if (self.start) self.start(program, game);
}

- (void)openSettings {
  if (self.presentedViewController || self.started) return;
  WinPadSettingsViewController* settings = [WinPadSettingsViewController new];
  __weak LibraryViewController* weak = self;
  settings.run = ^(NSString* program) {
    [weak startProgram:program game:nil];
  };
  UINavigationController* nav = [[UINavigationController alloc] initWithRootViewController:settings];
  nav.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;
  nav.modalPresentationStyle = UIModalPresentationFormSheet;
  [self presentViewController:nav animated:YES completion:nil];
}

- (void)attach:(GCController*)controller {
  if (self.started || !controller.extendedGamepad) return;
  __weak LibraryViewController* weak = self;
  controller.extendedGamepad.valueChangedHandler = ^(GCExtendedGamepad* pad, GCControllerElement* element) {
    [weak readPad:pad];
  };
}

// Acts on the buttons a controller pressed since its last change.
- (void)readPad:(GCExtendedGamepad*)pad {
  float x = pad.dpad.xAxis.value;
  if (fabsf(x) < 0.5f) x = pad.leftThumbstick.xAxis.value;
  const unsigned now = (x < -0.5f ? NavLeft : 0) | (x > 0.5f ? NavRight : 0) | (pad.buttonA.pressed ? NavA : 0) |
                       (pad.buttonB.pressed ? NavB : 0) | (pad.buttonY.pressed ? NavY : 0);
  const unsigned pressed = now & ~self.pad;
  self.pad = now;
  if (self.presentedViewController) {
    if (pressed & NavB) [self dismissViewControllerAnimated:YES completion:nil];
    return;
  }
  if (pressed & NavLeft) [self moveFocusBy:-1];
  if (pressed & NavRight) [self moveFocusBy:1];
  if (pressed & NavY) [self openSettings];
  if (pressed & NavA) [self startFocused];
}

- (void)pressesBegan:(NSSet<UIPress*>*)presses withEvent:(UIPressesEvent*)event {
  BOOL handled = NO;
  for (UIPress* press in presses) {
    switch (press.key.keyCode) {
      case UIKeyboardHIDUsageKeyboardLeftArrow:
        [self moveFocusBy:-1];
        handled = YES;
        break;
      case UIKeyboardHIDUsageKeyboardRightArrow:
        [self moveFocusBy:1];
        handled = YES;
        break;
      case UIKeyboardHIDUsageKeyboardReturnOrEnter:
        [self startFocused];
        handled = YES;
        break;
      default:
        break;
    }
  }
  if (!handled) [super pressesBegan:presses withEvent:event];
}
@end
