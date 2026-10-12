#import <Foundation/Foundation.h>
#import <AppKit/AppKit.h>
#import <ScreenCaptureKit/ScreenCaptureKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <QuartzCore/QuartzCore.h>
#import <ImageIO/ImageIO.h>
#include <mach/mach_time.h>

// Decode only the test fixture's barcode. No desktop images are saved.
static BOOL decode(CVPixelBufferRef image, NSString *region, uint32_t *value, NSString **reason, NSDictionary **marker) {
    *reason = @"marker-missing";
    if (CVPixelBufferGetPixelFormatType(image) != kCVPixelFormatType_32BGRA) return NO;
    CVPixelBufferLockBaseAddress(image,kCVPixelBufferLock_ReadOnly);
    const unsigned char *base = CVPixelBufferGetBaseAddress(image);
    size_t width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image), stride = CVPixelBufferGetBytesPerRow(image);
    size_t minX = [region isEqual:@"right"] ? width / 2 : 0;
    size_t maxX = [region isEqual:@"left"] ? width / 2 : width;
    BOOL found = NO;
    for (size_t y = 0; y < height && !found; y += 4) {
        const unsigned char *row = base + y * stride;
        for (size_t x = minX; x < maxX; x++) {
            const unsigned char *p = row + x*4;
            if (!(p[0] > 200 && p[2] > 200 && p[1] < 60)) continue;
            size_t end = x;
            while (end < maxX) {
                p = row + end*4;
                if (!(p[0] > 200 && p[2] > 200 && p[1] < 60)) break;
                end++;
            }
            double cell = end - x;
            if (cell < 3) { *reason = @"marker-too-small"; x = end; continue; }
            // Cyan-to-yellow interpolation can satisfy the green threshold.
            // The terminator follows all three header cells and the data bits.
            size_t green = x + 3 * (end - x);
            for (; green < maxX; green++) {
                p = row + green*4;
                if (p[0]<150 && p[1]>200 && p[2]<150) break;
            }
            if (green >= maxX) { *reason = @"green-missing"; x = end; continue; }
            cell = (green - x) / 35.0;
            const unsigned char *cyan = row + (size_t)(x+cell*1.5)*4;
            const unsigned char *yellow = row + (size_t)(x+cell*2.5)*4;
            // Window color conversion can mix the primaries; the data checksum remains exact.
            if (!(cyan[0]>200 && cyan[1]>200 && cyan[2]<150 && yellow[0]<150 && yellow[1]>200 && yellow[2]>200)) {
                if (marker) *marker = @{@"candidateX":@(x), @"greenX":@(green), @"cellPixels":@(cell),
                    @"cyanRGB":@[@(cyan[2]),@(cyan[1]),@(cyan[0])],
                    @"yellowRGB":@[@(yellow[2]),@(yellow[1]),@(yellow[0])]};
                *reason = @"marker-colors"; x = end; continue;
            }
            uint32_t bits = 0; BOOL valid = YES;
            for (NSUInteger bit = 0; bit < 32; bit++) {
                p = row + (size_t)(x+cell*(bit+3.5))*4;
                unsigned int sum = p[0]+p[1]+p[2];
                if (sum > 600) bits |= 1u << bit;
                else if (sum >= 150) { *reason = @"bit-edge"; valid = NO; break; }
            }
            uint8_t check = (uint8_t)(bits ^ (bits>>8) ^ (bits>>16) ^ 0xA5);
            if (valid && check == (uint8_t)(bits>>24)) {
                *value = bits;
                if (marker) *marker = @{@"x":@(x), @"sampleY":@(y), @"cellPixels":@(cell), @"widthPixels":@(cell * 36)};
                found = YES; break;
            }
            if (valid) *reason = @"checksum";
            x = end;
        }
    }
    CVPixelBufferUnlockBaseAddress(image,kCVPixelBufferLock_ReadOnly);
    return found;
}

