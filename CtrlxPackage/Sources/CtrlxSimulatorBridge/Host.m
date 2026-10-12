#import "CtrlxSimulatorBridge.h"
#import "DeviceInput.h"
#import "FrameTrace.h"
#import "ScreenshotImage.h"
#import <Metal/Metal.h>
#import <ImageIO/ImageIO.h>
#import <xpc/xpc.h>
#include <libproc.h>
#include <os/lock.h>
#include <stdatomic.h>

@interface CXSimulatorDevice (InspectorInitialization)
- (BOOL)prepareAccessibilityWithTimeout:(NSTimeInterval)timeout error:(NSError **)error;
@end

@interface CXSimulatorSlot : NSObject
@property(nonatomic) IOSurfaceRef surface;
@property(nonatomic, strong) id<MTLTexture> texture;
@property(nonatomic) uint64_t lease;
@property(nonatomic) BOOL reading;
@end
@implementation CXSimulatorSlot
- (void)dealloc { if (_surface) CFRelease(_surface); }
@end

@interface CXSimulatorWorker : NSObject
@property(nonatomic, strong) CXSimulatorDevice *device;
@property(nonatomic) BOOL inspector;
@property(nonatomic) pid_t parentPID;
@property(nonatomic) uint64_t parentSeconds;
@property(nonatomic) uint64_t parentMicros;
- (void)accept:(xpc_connection_t)peer;
@end

