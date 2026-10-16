// Characterize the real extension's debugger permission without changing its
// scripts, stored rules, or native messaging setup. All targets are private.
void WaitForDebuggerWindow(std::function<void()> complete, int attempt = 0) {
  for (const auto& [id, browser] : browsers) {
    NSView *view = (__bridge NSView *)browser->GetHost()->GetWindowHandle();
    if (browser->GetMainFrame()->GetURL().ToString().starts_with("devtools://") &&
        completedLoads[id] > 0 && view.window.isVisible && control->GetHost()->HasDevTools()) {
      Report(@"devtools-window-ready", @{@"visible": @YES, @"loaded": @YES}); complete(); return;
    }
  }
  if (attempt >= 50) { Report(@"failure", @{@"error": @"Native DevTools window did not become ready"}); CloseAll(); return; }
  Later(100, [complete, attempt] { if (!closing) WaitForDebuggerWindow(complete, attempt + 1); });
}

void TestENVDebugger() {
  FindENVTarget(@"chrome-extension://imebogohheacbbmhfiiddakclhifpbde/static/background/index.js", 0, [](NSString *worker) {
    NSString *expected = [configuration[@"fixture"] stringByAppendingString:@"/env"];
    NSString *urlJSON = [[NSString alloc] initWithData:[NSJSONSerialization dataWithJSONObject:expected
        options:NSJSONWritingFragmentsAllowed error:nil] encoding:NSUTF8StringEncoding];
    NSString *attach = [NSString stringWithFormat:@R"JS((async () => {
      const tabs = await chrome.tabs.query({});
      const matches = tabs.filter(tab => tab.url === %@);
      if (matches.length !== 1) throw new Error('Ambiguous private debugger fixture');
      const tabId = matches[0].id;
      globalThis.ctrlxProbeDebugger = {tabId, detached:[]};
      chrome.debugger.onDetach.addListener((source, reason) => {
        if (source.tabId === tabId) globalThis.ctrlxProbeDebugger.detached.push(reason);
      });
      try {
        await chrome.debugger.attach({tabId}, '1.3');
        const result = await chrome.debugger.sendCommand({tabId}, 'Runtime.evaluate',
          {expression:'location.href', returnByValue:true});
        return {attached:true, url:result.result.value};
      } catch (error) { return {attached:false, error:String(error)}; }
    })())JS", urlJSON];
    PrivateSession(worker, @"Runtime.evaluate", @{@"expression": attach, @"returnByValue": @YES, @"awaitPromise": @YES},
        [worker, expected](NSDictionary *response) {
      NSDictionary *value = response[@"result"][@"value"];
      if (response[@"exceptionDetails"] || ![value isKindOfClass:NSDictionary.class] ||
          ([value[@"attached"] boolValue] && ![value[@"url"] isEqual:expected])) {
        Report(@"failure", @{@"error": @"Extension debugger fixture failed", @"response": response}); CloseAll(); return;
      }
      Report(@"env-debugger-with-page-cdp", value);
      Evaluate(control, @"({url:location.href, title:document.title})", [worker, expected](NSDictionary *page) {
        if (![page[@"url"] isEqual:expected]) { Report(@"failure", @{@"error": @"CEF page control lost its exact source", @"page": page}); CloseAll(); return; }
        Report(@"page-cdp-with-env-debugger", page);
        CefWindowInfo info;
        control->GetHost()->ShowDevTools(info, new Client(), CefBrowserSettings(), CefPoint());
        WaitForDebuggerWindow([worker, expected] {
          PrivateSession(worker, @"Runtime.evaluate", @{@"expression": @R"JS((async () => {
            const state = globalThis.ctrlxProbeDebugger;
            let alive = false, error;
            try {
              const result = await chrome.debugger.sendCommand({tabId:state.tabId}, 'Runtime.evaluate',
                {expression:'location.href', returnByValue:true});
              alive = result.result.value;
            } catch (failure) { error = String(failure); }
            if (alive) await chrome.debugger.detach({tabId:state.tabId});
            return {alive, error, detached:state.detached};
          })())JS", @"returnByValue": @YES, @"awaitPromise": @YES}, [worker, expected](NSDictionary *response) {
            NSDictionary *value = response[@"result"][@"value"];
            if (response[@"exceptionDetails"] || ![value isKindOfClass:NSDictionary.class]) {
              Report(@"failure", @{@"error": @"Debugger conflict could not be inspected", @"response": response}); CloseAll(); return;
            }
            Report(@"env-debugger-with-devtools", value);
            Evaluate(control, @"({url:location.href, title:document.title})", [worker, expected](NSDictionary *page) {
              if (![page[@"url"] isEqual:expected]) { Report(@"failure", @{@"error": @"CEF control failed after DevTools", @"page": page}); CloseAll(); return; }
              Report(@"page-cdp-with-devtools", page);
              control->GetHost()->CloseDevTools();
              PrivateCommand("Target.detachFromTarget", @{@"sessionId": worker}, [](NSDictionary *) { resultCode = 0; CloseAll(); });
            });
          });
        });
      });
    });
  });
}
