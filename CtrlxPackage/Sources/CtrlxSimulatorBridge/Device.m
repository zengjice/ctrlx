#import "CtrlxSimulatorBridge.h"
#import <objc/message.h>
#import <objc/runtime.h>
#import <xpc/xpc.h>
#include <dlfcn.h>
#include <os/lock.h>
#include <stdatomic.h>
#include <mach/mach.h>
#include <sys/mman.h>
#include "InputState.h"

// DTUHID wire vocabulary and simulator XPC handshake follow facebook/idb
// 45e96c070ce62ee1df14ba21ccd8c07b720a8684 (MIT; see ThirdParty/idb-LICENSE).

static id CXGet(id object, NSString *name) {
    return ((id (*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(name));
}

static NSError *CXError(NSString *message) {
    return [NSError errorWithDomain:@"CtrlXSimulator" code:1 userInfo:@{NSLocalizedDescriptionKey:message}];
}

static BOOL CXFail(NSError **error, NSString *message) {
    if (error) *error = CXError(message);
    return NO;
}

static xpc_object_t CXUnsigned(NSUInteger value) { return xpc_uint64_create(value); }

@interface CXSimulatorAccessibilityDelegate : NSObject
@property(nonatomic, strong) id device;
@property(nonatomic, strong, nullable) NSError *failure;
@property(nonatomic) CFTimeInterval deadline;
@property(nonatomic, strong) id cachedTranslation;
@property(nonatomic, strong) NSDictionary<NSNumber *,id> *cachedAttributes;
@end

@implementation CXSimulatorAccessibilityDelegate
- (id)accessibilityTranslationDelegateBridgeCallbackWithToken:(NSString *)token {
    return [^id(id request) {
        NSTimeInterval remaining = self.deadline - NSProcessInfo.processInfo.systemUptime;
        if (self.failure || remaining <= 0) {
            self.failure = self.failure ?: CXError(@"The accessibility observation deadline expired");
            return CXGet(NSClassFromString(@"AXPTranslatorResponse"), @"emptyResponse");
        }
        NSUInteger kind = ((NSUInteger (*)(id,SEL))objc_msgSend)(request,NSSelectorFromString(@"requestType"));
        NSUInteger attribute = ((NSUInteger (*)(id,SEL))objc_msgSend)(request,NSSelectorFromString(@"attributeType"));
        id cached = self.cachedAttributes[@(attribute)];
        if (kind == 2 && cached && [self.cachedTranslation isEqual:CXGet(request,@"translation")]) {
            id response = [NSClassFromString(@"AXPTranslatorResponse") new];
            ((void (*)(id,SEL,id))objc_msgSend)(response,NSSelectorFromString(@"setResultData:"),cached == NSNull.null ? nil : cached);
            ((void (*)(id,SEL,NSUInteger))objc_msgSend)(response,NSSelectorFromString(@"setAttribute:"),attribute);
            ((void (*)(id,SEL,NSUInteger))objc_msgSend)(response,NSSelectorFromString(@"setAssociatedRequestType:"),kind);
            ((void (*)(id,SEL,id))objc_msgSend)(response,NSSelectorFromString(@"setAssociatedTranslationObject:"),self.cachedTranslation);
            return response;
        }
        NSCondition *condition = [[NSCondition alloc] init];
        __block id response = nil;
        __block BOOL completed = NO;
        void (^completion)(id) = ^(id value) {
            [condition lock]; response = value; completed = YES; [condition signal]; [condition unlock];
        };
        // CoreSimulator requires a dispatch queue for its completion callback.
        // Scheduling of CtrlX work remains outside this framework-owned queue.
        ((void (*)(id, SEL, id, id, id))objc_msgSend)(self.device, NSSelectorFromString(@"sendAccessibilityRequestAsync:completionQueue:completionHandler:"), request, dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), completion);
        NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:remaining];
        [condition lock];
        while (!completed && [condition waitUntilDate:deadline]) {}
        [condition unlock];
        if (!completed || !response) {
            self.failure = CXError(@"The device accessibility server did not answer before the observation deadline");
            return CXGet(NSClassFromString(@"AXPTranslatorResponse"), @"emptyResponse");
        }
        return response;
    } copy];
}
- (CGRect)accessibilityTranslationConvertPlatformFrameToSystem:(CGRect)frame withToken:(NSString *)token { return frame; }
- (id)accessibilityTranslationRootParentWithToken:(NSString *)token { return nil; }
@end

@implementation CXSimulatorDevice {
    id _device;
    id _display;
    NSUUID *_displayToken;
    CXSimulatorSurfaceHandler _surfaceHandler;
    NSString *_version;
    NSString *_identifier;
    xpc_connection_t _input;
    xpc_endpoint_t _inputEndpoint;
    atomic_bool _inputReady;
    id _translator;
    CXSimulatorAccessibilityDelegate *_accessibilityDelegate;
    os_unfair_lock _displayLock;
    id _sourceObject;
    NSDictionary *_cachedGeometry;
    uint64_t _geometryRevision;
    uint64_t _geometryGeneration;
    NSUInteger _pendingOrientation;
    NSDictionary *_lastGeometry;
    CXSimulatorInputState *_sharedInputState;
    size_t _sharedInputLength;
    xpc_object_t _sharedInputObject;
    NSString *_developerDirectory;
    NSArray *_contacts;
    NSMutableSet<NSNumber *> *_keys;
    NSMutableSet<NSNumber *> *_buttons;
}

