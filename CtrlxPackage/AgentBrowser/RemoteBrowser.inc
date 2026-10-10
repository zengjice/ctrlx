// Included in Bridge. Host-only, typed UI operations; no arbitrary CDP or JS.
 private:
  using RemoteReply = std::function<void(NSDictionary*, NSString*)>;
  struct RemotePending {
    std::string tab;
    uint64_t generation;
    Clock::time_point deadline;
    RemoteReply reply;
    size_t maximumBytes;
  };
  struct RemoteFrame {
    uint64_t generation;
    NSSize bounds;
    std::vector<RemoteReply> replies;
  };
  std::map<std::string, std::string> humanControl_;
  std::map<std::string, NSSize> remoteViewports_;
  std::map<std::string, NSMutableDictionary*> remotePressedPointers_;
  std::map<std::pair<int, int>, RemotePending> remotePending_;
  std::map<std::string, std::shared_ptr<RemoteFrame>> remoteFrames_;

  void RemoteFrameFinish(std::string id, std::shared_ptr<RemoteFrame> capture,
                         NSDictionary* value, NSString* error) {
    CEF_REQUIRE_UI_THREAD();
    auto pending = remoteFrames_.find(id);
    if (pending == remoteFrames_.end() || pending->second != capture) return;
    auto frame = pending->second;
    remoteFrames_.erase(pending);
    auto tab = tabs_.find(id);
    if (!error && (tab == tabs_.end() || tab->second.generation != frame->generation ||
        !NSEqualSizes(frame->bounds, ((__bridge NSView*)tab->second.browser->GetHost()->GetWindowHandle()).bounds.size)))
      error = @"Page changed. Read a new frame before interacting.";
    for (auto& reply : frame->replies) reply(error ? nil : value, error);
  }

  void RemoteFinish(std::pair<int, int> key, NSDictionary* value, NSString* error) {
    auto found = remotePending_.find(key);
    if (found == remotePending_.end()) return;
    auto pending = std::move(found->second);
    remotePending_.erase(found);
    pending.reply(value, error);
  }
  bool RemoteResult(CefRefPtr<CefBrowser> browser, int message, bool success, const void* data, size_t size) {
    auto key = std::pair{browser->GetIdentifier(), message};
    auto found = remotePending_.find(key);
    if (found == remotePending_.end()) return false;
    auto tab = tabs_.find(found->second.tab);
    if (tab == tabs_.end() || tab->second.generation != found->second.generation) {
      RemoteFinish(key, nil, @"Page changed. Read a new frame before interacting."); return true;
    }
    id value = success && size <= found->second.maximumBytes ? Parse(data, size) : nil;
    RemoteFinish(key, [value isKindOfClass:NSDictionary.class] ? value : nil,
      [value isKindOfClass:NSDictionary.class] ? nil : @"Browser operation failed or frame exceeded the size limit.");
    return true;
  }
  void RemoteForget(int browser) {
    std::vector<std::pair<int, int>> keys;
    for (auto& [key, pending] : remotePending_) if (key.first == browser) keys.push_back(key);
    for (auto key : keys) RemoteFinish(key, nil, @"Page closed or renderer detached.");
    for (auto& [id, tab] : tabs_) if (tab.browser->GetIdentifier() == browser) {
      auto frame = remoteFrames_.find(id);
      if (frame != remoteFrames_.end()) RemoteFrameFinish(id, frame->second, nil, @"Page closed or renderer detached.");
      humanControl_.erase(id); remoteViewports_.erase(id); remotePressedPointers_.erase(id);
    }
  }
  void ReapRemote() {
    std::vector<std::pair<int, int>> keys;
    for (auto& [key, pending] : remotePending_) if (Clock::now() > pending.deadline) keys.push_back(key);
    for (auto key : keys) RemoteFinish(key, nil, @"Browser request timed out; not retried.");
  }
  void RemoteCall(const std::string& id, const char* method, NSDictionary* params, RemoteReply reply,
                  size_t maximumBytes = 512 * 1024) {
    auto found = tabs_.find(id);
    if (found == tabs_.end()) { reply(nil, @"Page closed."); return; }
    auto browser = found->second.browser;
    const auto key = std::pair{browser->GetIdentifier(), ++nextMessage_};
    remotePending_[key] = {id, found->second.generation, Clock::now() + std::chrono::seconds(5), std::move(reply), maximumBytes};
    auto parsed = CefParseJSON(JSON(params), JSON_PARSER_RFC);
    if (!browser->GetHost()->ExecuteDevToolsMethod(key.second, method, parsed->GetDictionary()))
      RemoteFinish(key, nil, @"Browser request could not be submitted.");
  }
 public:
  bool SetHumanControl(NSString* identifier, NSString* token) {
    CEF_REQUIRE_UI_THREAD();
    std::string id = identifier.UTF8String ?: "";
    auto found = tabs_.find(id);
    if (found == tabs_.end()) return false;
    if (!token.length) {
      humanControl_.erase(id);
      auto pointer = remotePressedPointers_.find(id);
      if (pointer != remotePressedPointers_.end()) {
        pointer->second[@"type"] = @"mouseReleased";
        pointer->second[@"buttons"] = @0;
        auto value = CefParseJSON(JSON(pointer->second), JSON_PARSER_RFC);
        found->second.browser->GetHost()->ExecuteDevToolsMethod(++nextMessage_, "Input.dispatchMouseEvent", value->GetDictionary());
        remotePressedPointers_.erase(pointer);
      }
      return true;
    }
    // Never interrupt an in-flight Agent action or recording. The caller can
    // offer Take Control again after it finishes, without replaying anything.
    if (humanControl_.contains(id) || Busy(found->second.browser)) return false;
    for (auto& [key, deadline] : engineCaptures_) if (key.first == found->second.browser->GetIdentifier()) return false;
    humanControl_[id] = token.UTF8String;
    // Resume any earlier network interception before handing the page to a
    // person; an Agent cannot keep requests paused while its commands are gated.
    found->second.browser->GetHost()->ExecuteDevToolsMethod(++nextMessage_, "Fetch.disable", nullptr);
    return true;
  }
  bool HumanControlled(CefRefPtr<CefBrowser> browser) {
    for (auto& [id, tab] : tabs_) if (tab.browser->IsSame(browser)) return humanControl_.contains(id);
    return false;
  }
  void RemoteRequest(NSString* identifier, NSData* bytes, void (^completion)(NSData*, NSString*)) {
    CEF_REQUIRE_UI_THREAD();
    std::string id = identifier.UTF8String ?: "";
    auto found = tabs_.find(id);
    NSDictionary* request = bytes.length <= 65536 ? Parse(bytes.bytes, bytes.length) : nil;
    if (found == tabs_.end() || ![request isKindOfClass:NSDictionary.class]) {
      completion(nil, @"Unknown page or invalid request."); return;
    }
    RemoteReply reply = [completion](NSDictionary* value, NSString* error) {
      completion(value ? [NSJSONSerialization dataWithJSONObject:value options:0 error:nil] : nil, error);
    };
    NSString* action = request[@"action"];
    if (![action isKindOfClass:NSString.class]) { reply(nil, @"Invalid browser action."); return; }
    auto browser = found->second.browser;
    NSView* nativeView = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
    auto prior = remoteViewports_.find(id);
    if (prior != remoteViewports_.end() && !NSEqualSizes(prior->second, nativeView.bounds.size)) ++found->second.generation;
    remoteViewports_[id] = nativeView.bounds.size;
    if ([action isEqual:@"frame"]) {
      auto pending = remoteFrames_.find(id);
      if (pending != remoteFrames_.end()) {
        if (pending->second->generation != found->second.generation || pending->second->replies.size() >= 4) {
          reply(nil, @"Browser capture is busy. Read a new frame shortly."); return;
        }
        pending->second->replies.push_back(std::move(reply));
        return;
      }
      auto capture = std::make_shared<RemoteFrame>(RemoteFrame{found->second.generation, nativeView.bounds.size, {std::move(reply)}});
      remoteFrames_[id] = capture;
#if defined(CTRLX_UPSTREAM_BROWSER_PROBE)
      ++probeRemoteCaptureCounts_[browser->GetIdentifier()];
#endif
      RemoteCall(id, "Page.getLayoutMetrics", @{}, [this, id, capture](NSDictionary* metrics, NSString* error) {
        if (error) { RemoteFrameFinish(id, capture, nil, error); return; }
        NSDictionary* viewport = metrics[@"cssVisualViewport"];
        // Both viewport metrics exclude scrollbars. Use their unit ratio,
        // including pinch scale, to convert the full screenshot to CSS pixels.
        double cssWidth = [viewport[@"clientWidth"] doubleValue];
        double pixelWidth = [metrics[@"visualViewport"][@"clientWidth"] doubleValue];
        double pixelsPerCSSPixel = pixelWidth / cssWidth * [viewport[@"scale"] doubleValue];
        if (!std::isfinite(pixelsPerCSSPixel) || pixelsPerCSSPixel <= 0) {
          RemoteFrameFinish(id, capture, nil, @"Page has no usable viewport."); return;
        }
        // CDP clip/scale temporarily resizes the live render surface, which
        // flickers on the Host. Capture its current viewport without emulation.
        RemoteCall(id, "Page.captureScreenshot", @{@"format": @"jpeg", @"quality": @80,
          @"fromSurface": @YES, @"captureBeyondViewport": @NO},
          [this, id, capture, pixelsPerCSSPixel](NSDictionary* image, NSString* error) {
            NSString* encoded = image[@"data"];
            if (error || ![encoded isKindOfClass:NSString.class]) {
              RemoteFrameFinish(id, capture, nil, error ?: @"Browser frame is missing."); return;
            }
            CefRefPtr<Bridge> self = this;
            ++remoteImageJobs;
            if (!CefPostTask(TID_FILE_USER_VISIBLE, new Action([self, id, capture, encoded, pixelsPerCSSPixel] {
              auto frame = RemotePreviewFrame(encoded, pixelsPerCSSPixel);
              if (!CefPostTask(TID_UI, new Action([self, id, capture, frame] {
                --remoteImageJobs;
                self->RemoteFrameFinish(id, capture, frame.jpeg ? @{@"jpeg": [frame.jpeg base64EncodedStringWithOptions:0],
                  @"width": @(frame.width), @"height": @(frame.height), @"generation": @(capture->generation)} : nil,
                  frame.jpeg ? nil : @"Browser frame could not be encoded within the remote preview limit.");
              }))) { --remoteImageJobs; NSLog(@"CtrlX browser preview completion could not be scheduled."); }
            }))) {
              --remoteImageJobs;
              RemoteFrameFinish(id, capture, nil, @"Browser preview could not be scheduled.");
            }
          }, kRemoteScreenshotResponseBytes);
      });
      return;
    }
    NSString* lease = request[@"lease"];
    if (![lease isKindOfClass:NSString.class] || !humanControl_.contains(id) || humanControl_.at(id) != lease.UTF8String) {
      reply(nil, @"Control expired. Take Control again."); return;
    }
    if (![request[@"generation"] isKindOfClass:NSNumber.class] ||
        [request[@"generation"] unsignedLongLongValue] != found->second.generation) {
      reply(nil, @"Page changed. Read a new frame before interacting."); return;
    }
    if ([action isEqual:@"navigate"]) {
      if (!ValidURL(request[@"url"]) && ![request[@"url"] isEqual:@"about:blank"]) { reply(nil, @"Invalid HTTP(S) URL."); return; }
      browser->GetMainFrame()->LoadURL([request[@"url"] UTF8String]); reply(@{}, nil); return;
    }
    if ([action isEqual:@"back"]) { browser->GoBack(); reply(@{}, nil); return; }
    if ([action isEqual:@"forward"]) { browser->GoForward(); reply(@{}, nil); return; }
    if ([action isEqual:@"reload"]) { browser->Reload(); reply(@{}, nil); return; }
    if ([action isEqual:@"close"]) { browser->GetHost()->CloseBrowser(true); reply(@{}, nil); return; }
    if ([action isEqual:@"fit"]) {
      int width = [request[@"width"] intValue], height = [request[@"height"] intValue];
      if (width < 240 || height < 240 || width > 2560 || height > 2560) { reply(nil, @"Unsupported viewport size."); return; }
      // Page emulation is deliberately not used: it changes UA/OOPIF semantics.
      NSView* native = (__bridge NSView*)browser->GetHost()->GetWindowHandle();
      native.superview.frame = NSMakeRect(0, 0, width, height);
      native.frame = native.superview.bounds;
      ++found->second.generation;
      reply(@{}, nil); return;
    }
    if ([action isEqual:@"text"]) {
      NSString* text = request[@"text"];
      if (![text isKindOfClass:NSString.class] || text.length > 16000) { reply(nil, @"Invalid browser text."); return; }
      RemoteCall(id, "Input.insertText", @{@"text": text}, reply); return;
    }
    if ([action isEqual:@"mouse"]) {
      NSString* type = request[@"type"];
      if (![@[@"mousePressed", @"mouseReleased", @"mouseMoved", @"mouseWheel"] containsObject:type]) { reply(nil, @"Invalid pointer event."); return; }
      NSMutableDictionary* params = [NSMutableDictionary dictionary];
      for (NSString* key in @[@"x", @"y", @"deltaX", @"deltaY", @"buttons", @"modifiers", @"clickCount"])
        if ([request[key] isKindOfClass:NSNumber.class]) params[key] = request[key];
      if (!params[@"x"] || !params[@"y"]) { reply(nil, @"Missing pointer position."); return; }
      NSString* button = request[@"button"] ?: @"none";
      if (![@[@"none", @"left", @"right", @"middle"] containsObject:button]) { reply(nil, @"Invalid pointer button."); return; }
      params[@"type"] = type; params[@"button"] = button;
      if ([type isEqual:@"mousePressed"] || ([type isEqual:@"mouseMoved"] && remotePressedPointers_.contains(id)))
        remotePressedPointers_[id] = [params mutableCopy];
      if ([type isEqual:@"mouseReleased"]) remotePressedPointers_.erase(id);
      RemoteCall(id, "Input.dispatchMouseEvent", params, reply); return;
    }
    if ([action isEqual:@"key"]) {
      NSString* key = request[@"key"];
      if (![key isKindOfClass:NSString.class] || key.length > 32) { reply(nil, @"Invalid key."); return; }
      // CDP's virtual key code is required by Chromium for editing shortcuts.
      NSMutableString* shortcut = [NSMutableString string];
      const int mask = [request[@"modifiers"] intValue];
      for (auto pair : {std::pair{1, @"Alt+"}, {2, @"Control+"}, {4, @"Meta+"}, {8, @"Shift+"}})
        if (mask & pair.first) [shortcut appendString:pair.second];
      [shortcut appendString:[key.lowercaseString isEqual:@"a"] ? @"A" : key];
      NSMutableDictionary* params = [PageKeyDown(shortcut) mutableCopy];
      if (!params) params = [@{@"type": @"rawKeyDown", @"key": key,
        @"windowsVirtualKeyCode": request[@"keyCode"] ?: @0, @"modifiers": request[@"modifiers"] ?: @0} mutableCopy];
      RemoteCall(id, "Input.dispatchKeyEvent", params, [this, id, params, reply](NSDictionary*, NSString* error) {
        if (error) { reply(nil, error); return; }
        params[@"type"] = @"keyUp";
        [params removeObjectForKey:@"text"];
        [params removeObjectForKey:@"commands"];
        RemoteCall(id, "Input.dispatchKeyEvent", params, reply);
      }); return;
    }
    reply(nil, @"Unsupported browser action.");
  }
