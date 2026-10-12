#import <UIKit/UIKit.h>
#import <WebKit/WebKit.h>

static NSTimeInterval inputDownAt, inputUpAt;
static void saveInputEvent(NSDictionary *event) {
    NSURL *directory = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    NSURL *url = [directory URLByAppendingPathComponent:@"input-events.jsonl"];
    NSData *data = [NSJSONSerialization dataWithJSONObject:event options:0 error:nil];
    if (!data) return;
    if (![NSFileManager.defaultManager fileExistsAtPath:url.path]) [NSFileManager.defaultManager createFileAtPath:url.path contents:nil attributes:nil];
    NSFileHandle *file = [NSFileHandle fileHandleForWritingAtPath:url.path];
    [file seekToEndOfFile]; [file writeData:data]; [file writeData:[@"\n" dataUsingEncoding:NSUTF8StringEncoding]]; [file closeFile];
}
@interface CapacityApplication : UIApplication
@end
@implementation CapacityApplication
- (void)sendEvent:(UIEvent *)event {
    if (event.type == UIEventTypePresses) {
        for (UIPress *press in ((UIPressesEvent *)event).allPresses) {
            UIKey *key = press.key;
            saveInputEvent(@{@"kind":@"press", @"at":@(NSProcessInfo.processInfo.systemUptime),
                @"timestamp":@(press.timestamp), @"phase":@(press.phase),
                @"usage":@(key.keyCode), @"modifiers":@(key.modifierFlags)});
        }
    }
    for (UITouch *touch in event.allTouches) {
        if (touch.phase == UITouchPhaseBegan) inputDownAt = touch.timestamp;
        if (touch.phase == UITouchPhaseEnded) inputUpAt = touch.timestamp;
        CGPoint point = [touch locationInView:touch.window];
        saveInputEvent(@{@"kind":@"touch", @"at":@(NSProcessInfo.processInfo.systemUptime),
            @"timestamp":@(touch.timestamp), @"phase":@(touch.phase),
            @"viewClass":NSStringFromClass(touch.view.class) ?: @"", @"x":@(point.x), @"y":@(point.y)});
    }
    [super sendEvent:event];
}
@end

@interface CapacityBarcode : UIView
@property(nonatomic) uint16_t frameNumber;
@property(nonatomic) uint8_t tapNumber;
@end
@implementation CapacityBarcode
- (void)drawRect:(CGRect)rect {
    uint32_t value = self.frameNumber | ((uint32_t)self.tapNumber << 16);
    value |= (uint32_t)(uint8_t)(value ^ (value >> 8) ^ (value >> 16) ^ 0xA5) << 24;
    CGFloat cell = self.bounds.size.width / 36;
    for (NSUInteger i = 0; i < 36; i++) {
        UIColor *color = i == 0 ? UIColor.magentaColor : i == 1 ? UIColor.cyanColor : i == 2 ? UIColor.yellowColor : i == 35 ? UIColor.greenColor :
            ((value >> (i - 3)) & 1) ? UIColor.whiteColor : UIColor.blackColor;
        [color setFill]; UIRectFill(CGRectMake(i * cell, 0, cell + 0.1, self.bounds.size.height));
    }
}
@end

@interface SimulatorFixture : UIViewController <UITextFieldDelegate, UITextViewDelegate, WKScriptMessageHandler, WKNavigationDelegate>
@property(nonatomic, strong) UITextField *plain;
@property(nonatomic, strong) UITextField *secure;
@property(nonatomic, strong) UITextView *multiline;
@property(nonatomic, strong) UILabel *counter;
@property(nonatomic, strong) UILabel *animation;
@property(nonatomic, strong) CapacityBarcode *barcode;
@property(nonatomic, strong) CADisplayLink *displayLink;
@property(nonatomic) NSUInteger taps;
@property(nonatomic) NSUInteger frames;
@property(nonatomic) NSUInteger focusChanges;
@property(nonatomic, copy) NSString *webText;
@property(nonatomic, strong) WKWebView *web;
@property(nonatomic, copy) NSDictionary *webState;
@property(nonatomic, copy) NSString *launchID;
@property(nonatomic) BOOL webNavigationFinished;
@end

