#import <UIKit/UIKit.h>

static NSTimeInterval inputDownAt, inputUpAt;
@interface FixtureApplication : UIApplication
@end
@implementation FixtureApplication
- (void)sendEvent:(UIEvent *)event {
    for (UITouch *touch in event.allTouches) {
        if (touch.phase == UITouchPhaseBegan) inputDownAt = touch.timestamp;
        if (touch.phase == UITouchPhaseEnded) inputUpAt = touch.timestamp;
    }
    [super sendEvent:event];
}
@end

@interface FixtureBarcode : UIView
@property(nonatomic) uint16_t frameNumber;
@property(nonatomic) uint8_t tapNumber;
@end
@implementation FixtureBarcode
- (void)drawRect:(CGRect)rect {
    uint32_t value = self.frameNumber | ((uint32_t)self.tapNumber << 16);
    uint8_t check = (uint8_t)(value ^ (value >> 8) ^ (value >> 16) ^ 0xA5);
    value |= (uint32_t)check << 24;
    CGFloat cell = self.bounds.size.width / 36;
    for (NSUInteger i = 0; i < 36; i++) {
        UIColor *color = i == 0 ? UIColor.magentaColor : i == 1 ? UIColor.cyanColor : i == 2 ? UIColor.yellowColor : i == 35 ? UIColor.greenColor :
            ((value >> (i - 3)) & 1) ? UIColor.whiteColor : UIColor.blackColor;
        [color setFill]; UIRectFill(CGRectMake(i * cell, 0, cell + 0.1, self.bounds.size.height));
    }
}
@end

