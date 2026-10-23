// CEF's browser/UI process lives INSIDE CtrlX. Renderer/GPU helpers remain
// sandboxed subprocesses; no separate visible browser application is created.
#import "../Sources/CtrlxBrowserBridge/include/CtrlxBrowserBridge.h"
#include "AgentBrowser.h"
#include "Ownership.h"
#include "ExternalApplication.h"
#include <atomic>
#include <map>
#include <set>
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_cookie.h"
#include "include/cef_parser.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"

@interface CXEmbeddedBrowserRuntime : NSObject <CXBrowserRuntime>
@property(nonatomic, weak) id<CXBrowserHostDelegate> delegate;
@property(nonatomic) BOOL started;
@property(nonatomic) BOOL startScheduled;
@property(nonatomic) BOOL closing;
@property(nonatomic) BOOL endpointReady;
@property(nonatomic) BOOL shutdownScheduled;
@property(nonatomic) BOOL shuttingDown;
@property(nonatomic) BOOL loopRunning;
@property(nonatomic) BOOL cookieFlushRequested;
@property(nonatomic) BOOL cookiesFlushed;
@property(nonatomic, copy) NSString *shutdownTraceStage;
@property(nonatomic, copy) NSString *state;
@property(nonatomic, copy) NSString *profile;
@property(nonatomic, copy) NSString *initializationError;
- (void)traceShutdownStage:(NSString *)stage;
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
static std::map<int, CefRefPtr<CefBrowser>> extensionTools;
static CefRefPtr<CefBrowser> browserSettings;
static std::map<int, int> extensionWindows;
static void ReleaseExtensionControlFor(NSString *identifier);
static std::map<int, std::shared_ptr<ExternalApplicationActivation>> externalActivations;
static NSString *BrowserDiagnosticOrigin(NSString *raw) {
  NSURLComponents *parts = [NSURLComponents componentsWithString:raw];
  if (![@[@"https", @"http"] containsObject:parts.scheme.lowercaseString] || !parts.host.length) return @"opaque";
  parts.user = nil; parts.password = nil; parts.path = @""; parts.query = nil; parts.fragment = nil;
  return parts.string ?: @"opaque";
}
#ifdef CTRLX_UPSTREAM_BROWSER_PROBE
static NSMutableArray *externalApplicationProbe;
static NSMutableArray *externalApplicationLoads;
static void ProbeExternalApplicationLoad(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
    NSString *event, const CefString& url) {
  if (frame->IsMain() && externalApplicationLoads)
    [externalApplicationLoads addObject:@{@"event": event, @"browser": @(browser->GetIdentifier()),
      @"frame": @(frame->GetIdentifier().ToString().c_str()), @"url": @(url.ToString().c_str())}];
}
#endif

void AgentBrowserCancelHumanInput(CefRefPtr<CefBrowser> browser) {
  CEF_REQUIRE_UI_THREAD();
  auto found = externalActivations.find(browser->GetIdentifier());
  if (found != externalActivations.end()) { found->second->Cancel(); externalActivations.erase(found); }
}

void AgentBrowserHumanInput(CefRefPtr<CefBrowser> browser, const std::string& control) {
  CEF_REQUIRE_UI_THREAD();
  const int id = browser->GetIdentifier();
  AgentBrowserCancelHumanInput(browser);
  if (!runtime.isReady || !identifiers.contains(id)) return;
  externalActivations[id] = std::make_shared<ExternalApplicationActivation>(identifiers.at(id).UTF8String, control);
}

static void OpenExternalApplication(CefRefPtr<CefBrowser> browser, const CefString& url) {
  CEF_REQUIRE_UI_THREAD();
  if (!runtime.isReady || !ExternalApplicationURL(@(url.ToString().c_str()))) return;
  auto diagnose = [&](NSString *result) {
    RecordBrowserDiagnostic(@{@"event": @"external-application-dispatch", @"browserID": @(browser->GetIdentifier()),
      @"scheme": [NSURLComponents componentsWithString:@(url.ToString().c_str())].scheme ?: @"", @"result": result});
  };
  auto found = externalActivations.find(browser->GetIdentifier());
  if (found == externalActivations.end() || !found->second->Consume()) { diagnose(@"no-live-human-activation"); return; }
  auto activation = found->second;
  auto source = AgentBrowserTarget(@(activation->source.c_str()));
  if (!source || !source->IsValid() || AgentBrowserHumanControlToken(source) != activation->control) { diagnose(@"source-or-control-changed"); return; }
  diagnose(@"dispatched");
#ifdef CTRLX_UPSTREAM_BROWSER_PROBE
  if (externalApplicationProbe) {
    [externalApplicationProbe addObject:@{@"source": @(activation->source.c_str()), @"url": @(url.ToString().c_str()),
                                          @"control": @(activation->control.c_str())}];
    return; // Isolated native acceptance observes dispatch without launching personal apps.
  }
#endif
  if ([runtime.delegate respondsToSelector:@selector(browserTab:openExternalURL:controlToken:)])
    [runtime.delegate browserTab:@(activation->source.c_str()) openExternalURL:@(url.ToString().c_str())
                   controlToken:activation->control.empty() ? nil : @(activation->control.c_str())];
}

