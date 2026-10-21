// Isolated characterization of extension APIs, never linked into CtrlX.
#import <Cocoa/Cocoa.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <map>
#include <functional>
#include <cmath>
#include "include/cef_app.h"
#include "include/cef_application_mac.h"
#include "include/cef_client.h"
#include "include/cef_command_line.h"
#include "include/cef_parser.h"
#include "include/cef_task.h"
#include "include/wrapper/cef_helpers.h"
#include "include/wrapper/cef_library_loader.h"

// Private pasteboard and an exact probe WebContents; never the user's clipboard.
@interface ExtensionProbeDrag : NSObject <NSDraggingInfo>
@property(nonatomic, strong) NSPasteboard *pasteboard;
@property(nonatomic, strong) NSWindow *window;
@property(nonatomic) NSPoint location;
@end
@implementation ExtensionProbeDrag
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

@interface ExtensionProbeRuntime : NSObject
@property(nonatomic, copy) NSString *profile;
@property(nonatomic) BOOL closing;
@end
@implementation ExtensionProbeRuntime
@end

namespace {
NSDictionary *configuration;
ExtensionProbeRuntime *runtime;
NSString *installedFixtureID;
NSWindow *embeddedWindow;
std::map<int, CefRefPtr<CefBrowser>> browsers;
std::map<int, CefRefPtr<CefBrowser>> extensionTools;
std::map<int, NSView *> containers;
std::map<int, CefRefPtr<CefRegistration>> observers;
std::map<int, int> completedLoads;
CefRefPtr<CefBrowser> manager, embeddedA, embeddedB, control;
NSString *envInputSession;
void HandleENVInput(NSDictionary *parameters);
bool closing = false, started = false, expectingInstallDialog = false;
int resultCode = 1, nextMessage = 0;
std::map<int, std::function<void(NSDictionary *)>> pending;

void Report(NSString *phase, NSDictionary *result) {
  NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"phase": phase, @"result": result}
      options:0 error:nil];
  fprintf(stdout, "EXTENSION_PROBE %.*s\n", (int)data.length, (const char *)data.bytes);
  fflush(stdout);
}

class Action final : public CefTask {
 public:
  explicit Action(std::function<void()> action) : action_(std::move(action)) {}
  void Execute() override { action_(); }
 private:
  std::function<void()> action_;
  IMPLEMENT_REFCOUNTING(Action);
};

void Later(int milliseconds, std::function<void()> action) {
  CefPostDelayedTask(TID_UI, new Action(std::move(action)), milliseconds);
}

void WaitForClose() {
  if (browsers.empty() && extensionTools.empty()) CefQuitMessageLoop();
  else Later(50, WaitForClose);
}

void CloseAll() {
  if (closing) return;
  closing = true;
  runtime.closing = YES;
  pending.clear();
  auto copy = browsers;
  for (auto& [id, browser] : copy) browser->GetHost()->CloseBrowser(true);
  auto tools = extensionTools;
  for (auto& [id, browser] : tools) if (!copy.contains(id)) browser->GetHost()->CloseBrowser(true);
  Later(50, WaitForClose);
}

void Evaluate(CefRefPtr<CefBrowser> browser, NSString *javascript,
              std::function<void(NSDictionary *)> callback) {
  auto params = CefDictionaryValue::Create();
  params->SetString("expression", javascript.UTF8String);
  params->SetBool("returnByValue", true);
  params->SetBool("awaitPromise", true);
  params->SetDouble("timeout", 15000);
  int message = browser->GetHost()->ExecuteDevToolsMethod(0, "Runtime.evaluate", params);
  nextMessage = std::max(nextMessage, message);
  pending[message] = [callback](NSDictionary *response) {
    if (response[@"exceptionDetails"] || !response[@"result"][@"value"]) {
      Report(@"failure", @{@"response": response}); CloseAll(); return;
    }
    callback(response[@"result"][@"value"]);
  };
  if (!message) {
    Report(@"failure", @{@"error": @"Could not submit fixture evaluation"});
    CloseAll();
  }
}

