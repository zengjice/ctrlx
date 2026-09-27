// CEF's browser/UI process lives INSIDE CtrlX. Renderer/GPU helpers remain
// sandboxed subprocesses; no separate visible browser application is created.
#import "../Sources/CtrlxBrowserBridge/include/CtrlxBrowserBridge.h"
#include "AgentBrowser.h"
#include <algorithm>
#include <map>
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_cookie.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"

@interface CXEmbeddedBrowserRuntime : NSObject <CXBrowserRuntime>
@property(nonatomic, weak) id<CXBrowserHostDelegate> delegate;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL closing;
@property(nonatomic) BOOL endpointReady;
@property(nonatomic) BOOL shutdownScheduled;
@property(nonatomic) BOOL shuttingDown;
@property(nonatomic) BOOL pumping;
@property(nonatomic) BOOL cookieFlushRequested;
@property(nonatomic) BOOL cookiesFlushed;
@property(nonatomic, strong) NSTimer *pumpTimer;
@property(nonatomic, copy) NSString *state;
- (void)contextReady;
- (void)shutdownOnRunLoop;
- (void)schedulePump:(NSNumber *)delay;
- (void)pump;
@end

static CXEmbeddedBrowserRuntime *runtime;
static std::unique_ptr<CefScopedLibraryLoader> library;
static std::map<int, CefRefPtr<CefBrowser>> browsers;
static std::map<int, NSString *> identifiers;

class CookieFlushCompletion final : public CefCompletionCallback {
 public:
  void OnComplete() override {
    CEF_REQUIRE_UI_THREAD();
    runtime.cookiesFlushed = YES;
  }
 private:
  IMPLEMENT_REFCOUNTING(CookieFlushCompletion);
};

static bool WebURL(const std::string& raw) {
  if (raw == "about:blank") return true;
  NSURLComponents *url = [NSURLComponents componentsWithString:@(raw.c_str())];
  return url && [@[@"http", @"https"] containsObject:url.scheme.lowercaseString] &&
      url.host.length && !url.user && !url.password;
}

