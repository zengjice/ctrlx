#import <CoreGraphics/CoreGraphics.h>
#import <IOSurface/IOSurface.h>

// Keep the BGRA surface immutable until the returned image is released.
CGImageRef CXSimulatorCreateScreenshotImage(IOSurfaceRef surface, int orientation) CF_RETURNS_RETAINED;