NSString *PageProbe() {
  return @R"JS((async () => {
    const deadline = Date.now() + 8000;
    while (!document.documentElement.dataset.ctrlxExtension && Date.now() < deadline)
      await new Promise(resolve => setTimeout(resolve, 50));
    if (!document.documentElement.dataset.ctrlxExtension) throw new Error('Content script did not load');
    const extension = await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('Extension response timed out')), 8000);
      function receive(event) {
        if (event.source !== window || event.data?.kind !== 'ctrlx-extension-result') return;
        clearTimeout(timeout); window.removeEventListener('message', receive);
        event.data.error ? reject(new Error(event.data.error)) : resolve(event.data.result);
      }
      window.addEventListener('message', receive);
      window.postMessage({kind: 'ctrlx-extension-probe'}, location.origin);
    });
    const echo = await (await fetch('/echo', {cache: 'no-store'})).json();
    const cors = window.ctrlxCORSProbe ? await window.ctrlxCORSProbe() : null;
    return {url: location.href, extension, echo, cors};
  })())JS";
}

void BeginChecks();

class Client : public CefClient, public CefLifeSpanHandler,
    public CefLoadHandler, public CefDevToolsMessageObserver, public CefDialogHandler {
 public:
  explicit Client(NSView *container = nil) : container_(container) {}
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override { return this; }
  CefRefPtr<CefLoadHandler> GetLoadHandler() override { return this; }
  CefRefPtr<CefDialogHandler> GetDialogHandler() override { return this; }
  bool OnFileDialog(CefRefPtr<CefBrowser> browser, FileDialogMode mode, const CefString&,
      const CefString&, const std::vector<CefString>&, const std::vector<CefString>&,
      const std::vector<CefString>&, CefRefPtr<CefFileDialogCallback> callback) override {
    if (browser != manager || !expectingInstallDialog || mode != FILE_DIALOG_OPEN_FOLDER) return false;
    expectingInstallDialog = false;
    callback->Continue({CefString([configuration[@"extension"] UTF8String])});
    Report(@"install-dialog", @{@"selectedPrivateFixture": @YES});
    return true;
  }
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    int id = browser->GetIdentifier();
    browsers[id] = browser;
    observers[id] = browser->GetHost()->AddDevToolsMessageObserver(this);
    if (container_) {
      containers[id] = container_;
      NSView *view = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
      view.frame = container_.bounds;
      view.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
      Report(@"embedded-view", @{@"alloy": @(browser->GetHost()->GetRuntimeStyle() == CEF_RUNTIME_STYLE_ALLOY),
          @"attached": @([view isDescendantOf:container_] && view.window == embeddedWindow)});
    }
  }
  bool DoClose(CefRefPtr<CefBrowser>) override {
    if (!container_) return false;
    container_.subviews = @[];
    [container_ removeFromSuperview];
    return true;
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    CEF_REQUIRE_UI_THREAD();
    int id = browser->GetIdentifier();
    observers.erase(id);
    containers.erase(id);
    browsers.erase(id);
    container_ = nil;
    if (closing && browsers.empty() && extensionTools.empty()) CefQuitMessageLoop();
  }
  void OnLoadEnd(CefRefPtr<CefBrowser> browser, CefRefPtr<CefFrame> frame, int status) override {
    if (!frame->IsMain()) return;
    ++completedLoads[browser->GetIdentifier()];
    Report(@"loaded", @{@"url": @(frame->GetURL().ToString().c_str()), @"status": @(status),
        @"style": browser->GetHost()->GetRuntimeStyle() == CEF_RUNTIME_STYLE_ALLOY ? @"alloy" : @"chrome"});
  }
  void OnDevToolsMethodResult(CefRefPtr<CefBrowser>, int message, bool success,
                             const void *bytes, size_t size) override {
    auto it = pending.find(message);
    if (it == pending.end()) return;
    auto callback = std::move(it->second);
    pending.erase(it);
    NSDictionary *response = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:size]
        options:0 error:nil];
    if (!success) {
      Report(@"failure", @{@"message": @(message), @"response": response ?: @{}, @"success": @(success)});
      CloseAll();
      return;
    }
    Later(0, [callback, response] { if (!closing) callback(response); });
  }
  bool OnDevToolsMessage(CefRefPtr<CefBrowser>, const void *bytes, size_t size) override {
    NSDictionary *message = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:size]
        options:0 error:nil];
    if ([message[@"sessionId"] isEqual:envInputSession] &&
        [message[@"method"] isEqual:@"Runtime.bindingCalled"] &&
        [message[@"params"][@"name"] isEqual:@"ctrlxProbeInsertText"]) {
      Later(0, [message] { if (!closing) HandleENVInput(message[@"params"]); });
      return true;
    }
    if (!message[@"sessionId"] || !message[@"id"]) return false;
    auto it = pending.find([message[@"id"] intValue]);
    if (it == pending.end()) return false;
    auto callback = std::move(it->second);
    pending.erase(it);
    if (message[@"error"]) { Report(@"failure", message); CloseAll(); }
    else Later(0, [callback, message] { if (!closing) callback(message[@"result"] ?: @{}); });
    return true;
  }
 private:
  NSView *container_;
  IMPLEMENT_REFCOUNTING(Client);
};

