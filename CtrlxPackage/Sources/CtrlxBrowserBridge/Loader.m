#import "CtrlxBrowserBridge.h"
#include <dlfcn.h>

static void *library;
static NSString *loadError;

BOOL CXBrowserPrepareApplication(void) {
    NSString *path = [NSBundle.mainBundle.privateFrameworksPath stringByAppendingPathComponent:@"libCtrlXAgentBrowser.dylib"];
    if (![[NSFileManager defaultManager] fileExistsAtPath:path]) return NO;
    library = dlopen(path.fileSystemRepresentation, RTLD_NOW | RTLD_LOCAL);
    if (!library) { loadError = [NSString stringWithUTF8String:dlerror()]; return NO; }
    BOOL (*prepare)(void) = dlsym(library, "CXEmbeddedBrowserPrepareApplication");
    if (!prepare || !prepare()) {
        loadError = @"Browser application bootstrap must run before NSApplication is created.";
        return NO;
    }
    return YES;
}

id<CXBrowserRuntime> CXBrowserCreateRuntime(void) {
    if (!library || loadError) return nil;
    id (*create)(void) = dlsym(library, "CXEmbeddedBrowserCreateRuntime");
    return create ? create() : nil;
}
NSString *CXBrowserLoadError(void) { return loadError; }
