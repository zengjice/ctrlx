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
  std::map<int, size_t> probeRemoteCaptureCounts_;
  struct ProbeView {
    NSView* view;
    id observer;
    bool postsFrameChanges;
    bool postsBoundsChanges;
    NSMutableDictionary* measurements;
  };
  std::map<int, std::vector<ProbeView>> probeViews_;
  void ForgetProbeView(int browser) {
    auto found = probeViews_.find(browser);
    if (found == probeViews_.end()) return;
    for (auto& item : found->second) {
      for (id observer in (NSArray*)item.observer) [NSNotificationCenter.defaultCenter removeObserver:observer];
      item.view.postsFrameChangedNotifications = item.postsFrameChanges;
      item.view.postsBoundsChangedNotifications = item.postsBoundsChanges;
    }
    probeViews_.erase(found);
  }
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
    if ([command isEqual:@"probe.remote-view"]) {
      NSView* view = (__bridge NSView*)client.browser->GetHost()->GetWindowHandle();
      if ([request[@"action"] isEqual:@"start"]) {
        ForgetProbeView(browserID);
        NSMutableDictionary* measurements = [@{@"sizeChanges": @0} mutableCopy];
        std::function<void(NSView*)> observe = [&](NSView* child) {
          const NSSize bounds = child.bounds.size;
          NSMutableDictionary* samples = measurements;
          bool frames = child.postsFrameChangedNotifications, changes = child.postsBoundsChangedNotifications;
          child.postsFrameChangedNotifications = YES;
          child.postsBoundsChangedNotifications = YES;
          NSMutableArray* observers = [NSMutableArray array];
          for (NSString* name in @[NSViewFrameDidChangeNotification, NSViewBoundsDidChangeNotification]) {
            [observers addObject:[NSNotificationCenter.defaultCenter addObserverForName:name
              object:child queue:nil usingBlock:^(NSNotification*) {
                if (!NSEqualSizes(bounds, child.bounds.size)) samples[@"sizeChanges"] = @([samples[@"sizeChanges"] intValue] + 1);
              }]];
          }
          probeViews_[browserID].push_back({child, observers, frames, changes, measurements});
          for (NSView* descendant in child.subviews) observe(descendant);
        };
        observe(view);
      }
      NSMutableDictionary* result = [@{@"width": @(view.bounds.size.width), @"height": @(view.bounds.size.height),
        @"pixelRatio": @(view.window.backingScaleFactor), @"captures": @(probeRemoteCaptureCounts_[browserID])} mutableCopy];
      auto found = probeViews_.find(browserID);
      if (found != probeViews_.end()) [result addEntriesFromDictionary:found->second.front().measurements];
      if ([request[@"action"] isEqual:@"stop"]) ForgetProbeView(browserID);
      Reply(id, result); return true;
    }
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
    if ([command isEqual:@"probe.zoom"]) {
      double factor = [request[@"factor"] doubleValue];
      if (!std::isfinite(factor) || factor < .25 || factor > 4) { Reply(id, nil, @"Invalid fixture zoom."); return true; }
      client.browser->GetHost()->SetZoomLevel(std::log(factor) / std::log(1.2));
      Reply(id, @{}); return true;
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
             @"Network.disable", @"Browser.getVersion", @"Emulation.setPageScaleFactor"] containsObject:method])) {
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