using BrowserUITask = Action;
class ExtensionToolClient final : public Client {
 public:
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override {
    Client::OnAfterCreated(browser);
    extensionTools[browser->GetIdentifier()] = browser;
  }
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override {
    extensionTools.erase(browser->GetIdentifier());
    Client::OnBeforeClose(browser);
  }
};
}

// Exercise the actual product implementation in this isolated executable.
#include "../../CtrlxPackage/AgentBrowser/BrowserExtensions.inc"
#include "../../CtrlxPackage/AgentBrowser/ExtensionSurface.inc"

namespace {
#include "NativeWindowProbe.inc"

void AdminOperation(NSDictionary *request, std::function<void(NSDictionary *)> callback) {
  auto client = static_cast<ExtensionManagerClient*>(manager->GetHost()->GetClient().get());
  client->Request(request, ^(NSData *data, NSString *error) {
    if (error || !data) { Report(@"failure", @{@"error": error ?: @"Missing admin response"}); CloseAll(); return; }
    NSDictionary *value = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
    callback(value);
  });
}

#include "OptionsProbe.inc"

void ConfirmFixtureRemoval(int attempt) {
    if (closing) return;
    NSMutableArray *windows = [NSMutableArray array];
    id button = nil;
    NSWindow *dialogWindow = nil;
    int matches = 0;
    for (NSWindow *window in NSApp.windows) {
      if (!window.isVisible) continue;
      // This helper is compiled only into the disposable probe. Match the exact
      // known fixture dialog in this process; never operate another app's UI.
      bool fixtureDialog = [window.title isEqualToString:@"Remove \"CtrlX Extension Compatibility Fixture\"?"];
      NSMutableArray *nodes = [NSMutableArray array];
      std::function<void(id, int)> collect = [&](id node, int depth) {
        if (depth > 16 || nodes.count >= 500) return;
        NSString *role = [node respondsToSelector:@selector(accessibilityRole)] ? [node accessibilityRole] : @"";
        NSString *title = [node respondsToSelector:@selector(accessibilityTitle)] ? [node accessibilityTitle] : @"";
        NSString *label = [node respondsToSelector:@selector(accessibilityLabel)] ? [node accessibilityLabel] : @"";
        if (fixtureDialog && [role isEqualToString:NSAccessibilityButtonRole] && [label isEqualToString:@"Remove"]) {
          button = node; dialogWindow = window; ++matches;
        }
        if (role.length || title.length || label.length) [nodes addObject:@{@"role": role ?: @"", @"title": title ?: @"", @"label": label ?: @""}];
        if ([node respondsToSelector:@selector(accessibilityChildren)])
          for (id child in [node accessibilityChildren]) collect(child, depth + 1);
      };
      collect(window, 0);
      [windows addObject:@{@"title": window.title ?: @"", @"nodes": nodes}];
    }
    if (matches == 0 && attempt < 40) { Later(250, [attempt] { ConfirmFixtureRemoval(attempt + 1); }); return; }
    if (matches == 1 && attempt < 100) {
      // Chromium protects newly shown confirmation UI from immediate clicks.
      // Re-find the exact fixture button after the dialog has been visible.
      Later(1500, [] { ConfirmFixtureRemoval(100); }); return;
    }
    Report(@"uninstall-ui", @{@"windows": windows});
    if (matches != 1 || ![button respondsToSelector:@selector(accessibilityFrame)] || !dialogWindow) {
      Report(@"failure", @{@"error": @"Could not confirm the exact fixture uninstall dialog"}); CloseAll(); return;
    }
    NSRect frame = [button accessibilityFrame];
    Report(@"uninstall-button", @{@"frame": NSStringFromRect(frame),
        @"enabled": @([button isAccessibilityEnabled]), @"window": NSStringFromRect(dialogWindow.frame)});
    if ([configuration[@"nativeManagerInput"] boolValue]) {
      NSView *view = (__bridge NSView *)manager->GetHost()->GetWindowHandle();
      NSWindow *source = view.window;
      NSWindow *ancestor = dialogWindow;
      while (ancestor && ancestor != source) ancestor = ancestor.parentWindow;
      if (ancestor != source) {
        Report(@"failure", @{@"error": @"Uninstall confirmation is not owned by the exact manager window"}); CloseAll(); return;
      }
      CaptureOwnedWindow(source, @"native-uninstall.png", [source, frame] {
        double x = NSMidX(frame) - NSMinX(source.frame);
        double y = NSMaxY(source.frame) - NSMidY(frame);
        if (!ClickOwnedWindow(source, x, y)) {
          Report(@"failure", @{@"error": @"Uninstall confirmation lies outside the captured manager"}); CloseAll(); return;
        }
        Report(@"uninstall-confirmation", @{@"fixtureOnly": @YES, @"pressed": @YES, @"method": @"owned-manager-tree"});
      });
      return;
    }
    NSPoint point = [dialogWindow convertPointFromScreen:NSMakePoint(NSMidX(frame), NSMidY(frame))];
    [NSApp activateIgnoringOtherApps:YES];
    [dialogWindow makeKeyAndOrderFront:nil];
    for (NSEventType type : {NSEventTypeLeftMouseDown, NSEventTypeLeftMouseUp}) {
      NSEvent *event = [NSEvent mouseEventWithType:type location:point modifierFlags:0
          timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:dialogWindow.windowNumber
          context:nil eventNumber:0 clickCount:1 pressure:type == NSEventTypeLeftMouseDown ? 1 : 0];
      [NSApp sendEvent:event];
    }
    Report(@"uninstall-confirmation", @{@"fixtureOnly": @YES, @"pressed": @YES, @"method": @"own-window-mouse"});
    Later(1000, [] {
      if (closing) return;
      int dialogs = 0;
      for (NSWindow *window in NSApp.windows)
        if (window.isVisible && [window.title isEqualToString:@"Remove \"CtrlX Extension Compatibility Fixture\"?"]) ++dialogs;
      Report(@"uninstall-after-click", @{@"remainingDialogs": @(dialogs)});
    });
}

void FinishCompatibility() {
  if (![configuration[@"productionAdmin"] boolValue]) { resultCode = 0; CloseAll(); return; }
  manager = EnsureExtensionManager();
  if (!manager) { Report(@"failure", @{@"error": @"Could not reopen manager for uninstall"}); CloseAll(); return; }
  Later(250, [] { ConfirmFixtureRemoval(0); });
  AdminOperation(@{@"operation": @"uninstall", @"id": installedFixtureID}, [](NSDictionary *result) {
    Report(@"production-admin-uninstalled", result);
    for (NSDictionary *item in result[@"extensions"]) {
      if ([item[@"id"] isEqual:installedFixtureID]) {
        Report(@"failure", @{@"error": @"Uninstalled fixture remains in the runtime"}); CloseAll(); return;
      }
    }
    resultCode = 0; CloseAll();
  });
}

CefRefPtr<CefBrowser> Chrome(NSString *url) {
  CefWindowInfo info;
  info.runtime_style = CEF_RUNTIME_STYLE_CHROME;
  CefBrowserSettings settings;
  return CefBrowserHost::CreateBrowserSync(info, new Client(), url.UTF8String, settings, nullptr, nullptr);
}

void InspectCompatibility() {
  if (closing) return;
  if (!manager || !embeddedA || !embeddedB) {
    Report(@"failure", @{@"error": @"A required browser was not created"});
    CloseAll(); return;
  }
  if ([configuration[@"productionAdmin"] boolValue])
    observers[manager->GetIdentifier()] = manager->GetHost()->AddDevToolsMessageObserver(new Client());
  Evaluate(manager, @R"JS((async () => {
    const extensions = await chrome.developerPrivate.getExtensionsInfo({includeDisabled: true, includeTerminated: true});
    return {profile: await chrome.developerPrivate.getProfileConfiguration(),
      extensions: extensions.map(({id, name, state, location, version}) => ({id, name, state, location, version}))};
  })())JS", [](NSDictionary *result) {
    Report(@"manager", result);
    [embeddedWindow makeKeyAndOrderFront:nil];
    embeddedB->GetHost()->SetFocus(true);
    Later(500, [] {
      Evaluate(embeddedB, PageProbe(), [](NSDictionary *result) {
        Report(@"alloy-with-manager", result);
        Later(1000, [] {
          manager->GetHost()->CloseBrowser(true);
          Later(1000, [] {
            [embeddedWindow makeKeyAndOrderFront:nil];
            embeddedB->GetHost()->SetFocus(true);
            NSString *url = [configuration[@"fixture"] stringByAppendingString:@"/alloy-b?manager=closed"];
            embeddedB->GetMainFrame()->LoadURL(url.UTF8String);
            Later(500, [] { Evaluate(embeddedB, PageProbe(), [](NSDictionary *result) {
              Report(@"alloy-without-manager", result);
              control = Chrome([configuration[@"fixture"] stringByAppendingString:@"/chrome"]);
              if (!control) { CloseAll(); return; }
              auto other = Chrome([configuration[@"fixture"] stringByAppendingString:@"/chrome-other"]);
              if (!other) { CloseAll(); return; }
              Later(1500, [other] {
                NSView *otherView = (__bridge NSView *)other->GetHost()->GetWindowHandle();
                [otherView.window makeKeyAndOrderFront:nil];
                other->GetHost()->SetFocus(true);
                Evaluate(other, PageProbe(), [](NSDictionary *result) {
                  Report(@"chrome-other-window", result);
                  NSWindow *previous = NSApp.keyWindow.parentWindow;
                  if (previous) ClickOwnedWindow(previous, 40, previous.frame.size.height - 40);
                  NSView *view = (__bridge NSView *)control->GetHost()->GetWindowHandle();
                  [view.window makeKeyAndOrderFront:nil];
                control->GetHost()->SetFocus(true);
                Later(300, [] {
                Evaluate(control, PageProbe(), [](NSDictionary *result) {
                  Report(@"chrome-control", result);
                  NSView *view = (__bridge NSView *)control->GetHost()->GetWindowHandle();
                  NSWindow *popup = NSApp.keyWindow;
                  if (!popup.isVisible || popup.parentWindow != view.window) {
                    Report(@"failure", @{@"error": @"Fixture popup is not owned by the current Chrome window"}); CloseAll(); return;
                  }
                  NSWindow *source = view.window;
                  Later(500, [source] {
                    CaptureOwnedWindow(source, @"popup.png", [] {
                      Report(@"popup-capture", @{@"ownedNativeWindowWithPopup": @YES});
                      FinishCompatibility();
                    });
                  });
                });
                });
                });
              });
            }); });
          });
        });
      });
    });
  });
}

