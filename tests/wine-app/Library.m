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
// The focused game shows large above the row of all of them. A game
// controller (the d-pad or left stick picks, A starts, Y opens the
// settings, B closes them), a hardware keyboard (arrows, Enter) or a tap
// picks and starts one. Wine runs once per process, so a game starts in
// place of the library (main.m) and the app is started again for the next.
//
// With the "libraryTest" setting (CI, tests/wine-app/build-xcode.sh) the
// library writes the games it found to Documents/library.txt, then presses
// right and A.
#import "Library.h"

#import <GameController/GameController.h>

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
  return 4;
}

- (NSInteger)tableView:(UITableView*)tableView numberOfRowsInSection:(NSInteger)section {
  return section == 0 ? 2 : section == 1 ? PadCount + 1 : section == 2 ? (self.hasWindowProgram ? 4 : 3) : 2;
}

- (NSString*)tableView:(UITableView*)tableView titleForHeaderInSection:(NSInteger)section {
  return @[ @"Ovládání", @"Mapování tlačítek", @"Diagnostika", @"O aplikaci" ][section];
}

- (NSString*)tableView:(UITableView*)tableView titleForFooterInSection:(NSInteger)section {
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

- (void)touchChanged:(UISwitch*)toggle {
  [NSUserDefaults.standardUserDefaults setBool:toggle.on forKey:@"touchControls"];
}

- (void)fpsChanged:(UISwitch*)toggle {
  [NSUserDefaults.standardUserDefaults setBool:toggle.on forKey:@"fpsOverlay"];
}

- (void)tableView:(UITableView*)tableView didSelectRowAtIndexPath:(NSIndexPath*)path {
  [tableView deselectRowAtIndexPath:path animated:YES];
  if (path.section == 1 && path.row < PadCount) {
    WinPadKeyPickerViewController* picker = [WinPadKeyPickerViewController new];
    picker.input = (int)path.row;
    [self.navigationController pushViewController:picker animated:YES];
    return;
  }
  if (path.section == 1) {
    [NSUserDefaults.standardUserDefaults removeObjectForKey:@"padKeys"];
    [tableView reloadSections:[NSIndexSet indexSetWithIndex:1] withRowAnimation:UITableViewRowAnimationNone];
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
@property(nonatomic, strong) UILabel* logo;
@property(nonatomic, strong) UIButton* settings;
@property(nonatomic, strong) UIImageView* heroCover;
@property(nonatomic, strong) UILabel* heroPlaceholder;
@property(nonatomic, strong) UILabel* kicker;
@property(nonatomic, strong) UILabel* heroTitle;
@property(nonatomic, strong) UIStackView* tags;
@property(nonatomic, strong) UIButton* play;
@property(nonatomic, strong) UILabel* rowTitle;
@property(nonatomic, strong) UIScrollView* row;
@property(nonatomic, strong) NSMutableArray<UIButton*>* cards;
@property(nonatomic, strong) UILabel* addGame;
@property(nonatomic, strong) UILabel* empty;
@property(nonatomic, strong) UILabel* hints;
@property(nonatomic, strong) NSMutableArray* observers;
@property(nonatomic) unsigned pad;  // the controller buttons held at the last change (Nav*)
@property(nonatomic) BOOL started;
- (void)reload;
- (void)showFocus;
- (void)moveFocusBy:(NSInteger)by;
- (void)startFocused;
- (void)startProgram:(NSString*)program game:(WinPadGame*)game;
- (void)openSettings;
- (void)attach:(GCController*)controller;
- (void)readPad:(GCExtendedGamepad*)pad;
@end

enum { NavLeft = 1, NavRight = 2, NavA = 4, NavB = 8, NavY = 16 };
// A card's parts; its own tag is the game's index.
enum { CoverTag = 1001, TitleTag = 1002 };

@implementation LibraryViewController
- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = Hex(0x0E1116);
  self.overrideUserInterfaceStyle = UIUserInterfaceStyleDark;

  self.logo = [UILabel new];
  self.logo.text = @"WinPad";
  self.logo.font = [UIFont systemFontOfSize:32 weight:UIFontWeightBold];
  self.logo.textColor = Hex(0xE8ECF2);
  [self.view addSubview:self.logo];

  self.settings = [UIButton buttonWithType:UIButtonTypeSystem];
  [self.settings setImage:[UIImage systemImageNamed:@"gearshape.fill"] forState:UIControlStateNormal];
  self.settings.tintColor = Hex(0xE8ECF2);
  self.settings.backgroundColor = Hex(0x171B22);
  self.settings.layer.cornerRadius = 26;
  self.settings.accessibilityLabel = @"Nastavení";
  [self.settings addTarget:self action:@selector(openSettings) forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:self.settings];

  UILabel* placeholder;
  self.heroCover = CoverView(&placeholder, 28);
  self.heroCover.layer.cornerRadius = 20;
  self.heroPlaceholder = placeholder;
  [self.view addSubview:self.heroCover];

  self.kicker = [UILabel new];
  self.kicker.font = [UIFont systemFontOfSize:15 weight:UIFontWeightSemibold];
  self.kicker.textColor = Hex(0x8FB8FF);
  [self.view addSubview:self.kicker];

  self.heroTitle = [UILabel new];
  self.heroTitle.font = [UIFont systemFontOfSize:48 weight:UIFontWeightBold];
  self.heroTitle.textColor = Hex(0xE8ECF2);
  self.heroTitle.numberOfLines = 2;
  self.heroTitle.adjustsFontSizeToFitWidth = YES;
  self.heroTitle.minimumScaleFactor = 0.5;
  [self.view addSubview:self.heroTitle];

  self.tags = [UIStackView new];
  self.tags.axis = UILayoutConstraintAxisHorizontal;
  self.tags.spacing = 10;
  self.tags.alignment = UIStackViewAlignmentLeading;
  [self.view addSubview:self.tags];

  UIButtonConfiguration* config = [UIButtonConfiguration filledButtonConfiguration];
  config.baseBackgroundColor = Hex(0xE8ECF2);
  config.baseForegroundColor = Hex(0x0E1116);
  config.cornerStyle = UIButtonConfigurationCornerStyleCapsule;
  config.image = [UIImage systemImageNamed:@"a.circle.fill"];
  config.imagePadding = 12;
  config.title = @"Spustit";
  config.contentInsets = NSDirectionalEdgeInsetsMake(16, 20, 16, 28);
  self.play = [UIButton buttonWithConfiguration:config primaryAction:nil];
  [self.play addTarget:self action:@selector(startFocused) forControlEvents:UIControlEventTouchUpInside];
  [self.view addSubview:self.play];

  self.rowTitle = [UILabel new];
  self.rowTitle.text = @"Knihovna";
  self.rowTitle.font = [UIFont systemFontOfSize:22 weight:UIFontWeightSemibold];
  self.rowTitle.textColor = Hex(0xE8ECF2);
  [self.view addSubview:self.rowTitle];

  self.row = [UIScrollView new];
  self.row.showsHorizontalScrollIndicator = NO;
  self.row.clipsToBounds = NO;
  [self.view addSubview:self.row];

  self.addGame = [UILabel new];
  self.addGame.text = @"Přidat hru\n\nPřelož hru na Macu a zkopíruj její složku do Soubory › WinPad Wine";
  self.addGame.numberOfLines = 0;
  self.addGame.textAlignment = NSTextAlignmentCenter;
  self.addGame.font = [UIFont systemFontOfSize:14];
  self.addGame.textColor = Hex(0xB4BDCA);
  self.addGame.layer.borderColor = Hex(0x3A4352).CGColor;
  self.addGame.layer.borderWidth = 2;
  self.addGame.layer.cornerRadius = 16;
  [self.row addSubview:self.addGame];

  self.empty = [UILabel new];
  self.empty.text = @"Zatím tu není žádná hra.\n\nPřelož hru na Macu a její složku zkopíruj přes Finder → iPad → "
                    @"Soubory → WinPad Wine. Knihovna ji pak sama ukáže.";
  self.empty.numberOfLines = 0;
  self.empty.textAlignment = NSTextAlignmentCenter;
  self.empty.font = [UIFont systemFontOfSize:20];
  self.empty.textColor = Hex(0xB4BDCA);
  [self.view addSubview:self.empty];

  self.hints = [UILabel new];
  self.hints.text = @"Ⓐ Spustit     ◀ ▶ Vybrat     Ⓨ Nastavení     Ťuknutím vybereš, druhým ťuknutím spustíš";
  self.hints.font = [UIFont systemFontOfSize:16];
  self.hints.textColor = Hex(0xB4BDCA);
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
    UIImageView* cover = CoverView(&placeholder, 17);
    cover.layer.cornerRadius = 16;
    cover.tag = CoverTag;
    ShowCover(cover, placeholder, self.games[i]);
    [card addSubview:cover];
    UILabel* title = [UILabel new];
    title.text = self.games[i].title;
    title.font = [UIFont systemFontOfSize:17 weight:UIFontWeightSemibold];
    title.textColor = Hex(0xE8ECF2);
    title.tag = TitleTag;
    [card addSubview:title];
    [card addTarget:self action:@selector(tapCard:) forControlEvents:UIControlEventTouchUpInside];
    [self.row addSubview:card];
    [self.cards addObject:card];
  }
  const BOOL none = self.games.count == 0;
  for (UIView* v in @[ self.heroCover, self.kicker, self.heroTitle, self.tags, self.play ]) v.hidden = none;
  self.empty.hidden = !none;
  [self showFocus];
  [self.view setNeedsLayout];
}

- (void)showFocus {
  for (UIButton* card in self.cards) {
    UIView* cover = [card viewWithTag:CoverTag];
    const BOOL on = card.tag == self.focus;
    cover.layer.borderWidth = on ? 4 : 0;
    cover.layer.borderColor = Hex(0x8FB8FF).CGColor;
    ((UILabel*)[card viewWithTag:TitleTag]).textColor = Hex(on ? 0xE8ECF2 : 0xB4BDCA);
  }
  if (!self.games.count) return;
  WinPadGame* game = self.games[self.focus];
  ShowCover(self.heroCover, self.heroPlaceholder, game);
  self.kicker.text = [game.folder isEqualToString:[NSUserDefaults.standardUserDefaults stringForKey:@"lastGame"]] ? @"NAPOSLEDY HRÁNO" : @"HRA";
  self.heroTitle.text = game.title;
  for (UIView* tag in self.tags.arrangedSubviews) [tag removeFromSuperview];
  [self.tags addArrangedSubview:Tag(game.arch ? [@"Windows · " stringByAppendingString:game.arch] : @"Windows", 0xB4BDCA, 0x171B22)];
  [self.tags addArrangedSubview:game.imageInFolder ? Tag(@"Přeloženo (obraz ve složce hry)", 0x7DDC9A, 0x16301F)
                                 : game.image      ? Tag(@"Přeloženo pro iPad", 0x7DDC9A, 0x16301F)
                                                   : Tag(@"Nepřeloženo: jen s JITem z Xcode", 0xF2C46D, 0x332A14)];
  if (game.folderImageNote)
    [self.tags addArrangedSubview:Tag(@"Obraz ve složce je pro jiné sestavení aplikace", 0xF2C46D, 0x332A14)];
  if (self.focus < (NSInteger)self.cards.count) {
    const CGRect card = self.cards[self.focus].frame;
    [self.row scrollRectToVisible:CGRectInset(card, -24, 0) animated:YES];
  }
}

- (void)viewDidLayoutSubviews {
  [super viewDidLayoutSubviews];
  const CGRect b = self.view.bounds;
  const UIEdgeInsets safe = self.view.safeAreaInsets;
  const CGFloat m = b.size.width > 900 ? 56 : 24, top = safe.top + 24, w = b.size.width - 2 * m;
  self.logo.frame = CGRectMake(m, top, 200, 52);
  self.settings.frame = CGRectMake(b.size.width - m - 52, top, 52, 52);

  const CGFloat hints_h = 64, bottom = b.size.height - safe.bottom - hints_h;
  self.hints.frame = CGRectMake(m, bottom, w, hints_h);

  const CGFloat card_w = 260, card_h = 195, row_h = card_h + 44;
  const CGFloat row_y = bottom - 24 - row_h;
  self.rowTitle.frame = CGRectMake(m, row_y - 40, w, 28);
  self.row.frame = CGRectMake(0, row_y, b.size.width, row_h);
  self.row.contentInset = UIEdgeInsetsMake(0, m, 0, m);
  CGFloat x = 0;
  for (UIButton* card in self.cards) {
    card.frame = CGRectMake(x, 0, card_w, row_h);
    [card viewWithTag:CoverTag].frame = CGRectMake(0, 0, card_w, card_h);
    [card viewWithTag:TitleTag].frame = CGRectMake(0, card_h + 12, card_w, 24);
    x += card_w + 28;
  }
  self.addGame.frame = CGRectMake(x, 0, card_w, card_h);
  self.row.contentSize = CGSizeMake(x + card_w, row_h);

  const CGFloat hero_y = top + 52 + 32, hero_h = MAX(120, row_y - 72 - hero_y);
  const CGFloat cover_w = MIN(MIN(w * 0.4, 520), hero_h * 4 / 3), cover_h = cover_w * 3 / 4;
  self.heroCover.frame = CGRectMake(m, hero_y, cover_w, cover_h);
  self.heroPlaceholder.frame = CGRectInset(self.heroCover.bounds, 16, 16);
  const CGFloat tx = m + cover_w + 40, tw = b.size.width - m - tx;
  CGFloat ty = hero_y + MAX(0, (cover_h - 260) / 2);
  self.kicker.frame = CGRectMake(tx, ty, tw, 20);
  ty += 32;
  self.heroTitle.frame = CGRectMake(tx, ty, tw, 116);
  ty += 132;
  self.tags.frame = CGRectMake(tx, ty, tw, 32);
  ty += 56;
  const CGSize play = [self.play sizeThatFits:CGSizeMake(tw, 64)];
  self.play.frame = CGRectMake(tx, ty, MAX(play.width, 160), 60);
  self.empty.frame = CGRectMake(m, hero_y, w, MAX(120, row_y - 72 - hero_y));
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
