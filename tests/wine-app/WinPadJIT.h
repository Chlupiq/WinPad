// SPDX-License-Identifier: MIT
// FEX's JIT in the app (WinPadJIT.m, over JITPool.c): with a debugger StikDebug attaches, a game
// runs with the JIT and needs no AOT image of its own; without one it runs from its AOT image,
// FEX's interpreter running what the image lacks.
#import <Foundation/Foundation.h>

// The settings: "jit" (default on) runs games with the JIT when it is there; "jitStikDebug"
// (default on) turns it on before a game when it is not (built-in, or StikDebug).
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

// The built-in JIT (JITHelper/, StikJIT in an app extension of the app): no StikDebug app,
// only LocalDevVPN and a pairing file. Nil when it can be used, else why not.
NSString* WinPadJITBuiltInUnavailableReason(void);
// The pairing file: Documents/StikJIT/pairingFile.plist. A pairing file copied straight into
// Documents (Finder, Files: *.mobiledevicepairing, or a .plist with "pair" in its name) is
// moved there first.
NSString* WinPadJITPairingPath(void);
BOOL WinPadJITHasPairing(void);
// Copies the pairing file at URL (from a document picker) into place. NO with why in *ERROR.
BOOL WinPadJITImportPairing(NSURL* url, NSString** error);
// Asks the helper to attach to the app ("enable") or only to check the tunnel and mount the
// Developer Disk Image ("prepare"). DONE runs on the main thread with the helper's answer;
// for "enable" once the JIT pool is prepared and the debugger gone.
void WinPadJITBuiltInSend(NSString* operation, void (^done)(BOOL ok, NSString* message));
// YES when a game can get the JIT now without the user's help: built-in (pairing file there)
// or StikDebug installed.
BOOL WinPadJITCanTurnOn(void);
// Turns the JIT on the best way there is: built-in, else StikDebug, and prepares the JIT pool
// as soon as the debugger is attached. DONE (main thread, once) says whether the JIT is on, and
// why not.
void WinPadJITTurnOn(void (^done)(BOOL ok, NSString* message));
