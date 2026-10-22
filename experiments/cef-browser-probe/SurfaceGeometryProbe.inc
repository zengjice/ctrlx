// Owned AppKit fixtures exercise popup overflow, focus and nested
// scrolling without depending on a particular extension's changing UI.
void TestSurfaceGeometry(std::function<void()> complete) {
  NSWindow *root = [[NSWindow alloc] initWithContentRect:NSMakeRect(300, 450, 400, 260)
      styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  root.releasedWhenClosed = NO;
  root.backgroundColor = NSColor.redColor;
  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSMakeRect(160, 40, 200, 160)];
  NSTextView *document = [[NSTextView alloc] initWithFrame:NSMakeRect(0, 0, 180, 2000)];
  document.string = [@"Scroll fixture\n" stringByPaddingToLength:4000 withString:@"Scroll fixture\n" startingAtIndex:0];
  scroll.documentView = document;
  scroll.hasVerticalScroller = YES;
  [root.contentView addSubview:scroll];
  NSWindow *child = [[NSWindow alloc] initWithContentRect:NSMakeRect(240, 370, 180, 100)
      styleMask:NSWindowStyleMaskTitled backing:NSBackingStoreBuffered defer:NO];
  child.releasedWhenClosed = NO;
  child.backgroundColor = NSColor.blueColor;
  NSTextField *field = [[NSTextField alloc] initWithFrame:NSMakeRect(10, 20, 150, 24)];
  [child.contentView addSubview:field];
  [root addChildWindow:child ordered:NSWindowAbove];
  [root makeKeyAndOrderFront:nil];
  [child orderFront:nil];
  auto surface = std::make_shared<ExtensionSurface>(@"geometry-grant", [root] { return root.isVisible; }, [] {});
  if (!surface->SetWindow(root)) { Report(@"failure", @{@"error": @"Geometry fixture did not open"}); CloseAll(); return; }
  Later(150, [root, child, field, scroll, surface, complete] {
    surface->Request(@{@"lease": @"geometry-grant", @"action": @"frame", @"maximumDimension": @1600},
        ^(NSData *data, NSString *error) {
      NSDictionary *frame = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
      NSRect bounds = NSIntegralRect(NSUnionRect(root.frame, child.frame));
      NSData *jpeg = [[NSData alloc] initWithBase64EncodedString:frame[@"jpeg"] options:0];
      NSBitmapImageRep *bitmap = jpeg ? [NSBitmapImageRep imageRepWithData:jpeg] : nil;
      const NSPoint sample = NSMakePoint(NSMidX(child.frame)-NSMinX(bounds), NSMaxY(bounds)-NSMinY(child.frame)-8);
      NSColor *color = bitmap ? [[bitmap colorAtX:lround(sample.x) y:lround(sample.y)] colorUsingColorSpace:NSColorSpace.deviceRGBColorSpace] : nil;
      bool geometry = !error && [frame[@"width"] doubleValue] == bounds.size.width &&
          [frame[@"height"] doubleValue] == bounds.size.height && bitmap.pixelsWide == bounds.size.width &&
          bitmap.pixelsHigh == bounds.size.height && color.blueComponent > .7 && color.redComponent < .3;
      [jpeg writeToFile:[configuration[@"output"] stringByAppendingPathComponent:@"product-popup-overflow.jpg"] atomically:YES];
      if (!geometry) {
        Report(@"failure", @{@"error": error ?: @"Popup image and input bounds differ", @"bounds": NSStringFromRect(bounds),
            @"width": frame[@"width"] ?: @0, @"height": frame[@"height"] ?: @0,
            @"sample": NSStringFromPoint(sample), @"color": color.description ?: @"none"});
        [child close]; [root close]; surface->Revoke(); CloseAll(); return;
      }
      auto request = [surface, frame](NSDictionary *operation) {
        NSMutableDictionary *payload = [@{@"lease": @"geometry-grant", @"generation": frame[@"generation"]} mutableCopy];
        [payload addEntriesFromDictionary:operation];
        __block bool passed = false;
        surface->Request(payload, ^(NSData *data, NSString *error) {
          passed = data && !error;
          if (!passed) Report(@"failure", @{@"error": error ?: @"Missing fixture input response"});
        });
        return passed;
      };
      [NSApp deactivate];
      Later(100, [root, child, field, scroll, surface, bounds, request, complete] {
        const bool inactive = !NSApp.isActive;
        NSPoint point = [child convertPointToScreen:[field convertPoint:NSMakePoint(30, 12) toView:nil]];
        bool passed = true;
        for (NSString *type in @[@"mousePressed", @"mouseReleased"])
          passed = request(@{@"action": @"mouse", @"type": type, @"button": @"left", @"clickCount": @1,
              @"x": @(point.x-NSMinX(bounds)), @"y": @(NSMaxY(bounds)-point.y)}) && passed;
        passed = request(@{@"action": @"text", @"text": @"background field"}) && passed;
        NSPoint wheel = [root convertPointToScreen:[scroll convertPoint:NSMakePoint(80, 80) toView:nil]];
        CGFloat before = scroll.contentView.bounds.origin.y;
        passed = request(@{@"action": @"mouse", @"type": @"mouseWheel", @"x": @(wheel.x-NSMinX(bounds)),
            @"y": @(NSMaxY(bounds)-wheel.y), @"deltaX": @0, @"deltaY": @100}) && passed;
        Later(150, [root, child, field, scroll, surface, before, passed, inactive, complete] {
          NSString *value = [field.currentEditor string] ?: field.stringValue;
          bool focused = [value isEqual:@"background field"];
          bool scrolled = fabs(scroll.contentView.bounds.origin.y-before) > 10;
          NSDictionary *result = @{@"popupOverflow": @YES, @"inactiveBeforeInput": @(inactive),
              @"ownedPopupInput": @(focused), @"nestedScroll": @(scrolled), @"scrollBefore": @(before),
              @"scrollAfter": @(scroll.contentView.bounds.origin.y)};
          surface->Revoke(); [child close]; [root close];
          // Some desktop sessions immediately reactivate this fixture after
          // deactivate(). Report that limit instead of claiming background input.
          Report(passed && focused && scrolled ? @"product-surface-geometry" : @"failure", result);
          if (passed && focused && scrolled) complete(); else CloseAll();
        });
      });
    });
  });
}
