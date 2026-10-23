// SPDX-License-Identifier: MIT
// WinPad Wine's game library (Library.m): the screen the app opens on.
#import <UIKit/UIKit.h>

// A game the library found: a folder in the app's Documents with a Windows program.
@interface WinPadGame : NSObject
@property(nonatomic, copy) NSString* title;   // winpad.json's "title", else the folder's name
@property(nonatomic, copy) NSString* folder;  // the folder's name in Documents
@property(nonatomic, copy) NSString* exe;     // its program, relative to Documents
@property(nonatomic, copy) NSString* arch;    // "32bit", "64bit" or nil, from the program's PE header
@property(nonatomic, copy) NSString* image;   // the path of its AOT image in the bundle, or nil
@property(nonatomic, strong) UIImage* cover;  // cover.png or cover.jpg in its folder, or nil
@end

NSArray<WinPadGame*>* WinPadFindGames(void);

@interface LibraryViewController : UIViewController
// Runs a program: "game" with the game picked, or a test program (hello, window) with nil.
@property(nonatomic, copy) void (^start)(NSString* program, WinPadGame* game);
@end