void WaitForReload(int first, int second, int attempt) {
  if (closing) return;
  if (completedLoads[embeddedA->GetIdentifier()] > first && completedLoads[embeddedB->GetIdentifier()] > second) {
    Later(0, InspectCompatibility);
  } else if (attempt < 100) {
    Later(100, [first, second, attempt] { WaitForReload(first, second, attempt + 1); });
  } else {
    Report(@"failure", @{@"error": @"Fixture pages did not finish reloading after extension installation"}); CloseAll();
  }
}

void ReloadAndInspect() {
  const int first = completedLoads[embeddedA->GetIdentifier()], second = completedLoads[embeddedB->GetIdentifier()];
  embeddedA->Reload(); embeddedB->Reload();
  Later(0, [first, second] { WaitForReload(first, second, 0); });
}

#include "ENVExtensionProbe.inc"

void CheckFixtureVersion(NSString *path, NSString *version, NSString *phase, std::function<void()> next) {
  AdminOperation(@{@"operation": @"install", @"path": path}, [path, version, phase, next](NSDictionary *result) {
    Report(phase, result);
    NSArray *items = [result[@"extensions"] filteredArrayUsingPredicate:
        [NSPredicate predicateWithFormat:@"id == %@ AND path == %@ AND version == %@ AND state == 'ENABLED'",
          configuration[@"fixtureExpectedID"], path, version]];
    if (items.count != 1) { Report(@"failure", @{@"error": @"Fixture identity or version changed unexpectedly"}); CloseAll(); return; }
    next();
  });
}

