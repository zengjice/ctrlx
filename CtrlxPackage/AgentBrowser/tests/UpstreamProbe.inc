// Included inside Bridge only for a separately compiled acceptance runtime.
// Not a product API: permits upstream-generated page JS on disposable fixtures.
// Never build this into a distributed application.
 public:
  void ProbeDevToolsEvent(CefRefPtr<CefBrowser> browser, const CefString& method,
                       const void* params, size_t size) {
    if (size > 262144) return;
    auto& queue = probeEvents_[browser->GetIdentifier()];
    if (!queue) queue = [NSMutableArray array];
    if (queue.count >= 256) { probeOverflow_.insert(browser->GetIdentifier()); return; }
    id value = size ? Parse(params, size) : @{};
    if (value) [queue addObject:@{@"method": String(method.ToString()), @"params": value}];
  }
 private:
  std::map<int, NSMutableArray*> probeEvents_;
  std::set<int> probeOverflow_;
  bool HandleUpstreamProbe(int id, NSDictionary* request) {
    NSString *command = request[@"command"];
    if (![command hasPrefix:@"probe."]) return false;
    if (![NSBundle.mainBundle.bundleIdentifier isEqual:@"com.ctrlx.embedded-acceptance"] ||
        ![NSProcessInfo.processInfo.arguments containsObject:@"--e2e-test"]) {
      Reply(id, nil, @"Probe requires isolated acceptance app."); return true;
    }
    auto& client = clients_.at(id);
    NSString *token = request[@"tab"];
    if (![token isKindOfClass:NSString.class] || !tabs_.contains(token.UTF8String) ||
        !ownership_.Owns(client.run, token.UTF8String)) {
      Reply(id, nil, @"Probe tab not authorized."); return true;
    }
    client.tab = token.UTF8String;
    client.browser = tabs_.at(client.tab).browser;
    client.generation = tabs_.at(client.tab).generation;
    int browserID = client.browser->GetIdentifier();
    if ([command isEqual:@"probe.remote-control"]) {
      NSString* lease = request[@"lease"];
      Reply(id, @{@"accepted": @(SetHumanControl(token, [lease isKindOfClass:NSString.class] ? lease : nil))});
      return true;
    }
    if ([command isEqual:@"probe.remote"]) {
      NSDictionary* payload = request[@"request"];
      if (![payload isKindOfClass:NSDictionary.class]) { Reply(id, nil, @"Missing remote request."); return true; }
      client.busy = true;
      CefRefPtr<Bridge> self = this;
      auto bytes = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
      RemoteRequest(token, bytes, ^(NSData* data, NSString* error) {
        self->Reply(id, data ? Parse(data.bytes, data.length) : nil, error);
      });
      return true;
    }
    if ([command isEqual:@"probe.devtools"]) {
      NSString *action = request[@"action"];
      if (![@[@"show", @"close", @"status"] containsObject:action]) {
        Reply(id, nil, @"Invalid DevTools fixture action."); return true;
      }
      Reply(id, ProbeAgentBrowserDevTools(client.browser, action)); return true;
    }
    if (!ValidURL(String(client.browser->GetMainFrame()->GetURL().ToString()))) {
      Reply(id, nil, @"Probe requires HTTP(S) fixture."); return true;
    }
    if ([command isEqual:@"probe.events"]) {
      if (probeOverflow_.contains(browserID)) {
        Reply(id, nil, @"Probe event queue overflow; fixture invalid."); return true;
      }
      NSArray *events = [probeEvents_[browserID] copy] ?: @[];
      [probeEvents_[browserID] removeAllObjects];
      Reply(id, events); return true;
    }
    NSString *method = request[@"method"];
    NSDictionary *params = request[@"params"] ?: @{};
    if (![command isEqual:@"probe.cdp"] || ![method isKindOfClass:NSString.class] ||
        ![params isKindOfClass:NSDictionary.class] ||
        !([method hasPrefix:@"Runtime."] || [method hasPrefix:@"DOM."] ||
          [method hasPrefix:@"Accessibility."] || [method hasPrefix:@"Input."] ||
          [@[@"Page.enable", @"Page.disable", @"Page.getFrameTree", @"Page.getLayoutMetrics",
             @"Page.captureScreenshot", @"Page.setLifecycleEventsEnabled", @"Network.enable",
             @"Network.disable", @"Browser.getVersion"] containsObject:method])) {
      Reply(id, nil, @"Probe CDP method denied."); return true;
    }
    if ([method hasPrefix:@"Input."]) {
      callbacks_.select(client.browser);
      client.browser->GetHost()->SetFocus(true);
    }
    client.busy = true;
    Call(id, method.UTF8String, params, [this, id](NSDictionary* result) { Reply(id, result); });
    return true;
  }
