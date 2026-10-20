#import "CtrlxSimulatorBridge.h"
#import "Input.h"
#import <xpc/xpc.h>
#include <stdatomic.h>

@interface CXSimulatorFrame ()
- (instancetype)initWithObject:(xpc_object_t)object connection:(xpc_connection_t)connection;
@end

@implementation CXSimulatorFrame {
    IOSurfaceRef _surface;
    NSDictionary *_metadata;
    NSData *_metadataJSON;
    NSDictionary *_deliveryTiming;
    xpc_connection_t _connection;
    uint64_t _sequence;
    atomic_bool _finished;
}
- (instancetype)initWithObject:(xpc_object_t)object connection:(xpc_connection_t)connection {
    double sentAt = xpc_dictionary_get_double(object, "frameSendingAt");
    double receivedAt = sentAt > 0 ? NSProcessInfo.processInfo.systemUptime : 0;
    self = [super init];
    if (!self) return nil;
    xpc_object_t surface = xpc_dictionary_get_value(object, "surface");
    if (!surface) return nil;
    _surface = IOSurfaceLookupFromXPCObject(surface);
    if (!_surface) return nil;
    _connection = connection;
    _sequence = xpc_dictionary_get_uint64(object, "sequence");
    size_t length = 0;
    const void *bytes = xpc_dictionary_get_data(object, "metadata", &length);
    if (!bytes || length > 65536) return nil;
    _metadataJSON = [NSData dataWithBytes:bytes length:length];
    _metadata = [NSJSONSerialization JSONObjectWithData:_metadataJSON options:0 error:nil];
    if (![_metadata isKindOfClass:NSDictionary.class]) return nil;
    if (sentAt > 0) {
        _deliveryTiming = @{@"workerSendingAt": @(sentAt), @"clientReceivedAt": @(receivedAt),
                            @"clientDecodedAt": @(NSProcessInfo.processInfo.systemUptime)};
    }
    return self;
}
- (IOSurfaceRef)surface { return _surface; }
- (NSDictionary *)metadata { return _metadata; }
- (NSData *)metadataJSON { return _metadataJSON; }
- (NSDictionary *)deliveryTiming { return _deliveryTiming; }
- (void)finish {
    if (atomic_exchange(&_finished, true) || !_connection) return;
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(message, "release", _sequence);
    xpc_connection_send_message(_connection, message);
}
- (void)dealloc {
    [self finish];
    if (_surface) CFRelease(_surface);
}
@end