- (instancetype)initWithDeveloperDirectory:(NSString *)developerDirectory deviceSet:(NSString *)deviceSet identifier:(NSString *)identifier error:(NSError **)error {
    self = [super init];
    if (!self) return nil;
    _displayLock = OS_UNFAIR_LOCK_INIT;
    _keys = [NSMutableSet set];
    _buttons = [NSMutableSet set];
    _sharedInputLength = (size_t)getpagesize();
    void *region = mmap(NULL, _sharedInputLength, PROT_READ | PROT_WRITE, MAP_SHARED | MAP_ANON, -1, 0);
    if (region == MAP_FAILED) { CXFail(error, @"Cannot allocate input state page"); return nil; }
    _sharedInputState = region;
    _sharedInputState->protocolVersion = 1;
    atomic_init(&_sharedInputState->geometry, 0);
    atomic_init(&_sharedInputState->inputReady, 0);
    if (!atomic_is_lock_free(&_sharedInputState->geometry) || !atomic_is_lock_free(&_sharedInputState->inputReady)) {
        CXFail(error, @"Input state requires lock-free atomics"); return nil;
    }
    _sharedInputObject = xpc_shmem_create(region, _sharedInputLength);
    if (!_sharedInputObject) { CXFail(error, @"Cannot box input state page"); return nil; }
    NSString *path = @"/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator";
    if (!dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL)) {
        CXFail(error, [NSString stringWithFormat:@"Cannot load CoreSimulator: %s", dlerror()]); return nil;
    }
    @try {
        Class contextClass = NSClassFromString(@"SimServiceContext");
        SEL create = NSSelectorFromString(@"sharedServiceContextForDeveloperDir:error:");
        if (![contextClass respondsToSelector:create]) { CXFail(error, @"Unsupported CoreSimulator service context"); return nil; }
        id context = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(contextClass, create, developerDirectory, error);
        if (!context) return nil;
        id set = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(context, NSSelectorFromString(@"deviceSetWithPath:error:"), deviceSet, error);
        if (!set) return nil;
        for (id device in CXGet(set, @"devices")) {
            if ([[CXGet(device, @"UDID") UUIDString] caseInsensitiveCompare:identifier] == NSOrderedSame) { _device = device; break; }
        }
        if (!_device) { CXFail(error, @"Device is absent from the specified device set"); return nil; }
        _identifier = identifier.copy;
        _developerDirectory = developerDirectory.copy;
        _version = [[NSBundle bundleForClass:NSClassFromString(@"SimDevice")] objectForInfoDictionaryKey:@"CFBundleVersion"];
        if (!_version.length) { CXFail(error, @"Cannot identify the loaded CoreSimulator version"); return nil; }
        return self;
    } @catch (NSException *exception) {
        CXFail(error, exception.reason ?: @"CoreSimulator initialization failed"); return nil;
    }
}

- (NSDictionary *)capabilities {
    os_unfair_lock_lock(&_displayLock);
    BOOL connected = _display != nil;
    os_unfair_lock_unlock(&_displayLock);
    return @{@"device":_identifier, @"developerDirectory":_developerDirectory, @"coreSimulatorVersion":_version, @"transport":@"dtuhid", @"inputReady":@(atomic_load(&_inputReady)), @"displayConnected":@(connected)};
}

- (NSDictionary *)refreshSurface:(BOOL)invalidateGeometry {
    os_unfair_lock_lock(&_displayLock);
    id display = _display;
    uint64_t revision = ++_geometryRevision;
    if (invalidateGeometry) {
        _cachedGeometry = nil;
        ++_geometryGeneration;
        atomic_store_explicit(&_sharedInputState->geometry, _geometryGeneration << 1, memory_order_release);
    }
    os_unfair_lock_unlock(&_displayLock);
    if (!display) return nil;
    @try {
        id object = CXGet(display, @"framebufferSurface");
        if (!object) object = CXGet(display, @"ioSurface");
        if (!object || CFGetTypeID((__bridge CFTypeRef)object) != IOSurfaceGetTypeID()) return nil;
        IOSurfaceRef surface = (__bridge IOSurfaceRef)object;
        id properties = CXGet(display, @"screenProperties");
        NSUInteger screenOrientation = ((NSUInteger (*)(id, SEL))objc_msgSend)(properties, NSSelectorFromString(@"uiOrientation"));
        // CoreSimulator screen properties reverse UIKit's landscape values.
        NSUInteger orientation = screenOrientation == 3 ? 4 : screenOrientation == 4 ? 3 : screenOrientation;
        NSUInteger screen = ((NSUInteger (*)(id, SEL))objc_msgSend)(properties, NSSelectorFromString(@"screenID"));
        float scale = ((float (*)(id, SEL))objc_msgSend)(CXGet(_device, @"deviceType"), NSSelectorFromString(@"mainScreenScale"));
        NSDictionary *geometry = @{@"width":@(IOSurfaceGetWidth(surface)), @"height":@(IOSurfaceGetHeight(surface)), @"orientation":@(orientation), @"screen":@(screen), @"scale":@(scale)};
        os_unfair_lock_lock(&_displayLock);
        BOOL connected = _display == display;
        if (connected && _geometryRevision == revision) {
            if (![_lastGeometry isEqual:geometry]) {
                ++_geometryGeneration;
                _lastGeometry = geometry;
            }
            BOOL ready = !_pendingOrientation || _pendingOrientation == orientation;
            if (ready) _pendingOrientation = 0;
            NSMutableDictionary *versioned = geometry.mutableCopy;
            versioned[@"geometryVersion"] = @(_geometryGeneration);
            _sourceObject = object;
            _cachedGeometry = versioned;
            atomic_store_explicit(&_sharedInputState->geometry, (_geometryGeneration << 1) | (ready ? 1 : 0), memory_order_release);
        }
        NSDictionary *cached = _cachedGeometry;
        os_unfair_lock_unlock(&_displayLock);
        return connected ? cached : nil;
    } @catch (NSException *exception) {
        NSLog(@"Simulator frame unavailable: %@", exception.reason);
        return nil;
    }
}

