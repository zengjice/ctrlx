#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol CXBrowserTerminationDelegate <NSObject>
- (BOOL)tryToTerminateWithoutModalLoop;
@end

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
- (BOOL)isReady;
- (nullable NSString *)startupError;
// Human-created tab: explicit local UI route and no agent control grant.
- (void)openManualTabWithRoute:(NSDictionary<NSString *, NSString *> *)route url:(NSString *)url completion:(void (^)(NSString * _Nullable error))completion NS_SWIFT_NAME(openManualTab(route:url:completion:));
- (void)navigateTab:(NSString *)identifier url:(NSString *)url;
- (void)goBack:(NSString *)identifier;
- (void)goForward:(NSString *)identifier;
- (void)reloadTab:(NSString *)identifier;
- (void)showDevTools:(NSString *)identifier;
- (void)closeTab:(NSString *)identifier;
// Private Host boundary: validated page operations, never a remote CDP tunnel.
- (BOOL)setHumanControl:(nullable NSString *)token forTab:(NSString *)identifier;
- (void)requestBrowserTab:(NSString *)identifier request:(NSData *)request completion:(void (^)(NSData * _Nullable result, NSString * _Nullable error))completion;
- (void)beginShutdown;
- (BOOL)finishShutdown;
@optional
// Human-only Chrome-style windows share this Host's profile. Older native
// bundles omit these selectors; callers must report unavailable capability.
- (void)openExtensionWindowForTab:(NSString *)identifier completion:(void (^)(NSString * _Nullable identifier, NSString * _Nullable error))completion NS_SWIFT_NAME(openExtensionWindow(forTab:completion:));
- (void)showExtensionManagerForTab:(NSString *)identifier completion:(void (^)(NSString * _Nullable error))completion NS_SWIFT_NAME(showExtensionManager(forTab:completion:));
- (void)showBrowserWindow:(NSString *)identifier;
- (void)requestBrowserExtensionsForTab:(NSString *)identifier request:(NSData *)request completion:(void (^)(NSData * _Nullable result, NSString * _Nullable error))completion NS_SWIFT_NAME(requestBrowserExtensions(forTab:request:completion:));
// Explicit profile/window grant. Ordinary page control cannot call this surface.
- (BOOL)setExtensionControl:(nullable NSString *)token forTab:(NSString *)identifier;
- (void)requestExtensionSurfaceForTab:(NSString *)identifier request:(NSData *)request completion:(void (^)(NSData * _Nullable result, NSString * _Nullable error))completion NS_SWIFT_NAME(requestExtensionSurface(forTab:request:completion:));
@end

// Call before SwiftUI's App.main creates NSApplication. Absence of the optional
// native library is supported for ordinary SPM/tests and non-browser builds.
FOUNDATION_EXPORT BOOL CXBrowserPrepareApplication(void);
FOUNDATION_EXPORT void CXBrowserSetTerminationDelegate(id<CXBrowserTerminationDelegate> delegate);
FOUNDATION_EXPORT id<CXBrowserRuntime> _Nullable CXBrowserCreateRuntime(void);
FOUNDATION_EXPORT NSString * _Nullable CXBrowserLoadError(void);
NS_ASSUME_NONNULL_END
