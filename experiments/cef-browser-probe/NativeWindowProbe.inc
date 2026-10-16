// Test only: characterize capture of this process's Chrome UI, including popup
// windows. currentProcess excludes other apps and does not request screen access.
NSWindow *OwnedKeyboardWindow(NSWindow *source) {
  NSWindow *target = NSApp.keyWindow;
  for (NSWindow *owner = target; owner; owner = owner.parentWindow)
    if (owner == source && source.isVisible) return target;
  return nil;
}

bool InsertOwnedText(NSWindow *source, NSString *text) {
  NSWindow *target = OwnedKeyboardWindow(source);
  id responder = target.firstResponder;
  if (!target || ![responder isKindOfClass:NSView.class] ||
      ![(NSView *)responder isDescendantOf:target.contentView] ||
      ![responder respondsToSelector:@selector(insertText:replacementRange:)]) return false;
  [(id<NSTextInputClient>)responder insertText:text replacementRange:NSMakeRange(NSNotFound, 0)];
  return true;
}

bool KeyOwnedWindow(NSWindow *source, unsigned short keyCode, NSString *characters, NSEventModifierFlags flags = 0) {
  NSWindow *target = OwnedKeyboardWindow(source);
  if (!target) return false;
  id responder = target.firstResponder;
  if (keyCode == 0 && flags == NSEventModifierFlagCommand &&
      [responder respondsToSelector:@selector(doCommandBySelector:)]) {
    [(id<NSTextInputClient>)responder doCommandBySelector:@selector(selectAll:)];
    return true;
  }
  for (NSEventType type : {NSEventTypeKeyDown, NSEventTypeKeyUp}) {
    NSEvent *event = [NSEvent keyEventWithType:type location:NSZeroPoint modifierFlags:flags
        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:target.windowNumber context:nil
        characters:characters charactersIgnoringModifiers:characters isARepeat:NO keyCode:keyCode];
    [NSApp sendEvent:event];
  }
  return true;
}

bool ClickOwnedWindow(NSWindow *source, double x, double y) {
  if (!source.isVisible || !std::isfinite(x) || !std::isfinite(y) || x < 0 || y < 0 ||
      x >= source.frame.size.width || y >= source.frame.size.height) return false;
  NSPoint screen = NSMakePoint(source.frame.origin.x + x, NSMaxY(source.frame) - y);
  std::function<NSWindow *(NSWindow *)> targetAt = [&](NSWindow *window) -> NSWindow * {
    for (NSWindow *child in window.childWindows.reverseObjectEnumerator)
      if (child.isVisible && NSPointInRect(screen, child.frame)) return targetAt(child);
    return window;
  };
  NSWindow *target = targetAt(source);
  NSPoint point = [target convertPointFromScreen:screen];
  for (NSEventType type : {NSEventTypeLeftMouseDown, NSEventTypeLeftMouseUp}) {
    NSEvent *event = [NSEvent mouseEventWithType:type location:point modifierFlags:0
        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:target.windowNumber
        context:nil eventNumber:0 clickCount:1 pressure:type == NSEventTypeLeftMouseDown ? 1 : 0];
    [NSApp sendEvent:event];
  }
  Report(@"native-window-input", @{@"source": @(source.windowNumber), @"target": @(target.windowNumber), @"x": @(x), @"y": @(y)});
  return true;
}

void CaptureOwnedWindow(NSWindow *window, NSString *filename, std::function<void()> complete) {
  if (window.parentWindow) {
    Report(@"failure", @{@"error": @"Capture the owning top-level window; child-only filters may include its parent"}); CloseAll(); return;
  }
  if (@available(macOS 14.4, *)) {
    const NSInteger number = window.windowNumber;
    NSMutableArray *owned = [NSMutableArray array];
    for (NSWindow *candidate in NSApp.windows) {
      if (!candidate.isVisible) continue;
      [owned addObject:@{@"id": @(candidate.windowNumber), @"parent": @(candidate.parentWindow.windowNumber),
          @"title": candidate.title ?: @"", @"frame": NSStringFromRect(candidate.frame), @"key": @(candidate.isKeyWindow)}];
    }
    Report(@"native-window-tree", @{@"source": @(number), @"windows": owned});
    [SCShareableContent getCurrentProcessShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
      SCWindow *selected = nil;
      for (SCWindow *candidate in content.windows)
        if (candidate.windowID == number && candidate.owningApplication.processID == getpid()) selected = candidate;
      if (error || !selected) {
        Later(0, [error] { Report(@"failure", @{@"error": error.localizedDescription ?: @"Own source window was not capturable"}); CloseAll(); });
        return;
      }
      SCStreamConfiguration *settings = [[SCStreamConfiguration alloc] init];
      settings.width = lround(selected.frame.size.width);
      settings.height = lround(selected.frame.size.height);
      settings.showsCursor = NO;
      settings.ignoreShadowsSingleWindow = YES;
      settings.includeChildWindows = YES;
      SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:selected];
      [SCScreenshotManager captureImageWithFilter:filter configuration:settings completionHandler:^(CGImageRef image, NSError *captureError) {
        if (image) CGImageRetain(image);
        Later(0, [image, captureError, filename, complete] {
          if (!image || captureError) {
            if (image) CGImageRelease(image);
            Report(@"failure", @{@"error": captureError.localizedDescription ?: @"Own window capture failed"}); CloseAll(); return;
          }
          NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCGImage:image];
          CGImageRelease(image);
          NSData *png = [bitmap representationUsingType:NSBitmapImageFileTypePNG properties:@{}];
          NSString *path = [configuration[@"output"] stringByAppendingPathComponent:filename];
          if (![png writeToFile:path atomically:YES]) { Report(@"failure", @{@"error": @"Native window image could not be saved"}); CloseAll(); return; }
          Report(@"native-window-capture", @{@"file": filename, @"width": @(bitmap.pixelsWide), @"height": @(bitmap.pixelsHigh)});
          complete();
        });
      }];
    }];
  } else { Report(@"failure", @{@"error": @"Current-process window capture requires macOS 14.4"}); CloseAll(); }
}