void UpdateFixtureAndInspect() {
  if (!configuration[@"fixtureUpdate"]) { ReloadAndInspect(); return; }
  if (![installedFixtureID isEqual:configuration[@"fixtureExpectedID"]]) {
    Report(@"failure", @{@"error": @"Generated ZIP identity does not match Chromium"}); CloseAll(); return;
  }
  CheckFixtureVersion(configuration[@"fixtureUpdate"], @"2.0.0", @"fixture-updated", [] {
    CheckFixtureVersion(configuration[@"extension"], @"1.0.0", @"fixture-restored", [] {
      CheckFixtureVersion(configuration[@"fixtureUpdate"], @"2.0.0", @"fixture-updated-again", ReloadAndInspect);
    });
  });
}

bool CheckHiddenManager() {
  NSView *view = (__bridge NSView *)manager->GetHost()->GetWindowHandle();
  if (!view.window || view.window.isVisible || NSApp.keyWindow != embeddedWindow) {
    Report(@"failure", @{@"error": @"Background extension management stole focus or remained visible"});
    CloseAll(); return false;
  }
  return true;
}

void BeginChecks() {
  if (closing || started) return;
  started = true;
  if ([configuration[@"envPlugin"] boolValue]) { BeginENVChecks(); return; }
  if ([configuration[@"productionAdmin"] boolValue]) {
    if (!CheckHiddenManager()) return;
    AdminOperation(@{@"operation": @"install", @"path": configuration[@"extension"]}, [](NSDictionary *installed) {
      if (!CheckHiddenManager()) return;
      Report(@"production-admin-install", installed);
      NSDictionary *item = [installed[@"extensions"] filteredArrayUsingPredicate:
          [NSPredicate predicateWithFormat:@"name == %@", @"CtrlX Extension Compatibility Fixture"]].firstObject;
      if (!item) { Report(@"failure", @{@"error": @"Installed fixture was not found"}); CloseAll(); return; }
      NSString *identifier = item[@"id"];
      installedFixtureID = identifier;
      AdminOperation(@{@"operation": @"setEnabled", @"id": identifier, @"enabled": @NO}, [identifier](NSDictionary *disabled) {
        if (!CheckHiddenManager()) return;
        Report(@"production-admin-disabled", disabled);
        AdminOperation(@{@"operation": @"setEnabled", @"id": identifier, @"enabled": @YES}, [identifier](NSDictionary *enabled) {
          if (!CheckHiddenManager()) return;
          Report(@"production-admin-enabled", enabled);
          AdminOperation(@{@"operation": @"reload", @"id": identifier}, [](NSDictionary *reloaded) {
            if (!CheckHiddenManager()) return;
            Report(@"background-management-focus", @{@"hidden": @YES, @"sourceFocused": @YES});
            Report(@"production-admin-reloaded", reloaded);
            if (configuration[@"optionsMode"]) CheckExtensionOptions(UpdateFixtureAndInspect);
            else UpdateFixtureAndInspect();
          });
        });
      });
    });
    return;
  }
  if (![configuration[@"dynamicInstall"] boolValue]) { InspectCompatibility(); return; }
  if ([configuration[@"nativeDrag"] boolValue]) {
    Evaluate(manager, @R"JS((async () => {
      await chrome.developerPrivate.updateProfileConfiguration({inDeveloperMode: true});
      return {ready: true};
    })())JS", [](NSDictionary *) {
      NSView *view = (__bridge NSView *)manager->GetHost()->GetWindowHandle();
      NSView *target = [view hitTest:NSMakePoint(NSMidX(view.bounds), NSMidY(view.bounds))];
      while (target && ![target.registeredDraggedTypes containsObject:NSPasteboardTypeFileURL]) target = target.superview;
      if (!target) { Report(@"failure", @{@"error": @"No native drop destination"}); CloseAll(); return; }
      ExtensionProbeDrag *drag = [[ExtensionProbeDrag alloc] init];
      drag.pasteboard = [NSPasteboard pasteboardWithUniqueName];
      [drag.pasteboard writeObjects:@[[NSURL fileURLWithPath:configuration[@"extension"] isDirectory:YES]]];
      drag.window = view.window;
      drag.location = [view convertPoint:NSMakePoint(NSMidX(view.bounds), NSMidY(view.bounds)) toView:nil];
      NSDragOperation operation = [target draggingEntered:drag];
      Report(@"native-drag", @{@"destination": NSStringFromClass(target.class), @"operation": @(operation)});
      Later(300, [target, drag] {
        Evaluate(manager, @R"JS((async () => {
          await chrome.developerPrivate.notifyDragInstallInProgress();
          await chrome.developerPrivate.loadUnpacked({useDraggedPath: true, failQuietly: true, populateError: true});
          const extensions = await chrome.developerPrivate.getExtensionsInfo({includeDisabled: true});
          return {extensions: extensions.map(({id, name, state, location}) => ({id, name, state, location}))};
        })())JS", [target, drag](NSDictionary *result) {
          [target draggingExited:drag];
          [drag.pasteboard releaseGlobally];
          Report(@"dynamic-install", result);
          ReloadAndInspect();
        });
      });
    });
    return;
  }
  expectingInstallDialog = true;
  Evaluate(manager, @R"JS((async () => {
    await chrome.developerPrivate.updateProfileConfiguration({inDeveloperMode: true});
    await chrome.developerPrivate.loadUnpacked({failQuietly: true, populateError: true});
    const extensions = await chrome.developerPrivate.getExtensionsInfo({includeDisabled: true});
    return {extensions: extensions.map(({id, name, state, location}) => ({id, name, state, location}))};
  })())JS", [](NSDictionary *result) {
    Report(@"dynamic-install", result);
    ReloadAndInspect();
  });
}

