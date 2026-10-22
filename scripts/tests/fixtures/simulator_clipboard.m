#import "Clipboard.h"

static NSDictionary *deviceContent;
static NSDictionary *pendingContent;
static NSTimeInterval visibleAt;
static NSTimeInterval writeDelay;
static NSUInteger pushes, readsAfterPush;
static BOOL disconnectReader;
static NSUUID *deviceHost;
static NSInteger deviceGeneration = 1;

@interface ClipboardTestDevice : NSObject
@end
@implementation ClipboardTestDevice
- (mach_port_t)lookup:(NSString *)name error:(NSError **)error { return 1; }
@end

@interface ClipboardTestListener : NSObject
@end
@implementation ClipboardTestListener
+ (NSString *)machServiceName { return @"clipboard-test"; }
@end

@interface ClipboardTestConnection : NSObject <CXSimulatorPasteboardConnection>
@property(nonatomic, strong) NSPasteboard *board;
@property(nonatomic, strong) CXSimulatorClipboardTransfer *delegate;
@end
@implementation ClipboardTestConnection
- (instancetype)initWithConnectingToPort:(mach_port_t)port managingPasteboard:(NSPasteboard *)board delegate:(id)delegate delegateQueue:(dispatch_queue_t)queue {
    if ((self = [super init])) {
        NSCAssert(![board.name isEqual:NSPasteboardNameGeneral], @"Never use the user's clipboard");
        self.board = board;
        self.delegate = delegate;
        [delegate simPasteboardDidBecomeActive:self];
    }
    return self;
}
- (void)push {
    pushes++;
    NSData *data = [self.board dataForType:NSPasteboardTypeString];
    pendingContent = @{@"kind":@"text", @"data":[data base64EncodedStringWithOptions:0]};
    visibleAt = NSProcessInfo.processInfo.systemUptime + writeDelay;
}
- (void)pull {
    if (pushes) {
        readsAfterPush++;
        if (disconnectReader) {
            [self.delegate simPasteboardDidLoseConnection:self];
            return;
        }
    }
    if (pendingContent && NSProcessInfo.processInfo.systemUptime >= visibleAt) deviceContent = pendingContent;
    [self.board clearContents];
    if (deviceContent) {
        NSString *type = [deviceContent[@"kind"] isEqual:@"png"] ? NSPasteboardTypePNG : NSPasteboardTypeString;
        [self.board setData:[[NSData alloc] initWithBase64EncodedString:deviceContent[@"data"] options:0] forType:type];
    }
    [self.delegate simPasteboardDidApplySnapshot:self fromHost:deviceHost incomingGeneration:deviceGeneration toPasteboard:self.board atGeneration:1];
}
@end

static int testCopy(NSString *kind, NSDictionary *selected) {
    NSMutableData *large = [NSMutableData dataWithLength:400 * 1024];
    memset(large.mutableBytes, 'x', large.length);
    NSDictionary *old = @{@"kind":kind, @"data":[large base64EncodedStringWithOptions:0]};
    deviceContent = old;
    ClipboardTestDevice *device = [ClipboardTestDevice new];
    NSError *error = nil;
    NSDictionary *baseline = CXSimulatorClipboard(device, nil, YES, nil, &error);
    NSString *revision = baseline[@"revision"];
    BOOL passed = revision.length > 0 && baseline[@"content"] == nil && error == nil;
    for (int i = 0; i < 3; i++) {
        NSDictionary *unchanged = CXSimulatorClipboard(device, nil, NO, revision, &error);
        passed &= [unchanged[@"revision"] isEqual:revision] && unchanged[@"content"] == nil && error == nil;
    }
    deviceContent = selected;
    deviceGeneration++;
    NSDictionary *copied = CXSimulatorClipboard(device, nil, NO, revision, &error);
    passed &= [copied[@"content"] isEqual:selected] && ![copied[@"revision"] isEqual:revision] && error == nil;
    deviceContent = old;
    deviceGeneration++;
    NSDictionary *oversized = CXSimulatorClipboard(device, nil, NO, copied[@"revision"], &error);
    passed &= oversized == nil && [error.localizedDescription containsString:@"exceeds 384 KiB"];
    error = nil;
    NSDictionary *direct = CXSimulatorClipboard(device, nil, NO, nil, &error);
    passed &= direct == nil && [error.localizedDescription containsString:@"exceeds 384 KiB"] && pushes == 0;
    printf("%s: copy-old-%s, unchanged polls=3, new content returned, new/direct oversized content rejected\n",
        passed ? "PASS" : "FAIL", kind.UTF8String);
    return passed ? 0 : 1;
}

int main(int argc, const char **argv) {
    @autoreleasepool {
        Class listener = objc_allocateClassPair(ClipboardTestListener.class, "SimPasteboardPlus.SimPasteboardInterfaceListener", 0);
        Class connector = objc_allocateClassPair(ClipboardTestConnection.class, "SimPasteboardPlus.SimPasteboardInterface", 0);
        objc_registerClassPair(listener);
        objc_registerClassPair(connector);
        deviceHost = [NSUUID UUID];
        NSString *scenario = @(argv[1]);
        NSDictionary *expected = @{@"kind":@"text", @"data":[[@"new clipboard 中文" dataUsingEncoding:NSUTF8StringEncoding] base64EncodedStringWithOptions:0]};
        if ([scenario isEqual:@"copy-old-text"]) return testCopy(@"text", expected);
        if ([scenario isEqual:@"copy-old-image"]) return testCopy(@"png", expected);
        writeDelay = 0.06;
        if ([scenario isEqual:@"old-text"]) deviceContent = @{@"kind":@"text", @"data":@"b2xk"};
        if ([scenario isEqual:@"large-old-image"]) {
            deviceContent = @{@"kind":@"png", @"data":[[NSMutableData dataWithLength:400 * 1024] base64EncodedStringWithOptions:0]};
        }
        BOOL timeout = [scenario isEqual:@"timeout"];
        if (timeout) writeDelay = 60;
        disconnectReader = [scenario isEqual:@"disconnect"];
        NSTimeInterval start = NSProcessInfo.processInfo.systemUptime;
        NSError *error = nil;
        NSDictionary *result = CXSimulatorClipboard([ClipboardTestDevice new], expected, NO, nil, &error);
        NSTimeInterval elapsed = NSProcessInfo.processInfo.systemUptime - start;
        BOOL passed = pushes == 1;
        if (timeout) {
            passed &= result == nil && error != nil && elapsed >= 4.8 && elapsed < 5.8 && readsAfterPush > 1;
        } else if (disconnectReader) {
            passed &= result == nil && [error.localizedDescription containsString:@"disconnected"] && elapsed < 1;
        } else {
            passed &= result != nil && error == nil && [deviceContent isEqual:expected] && elapsed >= writeDelay && elapsed < 2 && readsAfterPush > 1;
        }
        printf("%s: %s, writes=%lu reads=%lu elapsed=%.3f error=%s\n", passed ? "PASS" : "FAIL", scenario.UTF8String,
            (unsigned long)pushes, (unsigned long)readsAfterPush, elapsed, error.localizedDescription.UTF8String ?: "none");
        return passed ? 0 : 1;
    }
}
