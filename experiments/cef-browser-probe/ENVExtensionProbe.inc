// Test-only operations on a verified ENV package in this executable's private
// profile. Never rewrite third-party scripts or expose target access to agents.
void PrivateCommand(const char *method, NSDictionary *parameters, std::function<void(NSDictionary *)> callback) {
  const int message = ++nextMessage;
  pending[message] = std::move(callback);
  NSData *json = [NSJSONSerialization dataWithJSONObject:parameters options:0 error:nil];
  auto value = CefParseJSON(json.bytes, json.length, JSON_PARSER_RFC);
  if (!value || control->GetHost()->ExecuteDevToolsMethod(message, method, value->GetDictionary()) != message) {
    Report(@"failure", @{@"error": @"Private fixture command could not be submitted"}); CloseAll();
  }
}

void PrivateSession(NSString *session, NSString *method, NSDictionary *parameters,
    std::function<void(NSDictionary *)> callback) {
  const int message = ++nextMessage;
  pending[message] = std::move(callback);
  NSData *json = [NSJSONSerialization dataWithJSONObject:@{@"id": @(message), @"sessionId": session,
      @"method": method, @"params": parameters} options:0 error:nil];
  if (!control->GetHost()->SendDevToolsMessage(json.bytes, json.length)) {
    Report(@"failure", @{@"error": @"Private fixture session could not be submitted"}); CloseAll();
  }
}

void FindENVTarget(NSString *url, int attempt, std::function<void(NSString *)> callback) {
  PrivateCommand("Target.getTargets", @{}, [url, attempt, callback](NSDictionary *result) {
    NSString *target = nil;
    for (NSDictionary *item in result[@"targetInfos"]) {
      if (![item[@"url"] isEqualToString:url]) continue;
      if (target) { Report(@"failure", @{@"error": @"Ambiguous ENV target"}); CloseAll(); return; }
      target = item[@"targetId"];
    }
    if (!target) {
      if (attempt >= 30) { Report(@"failure", @{@"error": @"ENV target did not appear", @"url": url}); CloseAll(); return; }
      Later(200, [url, attempt, callback] { if (!closing) FindENVTarget(url, attempt + 1, callback); });
      return;
    }
    PrivateCommand("Target.attachToTarget", @{@"targetId": target, @"flatten": @YES}, [url, callback](NSDictionary *attached) {
      NSString *session = attached[@"sessionId"];
      if (![session isKindOfClass:NSString.class]) { Report(@"failure", @{@"error": @"ENV target could not be attached"}); CloseAll(); return; }
      Report(@"env-target-attached", @{@"url": url});
      callback(session);
    });
  });
}

void HandleENVInput(NSDictionary *parameters) {
  NSString *text = parameters[@"payload"];
  if (![text isKindOfClass:NSString.class] || text.length > 1024) {
    Report(@"failure", @{@"error": @"Invalid private fixture input"}); CloseAll(); return;
  }
  NSString *session = envInputSession;
  PrivateSession(session, @"Input.insertText", @{@"text": text}, [session](NSDictionary *) {
    PrivateSession(session, @"Runtime.evaluate", @{@"expression": @"globalThis.ctrlxProbeInputDone()"}, [](NSDictionary *) {});
  });
}

NSWindow *ENVPopupWindow(NSWindow *source) {
  NSWindow *popup = nil;
  for (NSWindow *child in source.childWindows) {
    if (!child.isVisible) continue;
    if (popup) return nil;
    popup = child;
  }
  if (popup) {
    [NSApp activateIgnoringOtherApps:YES];
    [popup makeKeyAndOrderFront:nil];
  }
  return popup;
}

#include "ExtensionSurfaceProbe.inc"

