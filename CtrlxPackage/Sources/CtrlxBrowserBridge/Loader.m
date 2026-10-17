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

void CXBrowserSetTerminationDelegate(id<CXBrowserTerminationDelegate> delegate) {
    if (!library || loadError) return;
    void (*setDelegate)(id<CXBrowserTerminationDelegate>) = dlsym(library, "CXEmbeddedBrowserSetTerminationDelegate");
    if (setDelegate) setDelegate(delegate);
}

void CXBrowserSetDiagnosticsDelegate(id<CXApplicationDiagnosticsDelegate> delegate) {
    if (!library || loadError) return;
    void (*setDelegate)(id<CXApplicationDiagnosticsDelegate>) = dlsym(library, "CXEmbeddedBrowserSetDiagnosticsDelegate");
    if (setDelegate) setDelegate(delegate);
}

id<CXBrowserRuntime> CXBrowserCreateRuntime(void) {
    if (!library || loadError) return nil;
    id (*create)(void) = dlsym(library, "CXEmbeddedBrowserCreateRuntime");
    return create ? create() : nil;
}
NSString *CXBrowserLoadError(void) { return loadError; }