#ifdef CTRLX_UPSTREAM_BROWSER_PROBE
NSDictionary *ProbeExternalApplication(CefRefPtr<CefBrowser> browser, NSDictionary *request) {
  NSString *action = request[@"action"];
  if ([action isEqual:@"start"]) {
    externalApplicationProbe = [NSMutableArray array];
    externalApplicationLoads = [NSMutableArray array];
  }
  if ([action isEqual:@"click"]) {
    NSView *view = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
    [view.window makeKeyAndOrderFront:nil];
    NSPoint point = NSMakePoint([request[@"x"] doubleValue], [request[@"y"] doubleValue]);
    if (!view.isFlipped) point.y = view.bounds.size.height - point.y;
    point = [view convertPoint:point toView:nil];
    for (auto type : {NSEventTypeLeftMouseDown, NSEventTypeLeftMouseUp}) {
      NSEvent *event = [NSEvent mouseEventWithType:type location:point modifierFlags:0
        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:view.window.windowNumber context:nil
        eventNumber:1 clickCount:1 pressure:1];
      [NSApp sendEvent:event];
    }
  }
  return @{@"events": [externalApplicationProbe copy] ?: @[], @"loads": [externalApplicationLoads copy] ?: @[]};
}
#endif

static void RevealWindow(CefRefPtr<CefBrowser> browser) {
  NSView *view = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
  [view.window makeKeyAndOrderFront:nil];
  browser->GetHost()->SetFocus(true);
}

