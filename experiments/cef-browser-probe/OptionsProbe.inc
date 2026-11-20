// Locate fixture controls in the actual capture, including the Chrome toolbar
// and any scaling applied before the frame reaches a Viewer.
NSPoint OptionsControlPoint(NSBitmapImageRep *bitmap, NSDictionary *frame, bool edit) {
  NSInteger left = bitmap.pixelsWide, top = bitmap.pixelsHigh, right = -1, bottom = -1;
  for (NSInteger y = 0; y < bitmap.pixelsHigh; y += 2) {
    for (NSInteger x = 0; x < bitmap.pixelsWide; x += 2) {
      NSColor *color = [[bitmap colorAtX:x y:y] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace];
      const bool matches = edit
          ? std::min(color.redComponent, color.blueComponent) - color.greenComponent > .4
          : color.greenComponent - std::max(color.redComponent, color.blueComponent) > .4;
      if (matches) {
        left = std::min(left, x); right = std::max(right, x);
        top = std::min(top, y); bottom = std::max(bottom, y);
      }
    }
  }
  if (right <= left || bottom <= top) return NSMakePoint(-1, -1);
  return NSMakePoint((left + right) * .5 * [frame[@"width"] doubleValue] / bitmap.pixelsWide,
                     (top + bottom) * .5 * [frame[@"height"] doubleValue] / bitmap.pixelsHigh);
}

using OptionsProbeResult = std::function<void(NSString *)>;

void SendOptionsOperations(std::shared_ptr<ExtensionSurface> grant, NSNumber *generation, NSArray *operations,
                           OptionsProbeResult done, NSUInteger index = 0) {
  if (closing) return;
  if (index == operations.count) { done(nil); return; }
  NSMutableDictionary *payload = [@{@"lease": @"options-fixture", @"generation": generation} mutableCopy];
  [payload addEntriesFromDictionary:operations[index]];
  grant->Request(payload, ^(NSData *data, NSString *error) {
    Later(0, [grant, generation, operations, done, index, data, error] {
      if (closing) return;
      if (!data || error) done(error ?: @"Empty options input response");
      else SendOptionsOperations(grant, generation, operations, done, index + 1);
    });
  });
}

NSArray *OptionsClick(NSPoint point) {
  NSMutableArray *operations = [NSMutableArray array];
  for (NSString *type in @[@"mousePressed", @"mouseReleased"])
    [operations addObject:@{@"action": @"mouse", @"type": type, @"button": @"left", @"clickCount": @1,
        @"x": @(point.x), @"y": @(point.y)}];
  return operations;
}

void WaitForOptionsSignal(NSString *name, NSTimeInterval deadline, OptionsProbeResult done) {
  if (closing) return;
  NSString *path = [configuration[@"output"] stringByAppendingPathComponent:name];
  if ([[NSFileManager defaultManager] fileExistsAtPath:path]) done(nil);
  else if (NSProcessInfo.processInfo.systemUptime >= deadline)
    done([NSString stringWithFormat:@"Timed out waiting for %@", name]);
  else Later(50, [name, deadline, done] { WaitForOptionsSignal(name, deadline, done); });
}

NSView *OptionsHitView(CefRefPtr<CefBrowser> browser, NSPoint point) {
  NSView *view = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
  NSWindow *window = view.window;
  NSPoint screen = NSMakePoint(NSMinX(window.frame) + point.x, NSMaxY(window.frame) - point.y);
  NSPoint location = [window convertPointFromScreen:screen];
  NSView *content = window.contentView;
  return [content hitTest:[content.superview convertPoint:location fromView:nil]];
}

void CheckOptionsProtocolRejection(CefRefPtr<CefBrowser> browser, OptionsProbeResult done) {
  CefRefPtr<ExtensionOptionsInput> input = new ExtensionOptionsInput();
  auto submitted = std::make_shared<bool>(false);
  // An invalid parameter reaches Chromium, which rejects it asynchronously.
  input->Send(browser->GetHost(), "Input.insertText", @{@"text": @17}, nil, ^(NSString *error) {
    input->Cancel();
    bool rejected = *submitted && [error isEqual:@"Chromium rejected extension input."];
    Report(@"options-input-error", @{@"rejectedAfterSubmission": @(rejected)});
    done(rejected ? nil : @"Expected a Chromium input error after submission");
  });
  *submitted = true;
}