class EmbeddedClient final : public CefClient, public CefLifeSpanHandler,
    public CefDisplayHandler, public CefLoadHandler, public CefRequestHandler, public CefDownloadHandler, public CefJSDialogHandler {
 public:
  EmbeddedClient(std::string owner, NSView *container, NSDictionary *route, NSString *parent)
      : owner_(std::move(owner)), container_(container), route_(route), parent_(parent) {}
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefDisplayHandler> GetDisplayHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefRequestHandler> GetRequestHandler() override { return this; }
  CefRefPtr<CefDownloadHandler> GetDownloadHandler() override { return this; }
  CefRefPtr<CefJSDialogHandler> GetJSDialogHandler() override { return this; }
  bool OnJSDialog(CefRefPtr<CefBrowser> browser, const CefString&, JSDialogType type,
      const CefString& message, const CefString& defaultText, CefRefPtr<CefJSDialogCallback> callback, bool&) override {
    return AgentBrowserDialog(browser, type, message, defaultText, callback);
  }
  void OnResetDialogState(CefRefPtr<CefBrowser> browser) override { AgentBrowserDialogReset(browser); }
  bool OnBeforeDownload(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> item,
      const CefString&, CefRefPtr<CefBeforeDownloadCallback> callback) override {
    return AgentBrowserDownloadBegin(browser, item, callback);
  }
  void OnDownloadUpdated(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> item,
      CefRefPtr<CefDownloadItemCallback> callback) override { AgentBrowserDownloadUpdate(browser, item, callback); }
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    browsers[browser->GetIdentifier()] = browser;
    NSView *view = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
    view.frame = container_.bounds;
    view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    AddAgentBrowserTab(browser, owner_);
    for (NSDictionary *tab in AgentBrowserTabs()) {
      auto target = AgentBrowserTarget(tab[@"id"]);
      if (target && target->IsSame(browser)) { identifier_ = tab[@"id"]; break; }
    }
    if (!identifier_) { browser->GetHost()->CloseBrowser(true); return; }
    identifiers[browser->GetIdentifier()] = identifier_;
    [runtime.delegate browserTabCreated:identifier_ view:container_ route:route_ owner:@(owner_.c_str()) parent:parent_];
    [runtime.delegate browserTabSelected:identifier_];
  }
  bool DoClose(CefRefPtr<CefBrowser>) override {
    // Never let CEF close the parent CtrlX NSWindow when closing one tab.
    container_.subviews = @[];
    [container_ removeFromSuperview];
    return true;
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    RemoveAgentBrowserTab(browser);
    browsers.erase(browser->GetIdentifier());
    identifiers.erase(browser->GetIdentifier());
    [container_ removeFromSuperview];
    container_ = nil;
    if (identifier_) [runtime.delegate browserTabClosed:identifier_];
  }
  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>, int,
      const CefString& url, const CefString&, WindowOpenDisposition, bool,
      const CefPopupFeatures&, CefWindowInfo& info, CefRefPtr<CefClient>& client,
      CefBrowserSettings&, CefRefPtr<CefDictionaryValue>&, bool*) override {
    if (runtime.closing || browsers.size() >= 64 || (!url.empty() && !WebURL(url))) return true;
    NSView *container = [runtime.delegate browserContainerForRoute:route_];
    if (!container) return true;
    client = new EmbeddedClient(AgentBrowserOwner(browser), container, route_, identifier_);
    info.SetAsChild((__bridge void *)container, CefRect(0, 0, container.bounds.size.width, container.bounds.size.height));
    info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    return false;
  }
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request, bool, bool) override {
    if (!frame->IsMain()) return false;
    if (!WebURL(request->GetURL())) return true;
    AgentBrowserNavigation(browser);
    return false;
  }
  void OnLoadStart(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, TransitionType) override {
    if (frame->IsMain()) AgentBrowserNavigation(browser);
  }
  void Changed(CefRefPtr<CefBrowser> browser) {
    if (!identifier_) return;
    [runtime.delegate browserTabChanged:identifier_ title:title_ ?: @"" url:@(browser->GetMainFrame()->GetURL().ToString().c_str()) loading:browser->IsLoading()];
  }
  void OnAddressChange(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, const CefString&) override {
    if (frame->IsMain()) Changed(browser);
  }
  void OnTitleChange(CefRefPtr<CefBrowser> browser, const CefString& title) override {
    title_ = @(title.ToString().c_str()); Changed(browser);
  }
  void OnLoadingStateChange(CefRefPtr<CefBrowser> browser, bool, bool, bool) override { Changed(browser); }
  NSDictionary *Presentation() {
    // Read-only routing/attachment diagnostics, filtered by ownership by Tabs.
    return @{@"session": route_[@"session"] ?: @"", @"window": route_[@"window"] ?: @"",
             @"pane": route_[@"pane"] ?: @"", @"embedded": @YES,
             @"visible": @(container_.window != nil && !container_.isHiddenOrHasHiddenAncestor)};
  }
 private:
  std::string owner_;
  NSView *container_;
  NSDictionary *route_;
  NSString *parent_;
  NSString *identifier_;
  NSString *title_;
  IMPLEMENT_REFCOUNTING(EmbeddedClient);
};

class BrowserUITask final : public CefTask {
 public:
  explicit BrowserUITask(std::function<void()> work) : work_(std::move(work)) {}
  void Execute() override { work_(); }
 private:
  std::function<void()> work_;
  IMPLEMENT_REFCOUNTING(BrowserUITask);
};

// Own strings across the asynchronous Swift lookup; references supplied by the
// socket request handler expire as soon as that handler returns.
static void OpenTab(std::string owner, int pid, std::string url,
    std::function<bool()> current, std::function<void(CefRefPtr<CefBrowser>, NSString*)> done) {
  [runtime.delegate resolveBrowserProcess:pid completion:^(NSDictionary *route, NSString *error) {
    // Process discovery awaits Swift I/O. Resume Chromium creation on CEF's
    // native loop, not inside the Swift main-actor job delivering this result.
    CefPostTask(TID_UI, new BrowserUITask([=] {
    CEF_REQUIRE_UI_THREAD();
    if (!current()) { done(nullptr, @"Open request expired. No page was opened."); return; }
    if (!route) { done(nullptr, error ?: @"Source session unavailable. No page was opened."); return; }
    if (runtime.closing) { done(nullptr, @"CtrlX is shutting down. No page was opened."); return; }
    if (browsers.size() >= 64) { done(nullptr, @"Agent Browser tab limit reached."); return; }
    if (!WebURL(url)) { done(nullptr, @"Invalid page URL. No page was opened."); return; }
    NSView *container = [runtime.delegate browserContainerForRoute:route];
    if (!container) { done(nullptr, @"The source CtrlX workspace was closed. No page was opened."); return; }
    CefWindowInfo info;
    info.SetAsChild((__bridge void *)container, CefRect(0, 0, 1000, 700));
    info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    CefBrowserSettings settings;
    // All instances share ONE profile, not one profile per tab/session.
    auto browser = CefBrowserHost::CreateBrowserSync(info,
        new EmbeddedClient(owner, container, route, nil), url, settings, nullptr, nullptr);
    done(browser, browser ? nil : @"Chromium could not create the embedded page.");
    }));
  }];
}

