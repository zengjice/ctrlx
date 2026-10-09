// CEF's browser/UI process lives INSIDE CtrlX. Renderer/GPU helpers remain
// sandboxed subprocesses; no separate visible browser application is created.
#import "../Sources/CtrlxBrowserBridge/include/CtrlxBrowserBridge.h"
#include "AgentBrowser.h"
#include <atomic>
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
@property(nonatomic) BOOL loopRunning;
@property(nonatomic) BOOL cookieFlushRequested;
@property(nonatomic) BOOL cookiesFlushed;
@property(nonatomic, copy) NSString *state;
- (void)contextReady;
- (void)runBrowserLoop;
- (void)shutdownOnRunLoop;
#ifdef CTRLX_UPSTREAM_BROWSER_PROBE
- (void)probeCloseDevTools:(NSWindow *)window;
#endif
@end

static CXEmbeddedBrowserRuntime *runtime;
static std::unique_ptr<CefScopedLibraryLoader> library;
static std::map<int, CefRefPtr<CefBrowser>> browsers;
static std::map<int, NSString *> identifiers;
// DevTools are human-only native windows, never agent-controlled page tabs.
static std::map<int, CefRefPtr<CefBrowser>> devToolsBrowsers;
static std::atomic_size_t pendingDevTools{0};

class DevToolsClient final : public CefClient, public CefLifeSpanHandler {
 public:
  explicit DevToolsClient(int source) : source_(source) { ++pendingDevTools; }
  ~DevToolsClient() override { if (pending_) --pendingDevTools; }
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    pending_ = false;
    --pendingDevTools;
    devToolsBrowsers[browser->GetIdentifier()] = browser;
    // The source may have closed while CEF was creating the tools window.
    if (runtime.closing || !browsers.contains(source_)) browser->GetHost()->CloseBrowser(true);
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    devToolsBrowsers.erase(browser->GetIdentifier());
  }
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int,
      const CefString&, const CefString&, WindowOpenDisposition, bool,
      const CefPopupFeatures&, CefWindowInfo&, CefRefPtr<CefClient>&,
      CefBrowserSettings&, CefRefPtr<CefDictionaryValue>&, bool*) override {
    // DevTools must not create unmanaged pages or another automation target.
    return true;
  }
  int Source() const { return source_; }
 private:
  int source_;
  bool pending_ = true;
  IMPLEMENT_REFCOUNTING(DevToolsClient);
};

static void CloseDevToolsFor(CefRefPtr<CefBrowser> browser) {
  browser->GetHost()->CloseDevTools();
  // Also cover a tool whose association CEF already detached during closing.
  auto copy = devToolsBrowsers;
  for (const auto& [id, tools] : copy) {
    auto client = static_cast<DevToolsClient*>(tools->GetHost()->GetClient().get());
    if (client->Source() == browser->GetIdentifier()) tools->GetHost()->CloseBrowser(true);
  }
}

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
    CloseDevToolsFor(browser);
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
  void OnBeforeDevToolsPopup(CefRefPtr<CefBrowser> browser, CefWindowInfo&,
      CefRefPtr<CefClient>& client, CefBrowserSettings&,
      CefRefPtr<CefDictionaryValue>&, bool*) override {
    // Also isolate any CEF-provided entry point from the page's lifecycle client.
    client = new DevToolsClient(browser->GetIdentifier());
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
             @"visible": @(container_.window.isVisible && !container_.isHiddenOrHasHiddenAncestor)};
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
static void CreateRoutedTab(const std::string& owner, NSDictionary *route, const std::string& url,
    std::function<void(CefRefPtr<CefBrowser>, NSString*)> done) {
  CEF_REQUIRE_UI_THREAD();
  if (runtime.closing) { done(nullptr, @"CtrlX is shutting down. No page was opened."); return; }
  if (browsers.size() >= 64) { done(nullptr, @"Chromium tab limit reached."); return; }
  if (!WebURL(url)) { done(nullptr, @"Invalid page URL. No page was opened."); return; }
  NSView *container = [runtime.delegate browserContainerForRoute:route];
  if (!container) { done(nullptr, @"The source CtrlX workspace was closed. No page was opened."); return; }
  CefWindowInfo info;
  info.SetAsChild((__bridge void *)container, CefRect(0, 0, 1000, 700));
  info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
  CefBrowserSettings settings;
  // Human and agent tabs share ONE profile, never an agent control grant.
  auto browser = CefBrowserHost::CreateBrowserSync(info,
      new EmbeddedClient(owner, container, route, nil), url, settings, nullptr, nullptr);
  if (!browser) [container removeFromSuperview];
  done(browser, browser ? nil : @"Chromium could not create the embedded page.");
}