void TestENVNativeKeyboard(NSString *session, std::function<void()> complete) {
  PrivateSession(session, @"Runtime.evaluate", @{@"expression": @R"JS((() => {
      const input = document.querySelector('input[placeholder=\"Search Env\"]');
      if (!input) throw new Error('Missing ENV text field');
      const r = input.getBoundingClientRect();
      return {x:r.x+r.width/2, y:r.y+r.height/2, width:innerWidth, height:innerHeight};
    })())JS", @"returnByValue": @YES}, [session, complete](NSDictionary *response) {
    NSDictionary *point = response[@"result"][@"value"];
    NSView *view = (__bridge NSView *)control->GetHost()->GetWindowHandle();
    NSWindow *source = view.window, *popup = ENVPopupWindow(source);
    if (response[@"exceptionDetails"] || ![point isKindOfClass:NSDictionary.class] || popup.parentWindow != source) {
      Report(@"failure", @{@"error": @"ENV popup unavailable for keyboard input", @"response": response}); CloseAll(); return;
    }
    double x = NSMinX(popup.frame) - NSMinX(source.frame) + (popup.frame.size.width - [point[@"width"] doubleValue]) / 2 + [point[@"x"] doubleValue];
    double y = NSMaxY(source.frame) - NSMaxY(popup.frame) + (popup.frame.size.height - [point[@"height"] doubleValue]) / 2 + [point[@"y"] doubleValue];
    if (!ClickOwnedWindow(source, x, y)) {
      Report(@"failure", @{@"error": @"ENV text field is outside its owned window"}); CloseAll(); return;
    }
    PrivateSession(session, @"Runtime.evaluate", @{@"expression": @R"JS((async () => {
      const deadline = Date.now()+3000;
      while (Date.now()<deadline) {
        const input = document.querySelector('input[placeholder="Search Env"]');
        if (input === document.activeElement && !input.disabled && !input.readOnly) return true;
        await new Promise(resolve=>setTimeout(resolve,50));
      }
      throw new Error('Native click did not focus the editable ENV field: '+document.activeElement?.outerHTML);
    })())JS", @"returnByValue": @YES, @"awaitPromise": @YES}, [session, source, complete](NSDictionary *focused) {
    if (focused[@"exceptionDetails"] || ![focused[@"result"][@"value"] boolValue]) {
      Report(@"failure", @{@"error": @"ENV text field did not gain focus", @"response": focused}); CloseAll(); return;
    }
    if (InsertOwnedText(embeddedWindow, @"wrong target") ||
        !KeyOwnedWindow(source, 0, @"a", NSEventModifierFlagCommand) ||
        !InsertOwnedText(source, @"CtrlX 中文输入")) {
      Report(@"failure", @{@"error": @"Native text could not be scoped to the popup responder"}); CloseAll(); return;
    }
    Later(200, [session, source, complete] {
      PrivateSession(session, @"Runtime.evaluate", @{@"expression": @"document.querySelector('input[placeholder=\"Search Env\"]')?.value", @"returnByValue": @YES},
          [session, source, complete](NSDictionary *result) {
        if (![result[@"result"][@"value"] isEqual:@"CtrlX 中文输入"] ||
            !KeyOwnedWindow(source, 0, @"a", NSEventModifierFlagCommand) ||
            !KeyOwnedWindow(source, 51, @"\177")) {
          Report(@"failure", @{@"error": @"Native Unicode input or editing key failed", @"result": result}); CloseAll(); return;
        }
        Later(200, [session, source, complete] {
          PrivateSession(session, @"Runtime.evaluate", @{@"expression": @"document.querySelector('input[placeholder=\"Search Env\"]')?.value", @"returnByValue": @YES},
              [session, source, complete](NSDictionary *result) {
            if (![result[@"result"][@"value"] isEqual:@""]) {
              Report(@"failure", @{@"error": @"Native selection and delete did not clear the field", @"result": result}); CloseAll(); return;
            }
            Report(@"native-popup-keyboard", @{@"unicodeInserted": @YES, @"selectionDeleted": @YES, @"foreignWindowRejected": @YES});
            CaptureOwnedWindow(source, @"native-popup-keyboard.png", [session, complete] { TestENVProductionSurface(session, complete); });
          });
        });
      });
    });
    });
  });
}

