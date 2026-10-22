// Runs the product options path in a disposable profile and native window.
void WaitForOptions(CefRefPtr<CefBrowser> browser, std::function<void()> next, int attempt = 0) {
  if (closing) return;
  BOOL fixtureReady = [configuration[@"optionsMode"] isEqual:@"env"] ? attempt >= 20 :
      [[NSFileManager defaultManager] fileExistsAtPath:[configuration[@"output"] stringByAppendingPathComponent:@"options-ready.json"]];
  if (!completedLoads[browser->GetIdentifier()] || browser->IsLoading() || !fixtureReady || attempt < 20) {
    if (attempt < 200) Later(50, [browser, next, attempt] { WaitForOptions(browser, next, attempt + 1); });
    else { Report(@"failure", @{@"error": @"Options did not load"}); CloseAll(); }
    return;
  }
  Later(400, [browser, next] {
    NSView *view = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
    auto grant = std::make_shared<ExtensionSurface>(@"options-fixture", [] { return !closing; }, [] {});
    if (!grant->SetWindow(view.window)) { Report(@"failure", @{@"error": @"Options surface could not be bound"}); CloseAll(); return; }
    grant->Request(@{@"action": @"frame", @"lease": @"options-fixture", @"maximumDimension": @800}, ^(NSData *data, NSString *error) {
      NSDictionary *frame = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
      if (error || ![frame[@"jpeg"] length]) { Report(@"failure", @{@"error": error ?: @"Missing options frame"}); CloseAll(); return; }
      NSData *jpeg = [[NSData alloc] initWithBase64EncodedString:frame[@"jpeg"] options:0];
      if (![jpeg writeToFile:[configuration[@"output"] stringByAppendingPathComponent:@"options.jpg"] atomically:YES]) {
        Report(@"failure", @{@"error": @"Could not save options screenshot"}); CloseAll(); return;
      }
      Report(@"options-native-surface", @{@"captured": @YES, @"visible": @(view.window.isVisible),
          @"url": @(browser->GetMainFrame()->GetURL().ToString().c_str())});
      grant->Revoke();
      browser->GetHost()->CloseBrowser(true);
      Later(100, next);
    });
  });
}

void CheckExtensionOptionsContent(std::function<void()> next) {
  AdminOperation(@{@"operation": @"list"}, [next](NSDictionary *result) {
    NSDictionary *item = [result[@"extensions"] filteredArrayUsingPredicate:
        [NSPredicate predicateWithFormat:@"id == %@", installedFixtureID]].firstObject;
    bool expected = ![configuration[@"optionsMode"] isEqual:@"none"];
    if ([item[@"hasOptions"] boolValue] != expected) {
      Report(@"failure", @{@"error": @"Options availability was incorrect"}); CloseAll(); return;
    }
    auto client = static_cast<ExtensionManagerClient*>(manager->GetHost()->GetClient().get());
    if (!expected) {
      client->Request(@{@"operation": @"openOptions", @"id": installedFixtureID}, ^(NSData *, NSString *error) {
        if (!error) { Report(@"failure", @{@"error": @"Missing options was accepted"}); CloseAll(); return; }
        Report(@"options-unavailable", @{@"rejected": @YES}); next();
      });
      return;
    }
    auto opened = std::make_shared<CefRefPtr<CefBrowser>>();
    auto present = [opened](NSString *url) -> NSString * {
      auto browser = OpenExtensionOptionsWindow(url);
      if (!browser) return @"Options window was not created";
      Report(@"options-open", @{@"id": @(browser->GetIdentifier()), @"valid": @(browser->IsValid()), @"registered": @(extensionTools.contains(browser->GetIdentifier())), @"previous": @(*opened ? (*opened)->GetIdentifier() : -1)});
      if (*opened && (*opened)->GetIdentifier() != browser->GetIdentifier()) return @"Repeated options request created another window";
      *opened = browser;
      return nil;
    };
    client->Request(@{@"operation": @"openOptions", @"id": installedFixtureID}, ^(NSData *, NSString *error) {
      if (error) { Report(@"failure", @{@"error": error}); CloseAll(); return; }
      client->Request(@{@"operation": @"openOptions", @"id": installedFixtureID}, ^(NSData *, NSString *again) {
        if (again) { Report(@"failure", @{@"error": again}); CloseAll(); return; }
        Report(@"options-reused", @{@"sameBrowser": @YES});
        WaitForOptions(*opened, next);
      }, present);
    }, present);
  });
}

