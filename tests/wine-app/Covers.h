// SPDX-License-Identifier: MIT
// Game covers for WinPad Wine's library (Covers.m): looked up on the internet by the game's
// title and saved as cover.jpg in the game's folder, where the library takes them from.
#import <UIKit/UIKit.h>

@class WinPadGame;

// A cover one of the sources found.
@interface WinPadCover : NSObject
@property(nonatomic, copy) NSString* name;    // the game's name at the source
@property(nonatomic, copy) NSString* source;  // "Steam", "SteamGridDB", "Wikipedie"
// The picture: the first of these that loads (Steam has no tall picture for some old games).
@property(nonatomic, copy) NSArray<NSURL*>* urls;
@property(nonatomic, copy) NSURL* thumb;  // a smaller one for the list, or nil: urls
@end

// The covers found for QUERY (a game's title), best first: SteamGridDB (only with its API key,
// the "steamGridDBKey" setting), the Steam store (STEAM_APP_ID first if not 0), Wikipedia. None
// of these needs anything from the user but SteamGridDB's key. DONE runs on the main thread;
// error is set only when no source answered (no internet).
void WinPadFindCovers(NSString* query, long steam_app_id, void (^done)(NSArray<WinPadCover*>* covers, NSError* error));

// Loads a cover's picture (the first of its urls that loads; THUMB: its thumbnail first).
// DONE runs on the main thread, with nil if none loaded.
void WinPadLoadCover(WinPadCover* cover, BOOL thumb, void (^done)(UIImage* image, NSData* data));

// Saves IMAGE as the game's cover (cover.jpg in its folder; other cover.* removed), or with nil
// removes it. NO with why in *error.
BOOL WinPadSaveCover(WinPadGame* game, UIImage* image, NSError** error);

// The title the game is searched by: its title without what folder names add (_, ., "GOG"...).
NSString* WinPadCoverQuery(WinPadGame* game);
// The game's Steam app id (steam_appid.txt in its folder, or winpad.json's "steamAppId"), or 0.
long WinPadSteamAppId(WinPadGame* game);

// Finds a cover for each game without one, one game after another, and saves the one that
// surely is the game's (its name matches the title); a game is tried once (the "coverTried"
// setting), unless the internet was not there. Off with the "coverAuto" setting NO.
// CHANGED runs on the main thread after each saved cover.
void WinPadAutoCovers(NSArray<WinPadGame*>* games, void (^changed)(WinPadGame* game));
BOOL WinPadAutoCoversWanted(void);

// The screen to pick a game's cover: the covers found for its title (the search can be
// changed), a picture from Photos, or none. SAVED runs after the cover was changed.
@interface WinPadCoverPickerViewController : UIViewController
- (instancetype)initWithGame:(WinPadGame*)game;
@property(nonatomic, copy) void (^saved)(void);
@end
