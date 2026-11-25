#if defined(__OBJC__) && defined(__APPLE__)
#import <TargetConditionals.h>
#if TARGET_OS_IOS && !TARGET_OS_MACCATALYST
#import <MetalKit/MetalKit.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN
/// Renders a decoded NV12 video-range frame. Use one renderer per view.
API_AVAILABLE(ios(13.0))
@interface RCMetalRenderer : NSObject
- (nullable instancetype)initWithDevice:(id<MTLDevice>)device;
- (instancetype)init NS_UNAVAILABLE;
/// An absent frame clears the drawable.
- (BOOL)drawFrame:(nullable CVPixelBufferRef)frame
           inView:(MTKView *)view
         viewport:(CGRect)viewport NS_SWIFT_NAME(draw(frame:in:viewport:));
@end
NS_ASSUME_NONNULL_END
#endif
#endif