@implementation SimulatorFixture
- (void)viewDidLoad {
    [super viewDidLoad];
    self.view.backgroundColor = UIColor.whiteColor;
    self.webText = @"";
    self.launchID = NSUUID.UUID.UUIDString;
    self.webState = @{};
    UIStackView *stack = [UIStackView new]; stack.axis = UILayoutConstraintAxisVertical; stack.spacing = 12;
    stack.translatesAutoresizingMaskIntoConstraints = NO; [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[[stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:12], [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24], [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24]]];
    UILabel *title = [UILabel new]; title.text = @"CtrlX Simulator Fixture"; title.font = [UIFont boldSystemFontOfSize:22]; [stack addArrangedSubview:title];
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem]; [button setTitle:@"Tap counter" forState:UIControlStateNormal]; button.accessibilityIdentifier = @"fixture.tap";
    [button addTarget:self action:@selector(tap) forControlEvents:UIControlEventTouchUpInside]; [stack addArrangedSubview:button];
    self.counter = [UILabel new]; self.counter.text = @"Taps: 0"; self.counter.accessibilityIdentifier = @"fixture.counter"; [stack addArrangedSubview:self.counter];
    self.plain = [self field:@"Plain text" identifier:@"fixture.plain" secure:NO]; [stack addArrangedSubview:self.plain];
    self.secure = [self field:@"Secure text" identifier:@"fixture.secure" secure:YES]; [stack addArrangedSubview:self.secure];
    self.multiline = [UITextView new]; self.multiline.delegate = self; self.multiline.accessibilityIdentifier = @"fixture.multiline"; self.multiline.font = [UIFont systemFontOfSize:17]; self.multiline.layer.borderWidth = 1;
    [self.multiline.heightAnchor constraintEqualToConstant:70].active = YES; [stack addArrangedSubview:self.multiline];
    WKWebViewConfiguration *config = [WKWebViewConfiguration new]; [config.userContentController addScriptMessageHandler:self name:@"changed"];
    WKWebView *web = [[WKWebView alloc] initWithFrame:CGRectZero configuration:config]; [web.heightAnchor constraintEqualToConstant:100].active = YES;
    self.web = web; web.navigationDelegate = self;
    [web loadHTMLString:@"<meta name='viewport' content='width=device-width, initial-scale=1'><input id='web-input' aria-label='Web text' style='width:95%;height:40px;font-size:18px' placeholder='Web text'><script>const input=document.getElementById('web-input');function report(kind){const r=input.getBoundingClientRect();window.webkit.messageHandlers.changed.postMessage({kind,value:input.value,focused:document.activeElement===input,selectionStart:input.selectionStart,selectionEnd:input.selectionEnd,ready:document.readyState,rect:{x:r.x,y:r.y,width:r.width,height:r.height}});}for(const kind of ['focus','blur','input','select','compositionstart','compositionupdate','compositionend'])input.addEventListener(kind,()=>report(kind));document.addEventListener('selectionchange',()=>report('selectionchange'));document.addEventListener('DOMContentLoaded',()=>report('ready'));report('initial');</script>" baseURL:nil];
    [stack addArrangedSubview:web];
    self.animation = [UILabel new]; self.animation.text = @"Frame: 0"; self.animation.accessibilityIdentifier = @"fixture.animation"; [self.animation.heightAnchor constraintEqualToConstant:80].active = YES; [stack addArrangedSubview:self.animation];
    self.barcode = [[CapacityBarcode alloc] initWithFrame:CGRectMake(0,45,320,32)];
    [self.animation addSubview:self.barcode];
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(frame)];
    self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(60,60,60);
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [self save];
}
- (UITextField *)field:(NSString *)placeholder identifier:(NSString *)identifier secure:(BOOL)secure {
    UITextField *field = [UITextField new]; field.placeholder = placeholder; field.accessibilityIdentifier = identifier; field.secureTextEntry = secure;
    field.delegate = self;
    field.borderStyle = UITextBorderStyleRoundedRect; field.autocorrectionType = UITextAutocorrectionTypeNo;
    [field.heightAnchor constraintEqualToConstant:44].active = YES;
    [field addTarget:self action:@selector(changed:) forControlEvents:UIControlEventEditingChanged];
    [field addTarget:self action:@selector(focusChanged:) forControlEvents:UIControlEventEditingDidBegin | UIControlEventEditingDidEnd];
    return field;
}
- (void)tap { self.taps++; self.barcode.tapNumber = (uint8_t)self.taps; [self.barcode setNeedsDisplay]; self.counter.text = [NSString stringWithFormat:@"Taps: %lu", self.taps]; self.view.backgroundColor = self.taps%2 ? UIColor.systemYellowColor : UIColor.whiteColor; [self save]; }
- (void)changed:(id)sender { [self save]; }
- (void)focusChanged:(UIView *)sender {
    self.focusChanges++;
    saveInputEvent(@{@"kind":@"focus", @"at":@(NSProcessInfo.processInfo.systemUptime),
        @"identifier":sender.accessibilityIdentifier ?: @"", @"firstResponder":@(sender.isFirstResponder)});
    [self save];
}
- (void)textViewDidBeginEditing:(UITextView *)textView { [self focusChanged:textView]; }
- (void)textViewDidEndEditing:(UITextView *)textView { [self focusChanged:textView]; }
- (void)textViewDidChange:(UITextView *)textView { [self save]; }
- (void)textFieldDidChangeSelection:(UITextField *)textField { [self save]; }
- (void)textViewDidChangeSelection:(UITextView *)textView { [self save]; }
- (void)userContentController:(WKUserContentController *)controller didReceiveScriptMessage:(WKScriptMessage *)message {
    self.webState = message.body; self.webText = self.webState[@"value"];
    saveInputEvent(@{@"kind":@"web", @"at":@(NSProcessInfo.processInfo.systemUptime), @"launchID":self.launchID, @"state":self.webState});
    [self save];
}
- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    self.webNavigationFinished = YES;
    saveInputEvent(@{@"kind":@"web-navigation-finished", @"at":@(NSProcessInfo.processInfo.systemUptime), @"launchID":self.launchID});
    [self save];
}
- (void)frame { self.frames++; self.barcode.frameNumber = (uint16_t)self.frames; [self.barcode setNeedsDisplay]; self.animation.text = [NSString stringWithFormat:@"Frame: %lu", self.frames]; self.animation.backgroundColor = self.frames%2 ? UIColor.systemRedColor : UIColor.systemBlueColor; }
- (void)save {
    if (!self.plain || !self.secure || !self.multiline) return;
    CGRect webFrame = [self.web convertRect:self.web.bounds toView:self.view];
    NSMutableDictionary *selections = [NSMutableDictionary new];
    NSMutableDictionary *markedRanges = [NSMutableDictionary new];
    for (UIView<UITextInput> *field in @[self.plain, self.secure, self.multiline]) {
        UITextRange *range = field.selectedTextRange;
        if (range) selections[field.accessibilityIdentifier] = @{
            @"start":@([field offsetFromPosition:field.beginningOfDocument toPosition:range.start]),
            @"end":@([field offsetFromPosition:field.beginningOfDocument toPosition:range.end])};
        UITextRange *marked = field.markedTextRange;
        if (marked) markedRanges[field.accessibilityIdentifier] = @{
            @"start":@([field offsetFromPosition:field.beginningOfDocument toPosition:marked.start]),
            @"end":@([field offsetFromPosition:field.beginningOfDocument toPosition:marked.end])};
    }
    NSDictionary *state = @{@"taps":@(self.taps), @"plain":self.plain.text ?: @"", @"secure":self.secure.text ?: @"", @"multiline":self.multiline.text ?: @"", @"web":self.webText,
        @"selections":selections,
        @"markedRanges":markedRanges, @"webState":self.webState, @"webNavigationFinished":@(self.webNavigationFinished),
        @"webFrame":@{@"x":@(webFrame.origin.x), @"y":@(webFrame.origin.y),
            @"width":@(webFrame.size.width), @"height":@(webFrame.size.height)}, @"launchID":self.launchID,
        @"inputDownAt":@(inputDownAt),@"inputUpAt":@(inputUpAt),
        @"firstResponder":self.plain.isFirstResponder ? @"fixture.plain" : self.secure.isFirstResponder ? @"fixture.secure" : self.multiline.isFirstResponder ? @"fixture.multiline" : @"",
        @"focusChanges":@(self.focusChanges), @"sceneActivation":@(self.view.window.windowScene.activationState)};
    NSData *data = [NSJSONSerialization dataWithJSONObject:state options:0 error:nil];
    NSURL *directory = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    [data writeToURL:[directory URLByAppendingPathComponent:@"state.json"] atomically:YES];
}
@end

@interface FixtureScene : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation FixtureScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene]; self.window.rootViewController = [SimulatorFixture new]; [self.window makeKeyAndVisible];
}
@end
@interface FixtureApp : UIResponder <UIApplicationDelegate>
@end
@implementation FixtureApp
@end
int main(int argc, char *argv[]) { @autoreleasepool { return UIApplicationMain(argc, argv, NSStringFromClass(CapacityApplication.class), NSStringFromClass(FixtureApp.class)); } }