void EditOptions(CefRefPtr<CefBrowser> browser, std::shared_ptr<ExtensionSurface> grant,
                 NSDictionary *frame, NSData *jpeg, std::function<void()> done) {
  NSBitmapImageRep *bitmap = [NSBitmapImageRep imageRepWithData:jpeg];
  const NSPoint checkbox = OptionsControlPoint(bitmap, frame, false);
  const NSPoint edit = OptionsControlPoint(bitmap, frame, true);
  if (checkbox.x < 0 || edit.x < 0) {
    Report(@"failure", @{@"error": @"Options fixture controls missing from captured frame"}); CloseAll(); return;
  }
  NSNumber *generation = frame[@"generation"];
  NSView *initialRenderer = OptionsHitView(browser, edit);
  // Start another isolated app process to make the probe genuinely inactive.
  NSWorkspaceOpenConfiguration *launch = [NSWorkspaceOpenConfiguration configuration];
  launch.createsNewApplicationInstance = YES;
  launch.arguments = @[@"--options-focus-fixture"];
  [NSWorkspace.sharedWorkspace openApplicationAtURL:NSBundle.mainBundle.bundleURL configuration:launch
      completionHandler:^(NSRunningApplication *fixture, NSError *error) {
    CefPostTask(TID_UI, new BrowserUITask([fixture, error, browser, grant, generation, checkbox, edit, initialRenderer, done] {
      if (!fixture || fixture.processIdentifier == getpid()) {
        Report(@"failure", @{@"error": error.localizedDescription ?: @"Could not launch options focus fixture"});
        CloseAll(); return;
      }
      auto finish = [fixture, done](NSString *failure) {
        const bool inactive = !NSApp.isActive;
        Report(@"options-input-focus", @{@"stayedInactive": @(inactive)});
        [NSApp activateIgnoringOtherApps:YES];
        [fixture terminate];
        if (failure || !inactive) {
          Report(@"failure", @{@"error": failure ?: @"Host regained focus during options editing"});
          CloseAll();
        } else done();
      };
      Later(500, [browser, grant, generation, checkbox, edit, initialRenderer, finish] {
        if (NSApp.isActive) { finish(@"Options probe did not lose application focus"); return; }
        auto editReady = [browser, grant, generation, edit, initialRenderer, finish](NSString *error) {
          if (error) { finish(error); return; }
          NSView *renderer = OptionsHitView(browser, edit);
          BOOL changed = renderer && renderer != initialRenderer &&
              [renderer isKindOfClass:NSClassFromString(@"RenderWidgetHostViewCocoa")];
          Report(@"options-editor", @{@"rendererChanged": @(changed)});
          // The editor field occupies the original button's coordinates. Keep the
          // old frame generation and send text as soon as the click is acknowledged.
          NSArray *keys = @[
              @{@"action": @"key", @"key": @"a", @"modifiers": @4},
              @{@"action": @"text", @"text": @"Viewer edit 中文"},
              @{@"action": @"key", @"key": @"Enter"},
              @{@"action": @"text", @"text": @"tail"},
              @{@"action": @"key", @"key": @"Tab"},
          ];
          NSArray *operations = [OptionsClick(edit) arrayByAddingObjectsFromArray:keys];
          SendOptionsOperations(grant, generation, operations, [browser, finish](NSString *error) {
            if (error) { finish(error); return; }
            WaitForOptionsSignal(@"options-saved", NSProcessInfo.processInfo.systemUptime + 6, [browser, finish](NSString *error) {
              if (error) { finish(error); return; }
              CheckOptionsProtocolRejection(browser, finish);
            });
          });
        };
        SendOptionsOperations(grant, generation, [OptionsClick(checkbox) arrayByAddingObjectsFromArray:OptionsClick(edit)],
            [editReady, finish](NSString *error) {
          if (error) { finish(error); return; }
          WaitForOptionsSignal(@"options-editor-ready", NSProcessInfo.processInfo.systemUptime + 6, editReady);
        });
      });
    }));
  }];
}

// Runs the product options path in a disposable profile and native window.
void WaitForOptions(CefRefPtr<CefBrowser> browser, std::shared_ptr<ExtensionSurface> grant,
                    std::function<void()> next, int attempt = 0) {
  if (closing) return;
  BOOL fixtureReady = [configuration[@"optionsMode"] isEqual:@"env"] ? attempt >= 20 :
      [[NSFileManager defaultManager] fileExistsAtPath:[configuration[@"output"] stringByAppendingPathComponent:@"options-ready.json"]];
  if (!completedLoads[browser->GetIdentifier()] || browser->IsLoading() || !fixtureReady || attempt < 20) {
    if (attempt < 200) Later(50, [browser, grant, next, attempt] { WaitForOptions(browser, grant, next, attempt + 1); });
    else { Report(@"failure", @{@"error": @"Options did not load"}); CloseAll(); }
    return;
  }
  Later(400, [browser, grant, next] {
    NSView *view = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
    grant->Request(@{@"action": @"frame", @"lease": @"options-fixture", @"maximumDimension": @800}, ^(NSData *data, NSString *error) {
      NSDictionary *frame = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
      if (error || ![frame[@"jpeg"] length]) { Report(@"failure", @{@"error": error ?: @"Missing options frame"}); CloseAll(); return; }
      NSData *jpeg = [[NSData alloc] initWithBase64EncodedString:frame[@"jpeg"] options:0];
      if (![jpeg writeToFile:[configuration[@"output"] stringByAppendingPathComponent:@"options.jpg"] atomically:YES]) {
        Report(@"failure", @{@"error": @"Could not save options screenshot"}); CloseAll(); return;
      }
      Report(@"options-native-surface", @{@"captured": @YES, @"visible": @(view.window.isVisible),
          @"url": @(browser->GetMainFrame()->GetURL().ToString().c_str())});
      auto done = [grant, browser, next] {
        grant->Revoke();
        browser->GetHost()->CloseBrowser(true);
        Later(100, next);
      };
      if ([configuration[@"optionsMode"] isEqual:@"env"]) done();
      else EditOptions(browser, grant, frame, jpeg, done);
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
    auto grant = std::make_shared<ExtensionSurface>(@"options-fixture", [] { return !closing; }, [] {});
    auto present = [opened, grant](NSString *url) -> NSString * {
      auto browser = OpenExtensionOptionsWindow(url);
      if (!browser) return @"Options window was not created";
      NSView *view = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
      if (!grant->SetWindow(view.window, browser)) return @"Options surface could not be bound";
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
        WaitForOptions(*opened, grant, next);
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