void TestENVNativeInput(NSString *session, std::function<void()> complete) {
  PrivateSession(session, @"Runtime.evaluate", @{@"expression": @R"JS((async () => {
      const deadline = Date.now() + 3000;
      let button;
      do {
        button = document.querySelector('.arco-icon-pause')?.closest('button');
        if (button && !button.disabled) break;
        await new Promise(resolve => setTimeout(resolve, 100));
      } while (Date.now() < deadline);
      if (!button || button.disabled) throw new Error('Native click fixture needs an active ENV configuration');
      const r = button.getBoundingClientRect();
      return {x:r.x+r.width/2, y:r.y+r.height/2, width:innerWidth, height:innerHeight};
    })())JS", @"returnByValue": @YES, @"awaitPromise": @YES}, [session, complete](NSDictionary *response) {
    NSDictionary *point = response[@"result"][@"value"];
    NSView *view = (__bridge NSView *)control->GetHost()->GetWindowHandle();
    NSWindow *source = view.window, *popup = ENVPopupWindow(source);
    if (response[@"exceptionDetails"] || ![point isKindOfClass:NSDictionary.class] || popup.parentWindow != source) {
      Report(@"failure", @{@"error": @"Exact ENV child window was not available for native input", @"response": response}); CloseAll(); return;
    }
    double x = NSMinX(popup.frame) - NSMinX(source.frame) + (popup.frame.size.width - [point[@"width"] doubleValue]) / 2 + [point[@"x"] doubleValue];
    double y = NSMaxY(source.frame) - NSMaxY(popup.frame) + (popup.frame.size.height - [point[@"height"] doubleValue]) / 2 + [point[@"y"] doubleValue];
    if (!ClickOwnedWindow(source, x, y)) { Report(@"failure", @{@"error": @"Native popup point was outside the owned window"}); CloseAll(); return; }
    PrivateSession(session, @"Runtime.evaluate", @{@"expression": @R"JS((async () => {
        const [tab] = await chrome.tabs.query({active:true,currentWindow:true});
        const deadline = Date.now() + 8000;
        while (Date.now() < deadline) {
          const state = await chrome.storage.local.get('ENV_PLUGIN_V3_GLOBAL_PAUSED');
          const echo = (await chrome.scripting.executeScript({target:{tabId:tab.id},
            func:async()=>await (await fetch('/echo',{cache:'no-store'})).json()}))[0].result;
          if (state.ENV_PLUGIN_V3_GLOBAL_PAUSED === 'true' && echo.extensionHeader === null) return {paused:true,echo};
          await new Promise(resolve => setTimeout(resolve,100));
        }
        throw new Error('Native popup click did not pause the actual request rule');
      })())JS", @"returnByValue": @YES, @"awaitPromise": @YES}, [session, source, complete](NSDictionary *result) {
      if (result[@"exceptionDetails"] || ![result[@"result"][@"value"][@"paused"] boolValue]) {
        Report(@"failure", @{@"error": @"Native popup input did not take effect", @"result": result}); CloseAll(); return;
      }
      Report(@"native-popup-effect", result[@"result"][@"value"]);
      CaptureOwnedWindow(source, @"native-popup-paused.png", [session, complete] { TestENVNativeKeyboard(session, complete); });
    });
  });
}

#include "ExtensionDebuggerProbe.inc"

void CaptureENVPopup(NSString *session, bool succeeded = true) {
  PrivateSession(session, @"Page.captureScreenshot", @{@"format": @"png"}, [session, succeeded](NSDictionary *result) {
    NSData *png = [[NSData alloc] initWithBase64EncodedString:result[@"data"] options:0];
    NSString *path = [configuration[@"output"] stringByAppendingPathComponent:
        [configuration[@"envRestart"] boolValue] ? @"env-popup-restart.png" : @"env-popup.png"];
    if (!png.length || ![png writeToFile:path atomically:YES]) {
      Report(@"failure", @{@"error": @"ENV popup capture failed"}); CloseAll(); return;
    }
    Report(@"env-popup-capture", @{@"bytes": @(png.length)});
    auto finish = [session, succeeded] {
      PrivateCommand("Target.detachFromTarget", @{@"sessionId": session}, [succeeded](NSDictionary *) {
        if (succeeded && [configuration[@"envDebugger"] boolValue]) TestENVDebugger();
        else { resultCode = succeeded ? 0 : 1; CloseAll(); }
      });
    };
    if ([configuration[@"nativeWindowCapture"] boolValue]) {
      NSView *view = (__bridge NSView *)control->GetHost()->GetWindowHandle();
      CaptureOwnedWindow(view.window, @"native-popup.png", [session, succeeded, finish] {
        if (succeeded && [configuration[@"nativeWindowInput"] boolValue]) TestENVNativeInput(session, finish);
        else finish();
      });
    } else finish();
  });
}

