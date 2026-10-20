// SPDX-License-Identifier: MIT
// The iOS simulator SDK has no MetalFX, and the iPhoneOS SDK's headers of it
// need Metal 4, which the simulator's Metal does not declare either. This is
// the part of MetalFX's interface DXMT's winemetal_unix.c uses (its MetalFX
// upscalers and frame interpolation), so the file compiles for the simulator
// (tests/wine-i386/build-dxmt-unix.sh). The classes come from
// tests/wine-loader/host/metal-display.m, which reports that none of it is
// supported, so DXMT never creates a scaler or interpolator there.
#import <Metal/Metal.h>

@interface MTLFXSpatialScalerDescriptor : NSObject
@property(nonatomic) MTLPixelFormat colorTextureFormat;
@property(nonatomic) MTLPixelFormat outputTextureFormat;
@property(nonatomic) NSUInteger inputWidth, inputHeight, outputWidth, outputHeight;
+ (BOOL)supportsDevice:(id<MTLDevice>)device;
- (id)newSpatialScalerWithDevice:(id<MTLDevice>)device;
@end

@interface MTLFXTemporalScalerDescriptor : NSObject
@property(nonatomic) MTLPixelFormat colorTextureFormat, outputTextureFormat;
@property(nonatomic) MTLPixelFormat depthTextureFormat, motionTextureFormat;
@property(nonatomic) NSUInteger inputWidth, inputHeight, outputWidth, outputHeight;
@property(nonatomic) float inputContentMaxScale, inputContentMinScale;
@property(nonatomic) BOOL inputContentPropertiesEnabled, requiresSynchronousInitialization;
@property(nonatomic) BOOL autoExposureEnabled;
+ (BOOL)supportsDevice:(id<MTLDevice>)device;
- (id)newTemporalScalerWithDevice:(id<MTLDevice>)device;
@end

@interface MTLFXFrameInterpolatorDescriptor : NSObject
@property(nonatomic) MTLPixelFormat colorTextureFormat, outputTextureFormat;
@property(nonatomic) MTLPixelFormat depthTextureFormat, motionTextureFormat, uiTextureFormat;
@property(nonatomic) NSUInteger inputWidth, inputHeight, outputWidth, outputHeight;
+ (BOOL)supportsDevice:(id<MTLDevice>)device;
- (id)newFrameInterpolatorWithDevice:(id<MTLDevice>)device;
@end

@protocol MTLFXSpatialScaler <NSObject>
@property(nonatomic, retain) id<MTLTexture> colorTexture, outputTexture;
@property(nonatomic, retain) id<MTLFence> fence;
- (void)encodeToCommandBuffer:(id<MTLCommandBuffer>)commandBuffer;
@end

@protocol MTLFXTemporalScaler <NSObject>
@property(nonatomic, retain) id<MTLTexture> colorTexture, outputTexture, depthTexture;
@property(nonatomic, retain) id<MTLTexture> motionTexture, exposureTexture;
@property(nonatomic, retain) id<MTLFence> fence;
@property(nonatomic) NSUInteger inputContentWidth, inputContentHeight;
@property(nonatomic) BOOL reset, depthReversed;
@property(nonatomic) float motionVectorScaleX, motionVectorScaleY;
@property(nonatomic) float jitterOffsetX, jitterOffsetY, preExposure;
- (void)encodeToCommandBuffer:(id<MTLCommandBuffer>)commandBuffer;
@end

@protocol MTLFXFrameInterpolator <NSObject>
@property(nonatomic, retain) id<MTLTexture> colorTexture, prevColorTexture, depthTexture;
@property(nonatomic, retain) id<MTLTexture> motionTexture, outputTexture;
@property(nonatomic) float motionVectorScaleX, motionVectorScaleY, deltaTime;
@property(nonatomic) float nearPlane, farPlane, fieldOfView, aspectRatio;
@property(nonatomic) float jitterOffsetX, jitterOffsetY;
@property(nonatomic) BOOL shouldResetHistory;
@property(nonatomic, readonly) MTLTextureUsage colorTextureUsage, motionTextureUsage;
@property(nonatomic, readonly) MTLTextureUsage depthTextureUsage, outputTextureUsage;
- (void)encodeToCommandBuffer:(id<MTLCommandBuffer>)commandBuffer;
@end
