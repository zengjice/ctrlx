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

void CheckExtensionOptions(std::function<void()> next) {
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