class App final : public CefApp, public CefBrowserProcessHandler {
 public:
  CefRefPtr<CefBrowserProcessHandler> GetBrowserProcessHandler() override { return this; }
  CefRefPtr<CefClient> GetDefaultClient() override { return new Client(); }
  void OnBeforeCommandLineProcessing(const CefString&, CefRefPtr<CefCommandLine> command) override {
    command->AppendSwitch("use-mock-keychain");
    if (![configuration[@"dynamicInstall"] boolValue] && ![configuration[@"productionAdmin"] boolValue])
      command->AppendSwitchWithValue("load-extension", [configuration[@"extension"] UTF8String]);
  }
  void OnContextInitialized() override {
    @autoreleasepool {
      embeddedWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 1000, 600)
          styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskResizable
          backing:NSBackingStoreBuffered defer:NO];
      embeddedWindow.title = @"CtrlX extension compatibility — isolated profile";
      embeddedWindow.releasedWhenClosed = NO;
      [embeddedWindow makeKeyAndOrderFront:nil];
      CefBrowserSettings settings;
      for (int i = 0; i < 2; ++i) {
        NSView *container = [[NSView alloc] initWithFrame:NSMakeRect(i * 500, 0, 500, 600)];
        [embeddedWindow.contentView addSubview:container];
        CefWindowInfo info;
        info.SetAsChild((__bridge void *)container, CefRect(0, 0, 500, 600));
        info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;
        NSString *url = [configuration[@"fixture"] stringByAppendingString:i ? @"/alloy-b" : @"/alloy-a"];
        auto browser = CefBrowserHost::CreateBrowserSync(info, new Client(container), url.UTF8String,
            settings, nullptr, nullptr);
        if (i) embeddedB = browser; else embeddedA = browser;
      }
      manager = [configuration[@"productionAdmin"] boolValue] ? EnsureExtensionManager() : Chrome(@"chrome://extensions/");
      Later(3000, BeginChecks);
      Later([configuration[@"envPlugin"] boolValue] ? 90000 : 45000, [] {
        if (!closing) { Report(@"failure", @{@"error": @"Native probe timed out"}); CloseAll(); }
      });
    }
  }
 private:
  IMPLEMENT_REFCOUNTING(App);
};
}