static void OpenTab(std::string owner, int pid, std::string url,
    std::function<bool()> current, std::function<void(CefRefPtr<CefBrowser>, NSString*)> done) {
  [runtime.delegate resolveBrowserProcess:pid completion:^(NSDictionary *route, NSString *error) {
    // Process discovery awaits Swift I/O. Resume Chromium creation on CEF's
    // native loop, not inside the Swift main-actor job delivering this result.
    CefPostTask(TID_UI, new BrowserUITask([=] {
    CEF_REQUIRE_UI_THREAD();
    if (!current()) { done(nullptr, @"Open request expired. No page was opened."); return; }
    if (!route) { done(nullptr, error ?: @"Source session unavailable. No page was opened."); return; }
    CreateRoutedTab(owner, route, url, done);
    }));
  }];
}

class EmbeddedApp final : public CefApp, public CefBrowserProcessHandler {
 public:
  void OnBeforeCommandLineProcessing(const CefString& process, CefRefPtr<CefCommandLine> command) override {
    // Page-provided tools are opt-in through the bounded CLI, not an MCP server.
    // Match the pinned engine's Chromium launch prerequisites.
    command->AppendSwitchWithValue("enable-features", "WebMCPTesting,DevToolsWebMCPSupport");
  }
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
  void OnContextInitialized() override { [runtime contextReady]; }
 private:
  IMPLEMENT_REFCOUNTING(EmbeddedApp);
};