void InspectENVPopup() {
  FindENVTarget(@"chrome-extension://imebogohheacbbmhfiiddakclhifpbde/popup.html", 0, [](NSString *session) {
    NSString *script = @R"JS((async () => {
      const deadline = Date.now() + 5000;
      while (document.body.innerText.length < 20 && Date.now() < deadline)
        await new Promise(resolve => setTimeout(resolve, 100));
      return {
        text: document.body.innerText.slice(0, 12000),
        inputs: [...document.querySelectorAll('input,textarea,select')].map(e =>
          ({tag:e.tagName, type:e.type, placeholder:e.placeholder, value:e.value, label:e.getAttribute('aria-label')})),
        buttons: [...document.querySelectorAll('button,[role=button]')].map(e =>
          ({text:e.innerText, label:e.getAttribute('aria-label'), title:e.title})),
        tabs: await chrome.tabs.query({active:true, currentWindow:true}),
        storage: await chrome.storage.local.get(null)
      };
    })())JS";
    PrivateSession(session, @"Runtime.evaluate", @{@"expression": script, @"returnByValue": @YES, @"awaitPromise": @YES},
        [session](NSDictionary *result) {
      NSDictionary *value = result[@"result"][@"value"];
      if (result[@"exceptionDetails"] || ![value isKindOfClass:NSDictionary.class]) {
        Report(@"failure", @{@"error": @"ENV popup could not be inspected", @"result": result}); CloseAll(); return;
      }
      NSString *expected = [configuration[@"fixture"] stringByAppendingString:@"/env"];
      NSArray *tabs = value[@"tabs"];
      if (tabs.count != 1 || ![tabs.firstObject[@"url"] isEqual:expected]) {
        Report(@"failure", @{@"error": @"ENV popup did not identify the source page", @"result": value}); CloseAll(); return;
      }
      Report(@"env-popup", value);
      NSString *scenario = configuration[@"envScenario"];
      if ([scenario isKindOfClass:NSString.class] && scenario.length) {
        envInputSession = session;
        PrivateSession(session, @"Runtime.addBinding", @{@"name": @"ctrlxProbeInsertText"}, [session, scenario](NSDictionary *) {
        PrivateSession(session, @"Runtime.evaluate", @{@"expression": [NSString stringWithFormat:@"(async () => { %@ })()", scenario],
            @"returnByValue": @YES, @"awaitPromise": @YES, @"userGesture": @YES, @"timeout": @30000}, [session](NSDictionary *response) {
          NSDictionary *result = response[@"result"][@"value"];
          if (response[@"exceptionDetails"] || ![result isKindOfClass:NSDictionary.class]) {
            Report(@"failure", @{@"error": @"ENV scenario failed", @"response": response}); CaptureENVPopup(session, false); return;
          }
          Report(@"env-scenario", result);
          CaptureENVPopup(session);
        });
        });
      } else CaptureENVPopup(session);
    });
  });
}

void OpenENVAction(NSString *session, int attempt) {
  // A worker target may appear before its extension execution context exists.
  // Poll from the host; a promise created in the startup context can be lost
  // when Chrome replaces that context while loading the extension bindings.
  PrivateSession(session, @"Runtime.evaluate", @{@"expression": @"Boolean(globalThis.chrome?.action?.openPopup)",
      @"returnByValue": @YES}, [session, attempt](NSDictionary *readiness) {
    if (![readiness[@"result"][@"value"] boolValue]) {
      if (attempt >= 40) { Report(@"failure", @{@"error": @"ENV worker extension bindings did not become ready"}); CloseAll(); return; }
      Later(200, [session, attempt] { if (!closing) OpenENVAction(session, attempt + 1); }); return;
    }
    PrivateSession(session, @"Runtime.evaluate", @{@"expression": @"chrome.action.openPopup().then(() => ({opened:true}))",
        @"returnByValue": @YES, @"awaitPromise": @YES, @"userGesture": @YES}, [session](NSDictionary *result) {
      if (result[@"exceptionDetails"] || ![result[@"result"][@"value"][@"opened"] boolValue]) {
        Report(@"failure", @{@"error": @"ENV action could not open its popup", @"result": result}); CloseAll(); return;
      }
      Report(@"env-action-opened", @{@"opened": @YES});
      PrivateCommand("Target.detachFromTarget", @{@"sessionId": session}, [](NSDictionary *) { InspectENVPopup(); });
    });
  });
}

void WaitForENVPage(int attempt) {
  if (closing) return;
  if (completedLoads[control->GetIdentifier()] == 0) {
    if (attempt >= 50) { Report(@"failure", @{@"error": @"ENV source page did not load"}); CloseAll(); return; }
    Later(100, [attempt] { WaitForENVPage(attempt + 1); }); return;
  }
  NSView *view = (__bridge NSView *)control->GetHost()->GetWindowHandle();
  [NSApp activateIgnoringOtherApps:YES];
  [view.window makeKeyAndOrderFront:nil];
  control->GetHost()->SetFocus(true);
  FindENVTarget(@"chrome-extension://imebogohheacbbmhfiiddakclhifpbde/static/background/index.js", 0, [](NSString *session) {
    OpenENVAction(session, 0);
  });
}

void BeginENVChecks() {
  const bool restarted = [configuration[@"envRestart"] boolValue];
  NSDictionary *request = restarted ? @{@"operation": @"list"} : @{@"operation": @"install", @"path": configuration[@"extension"]};
  AdminOperation(request, [restarted](NSDictionary *result) {
    Report(restarted ? @"env-restored" : @"env-install", result);
    bool found = false;
    for (NSDictionary *item in result[@"extensions"])
      if ([item[@"id"] isEqual:@"imebogohheacbbmhfiiddakclhifpbde"] && [item[@"state"] isEqual:@"ENABLED"]) found = true;
    if (!found) { Report(@"failure", @{@"error": @"ENV was not installed with its verified identity"}); CloseAll(); return; }
    control = Chrome([configuration[@"fixture"] stringByAppendingString:@"/env"]);
    Later(0, [] { WaitForENVPage(0); });
  });
}