@implementation CXSimulatorWorker {
    xpc_connection_t _peer;
    NSOperationQueue *_operations;
    id<MTLDevice> _metal;
    id<MTLCommandQueue> _commandQueue;
    id<MTLTexture> _sourceTexture;
    NSArray<CXSimulatorSlot *> *_slots;
    CXSimulatorSlot *_screenshotBuffer;
    BOOL _encodingScreenshot;
    os_unfair_lock _sourceLock;
    IOSurfaceRef _source;
    NSDictionary *_geometry;
    BOOL _captureScheduled;
    BOOL _copying;
    BOOL _subscribed;
    atomic_bool _captureDemand;
    BOOL _dirty;
    uint64_t _sequence;
    uint64_t _sourceSequence;
    uint32_t _sourceSeed;
    double _displayActivityAt;
    NSString *_epoch;
    double _sourceAt;
    BOOL _frameTraceEnabled;
    BOOL _singleWriteSurfaces;
    CXSimulatorTraceMarker _sourceMarker;
    CXSimulatorTraceMarker _copyMarker;
    NSDictionary *_sourceFrameTrace;
    __weak NSOperation *_lastInputOperation;
    xpc_object_t _screenshotRequest;
    NSMutableDictionary *_screenshotTiming;
}
- (instancetype)init {
    self = [super init];
    if (!self) return nil;
    _sourceLock = OS_UNFAIR_LOCK_INIT;
    // This helper owns no UI. Keep its mutable state serial without main-run-loop scheduling.
    _operations = [NSOperationQueue new];
    _operations.maxConcurrentOperationCount = 1;
    _operations.qualityOfService = NSQualityOfServiceUserInteractive;
    _slots = @[[CXSimulatorSlot new], [CXSimulatorSlot new], [CXSimulatorSlot new]];
    _screenshotBuffer = [CXSimulatorSlot new];
    _epoch = NSUUID.UUID.UUIDString;
    _frameTraceEnabled = [NSProcessInfo.processInfo.environment[@"CTRLX_SIMULATOR_FRAME_TRACE"] isEqualToString:@"1"];
    _singleWriteSurfaces = [NSProcessInfo.processInfo.environment[@"CTRLX_SIMULATOR_SINGLE_WRITE_SURFACES"] isEqualToString:@"1"];
    return self;
}
- (void)reply:(xpc_object_t)request result:(NSDictionary *)result error:(NSError *)error {
    [self reply:request result:result error:error handoff:NO];
}
- (void)reply:(xpc_object_t)request result:(NSDictionary *)result error:(NSError *)error handoff:(BOOL)handoff {
    xpc_object_t response = xpc_dictionary_create_reply(request);
    if (!response) return;
    NSDictionary *object = error ? @{@"ok":@NO, @"error":error.localizedDescription} : @{@"ok":@YES, @"result":result ?: @{}};
    NSData *data = [NSJSONSerialization dataWithJSONObject:object options:0 error:nil];
    xpc_dictionary_set_data(response, "response", data.bytes, data.length);
    if (handoff && !error) {
        xpc_dictionary_set_value(response, "inputEndpoint", self.device.inputEndpoint);
        xpc_dictionary_set_value(response, "inputState", self.device.inputState);
    }
    xpc_connection_send_message(_peer, response);
}
- (void)accept:(xpc_connection_t)peer {
    struct proc_bsdinfo info = {0};
    BOOL live = proc_pidinfo(self.parentPID, PROC_PIDTBSDINFO, 0, &info, sizeof(info)) == sizeof(info)
        && info.pbi_uid == getuid() && info.pbi_start_tvsec == self.parentSeconds && info.pbi_start_tvusec == self.parentMicros;
    if (!live || xpc_connection_get_euid(peer) != getuid() || xpc_connection_get_pid(peer) != self.parentPID || _peer) {
        xpc_connection_cancel(peer); return;
    }
    _peer = peer;
    __weak CXSimulatorWorker *weakSelf = self;
    xpc_connection_set_event_handler(peer, ^(xpc_object_t object) {
        CXSimulatorWorker *worker = weakSelf;
        if (!worker) return;
        if (xpc_get_type(object) == XPC_TYPE_ERROR) {
            [worker->_operations addOperationWithBlock:^{
                NSError *error = nil;
                if ([worker.device.capabilities[@"inputReady"] boolValue] && ![worker.device cancelInput:&error]) NSLog(@"Simulator input cleanup: %@",error);
                [worker.device stopDisplay];
                if ([worker.device.capabilities[@"inputReady"] boolValue]) {
                    [worker.device drainInput:^(NSDictionary *result,NSError *failure) {
                        if (failure) NSLog(@"Simulator input drain: %@",failure);
                        exit(0);
                    }];
                    [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                        [[NSRunLoop mainRunLoop] addTimer:[NSTimer timerWithTimeInterval:1 repeats:NO block:^(NSTimer *timer) { exit(0); }] forMode:NSRunLoopCommonModes];
                    }];
                } else { exit(0); }
            }]; return;
        }
        if (xpc_get_type(object) != XPC_TYPE_DICTIONARY) return;
        double receivedAt = NSProcessInfo.processInfo.systemUptime;
        if (worker.inspector) { [worker handle:object receivedAt:receivedAt]; }
        else {
            NSBlockOperation *operation = [NSBlockOperation blockOperationWithBlock:^{ [worker handle:object receivedAt:receivedAt]; }];
            NSOperation *previous = worker->_lastInputOperation;
            if (previous) [operation addDependency:previous];
            worker->_lastInputOperation = operation;
            [worker->_operations addOperation:operation];
        }
    });
    xpc_connection_resume(peer);
}
- (void)source:(IOSurfaceRef)surface geometry:(NSDictionary *)geometry {
    if (!atomic_load_explicit(&_captureDemand, memory_order_acquire)) return;
    os_unfair_lock_lock(&_sourceLock);
    if (_source) CFRelease(_source);
    _source = (IOSurfaceRef)CFRetain(surface);
    _geometry = geometry;
    _sourceAt = NSProcessInfo.processInfo.systemUptime;
    _sourceSeed = IOSurfaceGetSeed(surface);
    if (_frameTraceEnabled) {
        uint64_t word = 0;
        double startedAt = NSProcessInfo.processInfo.systemUptime;
        BOOL decoded = CXSimulatorTraceDecode(surface, &_sourceMarker, &word);
        double decodedAt = NSProcessInfo.processInfo.systemUptime;
        _sourceFrameTrace = @{
            @"wordHex": decoded ? [NSString stringWithFormat:@"%016llx", (unsigned long long)word] : NSNull.null,
            @"decodedAt": @(decodedAt), @"decodeMs": @((decodedAt - startedAt) * 1000),
            @"seedBefore": @(_sourceSeed), @"seedAfter": @(IOSurfaceGetSeed(surface)),
        };
    }
    _sourceSequence++;
    _dirty = YES;
    BOOL schedule = !_captureScheduled;
    _captureScheduled = YES;
    os_unfair_lock_unlock(&_sourceLock);
    if (schedule) [_operations addOperationWithBlock:^{ [self capture]; }];
}
- (BOOL)ensureDisplay:(NSError **)error {
    _displayActivityAt = NSProcessInfo.processInfo.systemUptime;
    if ([self.device.capabilities[@"displayConnected"] boolValue]) return YES;
    __weak CXSimulatorWorker *weakSelf = self;
    return [self.device startDisplay:^(IOSurfaceRef surface, NSDictionary *geometry) { [weakSelf source:surface geometry:geometry]; } error:error];
}
- (void)stopUnusedDisplay {
    BOOL demand = _subscribed || _screenshotRequest;
    atomic_store_explicit(&_captureDemand, demand, memory_order_release);
    if (!demand) {
        if (![self.device.capabilities[@"inputReady"] boolValue]) [self.device stopDisplay];
        _sourceTexture = nil;
        os_unfair_lock_lock(&_sourceLock);
        if (_source) CFRelease(_source);
        _source = NULL; _geometry = nil;
        os_unfair_lock_unlock(&_sourceLock);
    }
}
- (NSDictionary *)versionedGeometry:(NSDictionary *)geometry {
    NSMutableDictionary *result = geometry.mutableCopy;
    result[@"epoch"] = _epoch;
    return result;
}
- (void)capture {
    if ((!_subscribed && !_screenshotRequest) || _copying) {
        os_unfair_lock_lock(&_sourceLock); _captureScheduled = NO; os_unfair_lock_unlock(&_sourceLock);
        return;
    }
    os_unfair_lock_lock(&_sourceLock);
    _captureScheduled = NO;
    BOOL changed = _dirty;
    IOSurfaceRef source = _source ? (IOSurfaceRef)CFRetain(_source) : NULL;
    NSDictionary *geometry = _geometry;
    double sourceAt = _sourceAt;
    uint64_t sourceSequence = _sourceSequence;
    uint32_t sourceSeed = _sourceSeed;
    NSDictionary *sourceFrameTrace = _sourceFrameTrace;
    // Capture entry can predate the callback selected while acquiring this lock.
    double now = NSProcessInfo.processInfo.systemUptime;
    if (changed && source) _dirty = NO;
    os_unfair_lock_unlock(&_sourceLock);
    if (!source) return;
    if ((!_subscribed && !_screenshotRequest) || _copying || !changed) { CFRelease(source); return; }
    if (!_metal) { _metal = MTLCreateSystemDefaultDevice(); _commandQueue = [_metal newCommandQueue]; }
    CXSimulatorSlot *slot = nil;
    for (CXSimulatorSlot *candidate in _slots) {
        if (!candidate.lease && !candidate.reading && (_singleWriteSurfaces || !candidate.surface || !IOSurfaceIsInUse(candidate.surface))) {
            slot = candidate; break;
        }
    }
    if (!slot) {
        os_unfair_lock_lock(&_sourceLock); _dirty = YES; os_unfair_lock_unlock(&_sourceLock);
        CFRelease(source); return;
    }
    NSUInteger width = IOSurfaceGetWidth(source), height = IOSurfaceGetHeight(source);
    if (_singleWriteSurfaces || !slot.surface || IOSurfaceGetWidth(slot.surface) != width || IOSurfaceGetHeight(slot.surface) != height) {
        slot.texture = nil;
        if (slot.surface) CFRelease(slot.surface);
        slot.surface = IOSurfaceCreate((__bridge CFDictionaryRef)@{(id)kIOSurfaceWidth:@(width), (id)kIOSurfaceHeight:@(height), (id)kIOSurfaceBytesPerElement:@4, (id)kIOSurfaceBytesPerRow:@((width*4+63)&~63), (id)kIOSurfacePixelFormat:@(0x42475241)});
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
        descriptor.usage = MTLTextureUsageShaderRead;
        descriptor.storageMode = MTLStorageModeShared;
        slot.texture = [_metal newTextureWithDescriptor:descriptor iosurface:slot.surface plane:0];
    }
    if (!_sourceTexture || IOSurfaceGetID(_sourceTexture.iosurface) != IOSurfaceGetID(source)) {
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
        descriptor.storageMode = MTLStorageModeShared;
        _sourceTexture = [_metal newTextureWithDescriptor:descriptor iosurface:source plane:0];
    }
    id<MTLTexture> texture = _sourceTexture;
    CFRelease(source);
    if (!slot.texture || !texture) { NSLog(@"Cannot map simulator IOSurface to Metal"); return; }
    // Retaining a framebuffer does not prevent its producer from updating it.
    if (IOSurfaceGetSeed(texture.iosurface) != sourceSeed) return;
    NSMutableDictionary *metadata = [self versionedGeometry:geometry].mutableCopy;
    metadata[@"sourceReadyAt"] = @(sourceAt);
    metadata[@"sourceSequence"] = @(sourceSequence);
    metadata[@"capturedAt"] = @(now);
    slot.lease = ++_sequence;
    metadata[@"sequence"] = @(slot.lease);
    _copying = YES;
    id<MTLCommandBuffer> command = [_commandQueue commandBuffer];
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    [blit copyFromTexture:texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(width,height,1) toTexture:slot.texture destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [blit endEncoding];
    [command addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
        double callbackAt = NSProcessInfo.processInfo.systemUptime;
        BOOL sourceUnchanged = IOSurfaceGetSeed(texture.iosurface) == sourceSeed;
        double gpuStartedAt = buffer.GPUStartTime, gpuEndedAt = buffer.GPUEndTime;
        [self->_operations addOperationWithBlock:^{
            self->_copying = NO;
            if (buffer.status != MTLCommandBufferStatusCompleted) {
                slot.lease = 0;
                if (self->_screenshotRequest) {
                    [self reply:self->_screenshotRequest result:nil error:[NSError errorWithDomain:@"CtrlXSimulator" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Simulator frame copy failed"}]];
                    self->_screenshotRequest = nil;
                    [self stopUnusedDisplay];
                }
            } else if (!sourceUnchanged) {
                slot.lease = 0;
            } else {
                metadata[@"copyReadyAt"] = @(NSProcessInfo.processInfo.systemUptime);
                if (self->_frameTraceEnabled) {
                    NSMutableDictionary *trace = sourceFrameTrace.mutableCopy;
                    uint64_t word = 0;
                    double startedAt = NSProcessInfo.processInfo.systemUptime;
                    BOOL decoded = CXSimulatorTraceDecode(slot.surface, &self->_copyMarker, &word);
                    double decodedAt = NSProcessInfo.processInfo.systemUptime;
                    trace[@"copiedWordHex"] = decoded ? [NSString stringWithFormat:@"%016llx", (unsigned long long)word] : NSNull.null;
                    trace[@"copyDecodedAt"] = @(decodedAt);
                    trace[@"copyDecodeMs"] = @((decodedAt - startedAt) * 1000);
                    metadata[@"sourceFrameTrace"] = trace;
                }
                if (gpuStartedAt >= now && gpuEndedAt >= gpuStartedAt && callbackAt >= gpuEndedAt) {
                    metadata[@"copyStagesMs"] = @[@((gpuStartedAt - now) * 1000),
                        @((gpuEndedAt - gpuStartedAt) * 1000), @((callbackAt - gpuEndedAt) * 1000),
                        @(([metadata[@"copyReadyAt"] doubleValue] - callbackAt) * 1000)];
                }
                if (self->_screenshotRequest) [self encodeScreenshot:slot metadata:metadata];
                if (self->_subscribed) {
                    xpc_object_t message = xpc_dictionary_create(NULL, NULL, 0);
                    xpc_dictionary_set_uint64(message, "sequence", slot.lease);
                    xpc_dictionary_set_value(message, "surface", IOSurfaceCreateXPCObject(slot.surface));
                    NSData *data = [NSJSONSerialization dataWithJSONObject:metadata options:0 error:nil];
                    xpc_dictionary_set_data(message, "metadata", data.bytes, data.length);
                    if (self->_frameTraceEnabled) {
                        xpc_dictionary_set_double(message, "frameSendingAt", NSProcessInfo.processInfo.systemUptime);
                    }
                    xpc_connection_send_message(self->_peer, message);
                } else { slot.lease = 0; }
            }
            [self capture];
        }];
    }];
    [command commit];
}
- (void)encodeScreenshot:(CXSimulatorSlot *)slot metadata:(NSDictionary *)metadata {
    xpc_object_t request = _screenshotRequest;
    _screenshotRequest = nil;
    NSMutableDictionary *timing = _screenshotTiming;
    _screenshotTiming = nil;
    if (timing) timing[@"firstCopyReadyAt"] = metadata[@"copyReadyAt"];
    atomic_store_explicit(&_captureDemand, _subscribed, memory_order_release);
    _encodingScreenshot = YES;
    slot.reading = YES;
    NSUInteger width = IOSurfaceGetWidth(slot.surface), height = IOSurfaceGetHeight(slot.surface);
    if (!_screenshotBuffer.surface || IOSurfaceGetWidth(_screenshotBuffer.surface) != width || IOSurfaceGetHeight(_screenshotBuffer.surface) != height) {
        _screenshotBuffer.texture = nil;
        if (_screenshotBuffer.surface) CFRelease(_screenshotBuffer.surface);
        _screenshotBuffer.surface = IOSurfaceCreate((__bridge CFDictionaryRef)@{(id)kIOSurfaceWidth:@(width), (id)kIOSurfaceHeight:@(height), (id)kIOSurfaceBytesPerElement:@4, (id)kIOSurfaceBytesPerRow:@((width*4+63)&~63), (id)kIOSurfacePixelFormat:@(0x42475241)});
        MTLTextureDescriptor *descriptor = [MTLTextureDescriptor texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm width:width height:height mipmapped:NO];
        descriptor.storageMode = MTLStorageModeShared;
        descriptor.usage = MTLTextureUsageShaderRead;
        _screenshotBuffer.texture = _screenshotBuffer.surface ? [_metal newTextureWithDescriptor:descriptor iosurface:_screenshotBuffer.surface plane:0] : nil;
    }
    id<MTLCommandBuffer> command = _screenshotBuffer.texture ? [_commandQueue commandBuffer] : nil;
    id<MTLBlitCommandEncoder> blit = [command blitCommandEncoder];
    if (!command || !blit) {
        slot.reading = NO;
        _encodingScreenshot = NO;
        [self reply:request result:nil error:[NSError errorWithDomain:@"CtrlXSimulator" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Cannot allocate the screenshot buffer"}]];
        [self stopUnusedDisplay];
        return;
    }
    [blit copyFromTexture:slot.texture sourceSlice:0 sourceLevel:0 sourceOrigin:MTLOriginMake(0,0,0) sourceSize:MTLSizeMake(width,height,1) toTexture:_screenshotBuffer.texture destinationSlice:0 destinationLevel:0 destinationOrigin:MTLOriginMake(0,0,0)];
    [blit endEncoding];
    if (timing) timing[@"secondCopySubmittedAt"] = @(NSProcessInfo.processInfo.systemUptime);
    [command addCompletedHandler:^(id<MTLCommandBuffer> buffer) {
        double completedAt = timing ? NSProcessInfo.processInfo.systemUptime : 0;
        [self->_operations addOperationWithBlock:^{
            slot.reading = NO;
            if (buffer.status == MTLCommandBufferStatusCompleted) {
                NSMutableDictionary *screenshotMetadata = metadata.mutableCopy;
                if (timing) {
                    timing[@"secondCopyCompletedAt"] = @(completedAt);
                    timing[@"secondCopyDequeuedAt"] = @(NSProcessInfo.processInfo.systemUptime);
                    screenshotMetadata[@"screenshotTiming"] = timing;
                }
                [self encodePNG:request metadata:screenshotMetadata];
            } else {
                self->_encodingScreenshot = NO;
                [self reply:request result:nil error:[NSError errorWithDomain:@"CtrlXSimulator" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Screenshot frame copy failed"}]];
            }
            [self stopUnusedDisplay];
            [self capture];
        }];
    }];
    [command commit];
}
- (void)encodePNG:(xpc_object_t)request metadata:(NSDictionary *)metadata {
    NSMutableDictionary *timing = [metadata[@"screenshotTiming"] mutableCopy];
    if (timing) timing[@"encodingRequestedAt"] = @(NSProcessInfo.processInfo.systemUptime);
    if (timing) timing[@"encodingSubmittedAt"] = @(NSProcessInfo.processInfo.systemUptime);
    [NSThread detachNewThreadWithBlock:^{
        @autoreleasepool {
            if (timing) timing[@"encodingThreadStartedAt"] = @(NSProcessInfo.processInfo.systemUptime);
            int orientation = [metadata[@"orientation"] intValue];
            CGImageRef cg = CXSimulatorCreateScreenshotImage(self->_screenshotBuffer.surface, orientation);
            if (timing) timing[@"imageReadyAt"] = @(NSProcessInfo.processInfo.systemUptime);
            NSMutableData *png = [NSMutableData data];
            CGImageDestinationRef output = cg ? CGImageDestinationCreateWithData((__bridge CFMutableDataRef)png, CFSTR("public.png"), 1, NULL) : NULL;
            BOOL success = NO;
            if (output) { CGImageDestinationAddImage(output,cg,NULL); success = CGImageDestinationFinalize(output); CFRelease(output); }
            if (cg) CGImageRelease(cg);
            if (timing) timing[@"pngReadyAt"] = @(NSProcessInfo.processInfo.systemUptime);
            NSDictionary *result = success && png.length <= 6*1024*1024 ? @{@"data":[png base64EncodedStringWithOptions:0],@"format":@"png",@"geometry":metadata} : nil;
            [self->_operations addOperationWithBlock:^{
                if (result && timing) {
                    timing[@"replyReadyAt"] = @(NSProcessInfo.processInfo.systemUptime);
                    NSMutableDictionary *geometry = metadata.mutableCopy;
                    geometry[@"screenshotTiming"] = timing;
                    NSMutableDictionary *timed = result.mutableCopy;
                    timed[@"geometry"] = geometry;
                    [self reply:request result:timed error:nil];
                } else {
                    [self reply:request result:result error:result ? nil : [NSError errorWithDomain:@"CtrlXSimulator" code:1 userInfo:@{NSLocalizedDescriptionKey:@"PNG encoding failed or exceeds 6 MiB"}]];
                }
                self->_encodingScreenshot = NO;
                [self stopUnusedDisplay];
                [self capture];
            }];
        }
    }];
}
- (void)handle:(xpc_object_t)object receivedAt:(double)receivedAt {
    uint64_t released = xpc_dictionary_get_uint64(object, "release");
    if (released) {
        for (CXSimulatorSlot *slot in _slots) if (slot.lease == released) { slot.lease = 0; break; }
        [self capture]; return;
    }
    size_t length = 0;
    const void *bytes = xpc_dictionary_get_data(object, "request", &length);
    NSError *error = nil;
    NSDictionary *request = bytes && length <= 65536 ? [NSJSONSerialization JSONObjectWithData:[NSData dataWithBytes:bytes length:length] options:0 error:&error] : nil;
    if (![request isKindOfClass:NSDictionary.class]) { [self reply:object result:nil error:error ?: [NSError errorWithDomain:@"CtrlXSimulator" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Invalid simulator request"}]]; return; }
    NSString *command = request[@"command"];
    if ([command isEqual:@"status"]) {
        if (self.inspector && ![self.device prepareAccessibilityWithTimeout:[request[@"timeoutSeconds"] doubleValue] ?: 30 error:&error]) {
            [self reply:object result:nil error:error]; return;
        }
        [self reply:object result:self.device.capabilities error:nil]; return;
    }
    if (self.inspector) {
        if ([command isEqual:@"application-active"]) {
            BOOL diagnostics = [request[@"activationDiagnostics"] boolValue];
            double began = diagnostics ? NSProcessInfo.processInfo.systemUptime : 0;
            NSDictionary *activation = [self.device activationForProcessIdentifier:[request[@"applicationPID"] intValue] timeout:[request[@"timeoutSeconds"] doubleValue] error:&error];
            if (diagnostics) {
                double ended = NSProcessInfo.processInfo.systemUptime;
                if (activation) {
                    NSMutableDictionary *timed = activation.mutableCopy;
                    timed[@"activationBeganAt"] = @(began);
                    timed[@"activationEndedAt"] = @(ended);
                    activation = timed;
                } else {
                    fprintf(stderr, "SimulatorActivation stage=helper pid=%d begin=%.9f end=%.9f error=%s\n",
                        [request[@"applicationPID"] intValue], began, ended, error.localizedDescription.UTF8String ?: "No activation response");
                }
            }
            [self reply:object result:activation error:error]; return;
        }
        if ([command isEqual:@"snapshot"]) {
            NSDictionary *snapshot = [self.device snapshotWithLimit:[request[@"limit"] unsignedIntegerValue] ?: 200 timeout:[request[@"timeoutSeconds"] doubleValue] ?: 2 error:&error];
            [self reply:object result:snapshot error:error]; return;
        }
    } else {
        if ([command isEqual:@"connect"]) {
            double started = NSProcessInfo.processInfo.systemUptime;
            NSLog(@"Simulator input connection starting");
            [self.device connectInput:^(NSDictionary *result, NSError *failure) {
                NSLog(@"Simulator input connection finished in %.3fs: %@", NSProcessInfo.processInfo.systemUptime - started, failure.localizedDescription ?: @"ready");
                [self->_operations addOperationWithBlock:^{
                    NSError *problem = failure;
                    if (!problem) {
                        double displayStarted = NSProcessInfo.processInfo.systemUptime;
                        NSLog(@"Simulator display connection starting");
                        [self ensureDisplay:&problem];
                        NSLog(@"Simulator display connection finished in %.3fs: %@", NSProcessInfo.processInfo.systemUptime - displayStarted, problem.localizedDescription ?: @"ready");
                    }
                    NSMutableDictionary *capabilities = self.device.capabilities.mutableCopy;
                    capabilities[@"epoch"] = self->_epoch;
                    [self reply:object result:capabilities error:problem handoff:YES];
                }];
            }]; return;
        }
        if ([command isEqual:@"subscribe"]) {
            if (!_subscribed) {
                if (!_metal) { _metal = MTLCreateSystemDefaultDevice(); _commandQueue = [_metal newCommandQueue]; }
                _subscribed = YES;
                atomic_store_explicit(&_captureDemand, true, memory_order_release);
                if (![self ensureDisplay:&error]) { _subscribed = NO; [self stopUnusedDisplay]; }
                else [self.device refreshDisplay];
            }
            [self reply:object result:self.device.capabilities error:error]; return;
        }
        if ([command isEqual:@"unsubscribe"]) {
            _subscribed = NO; [self stopUnusedDisplay];
            [self reply:object result:self.device.capabilities error:nil]; return;
        }
        if ([command isEqual:@"suspend-display"]) {
            // A delayed idle request must not invalidate a newly observed gesture's geometry.
            if (!_subscribed && !_screenshotRequest && !_encodingScreenshot
                && NSProcessInfo.processInfo.systemUptime - _displayActivityAt >= 60) {
                [self.device stopDisplay];
            }
            [self reply:object result:@{@"suspended":@(![self.device.capabilities[@"displayConnected"] boolValue])} error:nil];
            return;
        }
        if ([command isEqual:@"screenshot"]) {
            if (_screenshotRequest || _encodingScreenshot) {
                [self reply:object result:nil error:[NSError errorWithDomain:@"CtrlXSimulator" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Another screenshot is in progress"}]]; return;
            }
            _screenshotRequest = object;
            _screenshotTiming = [request[@"screenshotDiagnostics"] boolValue]
                ? [@{@"helperReceivedAt":@(receivedAt), @"helperStartedAt":@(NSProcessInfo.processInfo.systemUptime)} mutableCopy] : nil;
            atomic_store_explicit(&_captureDemand, true, memory_order_release);
            if (![self ensureDisplay:&error]) {
                _screenshotRequest = nil; [self stopUnusedDisplay]; [self reply:object result:nil error:error]; return;
            }
            if (_screenshotTiming) _screenshotTiming[@"displayReadyAt"] = @(NSProcessInfo.processInfo.systemUptime);
            [self.device refreshDisplay];
            if (_screenshotTiming) _screenshotTiming[@"displayRefreshedAt"] = @(NSProcessInfo.processInfo.systemUptime);
            os_unfair_lock_lock(&_sourceLock); _dirty = YES; os_unfair_lock_unlock(&_sourceLock);
            [self capture]; return;
        }
        if ([command isEqual:@"geometry"]) {
            NSDictionary *geometry = [self ensureDisplay:&error] ? [self.device currentGeometry] : nil;
            NSDictionary *result = geometry ? [self versionedGeometry:geometry] : nil;
            [self stopUnusedDisplay];
            [self reply:object result:result error:error ?: (result ? nil : [NSError errorWithDomain:@"CtrlXSimulator" code:1 userInfo:@{NSLocalizedDescriptionKey:@"The simulator display is not ready"}])]; return;
        }
        if ([command isEqual:@"cancel-rotation"]) {
            [self.device cancelRotation];
            [self reply:object result:@{@"accepted":@YES} error:nil]; return;
        }
        if ([command isEqual:@"rotate"]) {
            [self.device rotateToOrientation:[request[@"orientation"] unsignedIntegerValue] error:&error];
            [self reply:object result:@{@"accepted":@(error == nil)} error:error]; return;
        }

    }
    [self reply:object result:nil error:[NSError errorWithDomain:@"CtrlXSimulator" code:1 userInfo:@{NSLocalizedDescriptionKey:@"Unsupported simulator command for this helper role"}]];
}
- (void)dealloc { if (_source) CFRelease(_source); }
@end

int CXSimulatorHostRun(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 9) { fprintf(stderr, "usage: host service developer-dir device-set udid worker|inspector parent-pid parent-seconds parent-micros\n"); return 2; }
        NSError *error = nil;
        CXSimulatorWorker *worker = [CXSimulatorWorker new];
        double started = NSProcessInfo.processInfo.systemUptime;
        NSLog(@"Simulator %@ initialization starting; developer directory: %@", @(argv[5]), @(argv[2]));
        worker.device = [[CXSimulatorDevice alloc] initWithDeveloperDirectory:@(argv[2]) deviceSet:@(argv[3]) identifier:@(argv[4]) error:&error];
        worker.inspector = [@(argv[5]) isEqual:@"inspector"];
        worker.parentPID = (pid_t)strtol(argv[6], NULL, 10);
        worker.parentSeconds = strtoull(argv[7], NULL, 10);
        worker.parentMicros = strtoull(argv[8], NULL, 10);
        if (!worker.device) { fprintf(stderr, "%s\n", error.localizedDescription.UTF8String); return 1; }
        NSLog(@"Simulator %@ initialized in %.3fs; CoreSimulator %@", @(argv[5]), NSProcessInfo.processInfo.systemUptime - started, worker.device.capabilities[@"coreSimulatorVersion"]);
        xpc_connection_t listener = xpc_connection_create_mach_service(argv[1], NULL, XPC_CONNECTION_MACH_SERVICE_LISTENER);
        xpc_connection_set_event_handler(listener, ^(xpc_object_t peer) {
            if (xpc_get_type(peer) == XPC_TYPE_CONNECTION) [worker accept:(xpc_connection_t)peer];
        });
        xpc_connection_resume(listener);
        [[NSRunLoop currentRunLoop] run];
        return 0;
    }
}
