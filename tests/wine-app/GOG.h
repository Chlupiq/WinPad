// SPDX-License-Identifier: MIT
// GOG in WinPad Wine (GOG.m): the user signs in with their own GOG account, sees the Windows
// games they own and installs one straight onto the iPad, without a PC or a Mac.
//
// It talks to GOG as GOG Galaxy does (and Heroic Games Launcher, gogdl and lgogdownloader with
// it): the account's OAuth login with Galaxy's public client id, the account's games from
// embed.gog.com, and the game's files from GOG's content system (content-system.gog.com, its
// "generation 2" builds): a build's manifest lists depots, a depot's manifest lists files, a file
// is zlib-compressed chunks named by their MD5 on GOG's CDN. The files come out as the game's
// installer would leave them (with its goggame-ID.info, which the library's GOG profiles match),
// in Documents/<the game's folder>. GOG does not document this API and may change it.
//
// Only what GOG sells: its games are DRM-free, nothing here gets round a protection. The
// account's tokens stay in the iPad's Keychain.
#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

// After a game was installed: the notification's object is its folder's name in Documents.
extern NSNotificationName const WinPadGOGInstalledNotification;

BOOL WinPadGOGSignedIn(void);
void WinPadGOGSignOut(void);

// A game of the account.
@interface WinPadGOGProduct : NSObject
@property(nonatomic) long long productId;
@property(nonatomic, copy) NSString* title;
@property(nonatomic, copy, nullable) NSURL* imageURL;  // GOG's tile picture (landscape), or nil
@end

// The games the account owns that run on Windows, by title. DONE runs on the main queue.
void WinPadGOGOwnedGames(void (^done)(NSArray<WinPadGOGProduct*>* _Nullable games, NSString* _Nullable error));

// The folder in Documents a GOG game is installed in (its goggame-ID.info, or the
// .winpad-gog.json this app writes), or nil.
NSString* _Nullable WinPadGOGInstalledFolder(long long productId);

// An install, one per game: planned (its manifests read), then its files downloaded into
// Documents/.gog/ID and moved to Documents/<folder> when all are there. It goes on when the
// screen that started it is closed. One that stopped (no internet, cancelled) goes on from the
// files it already has when started again.
typedef NS_ENUM(NSInteger, WinPadGOGState) {
  WinPadGOGPlanning,
  WinPadGOGPlanned,      // waits for start (the size and language are known)
  WinPadGOGDownloading,
  WinPadGOGFinishing,    // small files out of their container, the folder moved
  WinPadGOGDone,
  WinPadGOGFailed,       // error says why; start goes on
  WinPadGOGCancelled,
};

@interface WinPadGOGInstall : NSObject
// The running or stopped install of PRODUCT, or a new one, which starts planning.
+ (instancetype)installFor:(WinPadGOGProduct*)product;
+ (nullable instancetype)existingFor:(long long)productId;
@property(nonatomic, readonly) WinPadGOGProduct* product;
@property(nonatomic, readonly) WinPadGOGState state;
@property(nonatomic, readonly, copy, nullable) NSString* error;
@property(nonatomic, readonly, copy, nullable) NSString* folder;    // its folder in Documents
@property(nonatomic, readonly, copy, nullable) NSString* language;  // the depots' language, "en-US"
@property(nonatomic, readonly) long long installSize;               // the files, bytes
@property(nonatomic, readonly) long long downloadSize;              // compressed, bytes
@property(nonatomic, readonly) long long downloaded;                // compressed, so far
@property(nonatomic, readonly) NSInteger fileCount;
// Called on the main queue whenever something above changed.
@property(nonatomic, copy, nullable) void (^changed)(WinPadGOGInstall* install);
- (void)start;
- (void)cancel;
@end

// The GOG screen the library opens: sign in, the account's games, install.
@interface WinPadGOGViewController : UITableViewController
@end

// CI (build-xcode.sh, with the "gogAPIBase" setting pointing at a local copy of GOG's servers):
// signs in with the code "test", lists the games, installs PRODUCT_ID and writes what happened
// into Documents/gog.txt, ending with "== finished".
void WinPadGOGTest(long long productId);

NS_ASSUME_NONNULL_END