- (NSDictionary *)currentGeometry {
    return [self refreshSurface:NO];
}

- (NSDictionary *)cachedGeometry {
    // Display callbacks invalidate and refresh this cache; HID submission must not make synchronous display RPCs.
    os_unfair_lock_lock(&_displayLock);
    NSDictionary *geometry = _cachedGeometry;
    os_unfair_lock_unlock(&_displayLock);
    return geometry;
}

- (void)refreshDisplay { [self refreshSurface:NO]; [self publishSurface]; }

- (void)publishSurface {
    os_unfair_lock_lock(&_displayLock);
    id surface = _sourceObject;
    NSDictionary *geometry = _cachedGeometry;
    CXSimulatorSurfaceHandler handler = _surfaceHandler;
    os_unfair_lock_unlock(&_displayLock);
    if (surface && geometry && handler) handler((__bridge IOSurfaceRef)surface, geometry);
}

- (BOOL)startDisplay:(CXSimulatorSurfaceHandler)handler error:(NSError **)error {
    if (_display) return CXFail(error, @"Display is already connected");
    @try {
        Protocol *displayProtocol = NSProtocolFromString(@"SimDisplayIOSurfaceRenderable");
        for (id port in CXGet(CXGet(_device, @"io"), @"ioPorts")) {
            id descriptor = CXGet(port, @"descriptor");
            if (displayProtocol && [descriptor conformsToProtocol:displayProtocol]) {
                id properties = CXGet(descriptor, @"screenProperties");
                BOOL primary = [CXGet(properties, @"uniqueId") isEqual:@"PurpleMain"];
                // iOS 27 uses a UUID for uniqueId and retains the primary role in deviceName.
                if (!primary && [properties respondsToSelector:NSSelectorFromString(@"deviceName")]) {
                    primary = [CXGet(properties, @"deviceName") isEqual:@"primary"];
                }
                if (primary) {
                    os_unfair_lock_lock(&_displayLock); _display = descriptor; os_unfair_lock_unlock(&_displayLock); break;
                }
            }
        }
        if (!_display) return CXFail(error, @"The booted device has no primary IOSurface display");
        _displayToken = NSUUID.UUID;
        os_unfair_lock_lock(&_displayLock); _surfaceHandler = [handler copy]; os_unfair_lock_unlock(&_displayLock);
        __weak CXSimulatorDevice *weakSelf = self;
        void (^changed)(id) = ^(id unused) {};
        ((void (*)(id, SEL, id, id))objc_msgSend)(_display, NSSelectorFromString(@"registerCallbackWithUUID:damageRectanglesCallback:"), _displayToken, changed);
        void (^frame)(void) = ^{ [weakSelf publishSurface]; };
        void (^surfaces)(id, id) = ^(id primary, id masked) { [weakSelf refreshSurface:YES]; [weakSelf publishSurface]; };
        void (^properties)(id) = ^(id value) { [weakSelf refreshSurface:YES]; [weakSelf publishSurface]; };
        ((void (*)(id, SEL, id, id, id, id, id))objc_msgSend)(_display, NSSelectorFromString(@"registerScreenCallbacksWithUUID:callbackQueue:frameCallback:surfacesChangedCallback:propertiesChangedCallback:"), _displayToken, dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), frame, surfaces, properties);
        [self refreshSurface:YES]; [self publishSurface];
        return YES;
    } @catch (NSException *exception) {
        [self stopDisplay]; return CXFail(error, exception.reason ?: @"Cannot subscribe to the display");
    }
}

- (void)stopDisplay {
    os_unfair_lock_lock(&_displayLock);
    id display = _display;
    _display = nil;
    _surfaceHandler = nil;
    _sourceObject = nil;
    _cachedGeometry = nil;
    ++_geometryGeneration;
    if (_sharedInputState) atomic_store_explicit(&_sharedInputState->geometry, _geometryGeneration << 1, memory_order_release);
    os_unfair_lock_unlock(&_displayLock);
    if (!display) return;
    for (NSString *name in @[@"unregisterDamageRectanglesCallbackWithUUID:", @"unregisterScreenCallbacksWithUUID:"]) {
        @try { ((void (*)(id, SEL, id))objc_msgSend)(display, NSSelectorFromString(name), _displayToken); }
        @catch (NSException *exception) { NSLog(@"Simulator display cleanup: %@", exception.reason); }
    }
    _displayToken = nil;
}