@interface WindowFrameProbe : NSObject <SCStreamOutput, SCStreamDelegate>
@property(nonatomic, strong) SCStream *stream;
@property(nonatomic, strong) NSLock *lock;
@property(nonatomic, strong) NSMutableArray *rows;
@property(nonatomic, strong) NSString *output;
@property(nonatomic, strong) NSString *region;
@property(nonatomic, strong) NSString *captureMode;
@property(nonatomic, strong) WindowFrameProbe *rightProbe;
@property(nonatomic) double started;
@property(nonatomic) double seconds;
@property(nonatomic) uint32_t lastValue;
@property(nonatomic) BOOL hasValue;
@property(nonatomic) NSUInteger rejected;
@property(nonatomic) NSUInteger callbacks;
@property(nonatomic, strong) NSMutableDictionary *rejectReasons;
@property(nonatomic, strong) NSDictionary *imageGeometry;
@property(nonatomic, strong) NSDictionary *barcodeGeometry;
@property(nonatomic, strong) NSArray *markerDiagnostics;
@property(nonatomic) int exitCode;
@end
@implementation WindowFrameProbe
- (void)stream:(SCStream *)stream didStopWithError:(NSError *)error {
    fprintf(stderr,"Capture stopped: %s\n",error.localizedDescription.UTF8String); self.exitCode = 1;
    CFRunLoopStop(CFRunLoopGetMain());
}
- (void)stream:(SCStream *)stream didOutputSampleBuffer:(CMSampleBufferRef)buffer ofType:(SCStreamOutputType)type {
    if (self.rightProbe) [self.rightProbe stream:stream didOutputSampleBuffer:buffer ofType:type];
    if (type != SCStreamOutputTypeScreen || !CMSampleBufferIsValid(buffer)) return;
    NSArray *attachments = (__bridge NSArray *)CMSampleBufferGetSampleAttachmentsArray(buffer,NO);
    NSDictionary *info = attachments.firstObject;
    if ([info[SCStreamFrameInfoStatus] integerValue] != SCFrameStatusComplete) return;
    CVPixelBufferRef image = CMSampleBufferGetImageBuffer(buffer);
    if (!image) return;
    double received = CACurrentMediaTime();
    [self.lock lock];
    if (self.started == 0 || received < self.started + 3) { [self.lock unlock]; return; }
    self.callbacks++;
    self.imageGeometry = @{@"width":@(CVPixelBufferGetWidth(image)),@"height":@(CVPixelBufferGetHeight(image)),
        @"format":@(CVPixelBufferGetPixelFormatType(image))};
    uint32_t value = 0;
    NSString *reason = nil;
    NSDictionary *marker = nil;
    if (!decode(image,self.region,&value,&reason,&marker)) {
        if (!self.markerDiagnostics) {
            CVPixelBufferLockBaseAddress(image,kCVPixelBufferLock_ReadOnly);
            const unsigned char *base = CVPixelBufferGetBaseAddress(image);
            size_t width = CVPixelBufferGetWidth(image), height = CVPixelBufferGetHeight(image), stride = CVPixelBufferGetBytesPerRow(image);
            NSMutableArray *markers = [NSMutableArray new];
            if (marker) [markers addObject:marker];
            for (size_t y = 0; y < height && markers.count < 8; y += 4) {
                const unsigned char *row = base + y * stride;
                for (size_t x = 0; x < width && markers.count < 8; x++) {
                    const unsigned char *p = row + x*4;
                    if (!(p[0]>200 && p[2]>200 && p[1]<60)) continue;
                    size_t end=x; while(end<width) { p=row+end*4; if(!(p[0]>200 && p[2]>200 && p[1]<60)) break; end++; }
                    if(end-x<3) { x=end; continue; }
                    NSMutableArray *colors=[NSMutableArray new];
                    for(size_t xx=x;xx<MIN(width,x+(end-x)*40);xx+=MAX((size_t)1,(end-x)/2)) {
                        p=row+xx*4; [colors addObject:@[@(xx),@(p[2]),@(p[1]),@(p[0])]];
                    }
                    [markers addObject:@{@"x":@(x),@"y":@(y),@"run":@(end-x),@"rgb":colors}]; x=end;
                }
            }
            self.markerDiagnostics = markers.copy;
            CVPixelBufferUnlockBaseAddress(image,kCVPixelBufferLock_ReadOnly);
        }
        self.rejected++; self.rejectReasons[reason] = @([self.rejectReasons[reason] unsignedIntegerValue] + 1);
        [self.lock unlock]; return;
    }
    if (!self.hasValue || value != self.lastValue) {
        self.barcodeGeometry = marker;
        mach_timebase_info_data_t clock; mach_timebase_info(&clock);
        double displayed = [info[SCStreamFrameInfoDisplayTime] unsignedLongLongValue] * (double)clock.numer / clock.denom / 1e9;
        [self.rows addObject:@{@"frame":@(value & 0xFFFF),@"taps":@((value>>16)&0xFF),@"displayAt":@(displayed),@"receivedAt":@(received)}];
        self.lastValue = value; self.hasValue = YES;
    }
    [self.lock unlock];
}
- (NSDictionary *)resultAt:(double)finished {
    [self.lock lock];
    double elapsed = finished - self.started - 3;
    NSDictionary *result = @{@"elapsedSeconds":@(elapsed),@"uniqueFrames":@(self.rows.count),
        @"uniqueWindowFPS":@(self.rows.count / elapsed),@"completeCallbacks":@(self.callbacks),
        @"barcodeRejected":@(self.rejected),@"rejectReasons":self.rejectReasons.copy,
        @"imageGeometry":self.imageGeometry ?: @{},@"barcodeGeometry":self.barcodeGeometry ?: @{},
        @"region":self.region ?: @"whole",@"captureMode":self.captureMode ?: @"window",@"frames":self.rows.copy};
    if (self.markerDiagnostics) { NSMutableDictionary *withDiagnostics=result.mutableCopy; withDiagnostics[@"markerDiagnostics"]=self.markerDiagnostics; result=withDiagnostics; }
    [self.lock unlock];
    return result;
}
- (void)finish {
    [self.stream stopCaptureWithCompletionHandler:^(NSError *error) {
        if (error) { fprintf(stderr,"Capture cleanup: %s\n",error.localizedDescription.UTF8String); self.exitCode = 1; }
        double finished = CACurrentMediaTime();
        NSDictionary *result = [self resultAt:finished];
        if (self.rightProbe) {
            result = @{@"left":result, @"right":[self.rightProbe resultAt:finished]};
            if (!self.rightProbe.rows.count) self.exitCode = 1;
        }
        NSError *writeError = nil;
        NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:&writeError];
        if (!data || ![data writeToFile:self.output options:NSDataWritingAtomic error:&writeError]) {
            fprintf(stderr,"Output: %s\n",writeError.localizedDescription.UTF8String); self.exitCode = 1;
        }
        if (!self.rows.count) self.exitCode = 1;
        printf("%lu unique frames; %lu rejected barcode frames\n",self.rows.count,self.rejected);
        CFRunLoopStop(CFRunLoopGetMain());
    }];
}
@end

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc == 3 && strcmp(argv[1], "--png") == 0) {
            NSURL *url = [NSURL fileURLWithPath:@(argv[2])];
            CGImageSourceRef source = CGImageSourceCreateWithURL((__bridge CFURLRef)url, NULL);
            CGImageRef image = source ? CGImageSourceCreateImageAtIndex(source, 0, NULL) : NULL;
            if (source) CFRelease(source);
            if (!image) { fprintf(stderr,"Cannot decode PNG\n"); return 1; }
            CVPixelBufferRef buffer = NULL;
            size_t width = CGImageGetWidth(image), height = CGImageGetHeight(image);
            CVReturn created = CVPixelBufferCreate(kCFAllocatorDefault, width, height,
                kCVPixelFormatType_32BGRA, NULL, &buffer);
            if (created != kCVReturnSuccess) { CGImageRelease(image); return 1; }
            CVPixelBufferLockBaseAddress(buffer, 0);
            CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
            CGContextRef context = CGBitmapContextCreate(CVPixelBufferGetBaseAddress(buffer),
                width, height, 8, CVPixelBufferGetBytesPerRow(buffer), colorSpace,
                kCGImageAlphaPremultipliedFirst | kCGBitmapByteOrder32Little);
            CGColorSpaceRelease(colorSpace);
            if (context) CGContextDrawImage(context, CGRectMake(0, 0, width, height), image);
            CVPixelBufferUnlockBaseAddress(buffer, 0);
            CGImageRelease(image);
            if (!context) { CVPixelBufferRelease(buffer); return 1; }
            CGContextRelease(context);
            uint32_t value = 0;
            NSString *reason = nil;
            BOOL valid = decode(buffer, nil, &value, &reason, NULL);
            CVPixelBufferRelease(buffer);
            NSDictionary *result = valid
                ? @{@"frame":@(value & 0xFFFF), @"taps":@((value >> 16) & 0xFF), @"width":@(width), @"height":@(height)}
                : @{@"error":reason, @"width":@(width), @"height":@(height)};
            NSData *data = [NSJSONSerialization dataWithJSONObject:result options:NSJSONWritingSortedKeys error:NULL];
            fwrite(data.bytes, 1, data.length, stdout); fputc('\n', stdout);
            return valid ? 0 : 1;
        }
        if (argc != 5 && argc != 6) { fprintf(stderr,"usage: WindowFrameProbe pid exact-window-title seconds new-output.json [left|right|both|display|display-both]\n"); return 2; }
        pid_t pid = (pid_t)strtol(argv[1],NULL,10); double seconds = strtod(argv[3],NULL);
        NSString *title = @(argv[2]), *output = @(argv[4]);
        NSString *region = argc == 6 ? @(argv[5]) : nil;
        BOOL displayCapture = [region isEqual:@"display"] || [region isEqual:@"display-both"];
        if (region && ![region isEqual:@"left"] && ![region isEqual:@"right"] && ![region isEqual:@"both"] && !displayCapture) return 2;
        if (pid <= 0 || seconds < 10 || seconds > 1800 || [NSFileManager.defaultManager fileExistsAtPath:output]) return 2;
        [NSApplication sharedApplication];
        if (!CGPreflightScreenCaptureAccess()) { fprintf(stderr,"Screen capture access has not been granted to this test process\n"); return 3; }
        WindowFrameProbe *probe = [WindowFrameProbe new]; probe.lock = [NSLock new]; probe.rows = [NSMutableArray new]; probe.rejectReasons = [NSMutableDictionary new];
        probe.output = output; probe.seconds = seconds; probe.region = displayCapture ? nil : region;
        probe.captureMode = displayCapture ? @"display-selected-window" : @"window";
        if ([region isEqual:@"both"] || [region isEqual:@"display-both"]) {
            probe.region = @"left";
            probe.rightProbe = [WindowFrameProbe new];
            probe.rightProbe.captureMode = probe.captureMode;
            probe.rightProbe.region = @"right"; probe.rightProbe.lock = [NSLock new];
            probe.rightProbe.rows = [NSMutableArray new]; probe.rightProbe.rejectReasons = [NSMutableDictionary new];
        }
        [SCShareableContent getShareableContentExcludingDesktopWindows:YES onScreenWindowsOnly:YES completionHandler:^(SCShareableContent *content,NSError *error) {
            NSArray *windows = [content.windows filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SCWindow *window,NSDictionary *bindings) {
                return window.owningApplication.processID == pid && [window.title isEqual:title];
            }]];
            if (error || windows.count != 1) {
                fprintf(stderr,"Expected exactly one visible window owned by %d named %s: %s (found %lu)\n",pid,argv[2],error.localizedDescription.UTF8String ?: "",windows.count);
                probe.exitCode = 1; CFRunLoopStop(CFRunLoopGetMain()); return;
            }
            SCWindow *window = windows.firstObject;
            SCContentFilter *filter = [[SCContentFilter alloc] initWithDesktopIndependentWindow:window];
            SCStreamConfiguration *config = [SCStreamConfiguration new]; config.width = window.frame.size.width * 2; config.height = window.frame.size.height * 2;
            if (displayCapture) {
                CGPoint center = CGPointMake(CGRectGetMidX(window.frame), CGRectGetMidY(window.frame));
                NSArray *displays = [content.displays filteredArrayUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(SCDisplay *display, NSDictionary *bindings) {
                    return CGRectContainsPoint(display.frame, center);
                }]];
                if (displays.count != 1 || !CGRectContainsRect([displays.firstObject frame], window.frame)) {
                    fprintf(stderr,"Owned test window must fit entirely in one display\n");
                    probe.exitCode = 1; CFRunLoopStop(CFRunLoopGetMain()); return;
                }
                SCDisplay *display = displays.firstObject;
                filter = [[SCContentFilter alloc] initWithDisplay:display includingWindows:@[window]];
                config.sourceRect = CGRectOffset(window.frame, -display.frame.origin.x, -display.frame.origin.y);
            }
            config.pixelFormat = kCVPixelFormatType_32BGRA; config.queueDepth = 3;
            config.minimumFrameInterval = CMTimeMake(1,120); config.showsCursor = NO; config.capturesAudio = NO;
            probe.stream = [[SCStream alloc] initWithFilter:filter configuration:config delegate:probe];
            NSError *setupError = nil;
            if (![probe.stream addStreamOutput:probe type:SCStreamOutputTypeScreen sampleHandlerQueue:NULL error:&setupError]) {
                fprintf(stderr,"Capture output: %s\n",setupError.localizedDescription.UTF8String); probe.exitCode = 1; CFRunLoopStop(CFRunLoopGetMain()); return;
            }
            [probe.stream startCaptureWithCompletionHandler:^(NSError *startError) {
                if (startError) { fprintf(stderr,"Capture startup: %s\n",startError.localizedDescription.UTF8String); probe.exitCode = 1; CFRunLoopStop(CFRunLoopGetMain()); return; }
                [probe.lock lock]; probe.started = CACurrentMediaTime(); [probe.lock unlock];
                probe.rightProbe.started = probe.started;
                [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                    [NSTimer scheduledTimerWithTimeInterval:seconds+3 repeats:NO block:^(NSTimer *timer) { [probe finish]; }];
                }];
            }];
        }];
        CFRunLoopRun();
        return probe.exitCode;
    }
}
