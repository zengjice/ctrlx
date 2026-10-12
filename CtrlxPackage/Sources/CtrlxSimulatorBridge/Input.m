#import "Input.h"
#include "InputState.h"
#include <dlfcn.h>
#include <libproc.h>
#include <sys/mman.h>
#include <sys/proc.h>

static NSError *CXInputError(NSString *message) {
    return [NSError errorWithDomain:@"CtrlXSimulator" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}

static xpc_object_t CXInputMessage(const char *type, xpc_object_t payload, BOOL barrier) {
    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(message, "messageType", type);
    xpc_dictionary_set_string(message, "featureIdentifier", "com.apple.coredevice.feature.remote.hid.digitizer");
    xpc_dictionary_set_bool(message, "isBarrier", barrier);
    xpc_dictionary_set_value(message, "payload", payload);
    return message;
}

static xpc_object_t CXTouchMessage(NSArray *points, NSUInteger phase, NSUInteger edge) {
    xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
    for (NSUInteger i = 0; i < points.count; i++) {
        xpc_object_t point = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_double(point, "x", [points[i][@"x"] doubleValue]);
        xpc_dictionary_set_double(point, "y", [points[i][@"y"] doubleValue]);
        xpc_dictionary_set_value(payload, i == 0 ? "pointOne" : "pointTwo", point);
    }
    xpc_dictionary_set_uint64(payload, "eventType", phase);
    xpc_dictionary_set_uint64(payload, "edge", edge);
    xpc_dictionary_set_uint64(payload, "target", 0);
    return CXInputMessage("IndigoDigitizerEvent", payload, NO);
}

static xpc_object_t CXUsageMessage(NSUInteger usage, BOOL down, BOOL button, BOOL barrier) {
    xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_uint64(payload, "usageCode", usage);
    xpc_dictionary_set_uint64(payload, "state", down ? 1 : 2);
    if (button) xpc_dictionary_set_uint64(payload, "usagePage", 0x0c);
    return CXInputMessage(button ? "IndigoButtonEvent" : "IndigoKeyboardButtonEvent", payload, barrier);
}

@implementation CXSimulatorInput {
    xpc_connection_t _connection;
    CXSimulatorInputState *_state;
    size_t _stateLength;
    NSString *_epoch;
    pid_t _workerPID;
    uint64_t _workerSeconds, _workerMicros;
    NSLock *_lock;
    BOOL _ready, _invalid;
    NSArray *_contacts;
    NSUInteger _contactEdge;
    NSMutableSet<NSNumber *> *_keys, *_buttons;
    CXSimulatorErrorHandler _errorHandler;
}
- (instancetype)initWithEndpoint:(xpc_endpoint_t)endpoint state:(xpc_object_t)state
                           epoch:(NSString *)epoch workerPID:(pid_t)workerPID
                    errorHandler:(CXSimulatorErrorHandler)errorHandler error:(NSError **)error {
    if (!(self = [super init])) return nil;
    _lock = [NSLock new];
    _keys = [NSMutableSet new]; _buttons = [NSMutableSet new];
    _epoch = epoch.copy; _errorHandler = [errorHandler copy];
    if (!endpoint || xpc_get_type(endpoint) != XPC_TYPE_ENDPOINT || !state || xpc_get_type(state) != XPC_TYPE_SHMEM
        || ![[NSUUID alloc] initWithUUIDString:epoch]) {
        if (error) *error = CXInputError(@"Simulator input handoff is invalid"); return nil;
    }
    void *region = NULL;
    _stateLength = xpc_shmem_map(state, &region);
    _state = region;
    if (_stateLength != (size_t)getpagesize() || !_state || _state->protocolVersion != 1
        || !atomic_is_lock_free(&_state->geometry) || !atomic_is_lock_free(&_state->inputReady)
        || mprotect(region, _stateLength, PROT_READ) != 0) {
        if (error) *error = CXInputError(@"Cannot map simulator input state as a read-only page"); return nil;
    }
    struct proc_bsdinfo worker = {0};
    if (proc_pidinfo(workerPID, PROC_PIDTBSDINFO, 0, &worker, sizeof(worker)) != sizeof(worker) || worker.pbi_uid != getuid()) {
        if (error) *error = CXInputError(@"Simulator input worker identity is unavailable"); return nil;
    }
    _workerPID = workerPID; _workerSeconds = worker.pbi_start_tvsec; _workerMicros = worker.pbi_start_tvusec;
    void (*enable)(xpc_connection_t) = dlsym(RTLD_DEFAULT, "xpc_connection_enable_sim2host_4sim");
    if (!enable || !(_connection = xpc_connection_create_from_endpoint(endpoint))) {
        if (error) *error = CXInputError(@"Direct simulator HID connection is unavailable"); return nil;
    }
    enable(_connection);
    __weak CXSimulatorInput *weakSelf = self;
    xpc_connection_set_event_handler(_connection, ^(xpc_object_t event) {
        CXSimulatorInput *input = weakSelf;
        if (!input || xpc_get_type(event) != XPC_TYPE_ERROR) return;
        [input->_lock lock]; BOOL unexpected = !input->_invalid; [input->_lock unlock];
        if (unexpected) {
            [input invalidate];
            input->_errorHandler(@"Simulator HID disconnected. Close and reopen this device; pending action outcomes are unknown");
        }
    });
    xpc_connection_resume(_connection);
    return self;
}
- (BOOL)workerIsLive {
    struct proc_bsdinfo worker = {0};
    return proc_pidinfo(_workerPID, PROC_PIDTBSDINFO, 0, &worker, sizeof(worker)) == sizeof(worker)
        && worker.pbi_uid == getuid() && worker.pbi_start_tvsec == _workerSeconds && worker.pbi_start_tvusec == _workerMicros
        && worker.pbi_status != SZOMB;
}
- (void)connect:(CXSimulatorReply)reply {
    xpc_connection_send_message_with_reply(_connection, CXUsageMessage(0, NO, NO, YES), NULL, ^(xpc_object_t response) {
        if (xpc_get_type(response) == XPC_TYPE_ERROR) { reply(nil, CXInputError(@"Direct simulator HID liveness probe failed")); return; }
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:NO block:^(NSTimer *timer) {
                [self->_lock lock];
                self->_ready = !self->_invalid && [self workerIsLive] && atomic_load_explicit(&self->_state->inputReady, memory_order_acquire);
                BOOL ready = self->_ready;
                [self->_lock unlock];
                reply(ready ? @{@"inputTransport":@"host-direct-hid"} : nil, ready ? nil : CXInputError(@"Simulator input ended during handoff"));
            }];
        }];
    });
}
- (void)releaseHeldTouches {
    if (_contacts) xpc_connection_send_message(_connection, CXTouchMessage(_contacts, 2, _contactEdge));
    _contacts = nil; _contactEdge = 0;
}
- (void)releaseHeldInput {
    if (!_connection) return;
    [self releaseHeldTouches];
    for (NSNumber *key in _keys) xpc_connection_send_message(_connection, CXUsageMessage(key.unsignedIntegerValue, NO, NO, NO));
    for (NSNumber *button in _buttons) xpc_connection_send_message(_connection, CXUsageMessage(button.unsignedIntegerValue, NO, YES, NO));
    [_keys removeAllObjects]; [_buttons removeAllObjects];
}
- (void)request:(NSDictionary *)request reply:(CXSimulatorReply)reply {
    double startedAt = NSProcessInfo.processInfo.systemUptime;
    NSString *command = request[@"command"];
    NSError *failure = nil;
    double submittedAt = 0, enqueuedAt = 0, validatedAt = 0;
    [_lock lock];
    if (!_ready || _invalid || ![self workerIsLive] || !atomic_load_explicit(&_state->inputReady, memory_order_acquire)) {
        failure = CXInputError(@"Simulator input is disconnected");
    } else if ([command isEqual:@"touch"]) {
        NSArray *points = request[@"points"];
        NSUInteger phase = [request[@"phase"] unsignedIntegerValue];
        NSUInteger edge = [request[@"edge"] unsignedIntegerValue];
        uint64_t version = [request[@"geometryVersion"] unsignedLongLongValue];
        if (![points isKindOfClass:NSArray.class] || points.count < 1 || points.count > 2 || phase > 2 || edge > 4) {
            failure = CXInputError(@"Touch requires one or two contacts, a valid phase and an edge of 0...4");
        }
        if (!failure && _contacts && phase != 0 && edge != _contactEdge) {
            failure = CXInputError(@"Touch edge changed during a held gesture");
        }
        if (!failure) for (NSDictionary *point in points) {
            double x = [point[@"x"] doubleValue], y = [point[@"y"] doubleValue];
            if (!isfinite(x) || !isfinite(y) || x < 0 || x > 1 || y < 0 || y > 1) {
                failure = CXInputError(@"Touch coordinates must be normalized to 0...1"); break;
            }
        }
        if (!failure && (!version || ![request[@"epoch"] isEqual:_epoch]
            || atomic_load_explicit(&_state->geometry, memory_order_acquire) != ((version << 1) | 1))) {
            failure = CXInputError(@"Display geometry changed; observe again before touching");
        }
        validatedAt = NSProcessInfo.processInfo.systemUptime;
        if (!failure) {
            if ([request[@"cancelBeforeTouch"] boolValue]) [self releaseHeldInput];
            submittedAt = NSProcessInfo.processInfo.systemUptime;
            xpc_connection_send_message(_connection, CXTouchMessage(points, phase, edge));
            enqueuedAt = NSProcessInfo.processInfo.systemUptime;
            _contacts = phase == 2 ? nil : points.copy;
            _contactEdge = phase == 2 ? 0 : edge;
        }
    } else if ([command isEqual:@"release-touch"]) {
        [self releaseHeldTouches];
    } else {
        BOOL button = [command isEqual:@"button"];
        NSUInteger usage = [request[@"usage"] unsignedIntegerValue];
        BOOL down = [request[@"down"] boolValue];
        xpc_connection_send_message(_connection, CXUsageMessage(usage, down, button, NO));
        NSMutableSet *held = button ? _buttons : _keys;
        if (down) [held addObject:@(usage)]; else [held removeObject:@(usage)];
    }
    if (failure) [self releaseHeldInput];
    [_lock unlock];
    NSMutableDictionary *result = [@{@"accepted":@(failure == nil), @"inputPath":@"direct-hid"} mutableCopy];
    if ([command isEqual:@"touch"]) {
        result[@"submittedAt"] = @(submittedAt); result[@"enqueuedAt"] = @(enqueuedAt);
        if ([request[@"inputDiagnostics"] boolValue]) {
            result[@"nativeInputStartedAt"] = @(startedAt); result[@"nativeInputValidatedAt"] = @(validatedAt);
        }
    }
    reply(failure ? nil : result, failure);
}
- (void)cancel:(CXSimulatorReply)reply {
    [_lock lock];
    if (_invalid || !_ready) { [_lock unlock]; reply(nil, CXInputError(@"Simulator input is disconnected")); return; }
    [self releaseHeldInput];
    xpc_connection_send_message_with_reply(_connection, CXUsageMessage(0, NO, NO, YES), NULL, ^(xpc_object_t response) {
        reply(@{@"accepted":@YES}, xpc_get_type(response) == XPC_TYPE_ERROR ? CXInputError(@"Input drain failed; outcome is unknown") : nil);
    });
    [_lock unlock];
}
- (void)invalidate {
    [_lock lock];
    if (_invalid) { [_lock unlock]; return; }
    _invalid = YES; _ready = NO;
    [self releaseHeldInput];
    xpc_connection_t connection = _connection;
    [_lock unlock];
    if (!connection) return;
    xpc_connection_send_message_with_reply(connection, CXUsageMessage(0, NO, NO, YES), NULL, ^(xpc_object_t response) {
        xpc_connection_cancel(connection);
    });
    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
        [NSTimer scheduledTimerWithTimeInterval:1 repeats:NO block:^(NSTimer *timer) { xpc_connection_cancel(connection); }];
    }];
}
- (void)dealloc { [self invalidate]; if (_state) munmap(_state, _stateLength); }
@end