- (xpc_object_t)message:(NSString *)type payload:(xpc_object_t)payload barrier:(BOOL)barrier {
    xpc_object_t object = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_string(object, "messageType", type.UTF8String);
    xpc_dictionary_set_string(object, "featureIdentifier", "com.apple.coredevice.feature.remote.hid.digitizer");
    xpc_dictionary_set_bool(object, "isBarrier", barrier);
    xpc_dictionary_set_value(object, "payload", payload);
    return object;
}

- (void)connectInput:(CXSimulatorReply)reply {
    if (_inputReady) { reply(self.capabilities, nil); return; }
    if ([_version compare:@"1155.4" options:NSNumericSearch] == NSOrderedAscending) {
        reply(nil, CXError(@"This build requires CoreSimulator 1155.4 or later; legacy Indigo is not implemented")); return;
    }
    NSError *error = nil;
    SEL keyboard = NSSelectorFromString(@"setHardwareKeyboardEnabled:keyboardType:error:");
    if (![_device respondsToSelector:keyboard] || !((BOOL (*)(id,SEL,BOOL,unsigned char,NSError **))objc_msgSend)(_device,keyboard,YES,40,&error)) {
        reply(nil,error ?: CXError(@"Cannot enable this simulator's hardware keyboard")); return;
    }
    mach_port_t port = ((mach_port_t (*)(id, SEL, id, NSError **))objc_msgSend)(_device, NSSelectorFromString(@"lookup:error:"), @"com.apple.coredevice.feature.remote.hid.digitizer", &error);
    xpc_endpoint_t (*endpointFromPort)(mach_port_t, uint64_t, uint64_t) = dlsym(RTLD_DEFAULT, "xpc_endpoint_create_mach_port_4sim");
    void (*enable)(xpc_connection_t) = dlsym(RTLD_DEFAULT, "xpc_connection_enable_sim2host_4sim");
    if (!port || !endpointFromPort || !enable) { reply(nil, error ?: CXError(@"DTUHID simulator connection is unavailable")); return; }
    xpc_endpoint_t endpoint = endpointFromPort(port, 0, 0);
    if (!endpoint) { reply(nil, CXError(@"Cannot create the DTUHID endpoint")); return; }
    _inputEndpoint = endpoint;
    _input = xpc_connection_create_from_endpoint(endpoint);
    if (!_input) { reply(nil, CXError(@"Cannot create the DTUHID connection")); return; }
    enable(_input);
    __weak CXSimulatorDevice *weakSelf = self;
    xpc_connection_set_event_handler(_input, ^(xpc_object_t event) {
        CXSimulatorDevice *strongSelf = weakSelf;
        if (strongSelf && xpc_get_type(event) == XPC_TYPE_ERROR) {
            strongSelf->_inputReady = NO;
            atomic_store_explicit(&strongSelf->_sharedInputState->inputReady, 0, memory_order_release);
        }
    });
    xpc_connection_resume(_input);
    xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_value(payload, "usageCode", CXUnsigned(0));
    xpc_dictionary_set_value(payload, "state", CXUnsigned(2));
    xpc_connection_send_message_with_reply(_input, [self message:@"IndigoKeyboardButtonEvent" payload:payload barrier:YES], NULL, ^(xpc_object_t response) {
        CXSimulatorDevice *strongSelf = weakSelf;
        if (!strongSelf) { reply(nil, CXError(@"Simulator connection ended")); return; }
        if (xpc_get_type(response) == XPC_TYPE_ERROR) { reply(nil, CXError(@"DTUHID liveness probe failed")); return; }
        [[NSOperationQueue mainQueue] addOperationWithBlock:^{
            [NSTimer scheduledTimerWithTimeInterval:0.2 repeats:NO block:^(NSTimer *timer) {
                strongSelf->_inputReady = YES;
                atomic_store_explicit(&strongSelf->_sharedInputState->inputReady, 1, memory_order_release);
                reply(strongSelf.capabilities, nil);
            }];
        }];
    });
}

- (xpc_endpoint_t)inputEndpoint { return atomic_load(&_inputReady) ? _inputEndpoint : nil; }
- (xpc_object_t)inputState { return _sharedInputObject; }
- (void)cancelRotation {
    os_unfair_lock_lock(&_displayLock);
    if (!_pendingOrientation) { os_unfair_lock_unlock(&_displayLock); return; }
    _pendingOrientation = 0;
    ++_geometryGeneration;
    atomic_store_explicit(&_sharedInputState->geometry, _geometryGeneration << 1, memory_order_release);
    os_unfair_lock_unlock(&_displayLock);
    [self refreshSurface:NO];
}
- (BOOL)rotateToOrientation:(NSUInteger)orientation error:(NSError **)error {
    if (orientation < 1 || orientation > 4) return CXFail(error, @"Orientation must be 1...4");
    os_unfair_lock_lock(&_displayLock);
    _pendingOrientation = orientation;
    _cachedGeometry = nil;
    ++_geometryGeneration;
    atomic_store_explicit(&_sharedInputState->geometry, _geometryGeneration << 1, memory_order_release);
    os_unfair_lock_unlock(&_displayLock);
    BOOL accepted = [self sendOrientation:orientation error:error];
    if (!accepted) [self cancelRotation];
    else [self refreshSurface:NO];
    return accepted;
}

