// Included by EmbeddedBrowser.mm. These profile administration operations never
// enter the Agent page gateway or accept arbitrary JavaScript/CDP from a Viewer.
#include "include/cef_version.h"
@interface CXExtensionPackageDrag : NSObject <NSDraggingInfo>
@property(nonatomic, strong) NSPasteboard *pasteboard;
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic) NSPoint location;
@end
@implementation CXExtensionPackageDrag
- (NSWindow *)draggingDestinationWindow { return self.window; }
- (NSDraggingFormation)draggingFormation { return NSDraggingFormationNone; }
- (void)setDraggingFormation:(NSDraggingFormation)value {}
- (NSPoint)draggingLocation { return self.location; }
- (NSPasteboard *)draggingPasteboard { return self.pasteboard; }
- (NSInteger)draggingSequenceNumber { return 1; }
- (id)draggingSource { return nil; }
- (NSDragOperation)draggingSourceOperationMask { return NSDragOperationCopy; }
- (NSImage *)draggedImage { return nil; }
- (NSPoint)draggedImageLocation { return self.location; }
- (void)slideDraggedImageTo:(NSPoint)point {}
- (NSArray *)namesOfPromisedFilesDroppedAtDestination:(NSURL *)destination { return @[]; }
- (BOOL)animatesToDestination { return NO; }
- (void)setAnimatesToDestination:(BOOL)value {}
- (NSInteger)numberOfValidItemsForDrop { return 1; }
- (void)setNumberOfValidItemsForDrop:(NSInteger)value {}
- (void)enumerateDraggingItemsWithOptions:(NSDraggingItemEnumerationOptions)options forView:(NSView *)view
    classes:(NSArray *)classes searchOptions:(NSDictionary *)searchOptions
    usingBlock:(void (^)(NSDraggingItem *, NSInteger, BOOL *))block {}
- (NSSpringLoadingHighlight)springLoadingHighlight { return NSSpringLoadingHighlightNone; }
- (void)resetSpringLoading {}
@end

static CefRefPtr<CefBrowser> extensionManager;
static std::map<std::string, int> extensionOptionsWindows;

static CefRefPtr<CefBrowser> OpenExtensionOptionsWindow(NSString *url) {
  CefRefPtr<CefBrowser> browser;
  auto saved = extensionOptionsWindows.find(url.UTF8String);
  if (saved != extensionOptionsWindows.end()) {
    auto found = extensionTools.find(saved->second);
    if (found != extensionTools.end() && found->second->IsValid()) browser = found->second;
  }
  if (!browser) {
    CefWindowInfo info;
    info.runtime_style = CEF_RUNTIME_STYLE_CHROME;
    info.bounds = CefRect(0, 0, 1100, 750);
    browser = CefBrowserHost::CreateBrowserSync(info, new ExtensionToolClient(),
        url.UTF8String, CefBrowserSettings(), nullptr, nullptr);
    if (browser) extensionOptionsWindows[url.UTF8String] = browser->GetIdentifier();
  } else {
    const auto current = browser->GetMainFrame()->GetURL().ToString();
    const std::string requested = url.UTF8String;
    if (current.substr(0, current.find('#')) != requested.substr(0, requested.find('#')))
      browser->GetMainFrame()->LoadURL(url.UTF8String);
  }
  if (browser) {
    NSView *view = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
    [view.window makeKeyAndOrderFront:nil];
    browser->GetHost()->SetFocus(true);
  }
  return browser;
}