class EmbeddedApp final : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
  void OnContextInitialized() override { [runtime contextReady]; }
  void OnScheduleMessagePumpWork(int64_t delay) override {
    // CEF may call on any thread. Its nested native loop must not run inside
    // a Swift main-actor/serial-dispatch job (which is not reentrant).
    [runtime performSelectorOnMainThread:@selector(schedulePump:) withObject:@(delay) waitUntilDone:NO];
  }
 private:
  IMPLEMENT_REFCOUNTING(EmbeddedApp);
};

@interface CXBrowserApplication : NSApplication <CefAppProtocol>
@property(nonatomic) BOOL handlingSendEvent;
@end
@implementation CXBrowserApplication
- (BOOL)isHandlingSendEvent { return self.handlingSendEvent; }
- (void)sendEvent:(NSEvent *)event {
  if (runtime.started) { CefScopedSendingEvent scope; [super sendEvent:event]; }
  else [super sendEvent:event];
}
@end

@implementation CXEmbeddedBrowserRuntime
- (BOOL)startWithDelegate:(id<CXBrowserHostDelegate>)delegate profile:(NSString *)profile state:(NSString *)state error:(NSError **)error {
  if (self.started) return YES;
  self.delegate = delegate;
  char canonicalProfile[PATH_MAX], canonicalState[PATH_MAX];
  if (!realpath(profile.fileSystemRepresentation, canonicalProfile) || !realpath(state.fileSystemRepresentation, canonicalState)) {
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    return NO;
  }
  profile = @(canonicalProfile);
  self.state = @(canonicalState);
  library = std::make_unique<CefScopedLibraryLoader>();
  if (!library->LoadInMain()) {
    if (error) *error = [NSError errorWithDomain:@"CtrlXBrowser" code:1 userInfo:@{NSLocalizedDescriptionKey: @"Cannot load the bundled Chromium framework."}];
    return NO;
  }
  CefSettings settings;
  settings.external_message_pump = true;
  NSString *bundle = NSBundle.mainBundle.bundlePath;
  CefString(&settings.main_bundle_path) = bundle.UTF8String;
  CefString(&settings.framework_dir_path) = [bundle stringByAppendingPathComponent:@"Contents/Frameworks/Chromium Embedded Framework.framework"].UTF8String;
  CefString(&settings.browser_subprocess_path) = [bundle stringByAppendingPathComponent:@"Contents/Frameworks/CtrlX Agent Browser Helper.app/Contents/MacOS/CtrlX Agent Browser Helper"].UTF8String;
  CefString(&settings.root_cache_path) = profile.UTF8String;
  CefString(&settings.cache_path) = [profile stringByAppendingPathComponent:@"Default"].UTF8String;
  settings.persist_session_cookies = true;
  CefString(&settings.log_file) = [profile stringByAppendingPathComponent:@"cef.log"].UTF8String;
  settings.log_severity = LOGSEVERITY_WARNING;
  // Do not feed CtrlX launch flags (or agent-supplied switches) into Chromium.
  const char *name = NSBundle.mainBundle.executablePath.UTF8String;
  char *argv[] = {const_cast<char *>(name), nullptr};
  if (!CefInitialize(CefMainArgs(1, argv), settings, new EmbeddedApp(), nullptr)) {
    if (error) *error = [NSError errorWithDomain:@"CtrlXBrowser" code:2 userInfo:@{NSLocalizedDescriptionKey: @"Chromium initialization failed. Close any older Agent Browser using this profile, then restart CtrlX."}];
    return NO;
  }
  self.started = YES;
  [self schedulePump:@0];
  return YES;
}
- (void)contextReady {
  self.endpointReady = StartAgentBrowser(self.state, {OpenTab, [](auto browser) {
    auto it = identifiers.find(browser->GetIdentifier());
    if (it != identifiers.end()) [runtime.delegate browserTabSelected:it->second];
  }, [] {}, [](auto browser) {
    return static_cast<EmbeddedClient*>(browser->GetHost()->GetClient().get())->Presentation();
  }});
  if (!self.endpointReady) NSLog(@"CtrlX embedded browser control endpoint could not start.");
}
- (void)schedulePump:(NSNumber *)delay {
  if (!self.started || self.shuttingDown) return;
  NSTimeInterval seconds = std::clamp(delay.doubleValue / 1000.0, 0.0, 0.033);
  NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:seconds];
  if (self.pumpTimer && [self.pumpTimer.fireDate compare:deadline] != NSOrderedDescending) return;
  [self.pumpTimer invalidate];
  self.pumpTimer = [NSTimer timerWithTimeInterval:seconds target:self selector:@selector(pump) userInfo:nil repeats:NO];
  [[NSRunLoop mainRunLoop] addTimer:self.pumpTimer forMode:NSRunLoopCommonModes];
}
- (void)pump {
  [self.pumpTimer invalidate];
  self.pumpTimer = nil;
  if (!self.started || self.shuttingDown) return;
  if (self.pumping) { [self schedulePump:@0]; return; }
  self.pumping = YES;
  CefDoMessageLoopWork();
  self.pumping = NO;
  // CEF's external-pump sample keeps an idle timer as well as wakeups; relying
  // solely on OnScheduleMessagePumpWork can strand delayed Chromium tasks.
  [self schedulePump:@33];
}
- (void)navigateTab:(NSString *)identifier url:(NSString *)url {
  auto browser = AgentBrowserTarget(identifier);
  if (browser && WebURL(url.UTF8String)) browser->GetMainFrame()->LoadURL(url.UTF8String);
}
- (void)goBack:(NSString *)identifier { auto browser = AgentBrowserTarget(identifier); if (browser) browser->GoBack(); }
- (void)goForward:(NSString *)identifier { auto browser = AgentBrowserTarget(identifier); if (browser) browser->GoForward(); }
- (void)reloadTab:(NSString *)identifier { auto browser = AgentBrowserTarget(identifier); if (browser) browser->Reload(); }
- (void)closeTab:(NSString *)identifier { auto browser = AgentBrowserTarget(identifier); if (browser) browser->GetHost()->CloseBrowser(true); }
- (void)beginShutdown {
  self.closing = YES;
  auto copy = browsers;
  StopAgentBrowser();
  for (auto& [id, browser] : copy) browser->GetHost()->CloseBrowser(true);
}
- (BOOL)finishShutdown {
  if (!self.started) return YES;
  if (!browsers.empty()) return NO;
  if (!AgentBrowserTransportsStopped()) return NO;
  // Closing the native views does not guarantee Chromium's pending cookie
  // writes reached disk. Keep its pump alive until the cookie-store completion
  // callback, rather than shutting down the network service immediately.
  if (!self.cookieFlushRequested) {
    self.cookieFlushRequested = YES;
    auto cookies = CefCookieManager::GetGlobalManager(nullptr);
    if (!cookies || !cookies->FlushStore(new CookieFlushCompletion())) {
      NSLog(@"CtrlX Agent Browser could not flush cookies before shutdown.");
      self.cookiesFlushed = YES; // Do not hang application quit on inaccessible storage.
    }
  }
  if (!self.cookiesFlushed) return NO;
  // CefShutdown spins native run loops while joining Chromium threads. Calling
  // it from a Swift main-actor job holds the serial main executor and can block
  // work those threads need. Enter from an AppKit run-loop callback instead.
  if (!self.shutdownScheduled) {
    self.shutdownScheduled = YES;
    [self performSelector:@selector(shutdownOnRunLoop) withObject:nil afterDelay:0];
  }
  return NO;
}
- (void)shutdownOnRunLoop {
  self.shuttingDown = YES;
  [self.pumpTimer invalidate];
  self.pumpTimer = nil;
  CefShutdown();
  self.started = NO;
  self.delegate = nil;
}
@end

extern "C" __attribute__((visibility("default"))) BOOL CXEmbeddedBrowserPrepareApplication() {
  if (NSApp && ![NSApp isKindOfClass:CXBrowserApplication.class]) return NO;
  [CXBrowserApplication sharedApplication];
  return YES;
}
extern "C" __attribute__((visibility("default"))) id CXEmbeddedBrowserCreateRuntime() {
  if (!runtime) runtime = [CXEmbeddedBrowserRuntime new];
  return runtime;
}