- (BOOL)sendTouch:(NSArray<NSDictionary<NSString *,NSNumber *> *> *)points phase:(NSUInteger)phase error:(NSError **)error {
    if (!_inputReady) return CXFail(error, @"DTUHID is not connected");
    if (points.count < 1 || points.count > 2 || phase > 2) return CXFail(error, @"Touch requires one or two contacts and a valid phase");
    xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
    for (NSUInteger i = 0; i < points.count; i++) {
        double x = [points[i][@"x"] doubleValue], y = [points[i][@"y"] doubleValue];
        if (!isfinite(x) || !isfinite(y) || x < 0 || y < 0 || x > 1 || y > 1) return CXFail(error, @"Touch coordinates must be normalized to 0...1");
        xpc_object_t point = xpc_dictionary_create(NULL, NULL, 0);
        xpc_dictionary_set_double(point, "x", x);
        xpc_dictionary_set_double(point, "y", y);
        xpc_dictionary_set_value(payload, i == 0 ? "pointOne" : "pointTwo", point);
    }
    xpc_dictionary_set_value(payload, "eventType", CXUnsigned(phase));
    xpc_dictionary_set_value(payload, "edge", CXUnsigned(0));
    xpc_dictionary_set_value(payload, "target", CXUnsigned(0));
    xpc_connection_send_message(_input, [self message:@"IndigoDigitizerEvent" payload:payload barrier:NO]);
    _contacts = phase == 2 ? nil : points.copy;
    return YES;
}

- (BOOL)sendKey:(NSUInteger)usage down:(BOOL)down error:(NSError **)error {
    if (!_inputReady) return CXFail(error, @"DTUHID is not connected");
    xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_value(payload, "usageCode", CXUnsigned(usage));
    xpc_dictionary_set_value(payload, "state", CXUnsigned(down ? 1 : 2));
    xpc_connection_send_message(_input, [self message:@"IndigoKeyboardButtonEvent" payload:payload barrier:NO]);
    if (down) [_keys addObject:@(usage)]; else [_keys removeObject:@(usage)];
    return YES;
}

- (BOOL)sendButton:(NSUInteger)usage down:(BOOL)down error:(NSError **)error {
    if (!_inputReady) return CXFail(error, @"DTUHID is not connected");
    xpc_object_t payload = xpc_dictionary_create(NULL, NULL, 0);
    xpc_dictionary_set_value(payload, "usagePage", CXUnsigned(0x0c));
    xpc_dictionary_set_value(payload, "usageCode", CXUnsigned(usage));
    xpc_dictionary_set_value(payload, "state", CXUnsigned(down ? 1 : 2));
    xpc_connection_send_message(_input, [self message:@"IndigoButtonEvent" payload:payload barrier:NO]);
    if (down) [_buttons addObject:@(usage)]; else [_buttons removeObject:@(usage)];
    return YES;
}

- (BOOL)cancelInput:(NSError **)error {
    if (!_inputReady) return CXFail(error, @"DTUHID is not connected");
    if (_contacts && ![self sendTouch:_contacts phase:2 error:error]) return NO;
    for (NSNumber *key in _keys.allObjects) if (![self sendKey:key.unsignedIntegerValue down:NO error:error]) return NO;
    for (NSNumber *button in _buttons.allObjects) if (![self sendButton:button.unsignedIntegerValue down:NO error:error]) return NO;
    return YES;
}

- (void)drainInput:(CXSimulatorReply)reply {
    if (!_inputReady) { reply(nil,CXError(@"DTUHID is not connected")); return; }
    xpc_object_t payload = xpc_dictionary_create(NULL,NULL,0);
    xpc_dictionary_set_value(payload,"usageCode",CXUnsigned(0));
    xpc_dictionary_set_value(payload,"state",CXUnsigned(2));
    xpc_connection_send_message_with_reply(_input,[self message:@"IndigoKeyboardButtonEvent" payload:payload barrier:YES],NULL,^(xpc_object_t response) {
        reply(@{@"accepted":@YES},xpc_get_type(response) == XPC_TYPE_ERROR ? CXError(@"Input drain failed; outcome is unknown") : nil);
    });
}

- (BOOL)sendOrientation:(NSUInteger)orientation error:(NSError **)error {
    if (orientation < 1 || orientation > 4) return CXFail(error, @"Orientation must be 1...4");
    @try {
        mach_port_t port = ((mach_port_t (*)(id, SEL, id, NSError **))objc_msgSend)(
            _device, NSSelectorFromString(@"lookup:error:"), @"PurpleWorkspacePort", error);
        if (!port) return CXFail(error, @"The simulator orientation service is unavailable");
        // idb's GSEvent wire layout: 108-byte orientation message, host flag, 4-byte payload.
        uint32_t message[28] = {0};
        mach_msg_header_t *header = (mach_msg_header_t *)message;
        header->msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
        header->msgh_size = 108;
        header->msgh_remote_port = port;
        header->msgh_id = 0x7b;
        message[6] = 50 | 0x20000;
        message[18] = 4;
        message[19] = (uint32_t)orientation;
        kern_return_t result = mach_msg(header, MACH_SEND_MSG | MACH_SEND_TIMEOUT, 108, 0, MACH_PORT_NULL, 2000, MACH_PORT_NULL);
        mach_port_deallocate(mach_task_self(), port);
        if (result != KERN_SUCCESS) return CXFail(error, [NSString stringWithFormat:@"Orientation send failed: %s", mach_error_string(result)]);
        return YES;
    } @catch (NSException *exception) {
        return CXFail(error, exception.reason ?: @"Orientation change failed");
    }
}

