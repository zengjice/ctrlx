#import <Foundation/Foundation.h>
#import <IOSurface/IOSurface.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^CXSimulatorSurfaceHandler)(IOSurfaceRef surface, NSDictionary<NSString *, id> *geometry);
typedef void (^CXSimulatorReply)(NSDictionary<NSString *, id> * _Nullable result, NSError * _Nullable error);

// The caller keeps the copied surface immutable until encoding returns.
NSDictionary<NSString *, id> * _Nullable CXSimulatorCreatePreview(IOSurfaceRef surface, int orientation, NSUInteger maximumDimension);

@interface CXSimulatorDevice : NSObject
- (nullable instancetype)initWithDeveloperDirectory:(NSString *)developerDirectory
                                         deviceSet:(NSString *)deviceSet
                                        identifier:(NSString *)identifier
                                             error:(NSError **)error;
@property(nonatomic, readonly) NSDictionary<NSString *, id> *capabilities;
- (BOOL)startDisplay:(CXSimulatorSurfaceHandler)handler error:(NSError **)error;
- (void)stopDisplay;
- (nullable NSDictionary<NSString *, id> *)currentGeometry;
- (nullable NSDictionary<NSString *, id> *)cachedGeometry;
- (void)refreshDisplay;
- (void)connectInput:(CXSimulatorReply)reply;
- (BOOL)sendTouch:(NSArray<NSDictionary<NSString *, NSNumber *> *> *)points phase:(NSUInteger)phase error:(NSError **)error;
- (BOOL)sendKey:(NSUInteger)usage down:(BOOL)down error:(NSError **)error;
- (BOOL)sendButton:(NSUInteger)usage down:(BOOL)down error:(NSError **)error;
- (BOOL)cancelInput:(NSError **)error;
- (void)drainInput:(CXSimulatorReply)reply;
- (BOOL)rotateToOrientation:(NSUInteger)orientation error:(NSError **)error;
- (nullable NSDictionary<NSString *, id> *)snapshotWithLimit:(NSUInteger)limit timeout:(NSTimeInterval)timeout error:(NSError **)error;
- (nullable NSDictionary<NSString *, id> *)activationForProcessIdentifier:(int)processIdentifier timeout:(NSTimeInterval)timeout error:(NSError **)error;
@end

NS_SWIFT_SENDABLE
@interface CXSimulatorFrame : NSObject
@property(nonatomic, readonly) IOSurfaceRef surface;
@property(nonatomic, readonly) NSDictionary<NSString *, id> *metadata;
@property(nonatomic, readonly) NSData *metadataJSON;
// Present only when the worker enables frame tracing; wire metadata remains unchanged.
@property(nonatomic, readonly, nullable) NSDictionary<NSString *, NSNumber *> *deliveryTiming;
- (void)finish;
@end

typedef void (^ NS_SWIFT_SENDABLE CXSimulatorFrameHandler)(CXSimulatorFrame *frame);
typedef void (^ NS_SWIFT_SENDABLE CXSimulatorErrorHandler)(NSString *message);

typedef void (^ NS_SWIFT_SENDABLE CXSimulatorDataReply)(NSData * _Nullable result, NSError * _Nullable error);

NS_SWIFT_SENDABLE
@interface CXSimulatorConnection : NSObject
- (instancetype)initWithServiceName:(NSString *)serviceName
                       frameHandler:(CXSimulatorFrameHandler)frameHandler
                       errorHandler:(CXSimulatorErrorHandler)errorHandler;
- (void)request:(NSDictionary<NSString *, id> *)request reply:(CXSimulatorReply)reply;
- (void)requestData:(NSData *)data reply:(CXSimulatorDataReply)reply;
- (void)invalidate;
@end

int CXSimulatorHostRun(int argc, const char * _Nonnull * _Nonnull argv);

NS_ASSUME_NONNULL_END
