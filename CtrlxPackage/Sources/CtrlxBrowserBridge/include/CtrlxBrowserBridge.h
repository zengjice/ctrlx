#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

// CEF stays in a separately built native library. Swift/SPM clients need only
// this small AppKit contract, never CEF headers or a downloaded SDK to compile.
@protocol CXBrowserHostDelegate <NSObject>
- (void)resolveBrowserProcess:(int)pid completion:(void (^)(NSDictionary<NSString *, NSString *> * _Nullable route, NSString * _Nullable error))completion;
- (nullable NSView *)browserContainerForRoute:(NSDictionary<NSString *, NSString *> *)route;
- (void)browserTabCreated:(NSString *)identifier view:(NSView *)view route:(NSDictionary<NSString *, NSString *> *)route owner:(NSString *)owner parent:(nullable NSString *)parent;
- (void)browserTabChanged:(NSString *)identifier title:(NSString *)title url:(NSString *)url loading:(BOOL)loading;
- (void)browserTabSelected:(NSString *)identifier;
- (void)browserTabClosed:(NSString *)identifier;
@end

@protocol CXBrowserRuntime <NSObject>
- (BOOL)startWithDelegate:(id<CXBrowserHostDelegate>)delegate profile:(NSString *)profile state:(NSString *)state error:(NSError **)error;
- (void)navigateTab:(NSString *)identifier url:(NSString *)url;
- (void)goBack:(NSString *)identifier;
- (void)goForward:(NSString *)identifier;
- (void)reloadTab:(NSString *)identifier;
- (void)showDevTools:(NSString *)identifier;
- (void)closeTab:(NSString *)identifier;
- (void)beginShutdown;
- (BOOL)finishShutdown;
@end

// Call before SwiftUI's App.main creates NSApplication. Absence of the optional
// native library is supported for ordinary SPM/tests and non-browser builds.
FOUNDATION_EXPORT BOOL CXBrowserPrepareApplication(void);
FOUNDATION_EXPORT id<CXBrowserRuntime> _Nullable CXBrowserCreateRuntime(void);
FOUNDATION_EXPORT NSString * _Nullable CXBrowserLoadError(void);
NS_ASSUME_NONNULL_END