- (BOOL)prepareAccessibilityWithTimeout:(NSTimeInterval)timeout error:(NSError **)error {
    if (!isfinite(timeout) || timeout <= 0 || timeout > 30) return CXFail(error,@"Invalid accessibility initialization timeout");
    if ([NSThread isMainThread]) return CXFail(error,@"Accessibility requests require an inspector thread");
    if (!dlopen("/System/Library/PrivateFrameworks/AccessibilityPlatformTranslation.framework/AccessibilityPlatformTranslation",RTLD_NOW | RTLD_GLOBAL)) {
        return CXFail(error,[NSString stringWithFormat:@"Cannot load accessibility translation: %s",dlerror()]);
    }
    @try {
        if (!_translator) {
            _translator = CXGet(NSClassFromString(@"AXPTranslator"),@"sharedInstance");
            if (!_translator) return CXFail(error,@"The accessibility translator is unavailable");
            _accessibilityDelegate = [CXSimulatorAccessibilityDelegate new];
            _accessibilityDelegate.device = _device;
            ((void (*)(id,SEL,id))objc_msgSend)(_translator,NSSelectorFromString(@"setBridgeTokenDelegate:"),_accessibilityDelegate);
        }
        CFTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + timeout;
        while (NSProcessInfo.processInfo.systemUptime < deadline) {
            _accessibilityDelegate.failure = nil;
            _accessibilityDelegate.deadline = MIN(deadline,NSProcessInfo.processInfo.systemUptime+2);
            id application = ((id (*)(id,SEL,unsigned,id))objc_msgSend)(_translator,NSSelectorFromString(@"frontmostApplicationWithDisplayId:bridgeDelegateToken:"),0,_identifier);
            if (application && !_accessibilityDelegate.failure) return YES;
            // Observe AX server readiness during helper startup, outside the snapshot budget.
            if (NSProcessInfo.processInfo.systemUptime < deadline) CFRunLoopRunInMode(kCFRunLoopDefaultMode,.05,false);
        }
        if (error) *error = _accessibilityDelegate.failure ?: CXError(@"No frontmost accessibility application before the initialization deadline");
        return NO;
    } @catch (NSException *exception) {
        return CXFail(error,exception.reason ?: @"Accessibility initialization failed");
    }
}

- (id)accessibilityResponseForElement:(id)element type:(NSUInteger)type attribute:(NSUInteger)attribute parameters:(id)parameters {
    ((void (*)(id,SEL,id))objc_msgSend)(element,NSSelectorFromString(@"setBridgeDelegateToken:"),_identifier);
    id request = ((id (*)(id,SEL,id))objc_msgSend)(NSClassFromString(@"AXPTranslatorRequest"),NSSelectorFromString(@"requestWithTranslation:"),element);
    ((void (*)(id,SEL,NSUInteger))objc_msgSend)(request,NSSelectorFromString(@"setRequestType:"),type);
    ((void (*)(id,SEL,NSUInteger))objc_msgSend)(request,NSSelectorFromString(@"setAttributeType:"),attribute);
    ((void (*)(id,SEL,id))objc_msgSend)(request,NSSelectorFromString(@"setParameters:"),parameters);
    id (^callback)(id) = [_accessibilityDelegate accessibilityTranslationDelegateBridgeCallbackWithToken:_identifier];
    return callback(request);
}

- (id)accessibilityRequestForElement:(id)element type:(NSUInteger)type attribute:(NSUInteger)attribute parameters:(id)parameters {
    return CXGet([self accessibilityResponseForElement:element type:type attribute:attribute parameters:parameters],@"resultData");
}

- (NSDictionary *)activationForProcessIdentifier:(int)processIdentifier timeout:(NSTimeInterval)timeout error:(NSError **)error {
    if (processIdentifier <= 1 || !isfinite(timeout) || timeout <= 0 || timeout > 2) {
        CXFail(error,@"Invalid application activation request"); return nil;
    }
    if ([NSThread isMainThread] || !_translator) {
        CXFail(error,@"Application activation requires an initialized inspector thread"); return nil;
    }
    @try {
        _accessibilityDelegate.failure = nil;
        _accessibilityDelegate.deadline = NSProcessInfo.processInfo.systemUptime + timeout;
        id application = ((id (*)(id,SEL,int))objc_msgSend)(_translator,NSSelectorFromString(@"translationApplicationObjectForPid:"),processIdentifier);
        // The read-only wrapper preserves the parameter for UIKit's active, focusable Scene query.
        NSDictionary *parameters = @{@"parameter":@{@"attribute":@95257,@"parameter":@{}}};
        id response = [self accessibilityResponseForElement:application type:2 attribute:59 parameters:parameters];
        id scenes = CXGet(response,@"resultData");
        NSUInteger code = ((NSUInteger (*)(id,SEL))objc_msgSend)(response,NSSelectorFromString(@"error"));
        if (_accessibilityDelegate.failure) { if (error) *error = _accessibilityDelegate.failure; return nil; }
        // A cold UIKit process can return no Scene value until activation completes.
        if (code == 3 && !scenes) return @{@"applicationPID":@(processIdentifier),@"active":@NO};
        if (code != 0 || ![scenes isKindOfClass:NSDictionary.class]) {
            CXFail(error,[NSString stringWithFormat:@"Application Scene activation is unavailable (AXP error %lu)",(unsigned long)code]); return nil;
        }
        BOOL active = NO;
        for (id display in scenes) {
            id values = scenes[display];
            if (![values isKindOfClass:NSArray.class]) { CXFail(error,@"Invalid application Scene response"); return nil; }
            if ([values count] > 0) active = YES;
        }
        return @{@"applicationPID":@(processIdentifier),@"active":@(active)};
    } @catch (NSException *exception) {
        CXFail(error,exception.reason ?: @"Application activation observation failed"); return nil;
    }
}