// Chrome's own extension/settings windows have profile scope, not Agent page
// authority. Track even native-UI-created tools through the shutdown barrier.
class ExtensionToolClient final : public CefClient, public CefLifeSpanHandler {
 public:
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    extensionTools[browser->GetIdentifier()] = browser;
    if (runtime.closing) browser->GetHost()->CloseBrowser(true);
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    extensionTools.erase(browser->GetIdentifier());
    if (browserSettings == browser) browserSettings = nullptr;
  }
 private:
  IMPLEMENT_REFCOUNTING(ExtensionToolClient);
};

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
    [runtime traceShutdownStage:@"cookies-flushed"];
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
    public CefDisplayHandler, public CefLoadHandler, public CefRequestHandler, public CefDownloadHandler, public CefJSDialogHandler,
    public CefPermissionHandler {
 #include "NetworkPermission.inc"
 public:
  EmbeddedClient(std::string owner, NSView *container, NSDictionary *route, NSString *parent, bool extensionWindow = false)
      : owner_(std::move(owner)), container_(container), route_(route), parent_(parent), extensionWindow_(extensionWindow) {}
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
    if (popupActivation_) externalActivations[browser->GetIdentifier()] = popupActivation_;
    NSView *view = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
    if (!extensionWindow_) {
      view.frame = container_.bounds;
      view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    }
    AddAgentBrowserTab(browser, owner_);
    for (NSDictionary *tab in AgentBrowserTabs()) {
      auto target = AgentBrowserTarget(tab[@"id"]);
      if (target && target->IsSame(browser)) { identifier_ = tab[@"id"]; break; }
    }
    if (!identifier_) { browser->GetHost()->CloseBrowser(true); return; }
    identifiers[browser->GetIdentifier()] = identifier_;
    [runtime.delegate browserTabCreated:identifier_ view:container_ route:route_ owner:@(owner_.c_str()) parent:parent_];
    if (owner_.empty() || extensionWindow_) [runtime.delegate browserTabSelected:identifier_];
  }
  bool DoClose(CefRefPtr<CefBrowser>) override {
    if (extensionWindow_) return false;
    // Never let CEF close the parent CtrlX NSWindow when closing one tab.
    container_.subviews = @[];
    [container_ removeFromSuperview];
    return true;
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    FinishNetworkPermission(CEF_PERMISSION_RESULT_IGNORE);
    AgentBrowserCancelHumanInput(browser);
    ReleaseExtensionControlFor(identifier_);
    CloseDevToolsFor(browser);
    RemoveAgentBrowserTab(browser);
    browsers.erase(browser->GetIdentifier());
    std::erase_if(extensionWindows, [id = browser->GetIdentifier()](const auto& pair) {
      return pair.first == id || pair.second == id;
    });
    identifiers.erase(browser->GetIdentifier());
    [container_ removeFromSuperview];
    container_ = nil;
    if (identifier_) [runtime.delegate browserTabClosed:identifier_];
  }
  bool OnBeforePopup(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>, int,
      const CefString& url, const CefString&, WindowOpenDisposition, bool,
      const CefPopupFeatures&, CefWindowInfo& info, CefRefPtr<CefClient>& client,
      CefBrowserSettings&, CefRefPtr<CefDictionaryValue>&, bool*) override {
    if (!url.empty() && !WebURL(url)) { OpenExternalApplication(browser, url); return true; }
    if (runtime.closing || browsers.size() >= 64) return true;
    NSView *container = [runtime.delegate browserContainerForRoute:route_];
    if (!container) return true;
    auto popup = new EmbeddedClient(AgentBrowserOwner(browser), container, route_, identifier_, extensionWindow_);
    auto activation = externalActivations.find(browser->GetIdentifier());
    if (activation != externalActivations.end()) popup->popupActivation_ = activation->second;
    client = popup;
    if (extensionWindow_) info.runtime_style = CEF_RUNTIME_STYLE_CHROME;
    else {
      info.SetAsChild((__bridge void *)container, CefRect(0, 0, container.bounds.size.width, container.bounds.size.height));
      info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
    }
    return false;
  }
  void OnBeforeDevToolsPopup(CefRefPtr<CefBrowser> browser, CefWindowInfo&,
      CefRefPtr<CefClient>& client, CefBrowserSettings&,
      CefRefPtr<CefDictionaryValue>&, bool*) override {
    // Also isolate any CEF-provided entry point from the page's lifecycle client.
    client = new DevToolsClient(browser->GetIdentifier());
  }
  bool OnBeforeBrowse(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame,
      CefRefPtr<CefRequest> request, bool, bool redirect) override {
#ifdef CTRLX_UPSTREAM_BROWSER_PROBE
    ProbeExternalApplicationLoad(browser, frame, @"before-browse", request->GetURL());
#endif
    if (ExternalApplicationURL(@(request->GetURL().ToString().c_str()))) {
      OpenExternalApplication(browser, request->GetURL()); return true;
    }
    if (!frame->IsMain()) return false;
    if (!WebURL(request->GetURL())) return true;
    FinishNetworkPermission(CEF_PERMISSION_RESULT_IGNORE);
    networkConsoleCategories_.clear();
    auto activation = externalActivations.find(browser->GetIdentifier());
    if (activation != externalActivations.end() && request->GetURL() != "about:blank")
      activation->second->Navigation(browser->GetIdentifier(), request->GetURL(), redirect);
    AgentBrowserNavigation(browser);
    return false;
  }
  bool OnOpenURLFromTab(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame>,
      const CefString& url, WindowOpenDisposition, bool) override {
    if (WebURL(url)) return false;
    OpenExternalApplication(browser, url); return true;
  }
  void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int) override {
#ifdef CTRLX_UPSTREAM_BROWSER_PROBE
    ProbeExternalApplicationLoad(browser, frame, @"load-end", frame->GetURL());
#endif
    if (!frame->IsMain() || frame->GetURL() == "about:blank") return;
    auto activation = externalActivations.find(browser->GetIdentifier());
    if (activation != externalActivations.end())
      activation->second->Loaded(browser->GetIdentifier(), frame->GetIdentifier());
  }
  void OnLoadStart(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, TransitionType) override {
#ifdef CTRLX_UPSTREAM_BROWSER_PROBE
    ProbeExternalApplicationLoad(browser, frame, @"load-start", frame->GetURL());
#endif
    if (!frame->IsMain()) return;
    auto activation = externalActivations.find(browser->GetIdentifier());
    if (activation != externalActivations.end())
      activation->second->Committed(browser->GetIdentifier(), frame->GetIdentifier(), frame->GetURL());
    AgentBrowserNavigation(browser);
  }
  void OnLoadError(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, ErrorCode code,
      const CefString&, const CefString& url) override {
    RecordBrowserDiagnostic(@{@"event": @"navigation-error", @"browserID": @(browser->GetIdentifier()),
      @"origin": BrowserDiagnosticOrigin(@(url.ToString().c_str())), @"errorCode": @(code), @"mainFrame": @(frame->IsMain())});
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
  void OnRenderProcessTerminated(CefRefPtr<CefBrowser> browser, TerminationStatus status,
      int errorCode, const CefString&) override {
    if (AgentBrowserDebugMode()) RecordBrowserDiagnostic(@{@"event": @"renderer-terminated",
      @"browserID": @(browser->GetIdentifier()), @"status": @(status), @"errorCode": @(errorCode)});
  }
  NSDictionary *Presentation() {
    // Read-only routing/attachment diagnostics, filtered by ownership by Tabs.
    return @{@"session": route_[@"session"] ?: @"", @"window": route_[@"window"] ?: @"",
             @"pane": route_[@"pane"] ?: @"", @"embedded": @(!extensionWindow_),
             @"visible": @(extensionWindow_ ? NativeWindowVisible() :
                 (container_.window.isVisible && !container_.isHiddenOrHasHiddenAncestor))};
  }
  NSDictionary *Route() { return route_; }
  bool IsExtensionWindow() const { return extensionWindow_; }
 private:
  bool NativeWindowVisible() {
    auto browser = AgentBrowserTarget(identifier_);
    NSView *view = browser ? (__bridge NSView *)browser->GetHost()->GetWindowHandle() : nil;
    return view.window.isVisible;
  }
  std::string owner_;
  NSView *container_;
  NSDictionary *route_;
  NSString *parent_;
  NSString *identifier_;
  NSString *title_;
  bool extensionWindow_;
  std::shared_ptr<ExternalApplicationActivation> popupActivation_;
  IMPLEMENT_REFCOUNTING(EmbeddedClient);
};

#ifdef CTRLX_UPSTREAM_BROWSER_PROBE
void ProbeNetworkPermission(CefRefPtr<CefBrowser> source, NSDictionary *request, void (^reply)(NSDictionary *, NSString *)) {
  auto client = static_cast<EmbeddedClient *>(source->GetHost()->GetClient().get());
  if ([request[@"action"] isEqual:@"respond"]) {
    [runtime respondToNetworkPermission:request[@"id"] forTab:identifiers.at(source->GetIdentifier())
      allow:[request[@"allow"] boolValue] controlToken:request[@"lease"] completion:^(NSString *error) { reply(@{}, error); }];
  } else reply(client->ProbeNetworkPermission(), nil);
}
#endif

class BrowserUITask final : public CefTask {
 public:
  explicit BrowserUITask(std::function<void()> work) : work_(std::move(work)) {}
  void Execute() override { work_(); }
 private:
  std::function<void()> work_;
  IMPLEMENT_REFCOUNTING(BrowserUITask);
};