@interface InteractionFixture : UIViewController <UIGestureRecognizerDelegate>
@property(nonatomic, strong) UILabel *status;
@property(nonatomic, strong) UILabel *dragTarget;
@property(nonatomic, strong) UILabel *loading;
@property(nonatomic, strong) UILabel *ready;
@property(nonatomic, strong) UIButton *moving;
@property(nonatomic, strong) FixtureBarcode *barcode;
@property(nonatomic, strong) CADisplayLink *displayLink;
@property(nonatomic) NSUInteger presses;
@property(nonatomic) NSUInteger taps;
@property(nonatomic) NSUInteger drags;
@property(nonatomic) CGPoint dragEnd;
@end
@implementation InteractionFixture
- (UIInterfaceOrientationMask)supportedInterfaceOrientations { return UIInterfaceOrientationMaskAll; }
- (BOOL)shouldAutorotate { return YES; }
- (UIButton *)button:(NSString *)title identifier:(NSString *)identifier y:(CGFloat)y action:(SEL)action {
    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    [button setTitle:title forState:UIControlStateNormal]; button.accessibilityIdentifier = identifier;
    button.frame = CGRectMake(24, y, 280, 36); [button addTarget:self action:action forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:button]; return button;
}
- (UILabel *)label:(NSString *)text identifier:(NSString *)identifier y:(CGFloat)y {
    UILabel *label = [UILabel new]; label.frame = CGRectMake(24, y, 320, 30); label.text = text;
    label.accessibilityIdentifier = identifier; [self.view addSubview:label]; return label;
}
- (void)viewDidLoad {
    [super viewDidLoad]; self.view.backgroundColor = UIColor.whiteColor;
    [self label:@"CtrlX Interaction Fixture" identifier:@"fixture.title" y:64];
    [self button:@"Tap counter" identifier:@"fixture.tap" y:100 action:@selector(tap)];
    self.status = [self label:@"Taps: 0; Presses: 0; Drags: 0" identifier:@"fixture.counter" y:140];
    self.dragTarget = [self label:@"Hold or drag me" identifier:@"fixture.gesture" y:185];
    self.dragTarget.frame = CGRectMake(24,185,200,64); self.dragTarget.backgroundColor = UIColor.orangeColor;
    self.dragTarget.userInteractionEnabled = YES;
    UILongPressGestureRecognizer *hold = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(hold:)];
    hold.minimumPressDuration = 0.35; hold.delegate = self; [self.dragTarget addGestureRecognizer:hold];
    UIPanGestureRecognizer *pan = [[UIPanGestureRecognizer alloc] initWithTarget:self action:@selector(pan:)];
    pan.delegate = self;
    [self.dragTarget addGestureRecognizer:pan];
    [self button:@"Start delayed state" identifier:@"fixture.begin" y:265 action:@selector(begin)];
    self.loading = [self label:@"Loading" identifier:@"fixture.loading" y:305]; self.loading.hidden = YES;
    self.ready = [self label:@"Ready" identifier:@"fixture.ready" y:305]; self.ready.hidden = YES;
    [self button:@"Ambiguous A" identifier:@"fixture.ambiguous" y:350 action:@selector(tap)];
    [self button:@"Ambiguous B" identifier:@"fixture.ambiguous" y:390 action:@selector(tap)];
    [self button:@"Arm target move" identifier:@"fixture.arm-move" y:430 action:@selector(armMove)];
    self.moving = [self button:@"Before move" identifier:@"fixture.moving" y:470 action:@selector(tap)];
    self.barcode = [[FixtureBarcode alloc] initWithFrame:CGRectMake(24,530,320,48)];
    self.barcode.accessibilityIdentifier = @"fixture.barcode"; self.barcode.isAccessibilityElement = YES;
    [self.view addSubview:self.barcode];
    self.displayLink = [CADisplayLink displayLinkWithTarget:self selector:@selector(frame)];
    self.displayLink.preferredFrameRateRange = CAFrameRateRangeMake(60,60,60);
    [self.displayLink addToRunLoop:NSRunLoop.mainRunLoop forMode:NSRunLoopCommonModes];
    [self save];
}
- (void)tap { self.taps++; self.barcode.tapNumber = (uint8_t)self.taps; [self.barcode setNeedsDisplay]; [self updateStatus]; }
- (BOOL)gestureRecognizer:(UIGestureRecognizer *)first shouldRecognizeSimultaneouslyWithGestureRecognizer:(UIGestureRecognizer *)second { return YES; }
- (void)hold:(UILongPressGestureRecognizer *)gesture {
    if (gesture.state == UIGestureRecognizerStateBegan) { self.presses++; [self updateStatus]; }
}
- (void)pan:(UIPanGestureRecognizer *)gesture {
    // Pan translation starts after UIKit's recognition threshold; inspect the actual finger location.
    self.dragTarget.center = [gesture locationInView:self.view];
    if (gesture.state == UIGestureRecognizerStateEnded) {
        self.dragEnd = [gesture locationInView:self.view]; self.drags++; [self updateStatus];
    }
}
- (void)begin {
    self.ready.hidden = YES; self.loading.hidden = NO;
    [NSTimer scheduledTimerWithTimeInterval:0.8 repeats:NO block:^(NSTimer *timer) {
        self.loading.hidden = YES; self.ready.hidden = NO; [self save];
    }];
}
- (void)armMove {
    self.moving.frame = CGRectMake(24,470,120,36); [self.moving setTitle:@"Before move" forState:UIControlStateNormal];
    [NSTimer scheduledTimerWithTimeInterval:0.8 repeats:NO block:^(NSTimer *timer) {
        self.moving.frame = CGRectMake(200,470,120,36); [self.moving setTitle:@"After move" forState:UIControlStateNormal];
    }];
}
- (void)frame { self.barcode.frameNumber++; [self.barcode setNeedsDisplay]; }
- (void)updateStatus {
    self.status.text = [NSString stringWithFormat:@"Taps: %lu; Presses: %lu; Drags: %lu", self.taps,self.presses,self.drags];
    [self save];
}
- (void)save {
    NSDictionary *value = @{@"taps":@(self.taps),@"presses":@(self.presses),@"drags":@(self.drags),
        @"dragX":@(self.dragTarget.center.x),@"dragY":@(self.dragTarget.center.y),
        @"dragEndX":@(self.dragEnd.x),@"dragEndY":@(self.dragEnd.y),@"ready":@(!self.ready.hidden),
        @"inputDownAt":@(inputDownAt),@"inputUpAt":@(inputUpAt),
        @"interfaceOrientation":@(self.view.window.windowScene.interfaceOrientation),
        @"deviceOrientation":@(UIDevice.currentDevice.orientation)};
    NSData *data = [NSJSONSerialization dataWithJSONObject:value options:0 error:nil];
    NSURL *directory = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    [data writeToURL:[directory URLByAppendingPathComponent:@"state.json"] atomically:YES];
}
@end

@interface InteractionScene : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation InteractionScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [InteractionFixture new]; [self.window makeKeyAndVisible];
}
@end
@interface InteractionApp : UIResponder <UIApplicationDelegate>
@end
@implementation InteractionApp
@end
int main(int argc, char *argv[]) { @autoreleasepool { return UIApplicationMain(argc,argv,NSStringFromClass(FixtureApplication.class),NSStringFromClass(InteractionApp.class)); } }
