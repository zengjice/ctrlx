static std::shared_ptr<ExtensionSurface> extensionSurface;
static NSString *extensionAnchor;
static NSString *extensionControlledPage;

static void ReleaseExtensionControlFor(NSString *identifier) {
  if (extensionSurface && ([extensionAnchor isEqual:identifier] || [extensionControlledPage isEqual:identifier]))
    extensionSurface->Revoke();
}

static bool AuthorizeExtensionRequest(NSString *target, NSDictionary *request) {
  return extensionSurface && [extensionAnchor isEqual:target] && extensionSurface->Authorize(request[@"lease"]);
}

static bool ExtensionControlOwnsWindow(NSWindow *window) {
  if (!window || !extensionSurface) return false;
  if (extensionSurface->Owns(window)) return true;
  for (NSString *identifier in @[extensionAnchor ?: @"", extensionControlledPage ?: @""]) {
    auto browser = AgentBrowserTarget(identifier);
    if (!browser) continue;
    NSView *view = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
    for (NSWindow *candidate = window; candidate; candidate = candidate.parentWindow)
      if (candidate == view.window) return true;
  }
  return false;
}

static void ConfigureExtensionStore(CefRefPtr<CefBrowser> manager, NSString *target, NSString *token) {
  auto client = static_cast<ExtensionManagerClient*>(manager->GetHost()->GetClient().get());
  client->storeSource = [target copy];
  const int managerID = manager->GetIdentifier();
  client->openStore = [target, token, managerID](NSString *url) {
    CefPostTask(TID_UI, new BrowserUITask([target, token, managerID, url] {
      auto source = AgentBrowserTarget(target);
      if (runtime.closing || !source || !source->IsValid() || !browsers.contains(source->GetIdentifier()) ||
          (token ? !AuthorizeExtensionRequest(target, @{@"lease": token}) :
              ((extensionSurface && extensionSurface->Active()) || AgentBrowserHumanControlled(source)))) return;
      if (![runtime.delegate respondsToSelector:@selector(browserTab:openWebStoreURL:controlToken:completion:)]) return;
      [runtime.delegate browserTab:target openWebStoreURL:url controlToken:token completion:^(NSString *opened, NSString *error) {
        if (!extensionManager || !extensionManager->IsValid() || extensionManager->GetIdentifier() != managerID ||
            (token ? !AuthorizeExtensionRequest(target, @{@"lease": token}) :
                (extensionSurface && extensionSurface->Active()))) return;
        if (error) {
          NSLog(@"[CtrlX Browser] Could not open Chrome Web Store: %@", error);
          if (extensionManager && extensionManager->IsValid()) {
            NSView *view = (__bridge NSView *)extensionManager->GetHost()->GetWindowHandle();
            if (view.window.isVisible && !view.window.attachedSheet) {
              NSAlert *alert = [NSAlert new];
              alert.messageText = @"Could not open Chrome Web Store";
              alert.informativeText = error;
              [alert beginSheetModalForWindow:view.window completionHandler:nil];
            }
          }
        } else if (!token && opened) {
          if (extensionManager && extensionManager->IsValid()) {
            NSView *view = (__bridge NSView *)extensionManager->GetHost()->GetWindowHandle();
            [view.window orderOut:nil];
          }
        }
      }];
    }));
  };
}

static void TakeExtensionControlFromHost(NSEvent *event) {
  if (extensionInputDepth != 0 || !event.window ||
      (event.type != NSEventTypeKeyDown && event.type != NSEventTypeLeftMouseDown &&
       event.type != NSEventTypeRightMouseDown && event.type != NSEventTypeScrollWheel)) return;
  ExtensionManagerClient *manager = nullptr;
  bool managerInput = false;
  if (extensionManager && extensionManager->IsValid()) {
    manager = static_cast<ExtensionManagerClient*>(extensionManager->GetHost()->GetClient().get());
    NSView *view = (__bridge NSView *)extensionManager->GetHost()->GetWindowHandle();
    for (NSWindow *window = event.window; window; window = window.parentWindow)
      if (window == view.window) { managerInput = true; break; }
  }
  // Revocation clears the lease's window. The manager retains its own source
  // so a later Host click can restore local routing after release or expiry.
  const bool controlledInput = extensionSurface && extensionSurface->Active() && ExtensionControlOwnsWindow(event.window);
  if (!managerInput && !controlledInput) return;
  // Rebind only after physical Host input. Queued Viewer callbacks keep their
  // captured token and must still fail authorization after this revocation.
  if (extensionSurface) extensionSurface->Revoke();
  if (manager && manager->storeSource.length)
    ConfigureExtensionStore(extensionManager, manager->storeSource, nil);
}