#include "BrowserExtensions.inc"
#include "ExtensionSurface.inc"

#include "ExtensionStoreRouting.inc"

static void OpenExtensionWindow(NSString *target, bool remote, void (^reply)(NSString *, NSString *)) {
  auto source = AgentBrowserTarget(target);
  if (runtime.closing || !source || !source->IsValid() || !browsers.contains(source->GetIdentifier()) ||
      (!remote && AgentBrowserHumanControlled(source))) {
    reply(nil, @"The source page is closed or controlled by a Viewer."); return;
  }
  auto client = static_cast<EmbeddedClient*>(source->GetHost()->GetClient().get());
  if (client->IsExtensionWindow()) { RevealWindow(source); reply(target, nil); return; }
  auto existing = extensionWindows.find(source->GetIdentifier());
  if (existing != extensionWindows.end() && browsers.contains(existing->second)) {
    auto browser = browsers.at(existing->second);
    if (AgentBrowserHumanControlled(browser) && (!remote || ![extensionControlledPage isEqual:identifiers.at(existing->second)])) {
      reply(nil, @"The extension window is controlled by a Viewer."); return;
    }
    RevealWindow(browser); reply(identifiers.at(existing->second), nil); return;
  }
  std::string url = source->GetMainFrame()->GetURL();
  if (!WebURL(url) || browsers.size() >= 64) { reply(nil, @"The page cannot open an extension window."); return; }
  NSMutableDictionary *route = [client->Route() mutableCopy];
  route[@"presentation"] = @"extensionWindow";
  NSView *container = [runtime.delegate browserContainerForRoute:route];
  if (!container) { reply(nil, @"The source workspace was closed."); return; }
  CefWindowInfo info;
  info.runtime_style = CEF_RUNTIME_STYLE_CHROME;
  info.bounds = CefRect(0, 0, 1100, 750);
  auto browser = CefBrowserHost::CreateBrowserSync(info,
      new EmbeddedClient(AgentBrowserOwner(source), container, route, target, true),
      url, CefBrowserSettings(), nullptr, nullptr);
  if (!browser || !identifiers.contains(browser->GetIdentifier())) {
    [container removeFromSuperview]; reply(nil, @"Chromium could not create the extension window."); return;
  }
  extensionWindows[source->GetIdentifier()] = browser->GetIdentifier();
  reply(identifiers.at(browser->GetIdentifier()), nil);
}

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
    NSString *pane = route[@"pane"];
    if (![pane isKindOfClass:NSString.class] || !pane.length) { done(nullptr, @"Source pane unavailable."); return; }
    CreateRoutedTab(owner, route, url, done);
    }));
  }];
}

class EmbeddedApp final : public CefApp, public CefBrowserProcessHandler {
 public:
  explicit EmbeddedApp(bool mockKeychain) : mockKeychain_(mockKeychain) {}
  void OnBeforeCommandLineProcessing(const CefString& process, CefRefPtr<CefCommandLine> command) override {
    // Page-provided tools are opt-in through the bounded CLI, not an MCP server.
    // Match the pinned engine's Chromium launch prerequisites.
    command->AppendSwitchWithValue("enable-features", "WebMCPTesting,DevToolsWebMCPSupport");
    if (mockKeychain_) command->AppendSwitch("use-mock-keychain");
#ifdef CTRLX_UPSTREAM_BROWSER_PROBE
    // Only the isolated acceptance binary can model a public-to-loopback fetch.
    NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
    NSUInteger index = [arguments indexOfObject:@"--ctrlx-probe-public-port"];
    if ([arguments containsObject:@"--e2e-test"] && index != NSNotFound && index + 1 < arguments.count) {
      int port = arguments[index + 1].intValue;
      if (port > 0 && port <= 65535)
        command->AppendSwitchWithValue("ip-address-space-overrides", [[NSString stringWithFormat:@"127.0.0.1:%d=public", port] UTF8String]);
    }
#endif
  }
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
  CefRefPtr<CefClient> GetDefaultClient() override { return new ExtensionToolClient(); }
  void OnContextInitialized() override { [runtime contextReady]; }
 private:
  const bool mockKeychain_;
  IMPLEMENT_REFCOUNTING(EmbeddedApp);
};

@interface CXBrowserApplication : NSApplication <CefAppProtocol>
@property(nonatomic) BOOL handlingSendEvent;
@end
static __weak id<CXBrowserTerminationDelegate> applicationTerminationDelegate;
static __weak id<CXApplicationDiagnosticsDelegate> applicationDiagnosticsDelegate;
static bool browserDebugMode = false;

