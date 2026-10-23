// Included in EmbeddedClient. CEF owns persistence and origin validation.
 private:
  struct NetworkPermission {
    uint64_t prompt;
    NSString *id;
    NSString *origin;
    uint32_t types;
    CefRefPtr<CefPermissionPromptCallback> callback;
  };
  std::optional<NetworkPermission> networkPermission_;
  std::set<std::string> networkConsoleCategories_;

  void PublishNetworkPermission(NSDictionary *value) {
    if (identifier_ && [runtime.delegate respondsToSelector:@selector(browserTab:networkPermissionChanged:)])
      [runtime.delegate browserTab:identifier_ networkPermissionChanged:value];
  }
  void FinishNetworkPermission(cef_permission_request_result_t result) {
    if (!networkPermission_) return;
    auto pending = *networkPermission_;
    networkPermission_.reset();
    PublishNetworkPermission(nil);
    RecordBrowserDiagnostic(@{@"event": @"network-permission-result", @"tab": identifier_ ?: @"",
      @"permission": pending.id, @"origin": pending.origin, @"types": @(pending.types), @"result": @(result)});
    pending.callback->Continue(result);
  }

 public:
  CefRefPtr<CefPermissionHandler> GetPermissionHandler() override { return this; }
  bool OnShowPermissionPrompt(CefRefPtr<CefBrowser> browser, uint64_t prompt,
      const CefString& origin, uint32_t types, CefRefPtr<CefPermissionPromptCallback> callback) override {
    CEF_REQUIRE_UI_THREAD();
    constexpr uint32_t network = CEF_PERMISSION_TYPE_LOCAL_NETWORK | CEF_PERMISSION_TYPE_LOOPBACK_NETWORK;
    if (!(types & network)) return false;
    NSString *site = BrowserDiagnosticOrigin(@(origin.ToString().c_str()));
    RecordBrowserDiagnostic(@{@"event": @"network-permission-request", @"tab": identifier_ ?: @"",
      @"origin": site, @"types": @(types), @"nativeChromePrompt": @(extensionWindow_)});
    // Chrome-style windows already have native permission UI.
    if (extensionWindow_) return false;
    if (runtime.closing || (types & ~network) || !identifier_ ||
        ![runtime.delegate respondsToSelector:@selector(browserTab:networkPermissionChanged:)]) {
      callback->Continue(CEF_PERMISSION_RESULT_IGNORE);
      return true;
    }
    FinishNetworkPermission(CEF_PERMISSION_RESULT_IGNORE);
    networkPermission_ = NetworkPermission{prompt, NSUUID.UUID.UUIDString, site, types, callback};
    PublishNetworkPermission(@{@"id": networkPermission_->id, @"origin": site,
      @"localNetwork": @((types & CEF_PERMISSION_TYPE_LOCAL_NETWORK) != 0),
      @"loopbackNetwork": @((types & CEF_PERMISSION_TYPE_LOOPBACK_NETWORK) != 0)});
    return true;
  }
  void OnDismissPermissionPrompt(CefRefPtr<CefBrowser>, uint64_t prompt,
      cef_permission_request_result_t result) override {
    if (!networkPermission_ || networkPermission_->prompt != prompt) return;
    RecordBrowserDiagnostic(@{@"event": @"network-permission-dismissed", @"tab": identifier_ ?: @"",
      @"permission": networkPermission_->id, @"origin": networkPermission_->origin, @"result": @(result)});
    networkPermission_.reset();
    PublishNetworkPermission(nil);
  }
  NSString *RespondToNetworkPermission(NSString *id, bool allow) {
    if (!networkPermission_ || ![networkPermission_->id isEqual:id]) return @"The permission request has expired.";
    FinishNetworkPermission(allow ? CEF_PERMISSION_RESULT_ACCEPT : CEF_PERMISSION_RESULT_DENY);
    return nil;
  }
#ifdef CTRLX_UPSTREAM_BROWSER_PROBE
  NSDictionary *ProbeNetworkPermission() {
    if (!networkPermission_) return @{};
    return @{@"id": networkPermission_->id, @"origin": networkPermission_->origin, @"types": @(networkPermission_->types)};
  }
#endif
  bool OnConsoleMessage(CefRefPtr<CefBrowser> browser, cef_log_severity_t level, const CefString& message,
      const CefString&, int) override {
    if (!AgentBrowserDebugMode() || level < LOGSEVERITY_WARNING) return false;
    NSString *text = @(message.ToString().c_str()).lowercaseString;
    NSString *category = nil;
    if ([text containsString:@"local network"] || [text containsString:@"loopback"] ||
        [text containsString:@"address space"]) category = @"local-network";
    else if ([text containsString:@"cors"]) category = @"cors";
    else if ([text containsString:@"err_connection"]) category = @"connection";
    else if ([text containsString:@"err_cert"]) category = @"certificate";
    else if ([text containsString:@"err_network_access_denied"]) category = @"network-access-denied";
    if (category && networkConsoleCategories_.insert(category.UTF8String).second)
      RecordBrowserDiagnostic(@{@"event": @"network-console-error", @"tab": identifier_ ?: @"",
        @"origin": BrowserDiagnosticOrigin(@(browser->GetMainFrame()->GetURL().ToString().c_str())), @"category": category});
    return false;
  }
