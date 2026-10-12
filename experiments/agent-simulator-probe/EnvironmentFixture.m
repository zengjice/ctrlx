#import <UIKit/UIKit.h>
#import <CoreLocation/CoreLocation.h>
#import <UserNotifications/UserNotifications.h>
#import <os/log.h>

@interface EnvironmentFixture : UIViewController <CLLocationManagerDelegate>
@property(nonatomic, strong) CLLocationManager *manager;
@property(nonatomic, strong) UILabel *status;
@property(nonatomic, strong) NSMutableDictionary *state;
- (void)save;
- (void)recordPush:(NSDictionary *)payload;
- (void)recordURL:(NSURL *)url;
@end

static __weak EnvironmentFixture *activeFixture;

@implementation EnvironmentFixture
- (void)viewDidLoad {
    [super viewDidLoad];
    activeFixture = self;
    self.view.backgroundColor = UIColor.systemBackgroundColor;
    self.state = [@{@"launchID":NSUUID.UUID.UUIDString, @"latitude":NSNull.null, @"longitude":NSNull.null,
                   @"locationStatus":@0, @"locationUpdates":@0, @"locationErrors":@0, @"pushDeliveryCount":@0, @"pushCallbacks":@0,
                   @"pushToken":@"", @"url":@""} mutableCopy];
    UIStackView *stack = [UIStackView new];
    stack.axis = UILayoutConstraintAxisVertical;
    stack.spacing = 18;
    stack.translatesAutoresizingMaskIntoConstraints = NO;
    [self.view addSubview:stack];
    [NSLayoutConstraint activateConstraints:@[
        [stack.topAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.topAnchor constant:20],
        [stack.leadingAnchor constraintEqualToAnchor:self.view.leadingAnchor constant:24],
        [stack.trailingAnchor constraintEqualToAnchor:self.view.trailingAnchor constant:-24]]];
    self.status = [UILabel new];
    self.status.numberOfLines = 0;
    self.status.accessibilityIdentifier = @"environment.status";
    [stack addArrangedSubview:self.status];
    for (NSArray *item in @[@[@"Request location", @"environment.location", @"requestLocation"],
                            @[@"Request notifications", @"environment.notifications", @"requestNotifications"],
                            @[@"Write diagnostic log", @"environment.log", @"writeDiagnosticLog"],
                            @[@"Crash test app", @"environment.crash", @"crashTestApp"]]) {
        UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
        [button setTitle:item[0] forState:UIControlStateNormal];
        button.accessibilityIdentifier = item[1];
        [button addTarget:self action:NSSelectorFromString(item[2]) forControlEvents:UIControlEventTouchUpInside];
        [stack addArrangedSubview:button];
    }
    [self registerForTraitChanges:@[UITraitUserInterfaceStyle.class] withHandler:^(__kindof id<UITraitEnvironment> environment, UITraitCollection *previous) {
        [(EnvironmentFixture *)environment save];
    }];
    self.manager = [CLLocationManager new];
    self.manager.delegate = self;
    self.manager.desiredAccuracy = kCLLocationAccuracyBest;
    [self save];
}
- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [self save];
}
- (void)writeDiagnosticLog {
    NSString *token = NSUUID.UUID.UUIDString;
    self.state[@"logToken"] = token;
    os_log_with_type(os_log_create("com.jicezeng.ctrlx.environment-fixture", "fixture"), OS_LOG_TYPE_DEFAULT,
                     "CtrlX environment fixture token=%{public}@ 测试 🙂", token);
    [self save];
}
- (void)crashTestApp { abort(); }
- (void)requestLocation { [self.manager requestWhenInUseAuthorization]; }
- (void)requestNotifications {
    [UNUserNotificationCenter.currentNotificationCenter requestAuthorizationWithOptions:UNAuthorizationOptionAlert | UNAuthorizationOptionBadge | UNAuthorizationOptionSound
        completionHandler:^(BOOL granted, NSError *error) {
            [NSOperationQueue.mainQueue addOperationWithBlock:^{
                self.state[@"notificationsGranted"] = @(granted);
                self.state[@"notificationError"] = error.localizedDescription ?: @"";
                [self save];
            }];
        }];
}
- (void)locationManagerDidChangeAuthorization:(CLLocationManager *)manager {
    self.state[@"locationStatus"] = @(manager.authorizationStatus);
    if (manager.authorizationStatus == kCLAuthorizationStatusAuthorizedAlways || manager.authorizationStatus == kCLAuthorizationStatusAuthorizedWhenInUse) {
        [manager startUpdatingLocation];
    } else {
        [manager stopUpdatingLocation];
        self.state[@"latitude"] = NSNull.null;
        self.state[@"longitude"] = NSNull.null;
    }
    [self save];
}
- (void)locationManager:(CLLocationManager *)manager didUpdateLocations:(NSArray<CLLocation *> *)locations {
    CLLocation *location = locations.lastObject;
    self.state[@"locationTimestamp"] = @(location.timestamp.timeIntervalSince1970);
    self.state[@"locationReceivedAt"] = @(NSDate.date.timeIntervalSince1970);
    self.state[@"locationSimulated"] = @(location.sourceInformation.isSimulatedBySoftware);
    self.state[@"latitude"] = @(location.coordinate.latitude);
    self.state[@"longitude"] = @(location.coordinate.longitude);
    self.state[@"locationUpdates"] = @([self.state[@"locationUpdates"] integerValue] + 1);
    [self save];
}
- (void)locationManager:(CLLocationManager *)manager didFailWithError:(NSError *)error {
    self.state[@"locationErrors"] = @([self.state[@"locationErrors"] integerValue] + 1);
    self.state[@"locationErrorCode"] = @(error.code);
    self.state[@"locationErrorDomain"] = error.domain;
    self.state[@"locationErrorAt"] = @(NSDate.date.timeIntervalSince1970);
    self.state[@"locationError"] = error.localizedDescription;
    [self save];
}
- (void)recordPush:(NSDictionary *)payload {
    self.state[@"pushCallbacks"] = @([self.state[@"pushCallbacks"] integerValue] + 1);
    NSString *token = [payload[@"token"] isKindOfClass:NSString.class] ? payload[@"token"] : @"";
    if (![token isEqual:self.state[@"pushToken"]]) {
        self.state[@"pushDeliveryCount"] = @([self.state[@"pushDeliveryCount"] integerValue] + 1);
        self.state[@"pushToken"] = token;
    }
    self.state[@"pushPayload"] = payload;
    [self save];
}
- (void)recordURL:(NSURL *)url { self.state[@"url"] = url.absoluteString ?: @""; [self save]; }
- (void)save {
    if (!self.state) return;
    self.state[@"appearance"] = self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark ? @"dark" : @"light";
    self.state[@"savedAt"] = @(NSProcessInfo.processInfo.systemUptime);
    self.status.text = [NSString stringWithFormat:@"Appearance: %@\nLocation permission: %@\nLocation: %@, %@\nPush: %@\nURL: %@",
        self.state[@"appearance"], self.state[@"locationStatus"], self.state[@"latitude"], self.state[@"longitude"],
        self.state[@"pushToken"], self.state[@"url"]];
    NSError *error = nil;
    NSData *data = [NSJSONSerialization dataWithJSONObject:self.state options:NSJSONWritingSortedKeys error:&error];
    NSURL *directory = [NSFileManager.defaultManager URLsForDirectory:NSDocumentDirectory inDomains:NSUserDomainMask].firstObject;
    if (!data || ![data writeToURL:[directory URLByAppendingPathComponent:@"environment-state.json"] options:NSDataWritingAtomic error:&error]) {
        NSLog(@"Environment fixture could not save: %@", error);
    }
}
@end