@implementation CXSimulatorConnection {
    xpc_connection_t _connection;
    CXSimulatorFrameHandler _frameHandler;
    CXSimulatorErrorHandler _errorHandler;
    CXSimulatorInput *_input;
    NSLock *_inputLock;
    atomic_bool _invalid;
}
- (void)requestData:(NSData *)data reply:(CXSimulatorDataReply)reply {
    double enteredAt = NSProcessInfo.processInfo.systemUptime;
    NSError *error = nil;
    NSDictionary *request = data.length <= 65536 ? [NSJSONSerialization JSONObjectWithData:data options:0 error:&error] : nil;
    if (![request isKindOfClass:NSDictionary.class]) {
        reply(nil, error ?: [NSError errorWithDomain:@"CtrlXSimulator" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Request must be a JSON object within 64 KB"}]); return;
    }
    [self request:request reply:^(NSDictionary *result, NSError *failure) {
        NSError *encodingError = nil;
        if (result && [request[@"inputDiagnostics"] boolValue]) {
            NSMutableDictionary *diagnostic = result.mutableCopy;
            diagnostic[@"clientEnteredAt"] = @(enteredAt);
            result = diagnostic;
        }
        if (result && [request[@"screenshotDiagnostics"] boolValue]) {
            NSMutableDictionary *timing = [result[@"geometry"][@"screenshotTiming"] mutableCopy];
            if (timing) {
                timing[@"bridgeEnteredAt"] = @(enteredAt);
                timing[@"bridgeEncodingStartedAt"] = @(NSProcessInfo.processInfo.systemUptime);
                NSMutableDictionary *geometry = [result[@"geometry"] mutableCopy];
                geometry[@"screenshotTiming"] = timing;
                NSMutableDictionary *timed = result.mutableCopy;
                timed[@"geometry"] = geometry;
                result = timed;
            }
        }
        NSData *encoded = result ? [NSJSONSerialization dataWithJSONObject:result options:0 error:&encodingError] : nil;
        reply(encoded, failure ?: encodingError);
    }];
}
- (instancetype)initWithServiceName:(NSString *)serviceName frameHandler:(CXSimulatorFrameHandler)frameHandler errorHandler:(CXSimulatorErrorHandler)errorHandler {
    self = [super init];
    if (!self) return nil;
    _frameHandler = [frameHandler copy];
    _errorHandler = [errorHandler copy];
    _inputLock = [NSLock new];
    _connection = xpc_connection_create_mach_service(serviceName.UTF8String, NULL, 0);
    __weak CXSimulatorConnection *weakSelf = self;
    xpc_connection_set_event_handler(_connection, ^(xpc_object_t object) {
        CXSimulatorConnection *strongSelf = weakSelf;
        if (!strongSelf) return;
        if (xpc_get_type(object) == XPC_TYPE_ERROR) {
            [strongSelf fail:@"Simulator helper disconnected. Close and reopen this device; pending action outcomes are unknown"];
            return;
        }
        if (xpc_get_type(object) != XPC_TYPE_DICTIONARY) return;
        if (xpc_dictionary_get_value(object, "surface")) {
            CXSimulatorFrame *frame = [[CXSimulatorFrame alloc] initWithObject:object connection:strongSelf->_connection];
            if (frame) strongSelf->_frameHandler(frame);
        }
    });
    xpc_connection_resume(_connection);
    return self;
}
- (void)request:(NSDictionary *)request reply:(CXSimulatorReply)reply {
    NSError *error = nil;
    NSString *command = request[@"command"];
    BOOL cancel = [command isEqual:@"cancel"];
    NSMutableDictionary *controlRequest = request.mutableCopy;
    if (cancel) controlRequest[@"command"] = @"cancel-rotation";
    NSData *data = [NSJSONSerialization dataWithJSONObject:controlRequest options:0 error:&error];
    if (atomic_load(&_invalid) || !data || data.length > 768 * 1024) {
        reply(nil, error ?: [NSError errorWithDomain:@"CtrlXSimulator" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Simulator connection is closed or request exceeds 768 KiB"}]); return;
    }
    CXSimulatorInput *input = [self connectedInput];
    if ([command isEqual:@"touch"] || [command isEqual:@"release-touch"]
        || [command isEqual:@"key"] || [command isEqual:@"button"]) {
        if (!input) { reply(nil, [NSError errorWithDomain:@"CtrlXSimulator" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Simulator input is not connected"}]); return; }
        [input request:request reply:reply]; return;
    }
    if (cancel && !input) {
        reply(nil, [NSError errorWithDomain:@"CtrlXSimulator" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Simulator input is not connected"}]); return;
    }
    xpc_object_t object = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_data(object, "request", data.bytes, data.length);
    NSLock *completionLock = [NSLock new];
    __block BOOL completed = NO;
    __block NSTimer *deadlineTimer = nil;
    BOOL (^finish)(NSDictionary *, NSError *) = ^BOOL(NSDictionary *result, NSError *failure) {
        [completionLock lock];
        BOOL first = !completed;
        completed = YES;
        NSTimer *timer = deadlineTimer;
        deadlineTimer = nil;
        [completionLock unlock];
        if (timer) [[NSOperationQueue mainQueue] addOperationWithBlock:^{ [timer invalidate]; }];
        if (first) reply(result, failure);
        return first;
    };
    NSTimeInterval timeout = [request[@"timeoutSeconds"] doubleValue] ?: 10;
    if (!isfinite(timeout) || timeout < 0.001 || timeout > 30) timeout = 10;
    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
        [completionLock lock];
        if (!completed) {
            deadlineTimer = [NSTimer timerWithTimeInterval:timeout repeats:NO block:^(NSTimer *timer) {
                if (finish(nil, [NSError errorWithDomain:@"CtrlXSimulator" code:5 userInfo:@{NSLocalizedDescriptionKey:@"Simulator helper timed out; operation outcome is unknown and was not retried"}]) && ![request[@"readOnly"] boolValue]) [self invalidate];
            }];
            [[NSRunLoop mainRunLoop] addTimer:deadlineTimer forMode:NSRunLoopCommonModes];
        }
        [completionLock unlock];
    }];
    void (^sendControl)(void) = ^{
    double sentAt = NSProcessInfo.processInfo.systemUptime;
    xpc_connection_send_message_with_reply(self->_connection, object, NULL, ^(xpc_object_t response) {
        double receivedAt = NSProcessInfo.processInfo.systemUptime;
        if (xpc_get_type(response) != XPC_TYPE_DICTIONARY) {
            finish(nil, [NSError errorWithDomain:@"CtrlXSimulator" code:2 userInfo:@{NSLocalizedDescriptionKey:@"Simulator helper disconnected; operation outcome is unknown and was not retried"}]); return;
        }
        size_t length = 0;
        const void *bytes = xpc_dictionary_get_data(response, "response", &length);
        NSError *failure = nil;
        NSDictionary *result = bytes && length <= 9*1024*1024 ? [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:length] options:0 error:&failure] : nil;
        if (![result isKindOfClass:NSDictionary.class]) {
            finish(nil, failure ?: [NSError errorWithDomain:@"CtrlXSimulator" code:3 userInfo:@{NSLocalizedDescriptionKey:@"Invalid simulator helper response"}]); return;
        }
        if (![result[@"ok"] boolValue]) {
            finish(nil, [NSError errorWithDomain:@"CtrlXSimulator" code:4 userInfo:@{NSLocalizedDescriptionKey:result[@"error"] ?: @"Simulator operation failed"}]); return;
        }
        if ([command isEqual:@"connect"]) {
            __weak CXSimulatorConnection *weakSelf = self;
            NSDictionary *capabilities = result[@"result"];
            CXSimulatorInput *direct = [[CXSimulatorInput alloc] initWithEndpoint:xpc_dictionary_get_value(response, "inputEndpoint")
                state:xpc_dictionary_get_value(response, "inputState") epoch:capabilities[@"epoch"]
                workerPID:xpc_connection_get_pid(self->_connection) errorHandler:^(NSString *message) { [weakSelf fail:message]; } error:&failure];
            [self->_inputLock lock];
            BOOL accepted = direct && !atomic_load(&self->_invalid) && !self->_input;
            if (accepted) self->_input = direct;
            [self->_inputLock unlock];
            if (!accepted) {
                [direct invalidate];
                finish(nil, failure ?: [NSError errorWithDomain:@"CtrlXSimulator" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Simulator input handoff ended or is already connected"}]); return;
            }
            [direct connect:^(NSDictionary *connected, NSError *problem) {
                if (problem) { [self invalidate]; finish(nil, problem); return; }
                NSMutableDictionary *ready = capabilities.mutableCopy;
                [ready addEntriesFromDictionary:connected];
                finish(ready, nil);
            }]; return;
        }
        NSDictionary *payload = result[@"result"];
        if ([request[@"screenshotDiagnostics"] boolValue]) {
            NSMutableDictionary *timing = [payload[@"geometry"][@"screenshotTiming"] mutableCopy];
            if (timing) {
                timing[@"bridgeSentAt"] = @(sentAt);
                timing[@"bridgeReceivedAt"] = @(receivedAt);
                timing[@"bridgeDecodedAt"] = @(NSProcessInfo.processInfo.systemUptime);
                NSMutableDictionary *geometry = [payload[@"geometry"] mutableCopy];
                geometry[@"screenshotTiming"] = timing;
                NSMutableDictionary *timed = payload.mutableCopy;
                timed[@"geometry"] = geometry;
                payload = timed;
            }
        }
        finish(payload, nil);
    });
    };
    if (cancel) [input cancel:^(NSDictionary *result, NSError *failure) {
        if (failure) finish(nil, failure);
        else if (!atomic_load(&self->_invalid)) sendControl();
        else finish(nil, [NSError errorWithDomain:@"CtrlXSimulator" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Simulator connection ended during input cancellation"}]);
    }];
    else sendControl();
}
- (CXSimulatorInput *)connectedInput {
    [_inputLock lock]; CXSimulatorInput *input = _input; [_inputLock unlock]; return input;
}
- (void)fail:(NSString *)message {
    if (!atomic_exchange(&_invalid, true)) {
        [[self connectedInput] invalidate];
        xpc_connection_cancel(_connection);
        _errorHandler(message);
    }
}
- (void)invalidate {
    BOOL first = !atomic_exchange(&_invalid, true);
    [[self connectedInput] invalidate];
    if (first) xpc_connection_cancel(_connection);
}
- (void)dealloc { [self invalidate]; }
@end
