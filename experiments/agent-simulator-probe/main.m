#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>
#import <objc/message.h>
#import <objc/runtime.h>
#import <CoreImage/CoreImage.h>
#import <ImageIO/ImageIO.h>
#import "CtrlxSimulatorBridge.h"
#include <libproc.h>
#include <stdatomic.h>
#include <dlfcn.h>

static id get(id object, NSString *name) {
    return ((id (*)(id, SEL))objc_msgSend)(object, NSSelectorFromString(name));
}

static void describe(id object) {
    fprintf(stderr, "CLASS %s\n", object_getClassName(object));
    unsigned count = 0;
    Method *methods = class_copyMethodList(object_getClass(object), &count);
    for (unsigned i = 0; i < count; i++) {
        fprintf(stderr, "  %s %s\n", sel_getName(method_getName(methods[i])), method_getTypeEncoding(methods[i]));
    }
    free(methods);
}

static void writeFrame(IOSurfaceRef surface, NSString *path) {
    CIImage *image = [CIImage imageWithIOSurface:surface];
    CGImageRef cg = [[CIContext contextWithOptions:nil] createCGImage:image fromRect:image.extent];
    CGImageDestinationRef output = CGImageDestinationCreateWithURL((__bridge CFURLRef)[NSURL fileURLWithPath:path], CFSTR("public.png"), 1, NULL);
    if (cg && output) { CGImageDestinationAddImage(output, cg, NULL); CGImageDestinationFinalize(output); }
    if (output) CFRelease(output);
    if (cg) CGImageRelease(cg);
}

static int launchctl(NSArray<NSString *> *arguments) {
    NSTask *task = [NSTask new]; task.executableURL = [NSURL fileURLWithPath:@"/bin/launchctl"]; task.arguments = arguments;
    NSError *error = nil;
    if (![task launchAndReturnError:&error]) { NSLog(@"launchctl %@", error); return 1; }
    [task waitUntilExit]; return task.terminationStatus;
}