bool AgentBrowserDebugMode() { return browserDebugMode; }
void RecordBrowserDiagnostic(NSDictionary* event) {
  if (!browserDebugMode || !NSThread.isMainThread ||
      ![applicationDiagnosticsDelegate respondsToSelector:@selector(recordBrowserDiagnostic:)]) return;
  @try {
    [applicationDiagnosticsDelegate recordBrowserDiagnostic:event];
  } @catch (NSException* exception) {
    browserDebugMode = false;
    NSLog(@"[agent-browser] Diagnostic callback failed; collection disabled (%@)", exception.name);
  }
}
@implementation CXBrowserApplication
- (void)reportException:(NSException *)exception {
  @try {
    if (NSThread.isMainThread) [applicationDiagnosticsDelegate recordAppKitException:exception];
  } @catch (NSException *diagnosticFailure) {
    NSLog(@"CtrlX could not capture AppKit diagnostics (%@)", diagnosticFailure.name);
  }
  // Preserve AppKit's reporting/crash policy; a snapshot is not recovery.
  [super reportException:exception];
}
- (BOOL)isHandlingSendEvent { return self.handlingSendEvent; }
- (void)sendEvent:(NSEvent *)event {
  TakeExtensionControlFromHost(event);
  // CDP input bypasses NSApplication. Physical Host input must not race the
  // remote controller, including a CEF field that was already first responder.
  if (runtime.started && extensionInputDepth == 0) for (auto& [id, browser] : browsers) {
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
  if (runtime.started && (event.type == NSEventTypeLeftMouseDown ||
      (event.type == NSEventTypeKeyDown && !event.isARepeat && (event.keyCode == 36 || event.keyCode == 49 || event.keyCode == 76)))) {
    for (auto& [id, browser] : browsers) {
      NSView *view = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
      if (!view.window || event.window != view.window || view.isHiddenOrHasHiddenAncestor) continue;
      NSView *target = event.type == NSEventTypeLeftMouseDown
        ? [view.window.contentView hitTest:[view.window.contentView convertPoint:event.locationInWindow fromView:nil]]
        : ([view.window.firstResponder isKindOfClass:NSView.class] ? (NSView*)view.window.firstResponder : nil);
      if (target && [target isDescendantOf:view]) {
        AgentBrowserHumanInput(browser, extensionInputDepth ? AgentBrowserHumanControlToken(browser) : "");
        break;
      }
    }
  }
  if (runtime.started) { CefScopedSendingEvent scope; [super sendEvent:event]; }
  else [super sendEvent:event];
}
- (void)terminate:(id)sender {
  // AppKit's terminateLater modal loop prevents CEF's native loop from
  // unwinding. Finish async cleanup before entering AppKit termination.
  if (runtime.started &&
      [applicationTerminationDelegate tryToTerminateWithoutModalLoop]) return;
  [super terminate:sender];
}
@end

@implementation CXEmbeddedBrowserRuntime
- (void)traceShutdownStage:(NSString *)stage {
  if (![NSProcessInfo.processInfo.arguments containsObject:@"--e2e-test"] ||
      [self.shutdownTraceStage isEqual:stage]) return;
  self.shutdownTraceStage = stage;
  NSLog(@"CtrlX Agent Browser shutdown stage=%@ started=%d loop=%d handlingEvent=%d pages=%zu tools=%zu pendingTools=%zu transportsStopped=%d cookiesRequested=%d cookiesFlushed=%d scheduled=%d",
        stage, self.started, self.loopRunning, [(id<CefAppProtocol>)NSApp isHandlingSendEvent],
        browsers.size(), devToolsBrowsers.size(), pendingDevTools.load(), AgentBrowserTransportsStopped(),
        self.cookieFlushRequested, self.cookiesFlushed, self.shutdownScheduled);
}
- (BOOL)startWithDelegate:(id<CXBrowserHostDelegate>)delegate profile:(NSString *)profile state:(NSString *)state error:(NSError **)error {
  if (self.started || self.startScheduled) return YES;
  if (self.closing || self.initializationError) {
    if (error) *error = [NSError errorWithDomain:@"CtrlXBrowser" code:2 userInfo:@{NSLocalizedDescriptionKey: self.initializationError ?: @"CtrlX is shutting down."}];
    return NO;
  }
  self.delegate = delegate;
  char canonicalProfile[PATH_MAX], canonicalState[PATH_MAX];
  if (!realpath(profile.fileSystemRepresentation, canonicalProfile) || !realpath(state.fileSystemRepresentation, canonicalState)) {
    if (error) *error = [NSError errorWithDomain:NSPOSIXErrorDomain code:errno userInfo:nil];
    return NO;
  }
  self.profile = @(canonicalProfile);
  self.state = @(canonicalState);
  self.startScheduled = YES;
  // Initialization installs RunLoop observers. Enter CEF's loop in the same
  // AppKit callback, before the outer loop can exit without a matching entry.
  [self performSelector:@selector(runBrowserLoop) withObject:nil afterDelay:0];
  return YES;
}
- (void)runBrowserLoop {
  if (!self.startScheduled || self.closing || self.shuttingDown) return;
  self.startScheduled = NO;
  library = std::make_unique<CefScopedLibraryLoader>();
  if (!library->LoadInMain()) {
    self.initializationError = @"Cannot load the bundled Chromium framework.";
    return;
  }
  NSString *profile = self.profile;
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
  NSArray<NSString *> *arguments = NSProcessInfo.processInfo.arguments;
  const bool mockKeychain = [arguments containsObject:@"--e2e-test"] &&
      [arguments containsObject:@"--e2e-browser-mock-keychain"];
  if (mockKeychain) NSLog(@"CtrlX Agent Browser E2E mock keychain enabled");
  if (!CefInitialize(CefMainArgs(1, argv), settings, new EmbeddedApp(mockKeychain), nullptr)) {
    self.initializationError = @"Chromium initialization failed. Close any older Agent Browser using this profile, then restart CtrlX.";
    return;
  }
  self.started = YES;
  self.loopRunning = YES;
  [self traceShutdownStage:@"native-loop-enter"];
  CefRunMessageLoop();
  self.loopRunning = NO;
  [self traceShutdownStage:@"native-loop-returned"];
  CefShutdown();
  self.started = NO;
  [self traceShutdownStage:@"native-shutdown-finished"];
  self.delegate = nil;
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
- (BOOL)isReady { return self.started && self.endpointReady && !self.closing; }
- (NSString *)startupError { return self.initializationError; }
- (void)openManualTabWithRoute:(NSDictionary<NSString *, NSString *> *)route url:(NSString *)url completion:(void (^)(NSString *))completion {
  if (!self.started || !self.endpointReady || self.closing) {
    completion(@"Chromium is not ready. Restart CtrlX and try again."); return;
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
  if (browser && WebURL(url.UTF8String)) { AgentBrowserCancelHumanInput(browser); browser->GetMainFrame()->LoadURL(url.UTF8String); }
}
- (void)goBack:(NSString *)identifier { auto browser = AgentBrowserTarget(identifier); if (browser) { AgentBrowserCancelHumanInput(browser); browser->GoBack(); } }
- (void)goForward:(NSString *)identifier { auto browser = AgentBrowserTarget(identifier); if (browser) { AgentBrowserCancelHumanInput(browser); browser->GoForward(); } }
- (void)reloadTab:(NSString *)identifier { auto browser = AgentBrowserTarget(identifier); if (browser) { AgentBrowserCancelHumanInput(browser); browser->Reload(); } }
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
- (void)openExtensionWindowForTab:(NSString *)identifier completion:(void (^)(NSString *, NSString *))completion {
  NSString *target = [identifier copy];
  void (^reply)(NSString *, NSString *) = [completion copy];
  if (!self.isReady || !CefPostTask(TID_UI, new BrowserUITask([target, reply] {
    if (extensionSurface && extensionSurface->Active()) {
      reply(nil, @"A Viewer controls browser extensions. Take control back first."); return;
    }
    OpenExtensionWindow(target, false, reply);
  }))) reply(nil, @"Chromium is not ready.");
}
- (void)showExtensionManagerForTab:(NSString *)identifier completion:(void (^)(NSString *))completion {
  NSString *target = [identifier copy];
  void (^reply)(NSString *) = [completion copy];
  if (!self.isReady || !CefPostTask(TID_UI, new BrowserUITask([target, reply] {
    if (extensionSurface && extensionSurface->Active()) {
      reply(@"A Viewer controls browser extensions. Take control back first."); return;
    }
    auto source = AgentBrowserTarget(target);
    if (runtime.closing || !source || !source->IsValid() || !browsers.contains(source->GetIdentifier()) ||
        AgentBrowserHumanControlled(source)) { reply(@"The source page is closed or controlled by a Viewer."); return; }
    auto browser = EnsureExtensionManager();
    if (browser) {
      ConfigureExtensionStore(browser, target, nil);
      RevealWindow(browser);
    }
    reply(browser ? nil : @"Chromium could not open extension management.");
  }))) reply(@"Chromium is not ready.");
}
- (void)showBrowserSettings:(NSString *)section completion:(void (^)(NSString *))completion {
  NSString *url = [section isEqual:@"passwords"] ? @"chrome://password-manager/passwords" :
      [section isEqual:@"general"] ? @"chrome://settings/" : nil;
  void (^reply)(NSString *) = [completion copy];
  if (!url) { reply(@"Unsupported browser settings section."); return; }
  if (!self.isReady || !CefPostTask(TID_UI, new BrowserUITask([url, reply] {
    if (runtime.closing) { reply(@"Chromium is shutting down."); return; }
    reply(ShowBrowserSettingsWindow(url) ? nil : @"Chromium could not open browser settings.");
  }))) reply(@"Chromium is not ready.");
}
- (void)requestBrowserExtensionsForTab:(NSString *)identifier request:(NSData *)request
    completion:(void (^)(NSData *, NSString *))completion {
  NSString *target = [identifier copy];
  NSData *bytes = [request copy];
  void (^reply)(NSData *, NSString *) = [completion copy];
  if (!self.isReady || bytes.length > 65536 || !CefPostTask(TID_UI, new BrowserUITask([target, bytes, reply] {
    NSDictionary *request = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
    if (![request isKindOfClass:NSDictionary.class]) { reply(nil, @"Invalid extension request."); return; }
    const bool remote = request[@"lease"] != nil;
    if ((remote && !AuthorizeExtensionRequest(target, request)) ||
        (!remote && extensionSurface && extensionSurface->Active())) {
      reply(nil, @"Extension control changed. Take Control again."); return;
    }
    auto source = AgentBrowserTarget(target);
    if (runtime.closing || !source || !source->IsValid() || !browsers.contains(source->GetIdentifier()) ||
        (!remote && AgentBrowserHumanControlled(source))) { reply(nil, @"The source page is closed or controlled by a Viewer."); return; }
    auto browser = EnsureExtensionManager();
    if (!browser) { reply(nil, @"Chromium could not open extension management."); return; }
    ConfigureExtensionStore(browser, target, remote ? request[@"lease"] : nil);
    if (remote && ([request[@"operation"] isEqual:@"uninstall"] ||
        ([request[@"operation"] isEqual:@"setEnabled"] && [request[@"enabled"] boolValue]))) {
      RevealWindow(browser);
      NSView *view = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
      extensionSurface->SetWindow(view.window);
    }
    auto client = static_cast<ExtensionManagerClient*>(browser->GetHost()->GetClient().get());
    client->Request(request, reply, [target, request, remote](NSString *url) -> NSString * {
      // Metadata lookup is asynchronous. Recheck the grant before opening or
      // focusing a native window, including Host takeover while it was pending.
      auto source = AgentBrowserTarget(target);
      if (runtime.closing || !source || !source->IsValid() || !browsers.contains(source->GetIdentifier()) ||
          (remote ? !AuthorizeExtensionRequest(target, request) :
              ((extensionSurface && extensionSurface->Active()) || AgentBrowserHumanControlled(source))))
        return @"Extension control changed before settings opened.";
      auto options = OpenExtensionOptionsWindow(url);
      if (!options) return @"Could not open extension settings.";
      NSView *view = (__bridge NSView *)options->GetHost()->GetWindowHandle();
      if (remote && !extensionSurface->SetWindow(view.window)) return @"Extension settings are unavailable.";
      return nil;
    });
  }))) reply(nil, @"Chromium is not ready or the extension request is too large.");
}
- (BOOL)setExtensionControl:(NSString *)token forTab:(NSString *)identifier {
  if (!self.isReady) return NO;
  if (!token.length) {
    if (extensionSurface && [extensionAnchor isEqual:identifier]) extensionSurface->Revoke();
    return YES;
  }
  if (extensionSurface && extensionSurface->Active()) return NO;
  auto source = AgentBrowserTarget(identifier);
  if (!source || !source->IsValid() || !browsers.contains(source->GetIdentifier()) ||
      !SetAgentBrowserHumanControl(identifier, token)) return NO;
  extensionAnchor = [identifier copy];
  extensionControlledPage = nil;
  NSString *anchor = extensionAnchor;
  extensionSurface = std::make_shared<ExtensionSurface>(token, [anchor] {
    auto browser = AgentBrowserTarget(anchor);
    return runtime.isReady && browser && browser->IsValid() && browsers.contains(browser->GetIdentifier());
  }, [anchor] {
    SetAgentBrowserHumanControl(anchor, nil);
    if (extensionControlledPage && ![extensionControlledPage isEqual:anchor])
      SetAgentBrowserHumanControl(extensionControlledPage, nil);
    extensionControlledPage = nil;
  });
  auto client = static_cast<EmbeddedClient*>(source->GetHost()->GetClient().get());
  if (client->IsExtensionWindow()) {
    NSView *view = (__bridge NSView *)source->GetHost()->GetWindowHandle();
    extensionSurface->SetWindow(view.window);
  }
  return YES;
}
- (void)requestExtensionSurfaceForTab:(NSString *)identifier request:(NSData *)request
    completion:(void (^)(NSData *, NSString *))completion {
  NSString *target = [identifier copy];
  NSData *bytes = [request copy];
  void (^reply)(NSData *, NSString *) = [completion copy];
  if (!self.isReady || bytes.length > 65536 || !CefPostTask(TID_UI, new BrowserUITask([target, bytes, reply] {
    NSDictionary *request = [NSJSONSerialization JSONObjectWithData:bytes options:0 error:nil];
    if (![request isKindOfClass:NSDictionary.class] || !AuthorizeExtensionRequest(target, request)) {
      reply(nil, @"Extension control expired. Take Control again."); return;
    }
    if ([request[@"action"] isEqual:@"ping"]) {
      reply([@"{}" dataUsingEncoding:NSUTF8StringEncoding], nil);
    } else if ([request[@"action"] isEqual:@"showManager"]) {
      auto browser = EnsureExtensionManager();
      if (!browser) { reply(nil, @"Chromium could not open extension management."); return; }
      ConfigureExtensionStore(browser, target, request[@"lease"]);
      RevealWindow(browser);
      NSView *view = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
      if (!extensionSurface->SetWindow(view.window)) { reply(nil, @"Extension management is unavailable."); return; }
      reply([@"{}" dataUsingEncoding:NSUTF8StringEncoding], nil);
    } else if ([request[@"action"] isEqual:@"openWindow"]) {
      auto grant = extensionSurface;
      OpenExtensionWindow(target, true, ^(NSString *page, NSString *error) {
        if (error) { reply(nil, error); return; }
        if (!grant->Authorize(request[@"lease"])) { reply(nil, @"Extension control expired."); return; }
        if (![page isEqual:target] && ![extensionControlledPage isEqual:page] &&
            !SetAgentBrowserHumanControl(page, request[@"lease"])) {
          reply(nil, @"The extension window is busy."); return;
        }
        extensionControlledPage = page;
        auto browser = AgentBrowserTarget(page);
        NSView *view = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
        if (!grant->SetWindow(view.window)) { reply(nil, @"The extension window is unavailable."); return; }
        reply([NSJSONSerialization dataWithJSONObject:@{@"tabID": page} options:0 error:nil], nil);
      });
    } else extensionSurface->Request(request, reply);
  }))) reply(nil, @"Chromium is not ready or the extension request is too large.");
}
- (void)showBrowserWindow:(NSString *)identifier {
  NSString *target = [identifier copy];
  if (!self.isReady) return;
  CefPostTask(TID_UI, new BrowserUITask([target] {
    auto browser = AgentBrowserTarget(target);
    if (runtime.closing || !browser || !browsers.contains(browser->GetIdentifier()) || AgentBrowserHumanControlled(browser)) return;
    auto client = static_cast<EmbeddedClient*>(browser->GetHost()->GetClient().get());
    if (client->IsExtensionWindow()) RevealWindow(browser);
  }));
}
- (void)closeTab:(NSString *)identifier {
  auto browser = AgentBrowserTarget(identifier);
  if (browser) { CloseDevToolsFor(browser); browser->GetHost()->CloseBrowser(true); }
}
- (BOOL)setHumanControl:(NSString *)token forTab:(NSString *)identifier {
  if (extensionSurface && extensionSurface->Active() &&
      ([extensionAnchor isEqual:identifier] || [extensionControlledPage isEqual:identifier])) {
    if (token.length) return NO;
    extensionSurface->Revoke();
  }
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
- (void)respondToNetworkPermission:(NSString *)permissionID forTab:(NSString *)identifier allow:(BOOL)allow controlToken:(NSString *)controlToken completion:(void (^)(NSString *))completion {
  if (!self.started || self.closing) { completion(@"Chromium is not ready."); return; }
  NSString *target = [identifier copy], *request = [permissionID copy], *control = [controlToken copy];
  void (^reply)(NSString *) = [completion copy];
  if (!CefPostTask(TID_UI, new BrowserUITask([target, request, control, allow, reply] {
    auto browser = AgentBrowserTarget(target);
    if (!runtime.isReady || !browser || !browser->IsValid() ||
        AgentBrowserHumanControlToken(browser) != std::string(control.UTF8String ?: "")) {
      reply(@"Browser control changed. The permission was not granted."); return;
    }
    auto client = static_cast<EmbeddedClient *>(browser->GetHost()->GetClient().get());
    reply(client->RespondToNetworkPermission(request, allow));
  }))) completion(@"Chromium could not schedule the permission response.");
}
- (void)beginShutdown {
  if (extensionSurface) extensionSurface->Revoke();
  self.closing = YES;
  [NSObject cancelPreviousPerformRequestsWithTarget:self selector:@selector(runBrowserLoop) object:nil];
  self.startScheduled = NO;
  [self traceShutdownStage:@"begin"];
  auto copy = browsers;
  StopAgentBrowser();
  for (auto& [id, browser] : copy) { CloseDevToolsFor(browser); browser->GetHost()->CloseBrowser(true); }
  auto tools = devToolsBrowsers;
  for (auto& [id, browser] : tools) browser->GetHost()->CloseBrowser(true);
  auto extensions = extensionTools;
  for (auto& [id, browser] : extensions) browser->GetHost()->CloseBrowser(true);
}
- (BOOL)finishShutdown {
  if (!self.started) { [self traceShutdownStage:@"finished"]; return YES; }
  if (!browsers.empty() || !devToolsBrowsers.empty() || !extensionTools.empty() || pendingDevTools.load() != 0 || pendingExtensionCaptures != 0) {
    [self traceShutdownStage:@"waiting-pages"];
    return NO;
  }
  if (!AgentBrowserTransportsStopped()) {
    [self traceShutdownStage:@"waiting-transports"];
    return NO;
  }
  // Closing the native views does not guarantee Chromium's pending cookie
  // writes reached disk. Keep its pump alive until the cookie-store completion
  // callback, rather than shutting down the network service immediately.
  if (!self.cookieFlushRequested) {
    self.cookieFlushRequested = YES;
    [self traceShutdownStage:@"request-cookie-flush"];
    auto cookies = CefCookieManager::GetGlobalManager(nullptr);
    if (!cookies || !cookies->FlushStore(new CookieFlushCompletion())) {
      NSLog(@"CtrlX Agent Browser could not flush cookies before shutdown.");
      self.cookiesFlushed = YES; // Do not hang application quit on inaccessible storage.
    }
  }
  if (!self.cookiesFlushed) { [self traceShutdownStage:@"waiting-cookie-flush"]; return NO; }
  // CefShutdown spins native run loops while joining Chromium threads. Calling
  // it from a Swift main-actor job holds the serial main executor and can block
  // work those threads need. Enter from an AppKit run-loop callback instead.
  if (!self.shutdownScheduled) {
    self.shutdownScheduled = YES;
    [self traceShutdownStage:@"schedule-native-shutdown"];
    [self performSelector:@selector(shutdownOnRunLoop) withObject:nil afterDelay:0];
  }
  [self traceShutdownStage:@"waiting-native-loop"];
  return NO;
}
- (void)shutdownOnRunLoop {
  self.shuttingDown = YES;
  [self traceShutdownStage:@"native-stop-loop"];
  if (self.loopRunning) {
    CefQuitMessageLoop();
  } else {
    // Shutdown may race the deferred first entry into the native loop.
    CefShutdown();
    self.started = NO;
    [self traceShutdownStage:@"native-shutdown-finished"];
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
extern "C" __attribute__((visibility("default"))) void CXEmbeddedBrowserSetTerminationDelegate(id<CXBrowserTerminationDelegate> delegate) {
  applicationTerminationDelegate = delegate;
}
extern "C" __attribute__((visibility("default"))) void CXEmbeddedBrowserSetDiagnosticsDelegate(id<CXApplicationDiagnosticsDelegate> delegate) {
  applicationDiagnosticsDelegate = delegate;
}
extern "C" __attribute__((visibility("default"))) void CXEmbeddedBrowserSetDebugMode(BOOL enabled) {
  browserDebugMode = enabled;
}
