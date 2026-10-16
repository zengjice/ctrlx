// Native Chrome UI is a separate human control surface. Never expose window IDs,
// arbitrary CDP targets, or system input to the remote page gateway.
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#include <cmath>
#include <memory>

static size_t pendingExtensionCaptures = 0;
static int extensionInputDepth = 0;

class ExtensionInputScope {
 public:
  ExtensionInputScope() { ++extensionInputDepth; }
  ~ExtensionInputScope() { --extensionInputDepth; }
 private:
  CefScopedSendingEvent sending_;
};

class ExtensionSurface final : public std::enable_shared_from_this<ExtensionSurface> {
 public:
  using Reply = void (^)(NSData *, NSString *);
  ExtensionSurface(NSString *token, std::function<bool()> sourceValid, std::function<void()> released)
      : token_([token copy]), sourceValid_(std::move(sourceValid)), released_(std::move(released)) {
    Renew();
  }
  ~ExtensionSurface() { Revoke(); }

  bool Active() {
    if (active_ && (!sourceValid_() || NSProcessInfo.processInfo.systemUptime >= expires_)) Revoke();
    return active_;
  }
  bool Authorize(NSString *token) {
    if (!Active() || ![token isKindOfClass:NSString.class] || ![token_ isEqual:token]) return false;
    Renew();
    return true;
  }
  void Revoke() {
    if (!active_) return;
    active_ = false;
    pressed_ = nil;
    keyboardWindow_ = nil;
    root_ = nil;
    geometry_ = nil;
    rootGeometry_ = nil;
    released_();
  }
  bool Owns(NSWindow *window) const {
    if (!root_ || !window) return false;
    for (NSWindow *candidate = window; candidate; candidate = candidate.parentWindow)
      if (candidate == root_) return true;
    return false;
  }
  bool SetWindow(NSWindow *window) {
    if (!Active() || !window || window.parentWindow || !window.isVisible) return false;
    if (root_ != window) {
      root_ = window; keyboardWindow_ = window; geometry_ = nil; rootGeometry_ = nil;
      pressed_ = nil; keyboardGeneration_ = ++generation_;
    }
    return true;
  }
  void Request(NSDictionary *request, Reply reply) {
    CEF_REQUIRE_UI_THREAD();
    if (!Authorize(request[@"lease"])) { reply(nil, @"Extension control expired. Take Control again."); return; }
    if (!root_.isVisible || root_.parentWindow) { reply(nil, @"The extension window is closed or hidden."); return; }
    NSString *action = request[@"action"];
    if ([action isEqual:@"frame"]) { Capture(request, reply); return; }
    const bool keyboard = [action isEqual:@"text"] || [action isEqual:@"key"];
    const bool numbered = [request[@"generation"] isKindOfClass:NSNumber.class];
    const uint64_t requested = numbered ? [request[@"generation"] unsignedLongLongValue] : 0;
    // Typing may open/resize autocomplete or change a popup's results. Keep
    // keyboard input bound to the clicked window while its root stays put;
    // coordinate input still requires the exact visible child-window layout.
    const bool keyboardValid = keyboard && numbered && requested >= keyboardGeneration_ && requested <= generation_ &&
        rootGeometry_ && [rootGeometry_ isEqual:RootGeometry()];
    const bool release = [action isEqual:@"mouse"] && [request[@"type"] isEqual:@"mouseReleased"];
    // A mouse-down can open a child popup. Its matching up belongs to the
    // original target, never to the new popup that now occupies that coordinate.
    if (!keyboardValid && !(release && pressed_ && Owns(pressed_) && pressed_.isVisible) &&
        (!numbered || requested != generation_ || !geometry_ ||
         ![geometry_ isEqual:Geometry()])) {
      // An obsolete hover is disposable, unlike a click, drag or edit. A popup
      // opening underneath the pointer must not terminate an otherwise valid grant.
      if ([action isEqual:@"mouse"] && [request[@"type"] isEqual:@"mouseMoved"] &&
          !pressed_ && [request[@"buttons"] intValue] == 0) {
        reply([@"{}" dataUsingEncoding:NSUTF8StringEncoding], nil); return;
      }
      reply(nil, @"The extension window changed. Wait for a fresh frame."); return;
    }
    ExtensionInputScope scope;
    NSString *error = nil;
    if ([action isEqual:@"text"]) error = InsertText(request[@"text"]);
    else if ([action isEqual:@"key"]) error = Key(request);
    else if ([action isEqual:@"mouse"]) error = Pointer(request);
    else if ([action isEqual:@"fit"]) {
      double width = [request[@"width"] doubleValue], height = [request[@"height"] doubleValue];
      if (!std::isfinite(width) || !std::isfinite(height) || width < 480 || width > 2560 || height < 360 || height > 2560)
        error = @"Unsupported extension window size.";
      else {
        NSRect frame = root_.frame;
        frame.origin.y += frame.size.height - height;
        frame.size = NSMakeSize(width, height);
        [root_ setFrame:frame display:YES];
        geometry_ = nil;
        rootGeometry_ = nil;
        keyboardGeneration_ = ++generation_;
      }
    } else error = @"Unsupported extension surface operation.";
    reply(error ? nil : [@"{}" dataUsingEncoding:NSUTF8StringEncoding], error);
  }