class ExtensionManagerClient final : public CefClient, public CefLifeSpanHandler,
    public CefLoadHandler, public CefDevToolsMessageObserver {
 public:
  using Completion = void (^)(NSData *, NSString *);
  using OptionsPresenter = std::function<NSString *(NSString *)>;
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    extensionManager = browser;
    browser_ = browser;
    extensionTools[browser->GetIdentifier()] = browser;
    observer_ = browser->GetHost()->AddDevToolsMessageObserver(this);
    if (runtime.closing) browser->GetHost()->CloseBrowser(true);
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    Finish(nil, @"Extension management was closed.");
    observer_ = nullptr;
    extensionTools.erase(browser->GetIdentifier());
    if (extensionManager == browser) extensionManager = nullptr;
    browser_ = nullptr;
  }
  void OnLoadEnd(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame> frame, int) override {
    if (!frame->IsMain()) return;
    ready_ = frame->GetURL().ToString() == "chrome://extensions/";
    if (request_) {
      if (ready_) Begin();
      else Finish(nil, @"Extension management navigated away from its trusted page.");
    }
  }
  bool OnBeforePopup(CefRefPtr<CefBrowser>, CefRefPtr<CefFrame>, int,
      const CefString&, const CefString&, WindowOpenDisposition, bool,
      const CefPopupFeatures&, CefWindowInfo&, CefRefPtr<CefClient>& client,
      CefBrowserSettings&, CefRefPtr<CefDictionaryValue>&, bool*) override {
    client = new ExtensionToolClient();
    return false;
  }

  void Request(NSDictionary *request, Completion completion, OptionsPresenter optionsPresenter = nullptr) {
    CEF_REQUIRE_UI_THREAD();
    if (busy_) { completion(nil, @"Another extension operation is in progress."); return; }
    busy_ = true;
    request_ = [request copy];
    completion_ = [completion copy];
    optionsPresenter_ = std::move(optionsPresenter);
    const int generation = ++generation_;
    CefRefPtr<ExtensionManagerClient> self = this;
    CefPostDelayedTask(TID_UI, new BrowserUITask([self, generation] {
      if (self->generation_ != generation || !self->completion_) return;
      if (self->request_) {
        self->Finish(nil, @"Extension management did not load. No operation was started.");
      } else {
        // A permission dialog or installer may still complete. Do not release
        // serialization or let a caller mistake a deadline for a rolled-back install.
        Completion completion = self->completion_;
        self->completion_ = nil;
        completion(nil, @"Chromium is still processing the extension operation. Its outcome is not yet known.");
      }
    }), 30000);
    if (ready_) Begin();
  }

  void OnDevToolsMethodResult(CefRefPtr<CefBrowser>, int message, bool success,
      const void *bytes, size_t size) override {
    NSDictionary *response = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:size]
        options:0 error:nil];
    const int generation = generation_;
    CefRefPtr<ExtensionManagerClient> self = this;
    // Some browser-side replies are synchronous. Wait until ExecuteDevToolsMethod
    // returns its assigned ID; also avoid reentering CEF's observer list.
    CefPostTask(TID_UI, new BrowserUITask([self, generation, message, response, success] {
      if (!self->busy_ || self->generation_ != generation || message != self->activeMessage_) return;
      auto callback = std::move(self->pending_);
      self->pending_ = nullptr;
      if (!success || ![response isKindOfClass:NSDictionary.class] || response[@"exceptionDetails"]) {
        NSString *error = response[@"exceptionDetails"][@"exception"][@"description"];
        self->Finish(nil, [error isKindOfClass:NSString.class] ? error : @"Chromium rejected the extension operation.");
        return;
      }
      if (callback) callback(response[@"result"][@"value"]);
    }));
  }

 private:
  bool Trusted() const {
    return browser_ && browser_->IsValid() && !runtime.closing &&
        browser_->GetMainFrame()->GetURL().ToString() == "chrome://extensions/";
  }
  void Evaluate(NSString *script, std::function<void(id)> callback) {
    if (!Trusted()) { Finish(nil, @"The extension management page is unavailable."); return; }
    pending_ = std::move(callback);
    auto params = CefDictionaryValue::Create();
    params->SetString("expression", script.UTF8String);
    params->SetBool("returnByValue", true);
    params->SetBool("awaitPromise", true);
    // This boundary is called only for an explicit human management action.
    // Chromium requires that gesture for uninstall and permission changes.
    params->SetBool("userGesture", true);
    params->SetDouble("timeout", 20000);
    activeMessage_ = browser_->GetHost()->ExecuteDevToolsMethod(0, "Runtime.evaluate", params);
    if (!activeMessage_)
      Finish(nil, @"Chromium could not start the extension operation.");
  }
  void Begin() {
    NSDictionary *request = request_;
    request_ = nil;
    NSString *operation = request[@"operation"];
    if (![operation isKindOfClass:NSString.class]) { Finish(nil, @"Invalid extension operation."); return; }
    if ([operation isEqualToString:@"install"]) {
      NSString *path = request[@"path"];
      NSString *root = [[[NSURL fileURLWithPath:runtime.profile] URLByAppendingPathComponent:@"CtrlXExtensions/packages"]
          URLByResolvingSymlinksInPath].path;
      NSString *resolved = [path isKindOfClass:NSString.class] ?
          [NSURL fileURLWithPath:path].URLByResolvingSymlinksInPath.path : nil;
      BOOL directory = NO;
      if (!resolved || ![resolved hasPrefix:[root stringByAppendingString:@"/"]] ||
          ![[NSFileManager defaultManager] fileExistsAtPath:resolved isDirectory:&directory] || !directory) {
        Finish(nil, @"Only a validated Host-managed extension directory can be installed."); return;
      }
      // Chromium accepts native drag data only while its window is visible.
      // Keep it behind the review sheet; no focus change is needed for loading.
      NSView *view = (__bridge NSView *)browser_->GetHost()->GetWindowHandle();
      hideAfter_ = !view.window.isVisible;
      returnWindow_ = NSApp.keyWindow;
      if (hideAfter_) [view.window orderBack:nil];
      Evaluate(@R"JS((async () => {
        await chrome.developerPrivate.updateProfileConfiguration({inDeveloperMode: true});
        return true;
      })())JS", [this, resolved](id) { Install(resolved); });
      return;
    }
    if ([operation isEqualToString:@"list"]) { List(); return; }
    NSString *identifier = request[@"id"];
    NSCharacterSet *invalid = [[NSCharacterSet characterSetWithCharactersInString:@"abcdefghijklmnop"] invertedSet];
    if (![identifier isKindOfClass:NSString.class] || identifier.length != 32 ||
        [identifier rangeOfCharacterFromSet:invalid].location != NSNotFound) {
      Finish(nil, @"Invalid extension ID."); return;
    }
    NSData *json = [NSJSONSerialization dataWithJSONObject:request options:0 error:nil];
    NSString *parameters = [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding];
    if ([operation isEqualToString:@"openOptions"]) {
      NSString *script = [NSString stringWithFormat:@R"JS((async () => {
        const p = %@;
        const entries = await chrome.developerPrivate.getExtensionsInfo({includeDisabled: true, includeTerminated: true});
        const entry = entries.find(item => item.id === p.id);
        if (!entry || entry.state !== 'ENABLED' || !entry.optionsPage)
          throw new Error('This extension has no available settings page. Enable it first if disabled.');
        const page = entry.optionsPage;
        if (!page.url.startsWith('chrome-extension://' + p.id + '/'))
          throw new Error('Unsupported extension settings address.');
        return page.openInTab ? page.url : 'chrome://extensions/?options=' + p.id;
      })())JS", parameters];
      Evaluate(script, [this](id value) {
        if (![value isKindOfClass:NSString.class]) { Finish(nil, @"Invalid extension settings address."); return; }
        NSString *error = optionsPresenter_ ? optionsPresenter_(value) :
            (OpenExtensionOptionsWindow(value) ? nil : @"Could not open extension settings.");
        Finish(error ? nil : [@"{\"extensions\":[]}" dataUsingEncoding:NSUTF8StringEncoding], error);
      });
      return;
    }
    if (![operation isEqualToString:@"setEnabled"] && ![operation isEqualToString:@"uninstall"] &&
        ![operation isEqualToString:@"reload"]) {
      Finish(nil, @"Unsupported extension operation."); return;
    }
    // Listing, disabling and reloading do not need a visible tool
    // window. Show only operations that may require native user confirmation.
    if ([operation isEqualToString:@"uninstall"] ||
        ([operation isEqualToString:@"setEnabled"] && [request[@"enabled"] boolValue])) {
      NSView *view = (__bridge NSView *)browser_->GetHost()->GetWindowHandle();
      hideAfter_ = !view.window.isVisible;
      returnWindow_ = NSApp.keyWindow;
      [view.window makeKeyAndOrderFront:nil];
      browser_->GetHost()->SetFocus(true);
    }
    NSString *script = [NSString stringWithFormat:@R"JS((async () => {
      const p = %@;
      if (p.operation === 'setEnabled') await chrome.management.setEnabled(p.id, p.enabled === true);
      else if (p.operation === 'uninstall') await chrome.management.uninstall(p.id, {showConfirmDialog: true});
      else await chrome.developerPrivate.reload(p.id, {failQuietly: true, populateErrorForUnpacked: true}).then(error => {
        if (error) throw new Error(error.error || 'Extension reload failed');
      });
      return true;
    })())JS", parameters];
    Evaluate(script, [this](id) { List(); });
  }
  void List() {
    Evaluate(@R"JS((async () => {
      const entries = await chrome.developerPrivate.getExtensionsInfo({includeDisabled: true, includeTerminated: true});
      return {extensions: entries.map(({id, name, version, description, state, location, path, optionsPage}) =>
        ({id, name, version, description, state, location, path, hasOptions: !!optionsPage}))};
    })())JS", [this](id value) {
      NSError *error = nil;
      NSMutableDictionary *result = [value isKindOfClass:NSDictionary.class] ? [value mutableCopy] : nil;
      result[@"chromiumVersion"] = [NSString stringWithFormat:@"%d.%d.%d.%d",
          CHROME_VERSION_MAJOR, CHROME_VERSION_MINOR, CHROME_VERSION_BUILD, CHROME_VERSION_PATCH];
      NSData *json = result ? [NSJSONSerialization dataWithJSONObject:result options:0 error:&error] : nil;
      Finish(json, json ? nil : @"Chromium returned an invalid extension list.");
    });
  }
  void Install(NSString *path) {
    if (!Trusted()) { Finish(nil, @"The extension management page is unavailable."); return; }
    NSView *view = (__bridge NSView *)browser_->GetHost()->GetWindowHandle();
    NSView *target = [view hitTest:NSMakePoint(NSMidX(view.bounds), NSMidY(view.bounds))];
    while (target && ![target.registeredDraggedTypes containsObject:NSPasteboardTypeFileURL]) target = target.superview;
    if (!target) { Finish(nil, @"Chromium has no extension package drop destination."); return; }
    dragView_ = target;
    drag_ = [[CXExtensionPackageDrag alloc] init];
    drag_.pasteboard = [NSPasteboard pasteboardWithUniqueName];
    [drag_.pasteboard writeObjects:@[[NSURL fileURLWithPath:path isDirectory:YES]]];
    drag_.window = view.window;
    drag_.location = [view convertPoint:NSMakePoint(NSMidX(view.bounds), NSMidY(view.bounds)) toView:nil];
    [target draggingEntered:drag_];
    Evaluate(@R"JS((async () => {
      await chrome.developerPrivate.notifyDragInstallInProgress();
      const error = await chrome.developerPrivate.loadUnpacked({useDraggedPath: true, failQuietly: true, populateError: true});
      if (error) throw new Error(error.error || 'Extension installation failed');
      return true;
    })())JS", [this](id) { EndDrag(); List(); });
  }
  void EndDrag() {
    if (!drag_) return;
    [dragView_ draggingExited:drag_];
    [drag_.pasteboard releaseGlobally];
    drag_ = nil;
    dragView_ = nil;
  }
  void Finish(NSData *result, NSString *error) {
    EndDrag();
    request_ = nil;
    pending_ = nullptr;
    optionsPresenter_ = nullptr;
    Completion completion = completion_;
    completion_ = nil;
    busy_ = false;
    if (hideAfter_) {
      NSView *view = browser_ ? (__bridge NSView *)browser_->GetHost()->GetWindowHandle() : nil;
      BOOL restore = view.window.isKeyWindow || NSApp.keyWindow.parentWindow == view.window;
      [view.window orderOut:nil];
      if (restore && returnWindow_.isVisible) [returnWindow_ makeKeyAndOrderFront:nil];
    }
    hideAfter_ = false;
    returnWindow_ = nil;
    if (completion) completion(result, error);
  }

  bool ready_ = false, busy_ = false;
  int generation_ = 0, activeMessage_ = 0;
  NSDictionary *request_ = nil;
  Completion completion_ = nil;
  std::function<void(id)> pending_;
  OptionsPresenter optionsPresenter_;
  CefRefPtr<CefRegistration> observer_;
  CefRefPtr<CefBrowser> browser_;
  NSView *dragView_ = nil;
  CXExtensionPackageDrag *drag_ = nil;
  bool hideAfter_ = false;
  NSWindow *returnWindow_ = nil;
  IMPLEMENT_REFCOUNTING(ExtensionManagerClient);
};

static CefRefPtr<CefBrowser> EnsureExtensionManager() {
  if (extensionManager && extensionManager->IsValid() &&
      extensionManager->GetMainFrame()->GetURL().ToString() == "chrome://extensions/") return extensionManager;
  // Do not orphan a manager that the user navigated away from.
  if (extensionManager && extensionManager->IsValid()) extensionManager->GetHost()->CloseBrowser(true);
  CefWindowInfo info;
  info.runtime_style = CEF_RUNTIME_STYLE_CHROME;
  info.bounds = CefRect(0, 0, 1100, 750);
  NSWindow *previous = NSApp.keyWindow;
  auto browser = CefBrowserHost::CreateBrowserSync(info, new ExtensionManagerClient(),
      "chrome://extensions/", CefBrowserSettings(), nullptr, nullptr);
  // CefWindowInfo.hidden controls the view, not Chrome's top-level window.
  // Keep the native manager available without covering the CtrlX management UI.
  if (browser) {
    NSView *view = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
    [view.window orderOut:nil];
    if (previous.isVisible) [previous makeKeyAndOrderFront:nil];
  }
  return browser;
}
