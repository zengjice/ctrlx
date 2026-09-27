// Standalone experiment: deliberately not linked into the production CtrlX app.
#import <Cocoa/Cocoa.h>
#include <algorithm>
#include <vector>
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"
#include "AutomationBridge.h"

namespace {
constexpr char kFixture[] = "http://127.0.0.1:8769/index.html";
// Public listing obtained from the installed official Chrome plugin's documented
// extension-ids.json. Opening it does NOT install or grant permissions.
constexpr char kStore[] =
    "https://chromewebstore.google.com/detail/chatgpt/hehggadaopoacecdllhhajmbjkdcmajg";
bool smokeTest = false;
bool smokeChromeControl = false;
int smokeResult = 1;
bool embeddedViewVerified = false;
bool automation = false;
}

@interface ProbeDelegate : NSObject <NSApplicationDelegate, NSWindowDelegate>
@property(nonatomic, strong) NSWindow* window;
@property(nonatomic, strong) NSView* browserContainer;
@property(nonatomic, strong) NSView* secondContainer;
@property(nonatomic, strong) NSTextField* address;
@property(nonatomic, strong) NSTextField* status;
- (void)createBrowser;
- (void)closeBrowsers;
- (void)navigate:(NSString*)url;
@end

static ProbeDelegate* probeUI;

class ProbeClient final : public CefClient,
                          public CefLifeSpanHandler,
                          public CefDisplayHandler,
                          public CefRequestHandler,
                          public CefLoadHandler {
 public:
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }

  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                      CefRefPtr<CefRequest> request, bool user_gesture,
                      bool is_redirect) override {
    if (smokeTest) fprintf(stderr, "[probe] before-browse main=%d fixture=%d\n",
                           frame->IsMain(), request->GetURL() == kFixture);
    return false;
  }

  void OnRenderViewReady(CefRefPtr<CefBrowser> browser) override {
    if (smokeTest) fprintf(stderr, "[probe] renderer-ready browser=%d\n", browser->GetIdentifier());
  }

  void OnLoadStart(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                   TransitionType transition_type) override {
    if (smokeTest) fprintf(stderr, "[probe] load-start main=%d\n", frame->IsMain());
  }

  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    browsers_.push_back(browser);
    if (automation) {
      NSView* view = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
      NSView* container = [view isDescendantOf:probeUI.browserContainer]
          ? probeUI.browserContainer : probeUI.secondContainer;
      // Only our two native embedded views, never a popup/extension browser.
      if (view && container && [view isDescendantOf:container] && view.window == probeUI.window &&
          browser->GetHost()->GetRuntimeStyle() == CEF_RUNTIME_STYLE_ALLOY) {
        view.frame = container.bounds;
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        AddProbeAutomationTab(browser);
        fprintf(stderr, "[probe] automation-tab embedded-parent=verified\n");
      }
    }
    NSView* createdView = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
    if (!primary_ && (!automation || [createdView isDescendantOf:probeUI.browserContainer])) {
      primary_ = browser;
      const bool alloy = browser->GetHost()->GetRuntimeStyle() == CEF_RUNTIME_STYLE_ALLOY;
      fprintf(stderr, "[probe] browser-created id=%d style=%s sandbox=enabled\n",
              browser->GetIdentifier(), alloy ? "alloy" : "chrome");
      probeUI.status.stringValue = alloy
          ? (automation ? @"Local CLI / internal CDP — two isolated targets, no ChatGPT extension"
                        : @"Embedded NSView / Alloy — official extension connection NOT verified")
          : @"Chrome style control — NOT proof of embedded-view compatibility";
      NSView* view = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
      if (probeUI.browserContainer && view) {
        view.frame = probeUI.browserContainer.bounds;
        view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
        embeddedViewVerified = alloy && [view isDescendantOf:probeUI.browserContainer] &&
            view.window == probeUI.window && NSWidth(view.bounds) > 0 && NSHeight(view.bounds) > 0;
        fprintf(stderr, "[probe] embedded-parent=%s size=%.0fx%.0f\n",
                embeddedViewVerified ? "verified" : "FAILED",
                NSWidth(view.bounds), NSHeight(view.bounds));
      }
    }
  }

  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    fprintf(stderr, "[probe] browser-closed id=%d\n", browser->GetIdentifier());
    RemoveProbeAutomationTab(browser);
    if (primary_ && primary_->IsSame(browser)) primary_ = nullptr;
    std::erase_if(browsers_, [&](const auto& item) { return item->IsSame(browser); });
    if (browsers_.empty()) CefQuitMessageLoop();
  }

  bool DoClose(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    fprintf(stderr, "[probe] browser-ready-to-close id=%d\n", browser->GetIdentifier());
    return false;
  }

  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool isLoading,
                            bool canGoBack, bool canGoForward) override {
    CEF_REQUIRE_UI_THREAD();
    fprintf(stderr, "[probe] loading browser=%d active=%d\n", browser->GetIdentifier(), isLoading);
  }

  void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                       const CefString& url) override {
    CEF_REQUIRE_UI_THREAD();
    if (primary_ && primary_->IsSame(browser) && frame->IsMain()) {
      probeUI.address.stringValue = [NSString stringWithUTF8String:url.ToString().c_str()];
    }
  }

  void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                 int httpStatusCode) override {
    CEF_REQUIRE_UI_THREAD();
    if (frame->IsMain()) {
      // Do not log page contents, credentials, or visited URLs.
      fprintf(stderr, "[probe] load-end browser=%d status=%d\n",
              browser->GetIdentifier(), httpStatusCode);
      if (smokeTest && primary_ && primary_->IsSame(browser)) {
        bool expectedView = smokeChromeControl
            ? browser->GetHost()->GetRuntimeStyle() == CEF_RUNTIME_STYLE_CHROME
            : embeddedViewVerified;
        smokeResult = expectedView && frame->GetURL() == kFixture && httpStatusCode == 200 ? 0 : 1;
        // Report the final PASS only after every browser has closed and CEF
        // shutdown has returned, not while teardown can still hang.
        fprintf(stderr, "[probe] fixture-load=%s\n",
                smokeResult == 0 ? "PASS" : "FAIL");
        CloseAll();
      }
    }
  }

  void OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
                   ErrorCode code, const CefString& text,
                   const CefString& failedURL) override {
    CEF_REQUIRE_UI_THREAD();
    if (code != ERR_ABORTED && frame->IsMain()) {
      fprintf(stderr, "[probe] load-error browser=%d code=%d\n",
              browser->GetIdentifier(), static_cast<int>(code));
      probeUI.status.stringValue = [NSString stringWithFormat:@"Navigation failed (%d). Is the fixture server running?", code];
      if (smokeTest) CloseAll();
    }
  }

  CefRefPtr<CefBrowser> primary() const { return primary_; }
  void CloseAll(bool force = false) {
    CEF_REQUIRE_UI_THREAD();
    auto browsers = browsers_;
    for (auto& browser : browsers) browser->GetHost()->CloseBrowser(force);
  }

 private:
  CefRefPtr<CefBrowser> primary_;
  std::vector<CefRefPtr<CefBrowser>> browsers_;
  IMPLEMENT_REFCOUNTING(ProbeClient);
};

