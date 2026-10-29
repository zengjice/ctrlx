static void ResolveBrowserIdentity(int pid, std::function<void(std::string, std::string)> done) {
  if (![runtime.delegate respondsToSelector:@selector(resolveBrowserAgentIdentity:completion:)]) { done("", ""); return; }
  [runtime.delegate resolveBrowserAgentIdentity:pid completion:^(NSDictionary* identity) {
    if (!runtime.isReady) return; // Stop already closed these clients; CEF may be shut down.
    std::string key = [identity[@"key"] UTF8String] ?: "", session = [identity[@"session"] UTF8String] ?: "";
    CefPostTask(TID_UI, new BrowserUITask([done, key, session] { done(key, session); }));
  }];
}

// Own strings across the asynchronous Swift lookup; references supplied by the
// socket request handler expire as soon as that handler returns.
static void OpenTab(std::string owner, int pid, std::string url, std::string conversation,
    std::function<bool()> current, std::function<void(CefRefPtr<CefBrowser>, NSString*)> done) {
  [runtime.delegate resolveBrowserProcess:pid completion:^(NSDictionary *route, NSString *error) {
    if (!runtime.isReady) return;
    // Both Swift lookups await I/O. Return to CEF's native loop before checking
    // the request again or creating a page, without reentering a Swift job.
    CefPostTask(TID_UI, new BrowserUITask([=] {
      if (!current()) { done(nullptr, @"Open request expired. No page was opened."); return; }
      if (!route) { done(nullptr, error ?: @"Source session unavailable. No page was opened."); return; }
      NSString *pane = route[@"pane"];
      if (![pane isKindOfClass:NSString.class] || !pane.length) { done(nullptr, @"Source pane unavailable."); return; }
      ResolveBrowserIdentity(pid, [=](std::string key, std::string) {
        if (!current() || key != conversation) {
          done(nullptr, @"Agent conversation changed or could not be verified. No page was opened."); return;
        }
        CreateRoutedTab(owner, conversation, route, url, done);
      });
    }));
  }];
}
