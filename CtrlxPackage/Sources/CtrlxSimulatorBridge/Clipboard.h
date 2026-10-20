#import <AppKit/AppKit.h>
#import <objc/message.h>
#import <objc/runtime.h>

// Declare the initializer so ARC honors its consumed receiver and retained result.
@protocol CXSimulatorPasteboardConnection
- (instancetype)initWithConnectingToPort:(mach_port_t)port managingPasteboard:(NSPasteboard *)board delegate:(id)delegate delegateQueue:(dispatch_queue_t)queue;
- (void)push;
- (void)pull;
@end

// One explicit transfer uses a private named pasteboard. Autosync is never enabled.
@interface CXSimulatorClipboardTransfer : NSObject
@property(nonatomic, strong) NSCondition *condition;
@property(nonatomic) BOOL active;
@property(nonatomic) BOOL received;
@property(nonatomic, strong) NSError *failure;
@property(nonatomic, strong) NSString *revision;
@end

@implementation CXSimulatorClipboardTransfer
- (instancetype)init {
    if ((self = [super init])) _condition = [NSCondition new];
    return self;
}
- (void)simPasteboardDidBecomeActive:(id)sender {
    [self.condition lock]; self.active = YES; [self.condition broadcast]; [self.condition unlock];
}
- (void)simPasteboardDidLoseConnection:(id)sender {
    [self.condition lock];
    self.failure = [NSError errorWithDomain:@"CtrlXSimulator" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Simulator clipboard disconnected"}];
    [self.condition broadcast]; [self.condition unlock];
}
- (BOOL)simPasteboardShouldApplySnapshot:(id)sender fromHost:(NSUUID *)host generation:(NSInteger)generation toPasteboard:(NSPasteboard *)board { return YES; }
- (void)simPasteboardDidApplySnapshot:(id)sender fromHost:(NSUUID *)host incomingGeneration:(NSInteger)generation toPasteboard:(NSPasteboard *)board atGeneration:(NSInteger)local {
    [self.condition lock]; self.received = YES;
    self.revision = [NSString stringWithFormat:@"%@:%ld",host.UUIDString,(long)generation];
    [self.condition broadcast]; [self.condition unlock];
}
- (void)simPasteboardErrorApplyingSnapshot:(id)sender fromHost:(NSUUID *)host generation:(NSInteger)generation error:(NSError *)error toPasteboard:(NSPasteboard *)board {
    [self.condition lock]; self.failure = error; [self.condition broadcast]; [self.condition unlock];
}
- (void)simPasteboardDidChangeAutoNotifyState:(id)sender forPasteboard:(NSPasteboard *)board toStatus:(BOOL)status {}
- (BOOL)waitForSnapshot:(BOOL)snapshot deadline:(NSDate *)deadline error:(NSError **)error {
    [self.condition lock];
    while (!self.failure && !(snapshot ? self.received : self.active) && [self.condition waitUntilDate:deadline]) {}
    BOOL success = !self.failure && (snapshot ? self.received : self.active);
    if (!success && error) *error = self.failure ?: [NSError errorWithDomain:@"CtrlXSimulator" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Simulator clipboard timed out"}];
    [self.condition unlock];
    return success;
}
@end

static NSDictionary *CXSimulatorClipboardUntil(id device, NSDictionary *content, NSDictionary *expected, BOOL revisionOnly, NSString *afterRevision, NSDate *deadline, NSError **error) {
    if (deadline.timeIntervalSinceNow <= 0) {
        if (error) *error = [NSError errorWithDomain:@"CtrlXSimulator" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Simulator clipboard timed out"}];
        return nil;
    }
    Class listener = NSClassFromString(@"SimPasteboardPlus.SimPasteboardInterfaceListener");
    Class connector = NSClassFromString(@"SimPasteboardPlus.SimPasteboardInterface");
    SEL initializer = NSSelectorFromString(@"initWithConnectingToPort:managingPasteboard:delegate:delegateQueue:");
    if (!listener || !connector || ![connector instancesRespondToSelector:initializer]) {
        if (error) *error = [NSError errorWithDomain:@"CtrlXSimulator" code:1 userInfo:@{NSLocalizedDescriptionKey:@"This Xcode does not support simulator clipboard transfer"}];
        return nil;
    }
    Protocol *protocol = NSProtocolFromString(@"_TtP17SimPasteboardPlus21SimPasteboardDelegate_");
    if (protocol) class_addProtocol(CXSimulatorClipboardTransfer.class, protocol);
    NSString *service = ((id (*)(id,SEL))objc_msgSend)(listener,NSSelectorFromString(@"machServiceName"));
    mach_port_t port = ((mach_port_t (*)(id,SEL,id,NSError **))objc_msgSend)(device,NSSelectorFromString(@"lookup:error:"),service,error);
    if (!port) return nil;
    NSPasteboard *board = [NSPasteboard pasteboardWithUniqueName];
    CXSimulatorClipboardTransfer *delegate = [CXSimulatorClipboardTransfer new];
    // The framework owns callback scheduling; CtrlX worker requests remain serialized.
    __attribute__((objc_precise_lifetime)) id<CXSimulatorPasteboardConnection> connection = [(id<CXSimulatorPasteboardConnection>)[connector alloc]
        initWithConnectingToPort:port managingPasteboard:board delegate:delegate
        delegateQueue:dispatch_get_global_queue(QOS_CLASS_USER_INITIATED,0)];
    NSDictionary *result = nil;
    do {
        if (!connection || ![delegate waitForSnapshot:NO deadline:deadline error:error]) break;
        [connection pull];
        if (![delegate waitForSnapshot:YES deadline:deadline error:error]) break;
        if (content) {
            NSString *kind = content[@"kind"];
            NSData *data = [content[@"data"] isKindOfClass:NSString.class] ? [[NSData alloc] initWithBase64EncodedString:content[@"data"] options:0] : nil;
            NSString *type = @{@"text":NSPasteboardTypeString,@"png":NSPasteboardTypePNG,@"jpeg":@"public.jpeg"}[kind];
            if (!type || !data.length || data.length > 384*1024) {
                if (error) *error = [NSError errorWithDomain:@"CtrlXSimulator" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Invalid simulator clipboard content"}];
                break;
            }
            [board clearContents];
            [board setData:data forType:type];
            [connection push];
            // Push is asynchronous; independent readers can still see the old snapshot.
            // Keep the writer alive and retry only observation within the original deadline.
            while (deadline.timeIntervalSinceNow > 0) {
                NSDictionary *observed = CXSimulatorClipboardUntil(device, nil, content, NO, nil, deadline, error);
                if (!observed) break;
                if ([observed[@"matches"] boolValue]) { result = @{}; break; }
                NSTimeInterval remaining = deadline.timeIntervalSinceNow;
                if (remaining > 0) [NSThread sleepForTimeInterval:MIN(0.02, remaining)];
            }
            if (!result && error && !*error) *error = [NSError errorWithDomain:@"CtrlXSimulator" code:1 userInfo:@{NSLocalizedDescriptionKey:@"The simulator did not acknowledge the clipboard contents before timeout"}];
            break;
        }
        if (expected) {
            NSString *type = @{@"text":NSPasteboardTypeString,@"png":NSPasteboardTypePNG,@"jpeg":@"public.jpeg"}[expected[@"kind"]];
            NSData *wanted = [[NSData alloc] initWithBase64EncodedString:expected[@"data"] options:0];
            result = @{@"matches":@([[board dataForType:type] isEqualToData:wanted])};
            break;
        }
        // A copy baseline and unchanged polls must not serialize or size-check old content.
        if (revisionOnly || [delegate.revision isEqualToString:afterRevision]) {
            result = @{@"revision":delegate.revision ?: @""};
            break;
        }
        NSString *kind = nil;
        NSData *data = nil;
        for (NSString *candidate in @[@"png",@"jpeg",@"text"]) {
            NSString *type = @{@"text":NSPasteboardTypeString,@"png":NSPasteboardTypePNG,@"jpeg":@"public.jpeg"}[candidate];
            data = [board dataForType:type];
            if (data.length) { kind = candidate; break; }
        }
        if (data.length > 384*1024) {
            if (error) *error = [NSError errorWithDomain:@"CtrlXSimulator" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Simulator clipboard exceeds 384 KiB"}];
            break;
        }
        result = @{@"revision":delegate.revision ?: @"", @"content":data.length ? @{@"kind":kind,@"data":[data base64EncodedStringWithOptions:0]} : NSNull.null};
    } while (NO);
    connection = nil;
    [board releaseGlobally];
    return result;
}

static NSDictionary *CXSimulatorClipboard(id device, NSDictionary *content, BOOL revisionOnly, NSString *afterRevision, NSError **error) {
    return CXSimulatorClipboardUntil(device, content, nil, revisionOnly, afterRevision, [NSDate dateWithTimeIntervalSinceNow:5], error);
}