static CefRefPtr<ProbeClient> probeClient;

class SmokeTimeout final : public CefTask {
 public:
  void Execute() override {
    CEF_REQUIRE_UI_THREAD();
    smokeResult = 1;
    fprintf(stderr, "[probe] %s=FAIL timeout\n",
            smokeChromeControl ? "chrome-control-smoke" : "native-smoke");
    if (probeClient && probeClient->primary()) probeClient->CloseAll(true);
    else CefQuitMessageLoop();
  }
 private:
  IMPLEMENT_REFCOUNTING(SmokeTimeout);
};

@interface ProbeApplication : NSApplication <CefAppProtocol>
@property(nonatomic) BOOL handlingSendEvent;
@end

@implementation ProbeApplication
- (BOOL)isHandlingSendEvent { return self.handlingSendEvent; }
- (void)sendEvent:(NSEvent*)event {
  CefScopedSendingEvent scope;
  [super sendEvent:event];
}
- (void)terminate:(id)sender { [probeUI closeBrowsers]; }
@end

@implementation ProbeDelegate
- (void)createBrowser {
  auto args = CefCommandLine::GetGlobalCommandLine();
  const bool chromeControl = args->HasSwitch("probe-chrome-control");
  CefWindowInfo info;
  if (chromeControl) {
    info.runtime_style = CEF_RUNTIME_STYLE_CHROME;
  } else {
    self.window = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 1120, 820)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                  NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.window.title = @"CtrlX Browser Probe — independent experiment";
    self.window.releasedWhenClosed = NO;
    self.window.delegate = self;
    self.window.minSize = NSMakeSize(800, 500);
    NSView* root = self.window.contentView;

    self.address = [[NSTextField alloc] initWithFrame:NSMakeRect(16, 768, 1088, 28)];
    self.address.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.address.placeholderString = @"URL (Return to navigate)";
    self.address.target = self;
    self.address.action = @selector(go:);
    [root addSubview:self.address];

    NSArray<NSString*>* titles = automation ? @[@"Fixture", @"Back", @"Reload"]
        : @[@"Fixture", @"Extensions", @"ChatGPT extension", @"Back", @"Reload"];
    SEL actions[] = {@selector(fixture:), automation ? @selector(back:) : @selector(extensions:),
        automation ? @selector(reload:) : @selector(store:), @selector(back:), @selector(reload:)};
    CGFloat x = 16;
    for (NSUInteger index = 0; index < titles.count; ++index) {
      NSButton* button = [NSButton buttonWithTitle:titles[index] target:self action:actions[index]];
      button.frame = NSMakeRect(x, 730, index == 2 ? 160 : 100, 28);
      button.autoresizingMask = NSViewMinYMargin;
      [root addSubview:button];
      x += button.frame.size.width + 10;
    }
    self.status = [NSTextField labelWithString:@"Starting sandboxed Chromium…"];
    self.status.frame = NSMakeRect(16, 700, 1088, 24);
    self.status.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    [root addSubview:self.status];

    CGFloat width = automation ? 560 : 1120;
    self.browserContainer = [[NSView alloc] initWithFrame:NSMakeRect(0, 0, width, 692)];
    self.browserContainer.autoresizingMask = automation ? NSViewHeightSizable : NSViewWidthSizable | NSViewHeightSizable;
    [root addSubview:self.browserContainer];
    info.SetAsChild((__bridge void*)self.browserContainer, CefRect(0, 0, width, 692));
    info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    [self.window makeKeyAndOrderFront:nil];
  }
  if (automation && !StartProbeAutomation([] { if (probeClient) probeClient->CloseAll(); })) {
    fprintf(stderr, "[probe] automation bridge failed to start\n");
    CefQuitMessageLoop();
    return;
  }
  probeClient = new ProbeClient();
  CefBrowserSettings settings;
  const std::string fixtureURL = automation
      ? std::string(kFixture) + "?run=" + NSUUID.UUID.UUIDString.UTF8String : kFixture;
  if (!CefBrowserHost::CreateBrowser(info, probeClient, fixtureURL, settings, nullptr, nullptr)) {
    fprintf(stderr, "[probe] browser creation failed\n");
    CefQuitMessageLoop();
  }
  if (automation) {
    self.secondContainer = [[NSView alloc] initWithFrame:NSMakeRect(560, 0, 560, 692)];
    self.secondContainer.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [self.window.contentView addSubview:self.secondContainer];
    CefWindowInfo second;
    second.SetAsChild((__bridge void*)self.secondContainer, CefRect(0, 0, 560, 692));
    second.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    if (!CefBrowserHost::CreateBrowser(second, probeClient, fixtureURL + "&tab=B",
                                       settings, nullptr, nullptr)) {
      fprintf(stderr, "[probe] second automation browser creation failed\n");
      [self closeBrowsers];
    }
  }
  if (smokeTest) CefPostDelayedTask(TID_UI, new SmokeTimeout(), 20000);
  [NSApp activateIgnoringOtherApps:YES];
}
- (void)navigate:(NSString*)url {
  if (probeClient && probeClient->primary())
    probeClient->primary()->GetMainFrame()->LoadURL(url.UTF8String);
}
- (void)go:(id)sender { [self navigate:self.address.stringValue]; }
- (void)fixture:(id)sender { [self navigate:@(kFixture)]; }
- (void)extensions:(id)sender { [self navigate:@"chrome://extensions/"]; }
- (void)store:(id)sender { [self navigate:@(kStore)]; }
- (void)back:(id)sender {
  if (probeClient && probeClient->primary()) probeClient->primary()->GoBack();
}
- (void)reload:(id)sender {
  if (probeClient && probeClient->primary()) probeClient->primary()->Reload();
}
- (void)closeBrowsers {
  if (probeClient) probeClient->CloseAll();
}
- (BOOL)windowShouldClose:(NSWindow*)sender {
  const bool ready = !probeClient || !probeClient->primary() ||
      probeClient->primary()->GetHost()->TryCloseBrowser();
  fprintf(stderr, "[probe] native-window-close ready=%d\n", ready);
  if (!ready) return NO;
  // NSWindow is retained under ARC. Closing it alone only hides it, leaving
  // CEF's child NSView alive and preventing OnBeforeClose / shutdown.
  self.window.contentView = nil;
  self.browserContainer = nil;
  self.secondContainer = nil;
  return YES;
}
- (BOOL)applicationSupportsSecureRestorableState:(NSApplication*)app { return YES; }
@end