@interface CXBrowserApplication : NSApplication <CefAppProtocol>
@property(nonatomic) BOOL handlingSendEvent;
@end
@implementation CXBrowserApplication
- (BOOL)isHandlingSendEvent { return self.handlingSendEvent; }
- (void)sendEvent:(NSEvent *)event {
  // CDP input bypasses NSApplication. Physical Host input must not race the
  // remote controller, including a CEF field that was already first responder.
  if (runtime.started) for (auto& [id, browser] : browsers) {
    if (!AgentBrowserHumanControlled(browser)) continue;
    NSView *view = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
    if (event.window != view.window) continue;
    BOOL keyboard = event.type == NSEventTypeKeyDown || event.type == NSEventTypeKeyUp || event.type == NSEventTypeFlagsChanged;
    if (keyboard && [view.window.firstResponder isKindOfClass:NSView.class] &&
        [(NSView*)view.window.firstResponder isDescendantOf:view]) return;
    BOOL pointer = event.type == NSEventTypeLeftMouseDown || event.type == NSEventTypeLeftMouseUp ||
      event.type == NSEventTypeLeftMouseDragged || event.type == NSEventTypeRightMouseDown ||
      event.type == NSEventTypeRightMouseUp || event.type == NSEventTypeScrollWheel;
    if (pointer && !view.isHiddenOrHasHiddenAncestor && NSPointInRect([view convertPoint:event.locationInWindow fromView:nil], view.bounds)) return;
  }
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
  // CefRunMessageLoop owns Chromium's application keep-alive. With the external
  // pump that keep-alive is absent: closing the last Chrome-style DevTools
  // window starts global fast shutdown, even while Alloy pages are still open.
  settings.external_message_pump = false;
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
  // Enter from AppKit, never from the Swift main-actor job that initialized us.
  [self performSelector:@selector(runBrowserLoop) withObject:nil afterDelay:0];
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
- (void)runBrowserLoop {
  if (!self.started || self.shuttingDown) return;
  self.loopRunning = YES;
  // CEF's macOS pump dispatches AppKit events and RunLoop sources while NSApp
  // is already running. Swift UI/I/O jobs remain free to execute in this loop.
  CefRunMessageLoop();
  self.loopRunning = NO;
  // Shutdown only after the native loop has unwound, not from one of its jobs.
  CefShutdown();
  self.started = NO;
  self.delegate = nil;
}
- (void)openManualTabWithRoute:(NSDictionary<NSString *, NSString *> *)route url:(NSString *)url completion:(void (^)(NSString *))completion {
  if (!self.started || !self.endpointReady || self.closing) {
    completion(@"Chromium is not ready. Try again, or choose WebKit in Settings > Browser."); return;
  }
  NSDictionary *destination = [route copy];
  std::string page = url.UTF8String ?: "";
  void (^reply)(NSString *) = [completion copy];
  if (!CefPostTask(TID_UI, new BrowserUITask([destination, page, reply] {
    // Creation runs on CEF's native loop, never reenters a Swift executor job.
    CreateRoutedTab("", destination, page, [reply](auto browser, NSString *error) { reply(error); });
  }))) completion(@"Chromium could not schedule the new tab.");
}
- (void)navigateTab:(NSString *)identifier url:(NSString *)url {
  auto browser = AgentBrowserTarget(identifier);
  if (browser && WebURL(url.UTF8String)) browser->GetMainFrame()->LoadURL(url.UTF8String);
}
- (void)goBack:(NSString *)identifier { auto browser = AgentBrowserTarget(identifier); if (browser) browser->GoBack(); }
- (void)goForward:(NSString *)identifier { auto browser = AgentBrowserTarget(identifier); if (browser) browser->GoForward(); }
- (void)reloadTab:(NSString *)identifier { auto browser = AgentBrowserTarget(identifier); if (browser) browser->Reload(); }
- (void)showDevTools:(NSString *)identifier {
  if (!self.started || self.closing) return;
  // Creating native Chromium windows must not reenter a Swift main-actor job.
  NSString *target = [identifier copy];
  CefPostTask(TID_UI, new BrowserUITask([target] {
    CEF_REQUIRE_UI_THREAD();
    auto browser = AgentBrowserTarget(target);
    if (runtime.closing || !browser || !browser->IsValid() ||
        !browsers.contains(browser->GetIdentifier())) return;
    CefWindowInfo info;
    CefString(&info.window_name) = "CtrlX Agent Browser — Developer Tools";
    info.bounds = CefRect(0, 0, 1000, 700);
    // CEF focuses the existing tools window if it is already open.
    browser->GetHost()->ShowDevTools(info, new DevToolsClient(browser->GetIdentifier()),
                                   CefBrowserSettings(), CefPoint());
  }));
}
- (void)closeTab:(NSString *)identifier {
  auto browser = AgentBrowserTarget(identifier);
  if (browser) { CloseDevToolsFor(browser); browser->GetHost()->CloseBrowser(true); }
}
- (BOOL)setHumanControl:(NSString *)token forTab:(NSString *)identifier {
  return self.started && !self.closing && SetAgentBrowserHumanControl(identifier, token);
}
- (void)requestBrowserTab:(NSString *)identifier request:(NSData *)request completion:(void (^)(NSData *, NSString *))completion {
  if (!self.started || self.closing) { completion(nil, @"Chromium is not ready."); return; }
  NSString *target = [identifier copy]; NSData *data = [request copy];
  void (^reply)(NSData*, NSString*) = [completion copy];
  if (!CefPostTask(TID_UI, new BrowserUITask([target, data, reply] {
    RequestRemoteBrowserTab(target, data, reply);
  }))) completion(nil, @"Chromium could not schedule the request.");
}
- (void)beginShutdown {
  self.closing = YES;
  auto copy = browsers;
  StopAgentBrowser();
  for (auto& [id, browser] : copy) { CloseDevToolsFor(browser); browser->GetHost()->CloseBrowser(true); }
  auto tools = devToolsBrowsers;
  for (auto& [id, browser] : tools) browser->GetHost()->CloseBrowser(true);
}
- (BOOL)finishShutdown {
  if (!self.started) return YES;
  if (!browsers.empty() || !devToolsBrowsers.empty() || pendingDevTools.load() != 0) return NO;
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
  if (self.loopRunning) {
    CefQuitMessageLoop();
  } else {
    // Shutdown may race the deferred first entry into the native loop.
    CefShutdown();
    self.started = NO;
    self.delegate = nil;
  }
}
#ifdef CTRLX_UPSTREAM_BROWSER_PROBE
- (void)probeCloseDevTools:(NSWindow *)window {
  if (!self.started || self.closing) return;
  // Match CXBrowserApplication's real AppKit event boundary, not a nested
  // performClose from inside the automation socket/CEF message-pump callback.
  CefScopedSendingEvent scope;
  [window performClose:nil];
}
#endif
@end

#ifdef CTRLX_UPSTREAM_BROWSER_PROBE
NSDictionary *ProbeAgentBrowserDevTools(CefRefPtr<CefBrowser> source, NSString *action) {
  CEF_REQUIRE_UI_THREAD();
  const int sourceID = source->GetIdentifier();
  if ([action isEqual:@"show"]) [runtime showDevTools:identifiers.at(sourceID)];
  auto copy = devToolsBrowsers;
  NSMutableArray *tools = [NSMutableArray array];
  for (const auto& [id, browser] : copy) {
    auto client = static_cast<DevToolsClient*>(browser->GetHost()->GetClient().get());
    if (client->Source() != sourceID) continue;
    NSView *view = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
    auto frame = browser->GetMainFrame();
    [tools addObject:@{@"id": @(id), @"url": frame ? @(frame->GetURL().ToString().c_str()) : @"",
                      @"loading": @(browser->IsLoading()), @"visible": @(view.window.visible)}];
    if ([action isEqual:@"close"])
      [runtime performSelector:@selector(probeCloseDevTools:) withObject:view.window afterDelay:0];
  }
  return @{@"tools": tools, @"total": @(devToolsBrowsers.size()), @"pending": @(pendingDevTools.load())};
}
#endif

extern "C" __attribute__((visibility("default"))) BOOL CXEmbeddedBrowserPrepareApplication() {
  if (NSApp && ![NSApp isKindOfClass:CXBrowserApplication.class]) return NO;
  [CXBrowserApplication sharedApplication];
  return YES;
}
extern "C" __attribute__((visibility("default"))) id CXEmbeddedBrowserCreateRuntime() {
  if (!runtime) runtime = [CXEmbeddedBrowserRuntime new];
  return runtime;
}
