// SPDX-License-Identifier: MIT
// WinPad probe app: runs tests/probe's x86-64 guest on an iPad, from the AOT
// image in Frameworks/probe-aot.dylib, with NoJIT. No memory is ever made
// executable, so it needs no debugger and no JIT entitlement.
//
// Then it calls a Windows DLL (tests/pe2macho/testdll.c) that tools/pe2macho
// wrapped into Frameworks/pe-testdll.dylib: PE code running as signed code.
//
// Everything FEX and the probe print goes to Documents/probe.log, shown on
// screen. If FEX stops the process (it aborts on a block missing from the
// image), the next launch shows the log of the run that did not finish.
#import <UIKit/UIKit.h>

#include <cstdio>
#include <cstring>
#include <dlfcn.h>
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

// Same checks as tests/pe2macho/main.c; 0 when the DLL's code ran.
int RunPeTest(const char* Path) {
  void* Lib = dlopen(Path, RTLD_NOW | RTLD_LOCAL);
  if (!Lib) {
    printf("PE test: dlopen: %s\n", dlerror());
    return 1;
  }
  auto* Image = static_cast<const char*>(dlsym(Lib, "pe_testdll_image"));
  auto* AddMul = reinterpret_cast<int (*)(int, int)>(dlsym(Lib, "pe_testdll_export_pe_add_mul"));
  auto* Greeting = reinterpret_cast<const char* (*)()>(dlsym(Lib, "pe_testdll_export_pe_greeting"));
  auto* Counter = reinterpret_cast<int (*)()>(dlsym(Lib, "pe_testdll_export_pe_counter"));
  if (!Image || !AddMul || !Greeting || !Counter || memcmp(Image, "MZ", 2) != 0) {
    printf("PE test: the dylib lacks the PE image or an export\n");
    return 1;
  }
  const int Product = AddMul(3, 4);
  const int Count = Counter();
  const char* Text = Greeting();
  printf("PE test: add_mul(3, 4) = %d, counter = %d, greeting \"%s\"\n", Product, Count, Text);
  const bool Ok = Product == 20 && Count == 8 && strcmp(Text, "hello from a PE image") == 0;
  printf("%s\n", Ok ? "PE code ran from the dylib" : "PE test FAILED");
  return Ok ? 0 : 1;
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
  // The log also goes to the original stderr at the end: Xcode's console.
  const int Console = dup(fileno(stderr));
  freopen(LogPath().fileSystemRepresentation, "w", stdout);
  dup2(fileno(stdout), fileno(stderr));
  setvbuf(stdout, nullptr, _IONBF, 0);
  setvbuf(stderr, nullptr, _IONBF, 0);

  char* Args[] = {(char*)"winpad-probe", (char*)"run", (char*)Image.fileSystemRepresentation, nullptr};
  int Status = WinPadProbeMain(3, Args);
  NSString* PeDylib = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"pe-testdll.dylib"];
  if (RunPeTest(PeDylib.fileSystemRepresentation) != 0 && Status == 0) {
    Status = 1;
  }
  printf("%s, exit %d\n", FinishedMarker, Status);

  NSString* Summary = Status == 0 ? @"OK: the x86 program ran from the AOT image without a JIT, and the Windows DLL from its dylib.\n\n" :
                                    [NSString stringWithFormat:@"FAILED (exit %d)\n\n", Status];
  NSString* Log = ReadLog();
  NSData* LogData = [[Summary stringByAppendingString:Log] dataUsingEncoding:NSUTF8StringEncoding];
  write(Console, LogData.bytes, LogData.length);
  dispatch_async(dispatch_get_main_queue(), ^{
    self.text.text = [Summary stringByAppendingString:Log];
  });
}
@end

// Apps built with the iOS 27 SDK must use the scene life cycle.
@interface ProbeSceneDelegate : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow* window;
@end

@implementation ProbeSceneDelegate
- (void)scene:(UIScene*)scene willConnectToSession:(UISceneSession*)session options:(UISceneConnectionOptions*)options {
  self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene*)scene];
  self.window.rootViewController = [ProbeViewController new];
  [self.window makeKeyAndVisible];
}
@end

@interface ProbeAppDelegate : UIResponder <UIApplicationDelegate>
@end

@implementation ProbeAppDelegate
- (BOOL)application:(UIApplication*)application didFinishLaunchingWithOptions:(NSDictionary*)options {
  return YES;
}

- (UISceneConfiguration*)application:(UIApplication*)application
    configurationForConnectingSceneSession:(UISceneSession*)session
                                   options:(UISceneConnectionOptions*)options {
  UISceneConfiguration* Config = [[UISceneConfiguration alloc] initWithName:@"Default" sessionRole:session.role];
  Config.delegateClass = [ProbeSceneDelegate class];
  return Config;
}
@end

int main(int argc, char* argv[]) {
  @autoreleasepool {
    return UIApplicationMain(argc, argv, nil, NSStringFromClass([ProbeAppDelegate class]));
  }
}
