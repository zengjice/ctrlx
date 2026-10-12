#import "CtrlxSimulatorBridge.h"
#import <xpc/xpc.h>

@interface CXSimulatorDevice (Input)
@property(nonatomic, readonly) xpc_endpoint_t inputEndpoint;
@property(nonatomic, readonly) xpc_object_t inputState;
- (void)cancelRotation;
@end