@interface ExtensionProbeApplication : NSApplication <CefAppProtocol>
@property(nonatomic) BOOL handlingSendEvent;
@end
@implementation ExtensionProbeApplication
- (BOOL)isHandlingSendEvent { return self.handlingSendEvent; }
- (void)sendEvent:(NSEvent *)event { CefScopedSendingEvent scope; [super sendEvent:event]; }
- (void)terminate:(id)sender { CloseAll(); }
@end

int main(int argc, char **argv) {
  if (argc != 2) { fprintf(stderr, "Usage: extension-probe /private/run/config.json\n"); return 2; }
  CefScopedLibraryLoader loader;
  if (!loader.LoadInMain()) return 1;
  @autoreleasepool {
    NSURL *configURL = [NSURL fileURLWithPath:@(argv[1])];
    NSError *error = nil;
    NSData *data = [NSData dataWithContentsOfURL:configURL options:0 error:&error];
    configuration = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
    if (![configuration isKindOfClass:NSDictionary.class] ||
        ![configuration[@"extension"] isKindOfClass:NSString.class] ||
        ![configuration[@"fixture"] hasPrefix:@"http://127.0.0.1:"]) {
      fprintf(stderr, "Invalid isolated extension probe configuration\n"); return 2;
    }
    NSURL *profile = [configURL.URLByDeletingLastPathComponent URLByAppendingPathComponent:@"profile"];
    runtime = [[ExtensionProbeRuntime alloc] init];
    runtime.profile = profile.path;
    if (![[NSFileManager defaultManager] createDirectoryAtURL:profile withIntermediateDirectories:YES
        attributes:nil error:&error]) return 2;
    [ExtensionProbeApplication sharedApplication];
    [NSApp setActivationPolicy:NSApplicationActivationPolicyRegular];
    CefSettings settings;
    CefString(&settings.root_cache_path) = profile.path.UTF8String;
    CefString(&settings.cache_path) = [profile.path stringByAppendingPathComponent:@"Default"].UTF8String;
    CefString(&settings.log_file) = [profile.path stringByAppendingPathComponent:@"cef.log"].UTF8String;
    settings.log_severity = LOGSEVERITY_WARNING;
    CefString(&settings.locale) = "en-US";
    // Keep our config path out of Chromium's navigation arguments.
    if (!CefInitialize(CefMainArgs(1, argv), settings, new App(), nullptr)) return 1;
    CefRunMessageLoop();
    manager = nullptr; embeddedA = nullptr; embeddedB = nullptr; control = nullptr;
    observers.clear();
    CefShutdown();
    embeddedWindow = nil;
  }
  Report(@"shutdown", @{@"complete": @(resultCode == 0)});
  return resultCode;
}
