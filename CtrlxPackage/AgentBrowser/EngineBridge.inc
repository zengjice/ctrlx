// Included in Bridge. Narrow, exact-page CDP transport for a managed engine.
// Same-UID software remains trusted. Credentials never enter page JavaScript.
 private:
  struct EngineGrant { std::string run, tab; };
  struct EnginePending { int connection; NSNumber* wireID; std::string token; uint64_t generation; Clock::time_point deadline; bool navigation; NSString* session; NSString* method; int tree = 0; int mobile = -1; };
  struct EngineFrameTree { EnginePending pending; NSMutableDictionary* root; NSMutableArray* children; size_t remaining; };
  std::map<std::pair<int, int>, EngineFrameTree> engineTrees_;
  CefRefPtr<CefServer> engineServer_;
  std::map<std::string, EngineGrant> engineGrants_;
  std::map<int, std::string> engineConnections_;
  std::map<std::pair<int, int>, EnginePending> enginePending_;
  // Only iframe sessions observed below this exact CefBrowser. Never accept
  // caller-supplied target IDs, discover browser targets, or attach other tabs.
  std::map<std::pair<int, std::string>, std::string> engineFrames_;
  std::map<std::pair<int, std::string>, std::set<std::string>> engineScripts_;
  std::map<int, std::string> enginePageTargets_;
  std::set<int> engineCaptureAttaching_;
  std::set<int> engineMobilePages_;
  std::map<std::pair<int, std::string>, Clock::time_point> engineCaptures_;

  void EngineAutoAttach(CefRefPtr<CefBrowser> browser, bool enabled) {
    auto params = CefParseJSON(JSON(@{@"autoAttach": @(enabled), @"flatten": @YES,
      @"waitForDebuggerOnStart": @NO, @"filter": @[@{@"type": @"iframe", @"exclude": @NO}, @{@"exclude": @YES}]}), JSON_PARSER_RFC);
    browser->GetHost()->ExecuteDevToolsMethod(++nextMessage_, "Target.setAutoAttach", params->GetDictionary());
  }

  bool EngineAlive(const std::string& token) {
    auto grant = engineGrants_.find(token);
    return grant != engineGrants_.end() && tabs_.contains(grant->second.tab) &&
      ownership_.Owns(grant->second.run, grant->second.tab) && Alive(ownership_.runs.at(grant->second.run));
  }
  void EngineSend(int connection, NSDictionary* value) {
    if (!engineServer_ || !engineConnections_.contains(connection)) return;
    auto bytes = JSON(value);
    if (bytes.size() > kMaxResponse) { engineServer_->CloseConnection(connection); return; }
    engineServer_->SendWebSocketMessage(connection, bytes.data(), bytes.size());
  }
  void EngineError(int connection, NSNumber* id, NSString* error) {
    EngineSend(connection, @{@"id": id, @"error": @{@"code": @-32000, @"message": error}});
  }
  void EngineForget(CefRefPtr<CefBrowser> browser) {
    const int id = browser->GetIdentifier();
    for (const auto& [key, pending] : enginePending_) if (key.first == id && !pending.tree)
      EngineError(pending.connection, pending.wireID, @"Page renderer detached; operation not retried.");
    std::erase_if(enginePending_, [id](auto& entry) { return entry.first.first == id; });
    std::erase_if(engineTrees_, [id](auto& entry) { return entry.first.first == id; });
    std::erase_if(engineFrames_, [id](auto& entry) { return entry.first.first == id; });
    std::erase_if(engineScripts_, [id](auto& entry) { return entry.first.first == id; });
    std::erase_if(engineCaptures_, [id](auto& entry) { return entry.first.first == id; });
    engineCaptureAttaching_.erase(id);
    engineMobilePages_.erase(id);
    enginePageTargets_.erase(id);
    engineDownloads_.erase(id);
    DialogCancel(id);
  }
  void EngineDetach(const std::string& token) {
    auto grant = engineGrants_.find(token);
    if (grant == engineGrants_.end() || !tabs_.contains(grant->second.tab)) return;
    for (const auto& [connection, other] : engineConnections_)
      if (other != token && EngineAlive(other) && engineGrants_.at(other).tab == grant->second.tab) return;
    auto browser = tabs_.at(grant->second.tab).browser;
    // Also run for dead/revoked owners BEFORE discarding their grant. Pending
    // Fetch requests and native dialog callbacks otherwise outlive the engine.
    browser->GetHost()->ExecuteDevToolsMethod(++nextMessage_, "Fetch.disable", nullptr);
    const auto captures = engineCaptures_;
    for (const auto& [key, deadline] : captures) if (key.first == browser->GetIdentifier()) EngineEndCapture(browser, key.second);
    std::erase_if(engineCaptures_, [&](auto& entry) { return entry.first.first == browser->GetIdentifier(); });
    engineCaptureAttaching_.erase(browser->GetIdentifier());
    enginePageTargets_.erase(browser->GetIdentifier());
    const auto scriptsBySession = engineScripts_;
    for (auto& [key, scripts] : scriptsBySession) if (key.first == browser->GetIdentifier()) {
      for (const auto& script : scripts) {
        NSMutableDictionary* message = [@{@"id": @(++nextMessage_), @"method": @"Page.removeScriptToEvaluateOnNewDocument", @"params": @{@"identifier": String(script)}} mutableCopy];
        if (!key.second.empty()) message[@"sessionId"] = String(key.second);
        auto raw = JSON(message); browser->GetHost()->SendDevToolsMessage(raw.data(), raw.size());
      }
    }
    std::erase_if(engineScripts_, [&](auto& entry) { return entry.first.first == browser->GetIdentifier(); });
    EngineAutoAttach(browser, false);
    std::erase_if(engineFrames_, [&](auto& entry) { return entry.first.first == browser->GetIdentifier(); });
    engineDownloads_.erase(browser->GetIdentifier());
    DialogCancel(browser->GetIdentifier());
  }
  void StartEngineServer() {
    ++engineServers;
    auto handler = new EngineServer;
    handler->destroyed = [] { --engineServers; };
    CefRefPtr<Bridge> self = this;
    handler->created = [self](auto server, bool running) {
      if (!running || self->listener_ < 0) { server->Shutdown(); return; }
      self->engineServer_ = server;
    };
    handler->connect = [self](int id, std::string url, bool safe, auto callback) {
      NSURLComponents* parts = [NSURLComponents componentsWithString:String(url)];
      std::string token = parts.path.length ? [parts.path substringFromIndex:1].UTF8String : "";
      if (!safe || parts.query || !self->engineServer_ || self->engineConnections_.size() >= 64 ||
          !self->EngineAlive(token)) { callback->Cancel(); return; }
      // One consumer per lease. Never steal events from another connection.
      for (const auto& [other, lease] : self->engineConnections_)
        if (lease == token) { callback->Cancel(); return; }
      self->engineConnections_[id] = token;
      callback->Continue();
    };
    handler->disconnected = [self](int id) {
      auto link = self->engineConnections_.find(id);
      if (link != self->engineConnections_.end()) self->EngineDetach(link->second);
      self->engineConnections_.erase(id);
      // Retain only registrations whose late success must be undone after
      // disconnect; otherwise an in-flight init hook/capture can outlive its lease.
      std::erase_if(self->enginePending_, [id](auto& pair) {
        return pair.second.connection == id && ![@[@"Page.addScriptToEvaluateOnNewDocument", @"Target.attachToTarget"] containsObject:pair.second.method];
      });
      std::erase_if(self->engineTrees_, [id](auto& pair) { return pair.second.pending.connection == id; });
    };
    handler->message = [self](int id, const std::string& data) { self->EngineMessage(id, data); };
    CefServer::CreateServer("127.0.0.1", 0, 8, handler);
  }
  bool AttachEngine(int id, NSDictionary* request) {
    if (![request[@"command"] isEqual:@"engine.attach"]) return false;
    NSString* tab = request[@"tab"];
    auto& client = clients_.at(id);
    if (![tab isKindOfClass:NSString.class] || !tabs_.contains(tab.UTF8String) ||
        !ownership_.Owns(client.run, tab.UTF8String)) {
      Reply(id, nil, @"Engine target is not owned by this instance."); return true;
    }
    if (!engineServer_) { Reply(id, nil, @"Engine gateway is unavailable; no page action was sent."); return true; }
    std::string token;
    for (const auto& [key, grant] : engineGrants_)
      if (grant.run == client.run && grant.tab == tab.UTF8String) { token = key; break; }
    if (token.empty()) {
      token = [NSUUID.UUID.UUIDString stringByAppendingString:NSUUID.UUID.UUIDString].UTF8String;
      engineGrants_[token] = {client.run, tab.UTF8String};
    }
    Reply(id, @{@"url": [NSString stringWithFormat:@"ws://%s/%s", engineServer_->GetAddress().ToString().c_str(), token.c_str()]});
    return true;
  }
  void EngineMessage(int connection, const std::string& bytes) {
    auto linked = engineConnections_.find(connection);
    if (linked == engineConnections_.end()) return;
    const auto token = linked->second;
    if (!EngineAlive(token)) { engineServer_->CloseConnection(connection); return; }
    id request = Parse(bytes.data(), bytes.size());
    if (![request isKindOfClass:NSDictionary.class] || ![request[@"id"] isKindOfClass:NSNumber.class]) {
      engineServer_->CloseConnection(connection); return;
    }
    NSNumber* wireID = request[@"id"];
    NSString* method = request[@"method"];
    NSDictionary* params = request[@"params"] ?: @{};
    // The upstream cookies command asks for all cookies. Translate, never
    // forward it: current-page reads preserve login without exporting a profile.
    if ([method isKindOfClass:NSString.class] && [method isEqual:@"Network.getAllCookies"]) method = @"Network.getCookies";
    // Page-scoped domains only. Browser/Target/global storage remain denied.
    NSArray* allowed = @[@"Browser.getVersion", @"Page.enable", @"Page.disable", @"Page.getFrameTree",
      @"Page.getLayoutMetrics", @"Page.captureScreenshot", @"Page.setLifecycleEventsEnabled",
      @"Page.startScreencast", @"Page.stopScreencast", @"Page.screencastFrameAck",
      @"Runtime.enable", @"Runtime.disable", @"Runtime.runIfWaitingForDebugger", @"Runtime.evaluate",
      @"Runtime.callFunctionOn", @"Runtime.releaseObject", @"Runtime.releaseObjectGroup",
      @"DOM.enable", @"DOM.disable", @"DOM.getDocument", @"DOM.querySelector", @"DOM.querySelectorAll",
      @"DOM.resolveNode", @"DOM.describeNode", @"DOM.getBoxModel", @"DOM.scrollIntoViewIfNeeded",
      @"Accessibility.enable", @"Accessibility.disable", @"Accessibility.getFullAXTree", @"Accessibility.getPartialAXTree",
      @"Input.insertText", @"Input.dispatchMouseEvent", @"Input.dispatchKeyEvent", @"Input.dispatchTouchEvent",
      @"Network.enable", @"Network.disable", @"Network.getResponseBody", @"Network.getRequestPostData",
      @"Network.setExtraHTTPHeaders", @"Network.emulateNetworkConditions", @"Network.setCacheDisabled",
      @"Network.setUserAgentOverride", @"Network.getCookies", @"Network.setCookies",
      @"Fetch.enable", @"Fetch.disable", @"Fetch.continueRequest", @"Fetch.fulfillRequest", @"Fetch.failRequest",
      @"Fetch.continueWithAuth", @"Fetch.getResponseBody", @"Fetch.continueResponse",
      @"Log.enable", @"Log.disable", @"Log.clear",
      @"DOM.getFrameOwner", @"DOM.setFileInputFiles", @"DOM.focus",
      @"Page.createIsolatedWorld", @"Page.printToPDF", @"Page.handleJavaScriptDialog",
      @"Page.navigate", @"Page.reload", @"Page.getNavigationHistory", @"Page.navigateToHistoryEntry",
      @"Page.addScriptToEvaluateOnNewDocument", @"Page.removeScriptToEvaluateOnNewDocument",
      @"Emulation.setDeviceMetricsOverride", @"Emulation.clearDeviceMetricsOverride",
      @"Emulation.setTouchEmulationEnabled", @"Emulation.setEmitTouchEventsForMouse",
      @"Emulation.setGeolocationOverride", @"Emulation.clearGeolocationOverride", @"Emulation.setEmulatedMedia",
      @"Emulation.setUserAgentOverride", @"Emulation.setTimezoneOverride", @"Emulation.setLocaleOverride",
      @"WebMCP.enable", @"WebMCP.disable", @"WebMCP.invokeTool", @"WebMCP.cancelInvocation",
      @"Target.getTargetInfo", @"Target.attachToTarget", @"Target.detachFromTarget",
      @"Target.setAutoAttach", @"Browser.setDownloadBehavior"];
    auto& tab = tabs_.at(engineGrants_.at(token).tab);
    NSString* session = request[@"sessionId"] ?: @"";
    if (![method isKindOfClass:NSString.class] || ![params isKindOfClass:NSDictionary.class] ||
        ![session isKindOfClass:NSString.class] ||
        (session.length && !engineFrames_.contains({tab.browser->GetIdentifier(), session.UTF8String})) ||
        ![allowed containsObject:method]) {
      EngineError(connection, wireID, @"CDP method not supported by CtrlX's scoped engine."); return;
    }
    if ([method isEqual:@"Target.setAutoAttach"]) {
      if (![params[@"autoAttach"] isKindOfClass:NSNumber.class]) { EngineError(connection, wireID, @"Invalid iframe attachment options."); return; }
      // No workers, unrelated pages, arbitrary filters, or paused renderers.
      params = @{@"autoAttach": @([params[@"autoAttach"] boolValue]), @"flatten": @YES,
        @"waitForDebuggerOnStart": @NO, @"filter": @[@{@"type": @"iframe", @"exclude": @NO}, @{@"exclude": @YES}]};
    }
    if ([method isEqual:@"Page.enable"] && !session.length) EngineAutoAttach(tab.browser, true);
    const int browserID = tab.browser->GetIdentifier();
    if (session.length && !engineCaptures_.contains({browserID, session.UTF8String}) && engineMobilePages_.contains(browserID) &&
        [@[@"Input.dispatchMouseEvent", @"Input.dispatchTouchEvent"] containsObject:method]) {
      EngineError(connection, wireID, @"OOPIF pointer input with mobile emulation is not supported; restore a desktop viewport first."); return;
    }
    if ([method isEqual:@"Target.getTargetInfo"]) {
      if (session.length || params.count) { EngineError(connection, wireID, @"Only the current root target is queryable."); return; }
    }
    if ([method isEqual:@"Target.attachToTarget"]) {
      bool busy = engineCaptureAttaching_.contains(browserID);
      for (const auto& [key, deadline] : engineCaptures_) busy |= key.first == browserID;
      if (session.length || busy || !enginePageTargets_.contains(browserID) ||
          ![params[@"targetId"] isEqual:String(enginePageTargets_.at(browserID))]) {
        EngineError(connection, wireID, @"Only one recording attachment to this exact page is permitted."); return;
      }
      params = @{@"targetId": String(enginePageTargets_.at(browserID)), @"flatten": @YES};
    }
    if ([method isEqual:@"Target.detachFromTarget"]) {
      NSString* child = params[@"sessionId"];
      if (session.length || ![child isKindOfClass:NSString.class] || !engineCaptures_.contains({browserID, child.UTF8String})) {
        EngineError(connection, wireID, @"Only this page's recording attachment can be detached."); return;
      }
      params = @{@"sessionId": child};
    }
    if ([method isEqual:@"Page.startScreencast"] && !engineCaptures_.contains({browserID, session.UTF8String})) {
      EngineError(connection, wireID, @"Screencast requires a bounded recording attachment."); return;
    }
    if ([method isEqual:@"Page.addScriptToEvaluateOnNewDocument"] &&
        engineScripts_[{tab.browser->GetIdentifier(), session.UTF8String}].size() >= 16) {
      EngineError(connection, wireID, @"Too many init scripts for this page."); return;
    }
    if ([method isEqual:@"Page.captureScreenshot"] && [params[@"clip"] isKindOfClass:NSDictionary.class]) {
      NSDictionary* clip = params[@"clip"];
      if (![clip[@"width"] isKindOfClass:NSNumber.class] || ![clip[@"height"] isKindOfClass:NSNumber.class]) {
        EngineError(connection, wireID, @"Invalid screenshot bounds."); return;
      }
      double width = [clip[@"width"] doubleValue], height = [clip[@"height"] doubleValue];
      if (!(width > 0 && height > 0 && width <= 16384 && height <= 16384 && width * height <= 16000000)) {
        EngineError(connection, wireID, @"Screenshot exceeds the 16 megapixel bound."); return;
      }
    }
    if ([method isEqual:@"Page.handleJavaScriptDialog"]) {
      auto dialog = engineDialogs_.find(tab.browser->GetIdentifier());
      if (dialog != engineDialogs_.end()) {
        const auto callback = dialog->second.callback;
        engineDialogs_.erase(dialog);
        const bool accept = [params[@"accept"] isKindOfClass:NSNumber.class] && [params[@"accept"] boolValue];
        NSString* text = [params[@"promptText"] isKindOfClass:NSString.class] ? params[@"promptText"] : @"";
        callback->Continue(accept, text.UTF8String);
        EngineSend(connection, @{@"id": wireID, @"result": @{}});
        auto event = JSON(@{@"result": @(accept), @"userInput": text});
        EngineEvent(tab.browser, "Page.javascriptDialogClosed", event.data(), event.size());
        return;
      }
    }
    if (!ValidURL(String(tab.browser->GetMainFrame()->GetURL().ToString()))) {
      EngineError(connection, wireID, @"Only the owned HTTP(S) page is exposed."); return;
    }
    if ([method isEqual:@"Page.navigate"] && !ValidURL(params[@"url"])) {
      EngineError(connection, wireID, @"Navigation requires an HTTP(S) URL."); return;
    }
    // A shared login profile is intentional, an all-sites cookie dump is not.
    // Reads are forced to this page; writes cannot name a different host.
    NSString* pageURL = String(tab.browser->GetMainFrame()->GetURL().ToString());
    NSURL* page = [NSURL URLWithString:pageURL];
    if ([method isEqual:@"Network.getCookies"]) params = @{@"urls": @[pageURL]};
    if ([method isEqual:@"Network.setCookies"]) {
      if (![params[@"cookies"] isKindOfClass:NSArray.class]) { EngineError(connection, wireID, @"Invalid cookies."); return; }
      for (id cookie in params[@"cookies"]) {
        if (![cookie isKindOfClass:NSDictionary.class]) { EngineError(connection, wireID, @"Invalid cookie."); return; }
        NSString* domain = cookie[@"domain"];
        NSURL* url = [cookie[@"url"] isKindOfClass:NSString.class] ? [NSURL URLWithString:cookie[@"url"]] : nil;
        if ((domain && (![domain isKindOfClass:NSString.class] || ![[domain stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"."]] isEqual:page.host])) ||
            (cookie[@"url"] && (!ValidURL(cookie[@"url"]) || ![url.host isEqual:page.host])) || (!domain && !url)) {
          EngineError(connection, wireID, @"Cookie writes must target the current page host."); return;
        }
      }
    }
    if ([method isEqual:@"Browser.setDownloadBehavior"]) {
      NSString* path = params[@"downloadPath"];
      struct stat info{};
      // Download setup is tab-local; never apply this browser-global CDP call
      // to the shared CEF request context. Only our private staging directories.
      bool privateEnginePath = [path isKindOfClass:NSString.class] &&
        (([path hasPrefix:@"/tmp/ctrlx-engine-"] && path.pathComponents.count == 3) ||
         ([path hasPrefix:@"/private/tmp/ctrlx-engine-"] && path.pathComponents.count == 4));
      if (!privateEnginePath || lstat(path.fileSystemRepresentation, &info) != 0 ||
          !S_ISDIR(info.st_mode) || info.st_uid != getuid() || (info.st_mode & 077) != 0) {
        EngineError(connection, wireID, @"Downloads require a private managed engine directory."); return;
      }
      engineDownloads_[tab.browser->GetIdentifier()] = {token, path};
      EngineSend(connection, @{@"id": wireID, @"result": @{}}); return;
    }
    if (enginePending_.size() >= 128) { EngineError(connection, wireID, @"Engine is busy; operation not sent."); return; }
    if ([method isEqual:@"Target.attachToTarget"]) engineCaptureAttaching_.insert(browserID);
    if ([method hasPrefix:@"Input."]) { callbacks_.select(tab.browser); tab.browser->GetHost()->SetFocus(true); }
    const int message = ++nextMessage_;
    bool navigation = [@[@"Page.navigate", @"Page.reload", @"Page.navigateToHistoryEntry"] containsObject:method];
    enginePending_[{tab.browser->GetIdentifier(), message}] = {connection, wireID, token, tab.generation, Clock::now() + std::chrono::seconds(10), navigation, session, method};
    if (!session.length && [method isEqual:@"Emulation.setDeviceMetricsOverride"])
      enginePending_.at({browserID, message}).mobile = [params[@"mobile"] isKindOfClass:NSNumber.class] && [params[@"mobile"] boolValue] ? 1 : 0;
    if (!session.length && [method isEqual:@"Emulation.clearDeviceMetricsOverride"])
      enginePending_.at({browserID, message}).mobile = 0;
    auto parsed = CefParseJSON(JSON(params), JSON_PARSER_RFC);
    bool sent;
    if (session.length) {
      auto raw = JSON(@{@"id": @(message), @"method": method, @"params": params, @"sessionId": session});
      sent = tab.browser->GetHost()->SendDevToolsMessage(raw.data(), raw.size());
    } else sent = tab.browser->GetHost()->ExecuteDevToolsMethod(message, method.UTF8String, parsed->GetDictionary()) != 0;
    if (!sent) {
      if ([method isEqual:@"Target.attachToTarget"]) engineCaptureAttaching_.erase(browserID);
      enginePending_.erase({tab.browser->GetIdentifier(), message});
      EngineError(connection, wireID, @"Page operation was not submitted.");
    }
  }
  bool EngineResult(CefRefPtr<CefBrowser> browser, int message, bool success, const void* data, size_t size) {
    auto found = enginePending_.find({browser->GetIdentifier(), message});
    if (found == enginePending_.end()) return false;
    const auto pending = found->second; enginePending_.erase(found);
    const auto connection = engineConnections_.find(pending.connection);
    if (connection == engineConnections_.end() || connection->second != pending.token) {
      id value = success && size <= kMaxResponse ? Parse(data, size) : nil;
      if ([value isKindOfClass:NSDictionary.class]) {
        if ([pending.method isEqual:@"Page.addScriptToEvaluateOnNewDocument"] && [value[@"identifier"] isKindOfClass:NSString.class]) {
          NSMutableDictionary* message = [@{@"id": @(++nextMessage_), @"method": @"Page.removeScriptToEvaluateOnNewDocument",
            @"params": @{@"identifier": value[@"identifier"]}} mutableCopy];
          if (pending.session.length) message[@"sessionId"] = pending.session;
          auto cleanup = JSON(message);
          browser->GetHost()->SendDevToolsMessage(cleanup.data(), cleanup.size());
        }
        if ([pending.method isEqual:@"Target.attachToTarget"] && [value[@"sessionId"] isKindOfClass:NSString.class])
          EngineEndCapture(browser, [value[@"sessionId"] UTF8String]);
      }
      return true;
    }
    if (pending.tree) {
      auto tree = engineTrees_.find({browser->GetIdentifier(), pending.tree});
      if (tree == engineTrees_.end()) return true;
      id value = success && size <= kMaxResponse ? Parse(data, size) : nil;
      if (![value isKindOfClass:NSDictionary.class] || ![value[@"frameTree"] isKindOfClass:NSDictionary.class]) {
        engineTrees_.erase(tree);
        std::erase_if(enginePending_, [&](auto& entry) { return entry.first.first == browser->GetIdentifier() && entry.second.tree == pending.tree; });
        EngineError(pending.connection, pending.wireID, @"Child frame changed while reading its tree; read again."); return true;
      }
      [tree->second.children addObject:value[@"frameTree"]];
      if (--tree->second.remaining == 0) {
        auto collected = tree->second; engineTrees_.erase(tree);
        if (!EngineAlive(collected.pending.token) || Clock::now() > collected.pending.deadline ||
            tabs_.at(engineGrants_.at(collected.pending.token).tab).generation != collected.pending.generation) {
          EngineError(pending.connection, pending.wireID, @"Frame tree changed; read it again."); return true;
        }
        // Chromium returns each renderer's tree separately for OOPIF. Merge
        // only frames learned from this page's auto-attachment lineage.
        bool changed = true;
        while (changed) {
          changed = false;
          for (NSDictionary* child in [collected.children copy]) {
            NSMutableDictionary* parent = EngineFindFrame(collected.root[@"frameTree"], child[@"frame"][@"parentId"]);
            if (!parent) continue;
            NSMutableArray* children = parent[@"childFrames"];
            if (!children) { children = [NSMutableArray array]; parent[@"childFrames"] = children; }
            if (!EngineFindFrame(collected.root[@"frameTree"], child[@"frame"][@"id"])) {
              auto bytes = JSON(child);
              [children addObject:[NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes.data() length:bytes.size()] options:NSJSONReadingMutableContainers error:nil]];
            }
            [collected.children removeObject:child]; changed = true;
          }
        }
        EngineSend(pending.connection, @{@"id": pending.wireID, @"result": collected.root, @"sessionId": collected.pending.session});
      }
      return true;
    }
    if (!EngineAlive(pending.token) || Clock::now() > pending.deadline ||
        (!pending.navigation && tabs_.at(engineGrants_.at(pending.token).tab).generation != pending.generation)) {
      EngineError(pending.connection, pending.wireID, @"Page/owner changed; outcome unknown. Not retried."); return true;
    }
    id value = size <= kMaxResponse ? (size ? Parse(data, size) : @{}) : nil;
    if (!success || ![value isKindOfClass:NSDictionary.class]) {
      if ([pending.method isEqual:@"Target.attachToTarget"]) engineCaptureAttaching_.erase(browser->GetIdentifier());
      EngineError(pending.connection, pending.wireID, @"Page operation failed or result too large; not retried."); return true;
    }
    if (pending.mobile == 1) engineMobilePages_.insert(browser->GetIdentifier());
    if (pending.mobile == 0) engineMobilePages_.erase(browser->GetIdentifier());
    if ([pending.method isEqual:@"Target.getTargetInfo"] && [value[@"targetInfo"] isKindOfClass:NSDictionary.class] &&
        [value[@"targetInfo"][@"targetId"] isKindOfClass:NSString.class])
      enginePageTargets_[browser->GetIdentifier()] = [value[@"targetInfo"][@"targetId"] UTF8String];
    if ([pending.method isEqual:@"Page.addScriptToEvaluateOnNewDocument"] && [value[@"identifier"] isKindOfClass:NSString.class])
      engineScripts_[{browser->GetIdentifier(), pending.session.UTF8String}].insert([value[@"identifier"] UTF8String]);
    if ([pending.method isEqual:@"Page.getFrameTree"]) {
      std::vector<std::string> frames;
      for (const auto& [key, parent] : engineFrames_)
        if (key.first == browser->GetIdentifier() && key.second != pending.session.UTF8String && !engineCaptures_.contains(key)) frames.push_back(key.second);
      if (!frames.empty() && enginePending_.size() + frames.size() < 128) {
        auto bytes = JSON(value);
        NSMutableDictionary* root = [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes.data() length:bytes.size()] options:NSJSONReadingMutableContainers error:nil];
        engineTrees_[{browser->GetIdentifier(), message}] = {pending, root, [NSMutableArray array], frames.size()};
        for (const auto& session : frames) {
          const int childID = ++nextMessage_;
          auto child = pending; child.tree = message; child.session = String(session);
          enginePending_[{browser->GetIdentifier(), childID}] = child;
          auto query = JSON(@{@"id": @(childID), @"method": @"Page.getFrameTree", @"sessionId": String(session)});
          browser->GetHost()->SendDevToolsMessage(query.data(), query.size());
        }
        return true;
      }
    }
    EngineSend(pending.connection, @{@"id": pending.wireID, @"result": value, @"sessionId": pending.session ?: @""});
    return true;
  }
  NSMutableDictionary* EngineFindFrame(NSMutableDictionary* node, NSString* id) {
    if (!id) return nil;
    if ([node[@"frame"][@"id"] isEqual:id]) return node;
    for (NSMutableDictionary* child in node[@"childFrames"]) if (auto found = EngineFindFrame(child, id)) return found;
    return nil;
  }
  void ReapEngine() {
    if (!engineServer_) return;
    for (const auto& [connection, token] : engineConnections_)
      if (!EngineAlive(token)) { EngineDetach(token); engineServer_->CloseConnection(connection); }
    std::erase_if(engineGrants_, [this](auto& pair) { return !EngineAlive(pair.first); });
    std::erase_if(engineDownloads_, [this](auto& pair) { return !EngineAlive(pair.second.token); });
    std::vector<int> cancelDialogs;
    for (auto& [browser, dialog] : engineDialogs_) if (!EngineAlive(dialog.token)) cancelDialogs.push_back(browser);
    for (int browser : cancelDialogs) DialogCancel(browser);
    for (const auto& [key, pending] : enginePending_)
      if (Clock::now() > pending.deadline) EngineError(pending.connection, pending.wireID, @"Page operation timed out; outcome unknown. Not retried.");
    std::erase_if(enginePending_, [](auto& pair) { return Clock::now() > pair.second.deadline; });
    std::erase_if(engineTrees_, [this](auto& pair) { return !EngineAlive(pair.second.pending.token) || Clock::now() > pair.second.pending.deadline; });
    // A crashed CLI cannot leave a recorder capturing indefinitely.
    auto captures = engineCaptures_;
    for (const auto& [key, deadline] : captures) if (Clock::now() > deadline) {
      for (const auto& [id, tab] : tabs_) if (tab.browser->GetIdentifier() == key.first) EngineEndCapture(tab.browser, key.second);
      engineCaptures_.erase(key);
    }
  }
  void EngineEndCapture(CefRefPtr<CefBrowser> browser, const std::string& session) {
    auto stop = JSON(@{@"id": @(++nextMessage_), @"method": @"Page.stopScreencast", @"sessionId": String(session)});
    browser->GetHost()->SendDevToolsMessage(stop.data(), stop.size());
    auto params = CefParseJSON(JSON(@{@"sessionId": String(session)}), JSON_PARSER_RFC);
    browser->GetHost()->ExecuteDevToolsMethod(++nextMessage_, "Target.detachFromTarget", params->GetDictionary());
  }
 public:
  bool OnDevToolsMessage(CefRefPtr<CefBrowser> browser, const void* data, size_t size) override {
    if (size > kMaxResponse) return false;
    id value = Parse(data, size);
    if (![value isKindOfClass:NSDictionary.class]) return false;
    NSString* session = value[@"sessionId"] ?: @"";
    if (![session isKindOfClass:NSString.class]) return true;
    if (session.length && !engineFrames_.contains({browser->GetIdentifier(), session.UTF8String})) return true;
    NSString* method = value[@"method"];
    if (session.length && [value[@"id"] isKindOfClass:NSNumber.class]) {
      auto payload = JSON(value[@"result"] ?: value[@"error"] ?: @{});
      EngineResult(browser, [value[@"id"] intValue], value[@"error"] == nil, payload.data(), payload.size());
      return true;
    }
    if (![method isKindOfClass:NSString.class]) return false;
    NSDictionary* params = value[@"params"];
    if (![params isKindOfClass:NSDictionary.class]) return session.length != 0;
    if ([method isEqual:@"Target.attachedToTarget"]) {
      NSString* child = params[@"sessionId"];
      NSDictionary* info = params[@"targetInfo"];
      const int browserID = browser->GetIdentifier();
      bool capture = [info isKindOfClass:NSDictionary.class] && [info[@"type"] isEqual:@"page"] &&
        engineCaptureAttaching_.contains(browserID) && enginePageTargets_.contains(browserID) &&
        [info[@"targetId"] isEqual:String(enginePageTargets_.at(browserID))];
      if (![child isKindOfClass:NSString.class] || !child.length ||
          ![params[@"targetInfo"] isKindOfClass:NSDictionary.class] ||
          (!capture && ![info[@"type"] isEqual:@"iframe"]) || engineFrames_.size() >= 128) return true;
      if (capture) {
        engineCaptureAttaching_.erase(browserID);
        engineCaptures_[{browserID, child.UTF8String}] = Clock::now() + std::chrono::seconds(15);
      }
      engineFrames_[{browser->GetIdentifier(), child.UTF8String}] = session.UTF8String;
    } else if ([method isEqual:@"Target.detachedFromTarget"]) {
      NSString* child = params[@"sessionId"];
      if (![child isKindOfClass:NSString.class]) return true;
      std::set<std::string> removed{child.UTF8String};
      bool changed = true;
      while (changed) {
        changed = false;
        for (auto& [key, parent] : engineFrames_)
          if (key.first == browser->GetIdentifier() && removed.contains(parent)) changed |= removed.insert(key.second).second;
      }
      std::erase_if(engineFrames_, [&](auto& entry) { return entry.first.first == browser->GetIdentifier() && removed.contains(entry.first.second); });
      std::erase_if(engineScripts_, [&](auto& entry) { return entry.first.first == browser->GetIdentifier() && removed.contains(entry.first.second); });
      std::erase_if(engineCaptures_, [&](auto& entry) { return entry.first.first == browser->GetIdentifier() && removed.contains(entry.first.second); });
    } else if (!session.length) return false;
    auto payload = JSON(params);
    EngineEvent(browser, method.UTF8String, payload.data(), payload.size(), session);
    return true;
  }
  void EngineEvent(CefRefPtr<CefBrowser> browser, const CefString& method, const void* data, size_t size, NSString* session = @"") {
    // These events come from this exact CefBrowser's observer, not the shared
    // browser endpoint. Filtering ownership on every event prevents tab leaks.
    const auto name = method.ToString();
    if (size > (name == "Page.screencastFrame" ? 6 * 1024 * 1024 : 262144) || !(name.starts_with("Runtime.executionContext") ||
        name == "Runtime.consoleAPICalled" || name == "Runtime.exceptionThrown" || name == "Log.entryAdded" ||
        name.starts_with("Network.") || name.starts_with("Fetch.") || name.starts_with("WebMCP.") ||
        name == "Target.attachedToTarget" || name == "Target.detachedFromTarget" || name == "Page.screencastFrame" ||
        name == "Browser.downloadWillBegin" || name == "Browser.downloadProgress" ||
        name == "Page.javascriptDialogOpening" || name == "Page.javascriptDialogClosed" ||
        name == "Page.frameAttached" || name == "Page.frameDetached" ||
        name == "Page.frameNavigated" || name == "Page.frameStartedLoading" ||
        name == "Page.frameStoppedLoading" || name == "Page.loadEventFired" ||
        name == "Page.domContentEventFired" || name == "Page.lifecycleEvent")) return;
    id value = size ? Parse(data, size) : @{};
    if (!value) return;
    for (const auto& [connection, token] : engineConnections_) {
      if (!EngineAlive(token)) continue;
      if (tabs_.at(engineGrants_.at(token).tab).browser->IsSame(browser))
        // Upstream directPage uses the empty string as its session identity.
        // Its event tracker compares Some("") (not None); missing sessionId
        // silently discards console/errors/network even though calls succeed.
        EngineSend(connection, @{@"method": String(name), @"params": value, @"sessionId": session});
    }
  }

 private:
  struct EngineDownload {
    std::string token; NSString* directory; bool started = false;
    Clock::time_point deadline = Clock::now() + std::chrono::seconds(30);
  };
  std::map<int, EngineDownload> engineDownloads_;
  std::map<uint32_t, NSString*> engineDownloadPaths_;
  struct EngineDialog { std::string token; CefRefPtr<CefJSDialogCallback> callback; };
  std::map<int, EngineDialog> engineDialogs_;
  void DialogCancel(int browser) {
    auto found = engineDialogs_.find(browser);
    if (found == engineDialogs_.end()) return;
    auto callback = found->second.callback;
    engineDialogs_.erase(found);
    callback->Continue(false, "");
  }
 public:
  bool DialogBegin(CefRefPtr<CefBrowser> browser, cef_jsdialog_type_t type, const CefString& message,
      const CefString& defaultText, CefRefPtr<CefJSDialogCallback> callback) {
    for (const auto& [connection, token] : engineConnections_) {
      if (!EngineAlive(token) || !tabs_.at(engineGrants_.at(token).tab).browser->IsSame(browser)) continue;
      DialogCancel(browser->GetIdentifier());
      engineDialogs_[browser->GetIdentifier()] = {token, callback};
      auto event = JSON(@{@"url": String(browser->GetMainFrame()->GetURL().ToString()),
        @"message": String(message.ToString()), @"defaultPrompt": String(defaultText.ToString()), @"hasBrowserHandler": @YES,
        @"type": type == JSDIALOGTYPE_PROMPT ? @"prompt" : (type == JSDIALOGTYPE_CONFIRM ? @"confirm" : @"alert")});
      EngineEvent(browser, "Page.javascriptDialogOpening", event.data(), event.size());
      return true; // The engine answers the callback; no AppKit modal loop.
    }
    return false; // Human-only tabs retain CEF's default dialog UI.
  }
  void DialogReset(CefRefPtr<CefBrowser> browser) { engineDialogs_.erase(browser->GetIdentifier()); }
  bool DownloadBegin(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> item, CefRefPtr<CefBeforeDownloadCallback> callback) {
    auto found = engineDownloads_.find(browser->GetIdentifier());
    if (found == engineDownloads_.end() || !EngineAlive(found->second.token) ||
        found->second.started || Clock::now() > found->second.deadline) return true; // cancel
    found->second.started = true;
    NSString* guid = [NSString stringWithFormat:@"ctrlx-%u", item->GetId()];
    NSString* name = String(item->GetSuggestedFileName().ToString()).lastPathComponent;
    if (!name.length || [name isEqual:@"."] || [name isEqual:@".."]) name = guid;
    NSString* path = [found->second.directory stringByAppendingPathComponent:guid];
    engineDownloadPaths_[item->GetId()] = path;
    auto data = JSON(@{@"guid": guid, @"url": String(item->GetURL().ToString()), @"suggestedFilename": name, @"frameId": @""});
    EngineEvent(browser, "Browser.downloadWillBegin", data.data(), data.size());
    callback->Continue(path.UTF8String, false);
    return true;
  }
  void DownloadUpdate(CefRefPtr<CefBrowser> browser, CefRefPtr<CefDownloadItem> item, CefRefPtr<CefDownloadItemCallback> callback) {
    auto path = engineDownloadPaths_.find(item->GetId());
    if (path == engineDownloadPaths_.end()) return;
    auto owner = engineDownloads_.find(browser->GetIdentifier());
    if (owner == engineDownloads_.end() || !EngineAlive(owner->second.token) || item->GetReceivedBytes() > 6 * 1024 * 1024) {
      callback->Cancel(); engineDownloadPaths_.erase(path); return;
    }
    auto data = JSON(@{@"guid": [NSString stringWithFormat:@"ctrlx-%u", item->GetId()],
      @"state": item->IsComplete() ? @"completed" : (item->IsCanceled() ? @"canceled" : @"inProgress"),
      @"totalBytes": @(item->GetTotalBytes()), @"receivedBytes": @(item->GetReceivedBytes()), @"filePath": path->second});
    EngineEvent(browser, "Browser.downloadProgress", data.data(), data.size());
    if (item->IsComplete() || item->IsCanceled()) engineDownloadPaths_.erase(path);
  }
