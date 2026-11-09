// SPDX-License-Identifier: MIT
// FEX's JIT in the app (WinPadJIT.m, over JITPool.c): with a debugger StikDebug attaches, a game
// runs with the JIT and needs no AOT image of its own; without one it runs from its AOT image,
// FEX's interpreter running what the image lacks.
#import <Foundation/Foundation.h>

// The settings: "jit" (default on) runs games with the JIT when it is there; "jitStikDebug"
// (default on) opens StikDebug before a game when it is not.
BOOL WinPadJITWanted(void);
BOOL WinPadJITAskWanted(void);

// Gets the JIT ready if it can: with StikDebug's script attached on a device with TXM, has it
// prepare the JIT pool (once per process). YES when a game started now runs with the JIT; NOTE
// says why or why not, for the log. A simulator answers NO: there the game runs as before (its
// image if it has one, else the JIT).
BOOL WinPadJITPrepare(NSString** note);

// One line for the settings: is the JIT there now, and why.
NSString* WinPadJITStatus(void);

// Whether to open StikDebug before a game: a device, the settings say so, no JIT yet, not
// started by Xcode, and StikDebug installed.
BOOL WinPadJITShouldAskStikDebug(void);
// Opens StikDebug with stikdebug://enable-jit for this process (with universal.js on a device
// with TXM). DONE gets whether it opened.
void WinPadJITAskStikDebug(void (^done)(BOOL opened));
// YES once a debugger is attached that can give the JIT (WinPadJITPrepare would do it).
BOOL WinPadJITAttached(void);

// YES when a game started now runs with the JIT (a simulator, or a debugger attached that gives it).
BOOL WinPadJITUsable(void);
// YES when StikDebug is installed (its URL scheme opens).
BOOL WinPadJITStikDebugInstalled(void);