 private:
  void Renew() { expires_ = NSProcessInfo.processInfo.systemUptime + 20; }
  NSArray *RootGeometry() const {
    return @[@(root_.windowNumber), NSStringFromRect(root_.frame)];
  }
  NSRect SurfaceBounds() const {
    NSRect bounds = root_.frame;
    std::function<void(NSWindow *)> include = [&](NSWindow *window) {
      if (!window.isVisible) return;
      bounds = NSUnionRect(bounds, window.frame);
      for (NSWindow *child in window.childWindows) include(child);
    };
    include(root_);
    return NSIntegralRect(bounds);
  }
  NSArray *Geometry() const {
    NSMutableArray *result = [NSMutableArray array];
    std::function<void(NSWindow *)> visit = [&](NSWindow *window) {
      if (!window.isVisible) return;
      [result addObject:@[@(window.windowNumber), NSStringFromRect(window.frame)]];
      for (NSWindow *child in window.childWindows) visit(child);
    };
    visit(root_);
    return result;
  }
  NSView *KeyboardResponder() const {
    NSWindow *window = keyboardWindow_;
    if (!Owns(window) || !window.isVisible) return nil;
    // Focus only the window explicitly clicked through this grant. AppKit's
    // key window may now be an unrelated CtrlX terminal or settings window.
    [window makeKeyAndOrderFront:nil];
    id responder = window.firstResponder;
    return [responder isKindOfClass:NSView.class] && [(NSView *)responder isDescendantOf:window.contentView]
        ? responder : nil;
  }
  NSString *InsertText(NSString *text) {
    if (![text isKindOfClass:NSString.class] || [text lengthOfBytesUsingEncoding:NSUTF8StringEncoding] > 16000)
      return @"Paste at most 16 KB of text at a time.";
    NSView *responder = KeyboardResponder();
    if (![responder respondsToSelector:@selector(insertText:replacementRange:)])
      return @"Click an input in the extension window first.";
    [(id<NSTextInputClient>)responder insertText:text replacementRange:NSMakeRange(NSNotFound, 0)];
    return nil;
  }
  NSString *Key(NSDictionary *request) {
    NSView *responder = KeyboardResponder();
    if (!responder) return @"The extension window does not have keyboard focus.";
    NSString *key = request[@"key"];
    int modifiers = [request[@"modifiers"] intValue];
    if (![key isKindOfClass:NSString.class]) return @"Invalid extension key.";
    // Clipboard/menu shortcuts are not remote text input. In particular Cmd+V
    // must never paste the Host's clipboard, nor Cmd+Q terminate the Host App.
    if (modifiers == 4 && [key.lowercaseString isEqual:@"a"] &&
        [responder respondsToSelector:@selector(doCommandBySelector:)]) {
      [(id<NSTextInputClient>)responder doCommandBySelector:@selector(selectAll:)];
      return nil;
    }
    if (modifiers != 0 && modifiers != 8) return @"This keyboard shortcut is unavailable in extension control.";
    NSDictionary *keys = @{@"Enter": @[@36, @"\r"], @"Tab": @[@48, @"\t"],
        @"Backspace": @[@51, @"\177"], @"Delete": @[@117, @"\uf728"], @"Escape": @[@53, @"\033"],
        @"ArrowLeft": @[@123, @"\uf702"], @"ArrowRight": @[@124, @"\uf703"],
        @"ArrowDown": @[@125, @"\uf701"], @"ArrowUp": @[@126, @"\uf700"],
        @"Home": @[@115, @"\uf729"], @"End": @[@119, @"\uf72b"],
        @"PageUp": @[@116, @"\uf72c"], @"PageDown": @[@121, @"\uf72d"]};
    NSArray *native = keys[key];
    if (!native) return @"Use text input for printable characters.";
    NSWindow *window = responder.window;
    for (NSEventType type : {NSEventTypeKeyDown, NSEventTypeKeyUp}) {
      NSEvent *event = [NSEvent keyEventWithType:type location:NSZeroPoint
          modifierFlags:modifiers == 8 ? NSEventModifierFlagShift : 0
          timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:window.windowNumber context:nil
          characters:native[1] charactersIgnoringModifiers:native[1] isARepeat:NO keyCode:[native[0] unsignedShortValue]];
      [window sendEvent:event];
    }
    return nil;
  }
  NSString *Pointer(NSDictionary *request) {
    double x = [request[@"x"] doubleValue], y = [request[@"y"] doubleValue];
    NSRect bounds = SurfaceBounds();
    if (!std::isfinite(x) || !std::isfinite(y) || x < 0 || y < 0 || x >= bounds.size.width || y >= bounds.size.height)
      return @"Pointer is outside the extension window.";
    NSString *type = request[@"type"], *button = request[@"button"];
    if ([request[@"modifiers"] intValue] != 0) return @"Modified pointer input is not supported in extension control.";
    NSPoint screen = NSMakePoint(NSMinX(bounds) + x, NSMaxY(bounds) - y);
    std::function<NSWindow *(NSWindow *)> targetAt = [&](NSWindow *window) -> NSWindow * {
      for (NSWindow *child in window.childWindows.reverseObjectEnumerator)
        if (child.isVisible && NSPointInRect(screen, child.frame)) return targetAt(child);
      return NSPointInRect(screen, window.frame) ? window : nil;
    };
    NSWindow *target = pressed_ ?: targetAt(root_);
    // A popup extending outside its root can leave empty space in the captured
    // union. That space has no input destination.
    if (!target) return nil;
    if (!Owns(target) || !target.isVisible) return @"The pointer's target was closed.";
    NSPoint location = [target convertPointFromScreen:screen];
    if ([type isEqual:@"mouseWheel"]) {
      double dx = [request[@"deltaX"] doubleValue], dy = [request[@"deltaY"] doubleValue];
      if (!std::isfinite(dx) || !std::isfinite(dy) || fabs(dx) > 4096 || fabs(dy) > 4096)
        return @"Invalid scroll input.";
      // Start with an AppKit event so CGEvent retains the exact window and local
      // coordinates. A standalone CG scroll event has no associated NSWindow.
      NSEvent *position = [NSEvent mouseEventWithType:NSEventTypeMouseMoved location:location modifierFlags:0
          timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:target.windowNumber context:nil
          eventNumber:0 clickCount:0 pressure:0];
      CGEventRef cg = position.CGEvent ? CGEventCreateCopy(position.CGEvent) : nullptr;
      if (!cg) return @"Could not create scroll input.";
      // This event is delivered only to the owned view, never posted globally.
      CGEventSetType(cg, kCGEventScrollWheel);
      CGEventSetIntegerValueField(cg, kCGScrollWheelEventIsContinuous, 1);
      CGEventSetIntegerValueField(cg, kCGScrollWheelEventPointDeltaAxis1, -lround(dy));
      CGEventSetIntegerValueField(cg, kCGScrollWheelEventPointDeltaAxis2, -lround(dx));
      NSEvent *event = [NSEvent eventWithCGEvent:cg];
      CFRelease(cg);
      NSView *hit = [target.contentView hitTest:[target.contentView convertPoint:location fromView:nil]];
      if (!hit) return @"No scroll destination at this point.";
      [hit scrollWheel:event];
      return nil;
    }
    int clicks = [request[@"clickCount"] intValue];
    if (clicks < 0 || clicks > 3) return @"Invalid pointer click count.";
    NSEventType kind;
    if ([type isEqual:@"mousePressed"] && [button isEqual:@"left"]) {
      if (pressed_) return @"A pointer press is already in progress.";
      kind = NSEventTypeLeftMouseDown;
      pressed_ = target;
      keyboardWindow_ = target;
      // Remote clicks already identify an authorized window. Do not consume the
      // first click merely activating a background Host through NSApplication.
      [target makeKeyAndOrderFront:nil];
    } else if ([type isEqual:@"mouseReleased"] && [button isEqual:@"left"]) {
      if (!pressed_) return @"No matching pointer press.";
      kind = NSEventTypeLeftMouseUp;
    } else if ([type isEqual:@"mouseMoved"]) kind = pressed_ ? NSEventTypeLeftMouseDragged : NSEventTypeMouseMoved;
    else return @"Only left pointer input is supported in extension control.";
    NSEvent *event = [NSEvent mouseEventWithType:kind location:location modifierFlags:0
        timestamp:NSProcessInfo.processInfo.systemUptime windowNumber:target.windowNumber context:nil
        eventNumber:0 clickCount:clicks pressure:kind == NSEventTypeLeftMouseDown ? 1 : 0];
    if (kind == NSEventTypeLeftMouseUp) pressed_ = nil;
    [target sendEvent:event];
    return nil;
  }
  void Capture(NSDictionary *request, Reply reply) {
    int maximum = request[@"maximumDimension"] ? [request[@"maximumDimension"] intValue] : 1600;
    if (maximum < 256 || maximum > 2560) { reply(nil, @"Unsupported extension frame size."); return; }
    if (capturing_ || pendingExtensionCaptures >= 4) { reply(nil, @"Extension capture is busy."); return; }
    NSArray *geometry = Geometry();
    if (![geometry_ isEqual:geometry]) { geometry_ = geometry; ++generation_; }
    NSArray *rootGeometry = RootGeometry();
    if (![rootGeometry_ isEqual:rootGeometry]) {
      rootGeometry_ = rootGeometry;
      keyboardGeneration_ = generation_;
    }
    const uint64_t generation = generation_;
    const NSInteger number = root_.windowNumber;
    // ScreenCaptureKit includes child popups beyond the root's bounds. Use the
    // same union for capture dimensions and pointer coordinates.
    const NSSize size = SurfaceBounds().size;
    if (size.width < 1 || size.height < 1 || size.width > 8192 || size.height > 8192) {
      reply(nil, @"Unsupported extension window dimensions."); return;
    }
    capturing_ = true;
    ++pendingExtensionCaptures;
    auto self = shared_from_this();
    auto finish = [self, geometry, generation, size, reply](CGImageRef image, NSString *error) {
      if (image) CGImageRetain(image);
      CefPostTask(TID_UI, new BrowserUITask([self, geometry, generation, size, image, error, reply] {
        self->capturing_ = false;
        --pendingExtensionCaptures;
        NSData *jpeg = nil;
        NSString *failure = error;
        if (!self->Active() || generation != self->generation_ || ![geometry isEqual:self->Geometry()])
          failure = @"Extension control or window geometry changed during capture.";
        else if (image && !failure) {
          NSBitmapImageRep *bitmap = [[NSBitmapImageRep alloc] initWithCGImage:image];
          for (NSNumber *quality in @[@0.7, @0.45, @0.25]) {
            jpeg = [bitmap representationUsingType:NSBitmapImageFileTypeJPEG properties:@{NSImageCompressionFactor: quality}];
            if (jpeg.length <= 512 * 1024) break;
          }
          if (!jpeg.length || jpeg.length > 512 * 1024) failure = @"Extension frame is too large. Request a smaller image.";
        } else if (!failure) failure = @"Extension window capture failed.";
        if (image) CGImageRelease(image);
        NSData *data = failure ? nil : [NSJSONSerialization dataWithJSONObject:@{
          @"jpeg": [jpeg base64EncodedStringWithOptions:0], @"width": @(size.width), @"height": @(size.height),
          @"generation": @(generation)} options:0 error:nil];
        reply(data, failure);
      }));
    };
    if (@available(macOS 14.4, *)) {
    [SCShareableContent getCurrentProcessShareableContentWithCompletionHandler:^(SCShareableContent *content, NSError *error) {
      SCWindow *selected = nil;
      for (SCWindow *candidate in content.windows)
        if (candidate.windowID == number && candidate.owningApplication.processID == getpid()) selected = candidate;
      if (error || !selected) { finish(nullptr, error.localizedDescription ?: @"The owned extension window is unavailable."); return; }
      double scale = std::min(1.0, maximum / std::max(size.width, size.height));
      SCStreamConfiguration *settings = [[SCStreamConfiguration alloc] init];
      settings.width = std::max(1L, lround(size.width * scale));
      settings.height = std::max(1L, lround(size.height * scale));
      settings.showsCursor = NO;
      settings.ignoreShadowsSingleWindow = YES;
      settings.includeChildWindows = YES;
      SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:selected];
      [SCScreenshotManager captureImageWithFilter:filter configuration:settings completionHandler:^(CGImageRef image, NSError *error) {
        finish(image, error.localizedDescription);
      }];
    }];
    } else finish(nullptr, @"Extension window capture requires macOS 14.4 or later.");
  }
  NSString *token_;
  NSWindow *root_ = nil, *pressed_ = nil, *keyboardWindow_ = nil;
  NSArray *geometry_ = nil;
  NSArray *rootGeometry_ = nil;
  uint64_t generation_ = 0;
  uint64_t keyboardGeneration_ = 0;
  double expires_;
  bool active_ = true, capturing_ = false;
  std::function<bool()> sourceValid_;
  std::function<void()> released_;
};