- (NSDictionary *)snapshotWithLimit:(NSUInteger)limit timeout:(NSTimeInterval)timeout error:(NSError **)error {
    if (limit == 0 || limit > 1000) { CXFail(error,@"Snapshot node limit must be 1...1000"); return nil; }
    if (!isfinite(timeout) || timeout <= 0 || timeout > 30) { CXFail(error,@"Invalid accessibility observation timeout"); return nil; }
    if ([NSThread isMainThread]) { CXFail(error,@"Accessibility requests require an inspector thread"); return nil; }
    if (!_translator) { CXFail(error,@"The accessibility inspector has not been initialized"); return nil; }
    CFTimeInterval deadline = NSProcessInfo.processInfo.systemUptime + MIN(timeout,2);
    @try {
        _accessibilityDelegate.failure = nil;
        _accessibilityDelegate.deadline = deadline;
        id application = ((id (*)(id,SEL,unsigned,id))objc_msgSend)(_translator,NSSelectorFromString(@"frontmostApplicationWithDisplayId:bridgeDelegateToken:"),0,_identifier);
        if (!application || _accessibilityDelegate.failure) { if (error) *error = _accessibilityDelegate.failure ?: CXError(@"No frontmost accessibility application"); return nil; }
        // Snapshot and translator attributes use distinct native namespaces (idb c11e82a).
        NSDictionary *options = @{@"attributes":@[@5003,@2001,@5019,@2003,@5001,@5058],@"traverseFromParentsToChildren":@YES,@"maxDepth":@32,@"maxChildren":@1000,@"maxArrayCount":@1000};
        id snapshot = [self accessibilityRequestForElement:application type:2 attribute:52 parameters:options];
        if (![snapshot isKindOfClass:NSDictionary.class]) { if (error) *error = _accessibilityDelegate.failure ?: CXError(@"The native accessibility snapshot is unavailable"); return nil; }
        int applicationPID = ((int (*)(id,SEL))objc_msgSend)(application,NSSelectorFromString(@"pid"));
        NSMutableArray *nodes = [NSMutableArray array];
        NSMutableArray *pending = [NSMutableArray arrayWithObject:@{@"snapshot":snapshot,@"ownerPID":@(applicationPID),@"parent":NSNull.null,@"depth":@0,@"secure":@NO}];
        NSMutableSet *seen = [NSMutableSet set], *continued = [NSMutableSet set];
        NSString *partialReason = nil;
        while (pending.count) {
            if (nodes.count >= limit || seen.count >= 1000 || NSProcessInfo.processInfo.systemUptime >= deadline || _accessibilityDelegate.failure) {
                partialReason = _accessibilityDelegate.failure ? @"device-response" : NSProcessInfo.processInfo.systemUptime >= deadline ? @"deadline" : @"node-limit";
                break;
            }
            NSDictionary *item = pending.lastObject; [pending removeLastObject];
            NSDictionary *subtree = item[@"snapshot"];
            id translation = subtree[@"UIAccessibilitySnapshotKeyElement"];
            if (![translation isKindOfClass:NSClassFromString(@"AXPTranslationObject")]) { partialReason = @"element-response"; break; }
            int pid = ((int (*)(id,SEL))objc_msgSend)(translation,NSSelectorFromString(@"pid"));
            NSArray *children = subtree[@"UIAccessibilitySnapshotKeyChildren"];
            if (![children isKindOfClass:NSArray.class]) children = @[];
            if (!children.count && pid > 0 && pid != [item[@"ownerPID"] intValue]) {
                if ([continued containsObject:translation]) { partialReason = @"remote-cycle"; break; }
                [continued addObject:translation];
                id remote = [self accessibilityRequestForElement:translation type:2 attribute:52 parameters:options];
                if (![remote isKindOfClass:NSDictionary.class]) { partialReason = @"remote-response"; break; }
                NSMutableDictionary *next = item.mutableCopy; next[@"snapshot"] = remote; next[@"ownerPID"] = @(pid);
                [pending addObject:next]; continue;
            }
            if ([seen containsObject:translation]) continue;
            [seen addObject:translation];
            NSDictionary *values = [self accessibilityRequestForElement:translation type:5 attribute:0 parameters:@{@"attributes":@[@21,@25,@26,@32,@33,@45,@51,@112]}];
            if (![values isKindOfClass:NSDictionary.class]) { partialReason = @"element-response"; break; }
            BOOL secure = [item[@"secure"] boolValue] || [values[@51] isEqual:@5];
            id parent = item[@"parent"];
            // Mac role conversion reuses this element's just-read attributes only.
            NSMutableDictionary *cached = values.mutableCopy;
            for (NSNumber *number in @[@21,@25,@26,@32,@33,@45,@51,@112]) if (!cached[number]) cached[number] = NSNull.null;
            _accessibilityDelegate.cachedTranslation = translation;
            _accessibilityDelegate.cachedAttributes = cached;
            @try {
                id element = nil, role = nil;
                NSInteger nativeRole = [values[@45] integerValue];
                // Ignored groups, labels and scroll indicators still contribute children.
                BOOL ignoredContainer = ![values[@26] boolValue] && (nativeRole == 5 || nativeRole == 14 || nativeRole == 13);
                if (nodes.count == 0 || !ignoredContainer) {
                    element = ((id (*)(id,SEL,id))objc_msgSend)(_translator,NSSelectorFromString(@"macPlatformElementFromTranslation:"),translation);
                    role = CXGet(element,@"accessibilityRole");
                }
                BOOL include = nodes.count == 0 || [values[@26] boolValue] || [role isEqual:@"AXScrollArea"] || [role isEqual:@"AXWebArea"] || [role isEqual:@"AXWindow"];
                if (include) {
                    id subrole = CXGet(element,@"accessibilitySubrole");
                    secure = secure || [subrole isEqual:@"AXSecureTextField"];
                    NSValue *frameValue = values[@21];
                    if (![frameValue isKindOfClass:NSValue.class] || strcmp(frameValue.objCType,@encode(CGRect)) != 0) { partialReason = @"element-frame"; break; }
                    CGRect frame; [frameValue getValue:&frame size:sizeof(frame)];
                    NSMutableDictionary *node = [@{@"index":@(nodes.count),@"parent":parent,@"frame":@{@"x":@(frame.origin.x),@"y":@(frame.origin.y),@"width":@(frame.size.width),@"height":@(frame.size.height)}} mutableCopy];
                    NSNumber *visible = values[@32];
                    if ([visible isKindOfClass:NSNumber.class]) node[@"visible"] = visible.boolValue ? @YES : @NO;
                    NSValue *pointValue = values[@112];
                    if ([pointValue isKindOfClass:NSValue.class] && strcmp(pointValue.objCType,@encode(CGPoint)) == 0) {
                        CGPoint point; [pointValue getValue:&point size:sizeof(point)];
                        if (isfinite(point.x) && isfinite(point.y)) node[@"visiblePoint"] = @{@"x":@(point.x),@"y":@(point.y)};
                    }
                    NSDictionary *attributes = @{@"role":role ?: NSNull.null,@"subrole":subrole ?: NSNull.null,@"label":values[@33] ?: NSNull.null,@"identifier":values[@25] ?: NSNull.null,@"title":CXGet(element,@"accessibilityTitle") ?: NSNull.null};
                    for (NSString *name in attributes) {
                        id value = attributes[name];
                        if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) node[name] = value;
                    }
                    if (!secure) {
                        id value = CXGet(element,@"accessibilityValue");
                        if ([value isKindOfClass:NSString.class] || [value isKindOfClass:NSNumber.class]) node[@"value"] = value;
                    }
                    if (_accessibilityDelegate.failure) { partialReason = @"device-response"; break; }
                    [nodes addObject:node]; parent = node[@"index"];
                }
            } @finally {
                _accessibilityDelegate.cachedTranslation = nil;
                _accessibilityDelegate.cachedAttributes = nil;
            }
            NSUInteger depth = [item[@"depth"] unsignedIntegerValue];
            if (depth >= 32 && children.count) { partialReason = partialReason ?: @"depth-limit"; continue; }
            for (id child in children.reverseObjectEnumerator) {
                if (![child isKindOfClass:NSDictionary.class]) { partialReason = partialReason ?: @"element-response"; continue; }
                [pending addObject:@{@"snapshot":child,@"ownerPID":item[@"ownerPID"],@"parent":parent,@"depth":@(depth+1),@"secure":@(secure)}];
                if (pending.count >= 1000) { partialReason = partialReason ?: @"pending-limit"; break; }
            }
        }
        if (_accessibilityDelegate.failure || NSProcessInfo.processInfo.systemUptime >= deadline) partialReason = _accessibilityDelegate.failure ? @"device-response" : @"deadline";
        NSMutableDictionary *result = [@{@"nodes":nodes,@"partial":partialReason ? @YES : @NO,@"applicationPID":@(applicationPID),@"capturedAt":@(NSDate.date.timeIntervalSince1970)} mutableCopy];
        if (partialReason) result[@"partialReason"] = partialReason;
        if (_accessibilityDelegate.failure) result[@"observationError"] = _accessibilityDelegate.failure.localizedDescription;
        return result;
    } @catch (NSException *exception) {
        CXFail(error,exception.reason ?: @"Accessibility query failed"); return nil;
    }
}

- (void)dealloc {
    [self stopDisplay];
    if (_input) xpc_connection_cancel(_input);
    if (_sharedInputState) { atomic_store(&_sharedInputState->inputReady, 0); munmap(_sharedInputState, _sharedInputLength); }
}
@end