class ProbeApp final : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
  void OnContextInitialized() override {
    CEF_REQUIRE_UI_THREAD();
    // This callback can run during CefInitialize, before the event loop owns
    // per-event autorelease pools. Do not retain temporary view references in
    // main's process-lifetime pool: the CEF child must deallocate on close.
    @autoreleasepool {
      [probeUI createBrowser];
    }
  }
 private:
  IMPLEMENT_REFCOUNTING(ProbeApp);
};

int main(int argc, char* argv[]) {
  CefScopedLibraryLoader loader;
  if (!loader.LoadInMain()) return 1;
  @autoreleasepool {
    [ProbeApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    probeUI = [[ProbeDelegate alloc] init];
    NSApp.delegate = probeUI;
    NSMenu* menu = [[NSMenu alloc] init];
    NSMenuItem* item = [[NSMenuItem alloc] init];
    NSMenu* appMenu = [[NSMenu alloc] init];
    [appMenu addItemWithTitle:@"Quit Browser Probe" action:@selector(terminate:) keyEquivalent:@"q"];
    item.submenu = appMenu;
    [menu addItem:item];
    NSApp.mainMenu = menu;

    auto args = CefCommandLine::CreateCommandLine();
    args->InitFromArgv(argc, argv);
    CefCommandLine::SwitchMap switches;
    args->GetSwitches(switches);
    for (const auto& [name, value] : switches) {
      if (name != "probe-smoke-test" && name != "probe-chrome-control" && name != "probe-automation") {
        fprintf(stderr, "[probe] unsupported argument\n");
        return 2;
      }
    }
    smokeTest = args->HasSwitch("probe-smoke-test");
    automation = args->HasSwitch("probe-automation");
    if (automation && (smokeTest || args->HasSwitch("probe-chrome-control"))) {
      fprintf(stderr, "[probe] automation has its own profile; do not combine modes\n");
      return 2;
    }
    smokeChromeControl = smokeTest && args->HasSwitch("probe-chrome-control");
    // Profile ownership is fixed by the experiment. Never use a Chrome profile.
    NSString* mode = automation ? @"Automation" : smokeChromeControl ? @"SmokeChromeControl" : smokeTest ? @"Smoke" :
        (args->HasSwitch("probe-chrome-control") ? @"ChromeControl" : @"Embedded");
    NSURL* support = [[NSFileManager defaultManager] URLsForDirectory:NSApplicationSupportDirectory
                                                          inDomains:NSUserDomainMask].firstObject;
    NSURL* profile = [[support URLByAppendingPathComponent:@"CtrlXBrowserProbe"] URLByAppendingPathComponent:mode];
    NSError* error = nil;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:profile withIntermediateDirectories:YES
                                                  attributes:nil error:&error]) {
      fprintf(stderr, "[probe] cannot create isolated data directory: %s\n", error.localizedDescription.UTF8String);
      return 1;
    }
    CefSettings settings;
    CefString(&settings.root_cache_path) = profile.path.UTF8String;
    // CDP acceptance starts from an in-memory browsing context, without stale
    // HTTP fixtures or persisted extensions. Never clear the other profiles.
    if (!automation)
      CefString(&settings.cache_path) = [[profile URLByAppendingPathComponent:@"Default"] path].UTF8String;
    CefString(&settings.log_file) = [[profile URLByAppendingPathComponent:@"cef.log"] path].UTF8String;
    settings.log_severity = LOGSEVERITY_WARNING;
    CefRefPtr<ProbeApp> app = new ProbeApp();
    if (!CefInitialize(CefMainArgs(argc, argv), settings, app, nullptr))
      return smokeTest ? 1 : CefGetExitCode();
    // Chromium initialization may install its own application delegate.
    NSApp.delegate = probeUI;
    CefRunMessageLoop();
    StopProbeAutomation();
    probeClient = nullptr;
    CefShutdown();
    probeUI = nil;
  }
  if (smokeTest) {
    fprintf(stderr, "[probe] %s=%s (NOT an official extension test)\n",
            smokeChromeControl ? "chrome-control-smoke" : "native-smoke",
            smokeResult == 0 ? "PASS" : "FAIL");
  }
  return smokeTest ? smokeResult : 0;
}