static int workerProbe(NSString *developer, NSString *set, NSString *udid) {
    NSString *service = [@"com.jicezeng.ctrlx.simulator.probe." stringByAppendingString:NSUUID.UUID.UUIDString];
    NSString *domain = [NSString stringWithFormat:@"gui/%u", getuid()];
    NSString *root = [NSFileManager.defaultManager.currentDirectoryPath stringByAppendingPathComponent:@".build-local/agent-simulator"];
    NSString *plist = [root stringByAppendingPathComponent:@"probe-worker.plist"];
    struct proc_bsdinfo info = {0};
    if (proc_pidinfo(getpid(), PROC_PIDTBSDINFO, 0, &info, sizeof(info)) != sizeof(info)) return 1;
    NSDictionary *job = @{@"Label":service, @"MachServices":@{service:@YES}, @"RunAtLoad":@YES,
        @"ProgramArguments":@[[root stringByAppendingPathComponent:@"CtrlxSimulatorHost"], service, developer, set, udid, @"worker", [NSString stringWithFormat:@"%d", getpid()], [NSString stringWithFormat:@"%llu", info.pbi_start_tvsec], [NSString stringWithFormat:@"%llu", info.pbi_start_tvusec]],
        @"StandardErrorPath":[root stringByAppendingPathComponent:@"probe-worker.log"]};
    NSData *data = [NSPropertyListSerialization dataWithPropertyList:job format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
    [data writeToFile:plist atomically:YES];
    if (launchctl(@[@"bootstrap", domain, plist])) return 1;
    __block atomic_uint frames = 0;
    __block atomic_bool connected = false;
    CXSimulatorConnection *connection = [[CXSimulatorConnection alloc] initWithServiceName:service frameHandler:^(CXSimulatorFrame *frame) {
        unsigned number = atomic_fetch_add(&frames, 1)+1;
        if (number == 1 || number == 30) {
            writeFrame(frame.surface, [NSString stringWithFormat:@"/tmp/ctrlx-simulator-worker-%u.png", number]);
            NSLog(@"XPC FRAME %u %@", number, frame.metadata);
        }
        [frame finish];
    } errorHandler:^(NSString *message) { NSLog(@"WORKER ERROR %@",message); }];
    [connection request:@{@"command":@"subscribe"} reply:^(NSDictionary *result, NSError *error) { NSLog(@"XPC SUBSCRIBE %@ %@", result, error); }];
    [connection request:@{@"command":@"connect"} reply:^(NSDictionary *result, NSError *error) {
        NSLog(@"XPC CONNECT %@ %@", result, error);
        connected = result != nil;
    }];
    [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:10]];
    [connection invalidate];
    launchctl(@[@"bootout", [domain stringByAppendingFormat:@"/%@", service]]);
    NSLog(@"XPC EXERCISE frames=%u connected=%d", atomic_load(&frames), atomic_load(&connected));
    return atomic_load(&frames) && atomic_load(&connected) ? 0 : 1;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 4 && argc != 5) { fprintf(stderr, "usage: probe developer-dir device-set udid [exercise]\n"); return 2; }
        NSString *developer = @(argv[1]);
        if (argc == 5 && [@(argv[4]) isEqual:@"worker"]) return workerProbe(developer, @(argv[2]), @(argv[3]));
        NSString *core = @"/Library/Developer/PrivateFrameworks/CoreSimulator.framework/CoreSimulator";
        if (!dlopen(core.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL)) {
            fprintf(stderr, "CoreSimulator: %s\n", dlerror()); return 1;
        }
        NSString *kit = [[developer stringByDeletingLastPathComponent] stringByAppendingPathComponent:@"SharedFrameworks/SimulatorKit.framework/SimulatorKit"];
        if (!dlopen(kit.fileSystemRepresentation, RTLD_NOW | RTLD_GLOBAL)) fprintf(stderr, "SimulatorKit: %s\n", dlerror());
        NSError *error = nil;
        id context = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(NSClassFromString(@"SimServiceContext"), NSSelectorFromString(@"sharedServiceContextForDeveloperDir:error:"), developer, &error);
        id set = ((id (*)(id, SEL, id, NSError **))objc_msgSend)(context, NSSelectorFromString(@"deviceSetWithPath:error:"), @(argv[2]), &error);
        id device = nil;
        for (id candidate in get(set, @"devices")) {
            if ([[get(candidate, @"UDID") UUIDString] caseInsensitiveCompare:@(argv[3])] == NSOrderedSame) { device = candidate; break; }
        }
        if (!device) { fprintf(stderr, "device: %s\n", error.description.UTF8String); return 1; }
        fprintf(stderr, "CoreSimulator %s, device %s\n", [[[NSBundle bundleForClass:NSClassFromString(@"SimDevice")] objectForInfoDictionaryKey:@"CFBundleVersion"] UTF8String], [get(device, @"name") UTF8String]);
        describe(get(device, @"io"));
        for (id port in get(get(device, @"io"), @"ioPorts")) {
            describe(port);
            id descriptor = get(port, @"descriptor");
            describe(descriptor);
            fprintf(stderr, "display protocol: %d\n", [descriptor conformsToProtocol:NSProtocolFromString(@"SimDisplayIOSurfaceRenderable")]);
            if ([descriptor conformsToProtocol:NSProtocolFromString(@"SimDisplayIOSurfaceRenderable")]) {
                id properties = get(descriptor, @"screenProperties");
                fprintf(stderr, "SCREEN %s\n", [properties description].UTF8String);
                fprintf(stderr, "SCREEN-ID %lu\n", ((unsigned long (*)(id, SEL))objc_msgSend)(properties, NSSelectorFromString(@"screenID")));
                fprintf(stderr, "SCREEN-UNIQUE %s\n", [get(properties, @"uniqueId") description].UTF8String);
            }
        }
        unsigned count = 0;
        Class *classes = objc_copyClassList(&count);
        for (unsigned i = 0; i < count; i++) {
            NSString *name = NSStringFromClass(classes[i]);
            if ([name hasPrefix:@"SimulatorKit."] && ([name containsString:@"Keyboard"] || [name containsString:@"Text"] || [name containsString:@"HID"])) {
                describe(classes[i]);
                unsigned n = 0; Method *methods = class_copyMethodList(classes[i], &n);
                for (unsigned j = 0; j < n; j++) fprintf(stderr, " INSTANCE %s %s\n", sel_getName(method_getName(methods[j])), method_getTypeEncoding(methods[j]));
                free(methods);
            }
        }
        free(classes);
        unsigned int machPort = ((unsigned int (*)(id, SEL, id, NSError **))objc_msgSend)(device, NSSelectorFromString(@"lookup:error:"), @"com.apple.coredevice.feature.remote.hid.digitizer", &error);
        fprintf(stderr, "DTUHID port %u error %s\n", machPort, error.description.UTF8String);
        if (argc == 5 && ([@(argv[4]) isEqual:@"paste"] || [@(argv[4]) isEqual:@"allow-paste"])) {
            BOOL allowPaste = [@(argv[4]) isEqual:@"allow-paste"];
            CXSimulatorDevice *bridge = [[CXSimulatorDevice alloc] initWithDeveloperDirectory:developer deviceSet:@(argv[2]) identifier:@(argv[3]) error:&error];
            [bridge connectInput:^(NSDictionary *result, NSError *failure) {
                NSLog(@"PASTE CONNECT %@ %@",result,failure);
                if (!result) return;
                NSArray *point = @[@{@"x":allowPaste ? @0.335 : @0.5,@"y":allowPaste ? @0.575 : @0.25}];
                [bridge sendTouch:point phase:0 error:NULL];
                [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:NO block:^(NSTimer *timer) {
                    [bridge sendTouch:point phase:2 error:NULL];
                    if (allowPaste) return;
                    [NSTimer scheduledTimerWithTimeInterval:0.5 repeats:NO block:^(NSTimer *timer) {
                        [bridge sendKey:227 down:YES error:NULL];
                        [bridge sendKey:25 down:YES error:NULL];
                        [bridge sendKey:25 down:NO error:NULL];
                        [bridge sendKey:227 down:NO error:NULL];
                    }];
                }];
            }];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:5]];
            return 0;
        }
        if (argc == 5 && [@(argv[4]) isEqual:@"text"]) {
            CXSimulatorDevice *bridge = [[CXSimulatorDevice alloc] initWithDeveloperDirectory:developer deviceSet:@(argv[2]) identifier:@(argv[3]) error:&error];
            [bridge connectInput:^(NSDictionary *result, NSError *failure) {
                NSLog(@"TEXT CONNECT %@ %@", result, failure);
                if (!result) return;
                [[NSOperationQueue mainQueue] addOperationWithBlock:^{
                    [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:NO block:^(NSTimer *timer) {
                        [bridge sendTouch:@[@{@"x":@0.5,@"y":@0.25}] phase:0 error:NULL];
                        [NSTimer scheduledTimerWithTimeInterval:0.05 repeats:NO block:^(NSTimer *timer) {
                            [bridge sendTouch:@[@{@"x":@0.5,@"y":@0.25}] phase:2 error:NULL];
                            [NSTimer scheduledTimerWithTimeInterval:0.3 repeats:NO block:^(NSTimer *timer) {
                                [NSThread detachNewThreadWithBlock:^{
                                    NSError *failure = nil;
                                    NSDictionary *snapshot = [bridge snapshotWithLimit:200 timeout:2 error:&failure];
                                    NSLog(@"TEXT SNAPSHOT %@ %@", snapshot, failure);
                                    id translator = [bridge valueForKey:@"_translator"];
                                    id application = ((id (*)(id, SEL, unsigned, id))objc_msgSend)(translator,NSSelectorFromString(@"frontmostApplicationWithDisplayId:bridgeDelegateToken:"),0,@(argv[3]));
                                    id root = ((id (*)(id, SEL, id))objc_msgSend)(translator,NSSelectorFromString(@"macPlatformElementFromTranslation:"),application);
                                    NSMutableArray *pending = [NSMutableArray arrayWithObject:root];
                                    while (pending.count) {
                                        id element = pending.lastObject; [pending removeLastObject];
                                        ((void (*)(id, SEL, id))objc_msgSend)(get(element,@"translation"),NSSelectorFromString(@"setBridgeDelegateToken:"),@(argv[3]));
                                        if ([get(element,@"accessibilityIdentifier") isEqual:@"fixture.plain"]) {
                                            BOOL selected = ((BOOL (*)(id, SEL, id))objc_msgSend)(element,NSSelectorFromString(@"accessibilityIsAttributeSettable:"),@"AXSelectedText");
                                            BOOL value = ((BOOL (*)(id, SEL, id))objc_msgSend)(element,NSSelectorFromString(@"accessibilityIsAttributeSettable:"),@"AXValue");
                                            NSLog(@"TEXT SETTABLE selected=%d value=%d",selected,value);
                                            if (selected) ((void (*)(id, SEL, id, id))objc_msgSend)(element,NSSelectorFromString(@"accessibilitySetValue:forAttribute:"),@"测试文字 🙂",@"AXSelectedText");
                                            else if (value) ((void (*)(id, SEL, id))objc_msgSend)(element,NSSelectorFromString(@"setAccessibilityValue:"),@"测试文字 🙂");
                                            NSLog(@"TEXT AFTER %@", get(element,@"accessibilityValue"));
                                            break;
                                        }
                                        NSArray *children = get(element,@"accessibilityChildren");
                                        if (children) [pending addObjectsFromArray:children];
                                    }
                                }];
                            }];
                        }];
                    }];
                }];
            }];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:10]];
            return 0;
        }
        if (argc == 5) {
            CXSimulatorDevice *bridge = [[CXSimulatorDevice alloc] initWithDeveloperDirectory:developer deviceSet:@(argv[2]) identifier:@(argv[3]) error:&error];
            if (!bridge) { NSLog(@"BRIDGE %@", error); return 1; }
            __block atomic_uint frames = 0;
            BOOL display = [bridge startDisplay:^(IOSurfaceRef surface, NSDictionary *geometry) {
                unsigned number = atomic_fetch_add(&frames, 1)+1;
                if (number == 1 || number == 30) {
                    CIImage *image = [CIImage imageWithIOSurface:surface];
                    CGImageRef cg = [[CIContext contextWithOptions:nil] createCGImage:image fromRect:image.extent];
                    NSURL *url = [NSURL fileURLWithPath:[NSString stringWithFormat:@"/tmp/ctrlx-simulator-frame-%u.png", number]];
                    CGImageDestinationRef output = CGImageDestinationCreateWithURL((__bridge CFURLRef)url, CFSTR("public.png"), 1, NULL);
                    if (cg && output) { CGImageDestinationAddImage(output, cg, NULL); CGImageDestinationFinalize(output); }
                    if (output) CFRelease(output);
                    if (cg) CGImageRelease(cg);
                    NSLog(@"FRAME %u %@ %@", number, geometry, url.path);
                }
            } error:&error];
            if (!display) { NSLog(@"DISPLAY %@", error); return 1; }
            __block atomic_bool ready = false;
            [NSThread detachNewThreadWithBlock:^{
                NSError *failure = nil;
                NSDictionary *snapshot = [bridge snapshotWithLimit:200 timeout:2 error:&failure];
                NSLog(@"AX %@ %@", snapshot, failure);
            }];
            [bridge connectInput:^(NSDictionary *result, NSError *failure) {
                NSLog(@"INPUT %@ %@", result, failure);
                ready = result != nil;
                if (ready) {
                    NSError *inputError = nil;
                    [bridge sendTouch:@[@{@"x":@0.5,@"y":@0.5}] phase:0 error:&inputError];
                    [bridge sendTouch:@[@{@"x":@0.5,@"y":@0.5}] phase:2 error:&inputError];
                    NSLog(@"TOUCH %@", inputError);
                }
            }];
            [[NSRunLoop currentRunLoop] runUntilDate:[NSDate dateWithTimeIntervalSinceNow:10]];
            [bridge stopDisplay];
            NSLog(@"EXERCISE frames=%u inputReady=%d", frames, ready);
            return frames > 0 && ready ? 0 : 1;
        }
        return 0;
    }
}
