// Injected only into a disposable signed acceptance app, never shipped.
#import <AppKit/AppKit.h>
#import <dlfcn.h>
#import <objc/runtime.h>
#import "../../Sources/CtrlxBrowserBridge/include/CtrlxBrowserBridge.h"

static NSString *root;
static BOOL finished;
static id<CXApplicationDiagnosticsDelegate> failingDelegate;

@interface FailingDiagnostics : NSObject <CXApplicationDiagnosticsDelegate>
@end
@implementation FailingDiagnostics
- (void)recordAppKitException:(NSException *)exception {
  [NSException raise:NSInternalInconsistencyException format:@"Synthetic diagnostic failure"];
}
@end

// The recognizable frame exercises the production filter without inducing a
// real constraint feedback loop. It does not reproduce the original crash.
__attribute__((noinline, visibility("default")))
void CtrlXTest_postWindowNeedsUpdateConstraints(void) {
  [NSException raise:NSGenericException format:@"PRIVATE-APPKIT-PROBE-CONTENT"];
}

static void observeSuperReport(__unused id application, __unused SEL selector, NSException *exception) {
  if (![exception.name isEqualToString:NSGenericException]) abort();
  finished = YES;
  [@"forwarded" writeToFile:[root stringByAppendingPathComponent:@"forwarded"]
                atomically:YES encoding:NSUTF8StringEncoding error:nil];
}

@interface AppKitDiagnosticProbe : NSObject
@end
@implementation AppKitDiagnosticProbe
+ (void)load {
  const char *path = getenv("CTRLX_APPKIT_PROBE_ROOT");
  if (!path) return;
  root = @(path);
  NSLog(@"AppKit diagnostic probe loaded");
  [[NSNotificationCenter defaultCenter] addObserverForName:NSApplicationDidFinishLaunchingNotification
      object:nil queue:nil usingBlock:^(__unused NSNotification *notification) {
    NSLog(@"AppKit diagnostic probe observing %@", NSStringFromClass(NSApp.class));
    __block BOOL loggedToolbar = NO;
    __block BOOL loggedTick = NO;
    [NSTimer scheduledTimerWithTimeInterval:0.1 repeats:YES block:^(NSTimer *timer) {
      if (!loggedTick) { NSLog(@"Probe timer tick at %@", root); loggedTick = YES; }
      if (![[NSFileManager defaultManager] fileExistsAtPath:[root stringByAppendingPathComponent:@"go"]]) return;
      if (!loggedToolbar) NSLog(@"Probe window count: %lu", (unsigned long)NSApp.windows.count);
      BOOL ready = NO;
      for (NSWindow *window in NSApp.windows) {
        for (NSToolbarItem *item in window.toolbar.items) {
          if (!loggedToolbar) NSLog(@"Probe toolbar item: %@", item.itemIdentifier);
          if ([item.itemIdentifier isEqualToString:@"ctrlx.toolbar.connection"]) ready = YES;
        }
      }
      loggedToolbar = YES;
      if (!ready) return;
      [timer invalidate];
      if (getenv("CTRLX_APPKIT_PROBE_FAIL_DELEGATE")) {
        // Only the superclass is replaced; the production override must catch
        // the failing diagnostics callback and still forward the same exception.
        Method method = class_getInstanceMethod(NSApplication.class, @selector(reportException:));
        method_setImplementation(method, (IMP)observeSuperReport);
        NSString *library = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"libCtrlXAgentBrowser.dylib"];
        void *handle = dlopen(library.fileSystemRepresentation, RTLD_LAZY | RTLD_NOLOAD);
        void (*setDelegate)(id<CXApplicationDiagnosticsDelegate>) = handle ? dlsym(handle, "CXEmbeddedBrowserSetDiagnosticsDelegate") : NULL;
        if (!setDelegate) abort();
        failingDelegate = [FailingDiagnostics new];
        setDelegate(failingDelegate);
      }
      @try {
        CtrlXTest_postWindowNeedsUpdateConstraints();
      } @catch (NSException *exception) {
        [NSApp reportException:exception];
      }
      if (!finished) {
        // The normal case must retain AppKit's crash-on-exception policy.
        [@"unexpected return" writeToFile:[root stringByAppendingPathComponent:@"unexpected-return"]
                              atomically:YES encoding:NSUTF8StringEncoding error:nil];
      }
    }];
  }];
}
@end
