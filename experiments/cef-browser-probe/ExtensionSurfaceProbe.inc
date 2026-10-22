#include "SurfaceGeometryProbe.inc"

// Exercise the same native surface used by the product, with a real ENV popup.
void TestENVProductionSurface(NSString *session, std::function<void()> complete) {
  NSView *view = (__bridge NSView *)control->GetHost()->GetWindowHandle();
  NSWindow *source = view.window;
  auto released = std::make_shared<bool>(false);
  auto surface = std::make_shared<ExtensionSurface>(@"fixture-grant", [source] {
    return !closing && source.isVisible;
  }, [released] { *released = true; });
  if (!surface->SetWindow(source)) { Report(@"failure", @{@"error": @"Could not bind native surface"}); CloseAll(); return; }
  surface->Request(@{@"lease": @"fixture-grant", @"action": @"frame", @"maximumDimension": @1600},
      ^(NSData *data, NSString *error) {
    NSDictionary *frame = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    NSData *jpeg = [[NSData alloc] initWithBase64EncodedString:frame[@"jpeg"] options:0];
    if (error || !jpeg.length || jpeg.length > 512 * 1024 || !frame[@"generation"] ||
        ![jpeg writeToFile:[configuration[@"output"] stringByAppendingPathComponent:@"product-native-surface.jpg"] atomically:YES]) {
      Report(@"failure", @{@"error": error ?: @"Invalid native surface frame"}); CloseAll(); return;
    }
    auto request = [surface, frame](NSDictionary *operation, bool shouldPass = true) {
      NSMutableDictionary *payload = [@{@"lease": @"fixture-grant", @"generation": frame[@"generation"]} mutableCopy];
      [payload addEntriesFromDictionary:operation];
      __block bool passed = false;
      surface->Request(payload, ^(NSData *reply, NSString *failure) {
        passed = shouldPass ? reply && !failure : !reply && failure;
        if (!passed) Report(@"failure", @{@"operation": operation, @"error": failure ?: @"Unexpected native success"});
      });
      if (!passed) CloseAll();
      return passed;
    };
    if (!request(@{@"action": @"text", @"text": @"wrong token", @"lease": @"other"}, false) ||
        !request(@{@"action": @"text", @"text": @"stale frame", @"generation": @0}, false) ||
        !request(@{@"action": @"key", @"key": @"v", @"modifiers": @4}, false)) return;
    PrivateSession(session, @"Runtime.evaluate", @{@"expression": @R"JS((() => {
      const input = document.querySelector('input[placeholder="Search Env"]');
      const r = input.getBoundingClientRect();
      return {x:r.x+r.width/2,y:r.y+r.height/2,width:innerWidth,height:innerHeight};
    })())JS", @"returnByValue": @YES}, [source, session, surface, released, request, complete](NSDictionary *result) {
      NSDictionary *point = result[@"result"][@"value"];
      NSWindow *popup = ENVPopupWindow(source);
      if (!point || popup.parentWindow != source) { Report(@"failure", @{@"error": @"Product input popup unavailable"}); CloseAll(); return; }
      double x = NSMinX(popup.frame) - NSMinX(source.frame) + (popup.frame.size.width - [point[@"width"] doubleValue]) / 2 + [point[@"x"] doubleValue];
      double y = NSMaxY(source.frame) - NSMaxY(popup.frame) + (popup.frame.size.height - [point[@"height"] doubleValue]) / 2 + [point[@"y"] doubleValue];
      for (NSString *type in @[@"mousePressed", @"mouseReleased"])
        if (!request(@{@"action": @"mouse", @"type": type, @"button": @"left", @"x": @(x), @"y": @(y), @"clickCount": @1})) return;
      PrivateSession(session, @"Runtime.evaluate", @{@"expression": @R"JS((async () => {
        const deadline=Date.now()+3000;
        while(Date.now()<deadline) {
          if(document.activeElement===document.querySelector('input[placeholder="Search Env"]')) return true;
          await new Promise(r=>setTimeout(r,50));
        }
        throw new Error('Product click did not focus input');
      })())JS", @"awaitPromise": @YES, @"returnByValue": @YES}, [source, session, surface, released, request, complete](NSDictionary *focus) {
        if (![focus[@"result"][@"value"] boolValue]) { Report(@"failure", focus); CloseAll(); return; }
        // Remote input must stay in its clicked window when another CtrlX
        // window becomes key, rather than typing into that unrelated window.
        [embeddedWindow makeKeyAndOrderFront:nil];
        NSPanel *suggestions = [[NSPanel alloc] initWithContentRect:NSMakeRect(NSMinX(source.frame)+20,
            NSMinY(source.frame)+20, 100, 50) styleMask:NSWindowStyleMaskNonactivatingPanel
            backing:NSBackingStoreBuffered defer:NO];
        [source addChildWindow:suggestions ordered:NSWindowAbove];
        [suggestions orderFront:nil];
        if (!request(@{@"action": @"mouse", @"type": @"mouseMoved", @"x": @10, @"y": @10, @"buttons": @0}) ||
            !request(@{@"action": @"mouse", @"type": @"mousePressed", @"button": @"left", @"x": @10, @"y": @10}, false)) return;
        if (!request(@{@"action": @"key", @"key": @"a", @"modifiers": @4}) ||
            !request(@{@"action": @"text", @"text": @"产品路径 中文"})) return;
        [source removeChildWindow:suggestions];
        [suggestions orderOut:nil];
        Later(150, [source, session, surface, released, request, complete] {
          PrivateSession(session, @"Runtime.evaluate", @{@"expression": @"document.querySelector('input[placeholder=\"Search Env\"]').value", @"returnByValue": @YES},
              [source, session, surface, released, request, complete](NSDictionary *value) {
            if (![value[@"result"][@"value"] isEqual:@"产品路径 中文"]) { Report(@"failure", value); CloseAll(); return; }
            if (!request(@{@"action": @"key", @"key": @"a", @"modifiers": @4}) ||
                !request(@{@"action": @"key", @"key": @"Backspace", @"modifiers": @0})) return;
            NSRect original = source.frame;
            [source setFrameOrigin:NSMakePoint(original.origin.x+1, original.origin.y)];
            if (!request(@{@"action": @"text", @"text": @"moved window"}, false)) return;
            [source setFrame:original display:YES];
            surface->Revoke();
            if (!*released || !request(@{@"action": @"text", @"text": @"revoked"}, false)) return;
            PrivateSession(session, @"Runtime.evaluate", @{@"expression": @"document.querySelector('input[placeholder=\"Search Env\"]').value", @"returnByValue": @YES},
                [complete](NSDictionary *empty) {
              if (![empty[@"result"][@"value"] isEqual:@""]) { Report(@"failure", empty); CloseAll(); return; }
              Report(@"product-native-surface", @{@"capture": @YES, @"mouse": @YES, @"unicode": @YES,
                  @"editing": @YES, @"wrongLeaseRejected": @YES, @"staleGeometryRejected": @YES,
                  @"hostClipboardRejected": @YES, @"revokedInputRejected": @YES, @"restoredOwnedFocus": @YES,
                  @"keyboardSurvivesChildChange": @YES, @"obsoleteHoverIgnored": @YES, @"obsoleteClickRejected": @YES});
              TestSurfaceGeometry(complete);
            });
          });
        });
      });
    });
  });
}
