// SPDX-License-Identifier: MIT
// WinPad probe app: runs tests/probe's x86-64 guest on an iPad, from the AOT
// image in Frameworks/probe-aot.dylib, with NoJIT. No memory is ever made
// executable, so it needs no debugger and no JIT entitlement.
//
// Everything FEX and the probe print goes to Documents/probe.log, shown on
// screen. If FEX stops the process (it aborts on a block missing from the
// image), the next launch shows the log of the run that did not finish.
#import <UIKit/UIKit.h>

#include <cstdio>
#include <unistd.h>

int WinPadProbeMain(int argc, char** argv);

namespace {
constexpr const char* FinishedMarker = "== finished";

NSString* LogPath() {
  NSString* Docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
  return [Docs stringByAppendingPathComponent:@"probe.log"];
}

NSString* ReadLog() {
  return [NSString stringWithContentsOfFile:LogPath() encoding:NSUTF8StringEncoding error:nil] ?: @"";
}
} // namespace

@interface ProbeViewController : UIViewController
@property(nonatomic, strong) UITextView* text;
@end

@implementation ProbeViewController
- (void)viewDidLoad {
  [super viewDidLoad];
  self.view.backgroundColor = UIColor.systemBackgroundColor;
  self.text = [[UITextView alloc] initWithFrame:self.view.bounds];
  self.text.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
  self.text.editable = NO;
  self.text.font = [UIFont monospacedSystemFontOfSize:14 weight:UIFontWeightRegular];
  self.text.textContainerInset = UIEdgeInsetsMake(48, 16, 16, 16);
  [self.view addSubview:self.text];

  NSString* Previous = ReadLog();
  if (Previous.length && ![Previous containsString:@(FinishedMarker)]) {
    self.text.text = [@"WinPad probe: the last run stopped before it finished. Its log:\n\n" stringByAppendingString:Previous];
    [[NSFileManager defaultManager] moveItemAtPath:LogPath() toPath:[LogPath() stringByAppendingString:@".crashed"] error:nil];
    return;
  }
  self.text.text = @"WinPad probe: running…";
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    [self runProbe];
  });
}

- (void)runProbe {
  NSString* Image = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"probe-aot.dylib"];
  // FEX and the probe write with stdio; send both streams to the log file.
  freopen(LogPath().fileSystemRepresentation, "w", stdout);
  dup2(fileno(stdout), fileno(stderr));
  setvbuf(stdout, nullptr, _IONBF, 0);
  setvbuf(stderr, nullptr, _IONBF, 0);

  char* Args[] = {(char*)"winpad-probe", (char*)"run", (char*)Image.fileSystemRepresentation, nullptr};
  const int Status = WinPadProbeMain(3, Args);
  printf("%s, exit %d\n", FinishedMarker, Status);

  NSString* Summary = Status == 0 ? @"OK: the x86 program ran from the AOT image without a JIT.\n\n" :
                                    [NSString stringWithFormat:@"FAILED (exit %d)\n\n", Status];
  NSString* Log = ReadLog();
  dispatch_async(dispatch_get_main_queue(), ^{
    self.text.text = [Summary stringByAppendingString:Log];
  });
}
@end

@interface ProbeAppDelegate : UIResponder <UIApplicationDelegate>
@property(nonatomic, strong) UIWindow* window;
@end

@implementation ProbeAppDelegate
- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)options {
  self.window = [[UIWindow alloc] initWithFrame:UIScreen.mainScreen.bounds];
  self.window.rootViewController = [ProbeViewController new];
  [self.window makeKeyAndVisible];
  return YES;
}
@end

int main(int argc, char* argv[]) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([ProbeAppDelegate class]));
  }
}