void CheckStoreHostTakeover(std::function<void()> next, int mode = 0) {
  NSString *phase = mode == 0 ? @"store-host-takeover" :
      mode == 1 ? @"store-host-after-release" : @"store-host-after-expiry";
  auto client = static_cast<ExtensionManagerClient*>(manager->GetHost()->GetClient().get());
  StoreProbeDelegate *delegate = [StoreProbeDelegate new];
  delegate.calls = [NSMutableArray array];
  runtime.delegate = delegate;
  extensionAnchor = @"store-source";
  NSView *view = (__bridge NSView *)manager->GetHost()->GetWindowHandle();
  [view.window makeKeyAndOrderFront:nil];
  extensionSurface = std::make_shared<ExtensionSurface>(@"viewer-store", [] { return !closing; }, [] {});
  if (!extensionSurface->SetWindow(view.window)) {
    Report(@"failure", @{@"error": @"Store takeover surface could not be bound"}); CloseAll(); return;
  }
  ConfigureExtensionStore(manager, extensionAnchor, @"viewer-store");
  NSEvent *event = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSMakePoint(10, 10)
      modifierFlags:0 timestamp:0 windowNumber:view.window.windowNumber context:nil eventNumber:1 clickCount:1 pressure:1];
  {
    ExtensionInputScope scope;
    TakeExtensionControlFromHost(event);
  }
  const bool remoteKeptGrant = extensionSurface->Authorize(@"viewer-store");
  auto staleCallback = client->openStore;
  if (mode == 1) extensionSurface->Revoke();
  // Wait for the production 20-second lease; do not fake expiry by revoking it.
  Later(mode == 2 ? 20200 : 0, [client, delegate, remoteKeptGrant, staleCallback, event, phase, mode, next] {
    const bool initialStateCorrect = extensionSurface->Active() == (mode == 0);
    if (mode != 0) {
      // The manager must retain its own source even after another grant changes
      // the last extension anchor. Unrelated Host input must not rebind it.
      extensionAnchor = @"other-source";
      NSWindow *unrelated = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 100, 100)
          styleMask:NSWindowStyleMaskBorderless backing:NSBackingStoreBuffered defer:NO];
      NSEvent *other = [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown location:NSZeroPoint
          modifierFlags:0 timestamp:0 windowNumber:unrelated.windowNumber context:nil eventNumber:2 clickCount:1 pressure:1];
      TakeExtensionControlFromHost(other);
      {
        ExtensionInputScope scope;
        TakeExtensionControlFromHost(event);
      }
    }
    client->RouteStore("https://chromewebstore.google.com/detail/queued/abcdefghijklmnopabcdefghijklmnop");
    TakeExtensionControlFromHost(event);
    const bool hostRevoked = !extensionSurface->Active();
    staleCallback(@"https://chromewebstore.google.com/detail/stale/abcdefghijklmnopabcdefghijklmnop");
    client->RouteStore("https://chromewebstore.google.com/");
    Later(250, [client, delegate, remoteKeptGrant, initialStateCorrect, hostRevoked, phase, mode, next] {
      const bool passed = remoteKeptGrant && initialStateCorrect && hostRevoked && delegate.calls.count == 1 &&
          [delegate.calls.firstObject[@"token"] isEqual:@"local"] &&
          [delegate.calls.firstObject[@"source"] isEqual:@"store-source"] &&
          [delegate.calls.firstObject[@"url"] isEqual:@"https://chromewebstore.google.com/"];
      Report(phase, @{@"passed": @(passed), @"remoteKeptGrant": @(remoteKeptGrant),
          @"initialStateCorrect": @(initialStateCorrect), @"hostRevoked": @(hostRevoked), @"opened": @(delegate.calls.count)});
      client->openStore = nullptr;
      extensionSurface.reset();
      extensionAnchor = nil;
      runtime.delegate = nil;
      if (!passed) { Report(@"failure", @{@"error": @"Host takeover did not rebind the store route safely", @"scenario": phase}); }
      if (mode < 2) CheckStoreHostTakeover(next, mode + 1);
      else CheckExtensionOptionsContent(next);
    });
  });
}

// Exercise Chromium's actual popup and same-tab callbacks from the trusted manager.
void CheckExtensionOptions(std::function<void()> next) {
  auto client = static_cast<ExtensionManagerClient*>(manager->GetHost()->GetClient().get());
  auto urls = std::make_shared<std::vector<std::string>>();
  const size_t toolCount = extensionTools.size();
  client->openStore = [urls](NSString *url) { urls->push_back(url.UTF8String); };
  auto params = CefDictionaryValue::Create();
  params->SetString("expression", R"JS((() => {
    function find(root) {
      for (const a of root.querySelectorAll('a[href]'))
        if (a.href.startsWith('https://chromewebstore.google.com/')) return a;
      for (const element of root.querySelectorAll('*')) {
        if (element.shadowRoot) { const a = find(element.shadowRoot); if (a) return a; }
      }
    }
    const link = find(document);
    if (!link) throw new Error('Native manager store link not found');
    link.click();
  })())JS");
  params->SetBool("userGesture", true);
  manager->GetHost()->ExecuteDevToolsMethod(0, "Runtime.evaluate", params);
  Later(500, [client, urls, toolCount, next] {
    manager->GetMainFrame()->LoadURL("https://chromewebstore.google.com/detail/fixture/abcdefghijklmnopabcdefghijklmnop");
    Later(500, [client, urls, toolCount, next] {
      const bool passed = urls->size() == 2 &&
          urls->at(0).starts_with("https://chromewebstore.google.com/") &&
          urls->at(1) == "https://chromewebstore.google.com/detail/fixture/abcdefghijklmnopabcdefghijklmnop" &&
          extensionTools.size() == toolCount && manager->GetMainFrame()->GetURL() == "chrome://extensions/" &&
          !client->RouteStore("https://chromewebstore.google.com.evil.test/");
      client->openStore = nullptr;
      Report(@"store-routing", @{@"passed": @(passed), @"count": @(urls->size()), @"noNativePopup": @(extensionTools.size() == toolCount)});
      if (!passed) { Report(@"failure", @{@"error": @"Store navigation escaped the embedded-tab route"}); CloseAll(); return; }
      CheckStoreHostTakeover(next);
    });
  });
}