@interface EnvironmentApp : NSObject <UIApplicationDelegate, UNUserNotificationCenterDelegate>
@end
@implementation EnvironmentApp
- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)options {
    UNUserNotificationCenter.currentNotificationCenter.delegate = self;
    return YES;
}
- (void)userNotificationCenter:(UNUserNotificationCenter *)center willPresentNotification:(UNNotification *)notification
        withCompletionHandler:(void (^)(UNNotificationPresentationOptions))completion {
    [NSOperationQueue.mainQueue addOperationWithBlock:^{ [activeFixture recordPush:notification.request.content.userInfo]; }];
    completion(UNNotificationPresentationOptionNone);
}
- (void)application:(UIApplication *)application didReceiveRemoteNotification:(NSDictionary *)userInfo
        fetchCompletionHandler:(void (^)(UIBackgroundFetchResult))completion {
    [activeFixture recordPush:userInfo];
    completion(UIBackgroundFetchResultNewData);
}
@end

@interface EnvironmentScene : UIResponder <UIWindowSceneDelegate>
@property(nonatomic, strong) UIWindow *window;
@end
@implementation EnvironmentScene
- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)options {
    self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *)scene];
    self.window.rootViewController = [EnvironmentFixture new];
    [self.window makeKeyAndVisible];
    for (UIOpenURLContext *context in options.URLContexts) [activeFixture recordURL:context.URL];
}
- (void)scene:(UIScene *)scene openURLContexts:(NSSet<UIOpenURLContext *> *)contexts {
    for (UIOpenURLContext *context in contexts) [activeFixture recordURL:context.URL];
}
@end

int main(int argc, char **argv) {
    @autoreleasepool { return UIApplicationMain(argc, argv, nil, NSStringFromClass(EnvironmentApp.class)); }
}
