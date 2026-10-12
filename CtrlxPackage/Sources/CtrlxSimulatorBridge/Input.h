#import "CtrlxSimulatorBridge.h"
#import <xpc/xpc.h>

@interface CXSimulatorInput : NSObject
- (instancetype)initWithEndpoint:(xpc_endpoint_t)endpoint state:(xpc_object_t)state
                           epoch:(NSString *)epoch workerPID:(pid_t)workerPID
                    errorHandler:(CXSimulatorErrorHandler)errorHandler error:(NSError **)error;
- (void)connect:(CXSimulatorReply)reply;
- (void)request:(NSDictionary *)request reply:(CXSimulatorReply)reply;
- (void)cancel:(CXSimulatorReply)reply;
- (void)invalidate;
@end
