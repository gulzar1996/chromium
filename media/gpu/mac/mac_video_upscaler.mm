// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#include "mac_video_upscaler.h"

#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#import <MetalFX/MetalFX.h>
#import <VideoToolbox/VideoToolbox.h>

#include <utility>

namespace media {
namespace {
using Buffer = MacVideoUpscaler::Buffer;
Buffer Allocate(size_t width,
                size_t height,
                OSType format,
                NSDictionary* requirements = nil) {
  NSMutableDictionary* attributes = requirements
                                        ? [requirements mutableCopy]
                                        : [NSMutableDictionary dictionary];
  attributes[(id)kCVPixelBufferWidthKey] = @(width);
  attributes[(id)kCVPixelBufferHeightKey] = @(height);
  attributes[(id)kCVPixelBufferPixelFormatTypeKey] = @(format);
  attributes[(id)kCVPixelBufferIOSurfacePropertiesKey] = @{};
  attributes[(id)kCVPixelBufferMetalCompatibilityKey] = @YES;
  CVPixelBufferRef buffer = nullptr;
  if (CVPixelBufferCreate(kCFAllocatorDefault, width, height, format,
                          (__bridge CFDictionaryRef)attributes,
                          &buffer) != kCVReturnSuccess) {
    return {};
  }
  return Buffer(buffer, CVPixelBufferRelease);
}
void Set709(CVPixelBufferRef buffer) {
  CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey,
                        kCVImageBufferColorPrimaries_ITU_R_709_2,
                        kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey,
                        kCVImageBufferTransferFunction_ITU_R_709_2,
                        kCVAttachmentMode_ShouldPropagate);
  CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                        kCVImageBufferYCbCrMatrix_ITU_R_709_2,
                        kCVAttachmentMode_ShouldPropagate);
}
}  // namespace

struct MacVideoUpscaler::Impl {
  explicit Impl(std::string value) : backend(std::move(value)) {}
  ~Impl() {
    if (@available(macOS 26.0, *)) {
      [processor endSession];
    }
    if (texture_cache) {
      CFRelease(texture_cache);
    }
    if (srgb) {
      CGColorSpaceRelease(srgb);
    }
  }
  std::string backend;
  std::string last_status;
  size_t width = 0, height = 0;
  bool ready = false;
  id<MTLDevice> device;
  id<MTLCommandQueue> queue;
  CIContext* context;
  CGColorSpaceRef srgb = nullptr;
  CVMetalTextureCacheRef texture_cache = nullptr;
  id<MTLFXSpatialScaler> scaler;
  id<MTLTexture> input_texture;
  VTFrameProcessor* processor API_AVAILABLE(macos(26.0));
  VTLowLatencySuperResolutionScalerConfiguration* config
      API_AVAILABLE(macos(26.0));

  bool Configure(size_t w, size_t h, std::string& reason) {
    width = w;
    height = h;
    ready = false;
    if (@available(macOS 26.0, *)) {
      [processor endSession];
      processor = nil;
      config = nil;
    }
    scaler = nil;
    input_texture = nil;
    if (!device) {
      device = MTLCreateSystemDefaultDevice();
      queue = [device newCommandQueue];
      if (device) {
        context = [CIContext contextWithMTLDevice:device
                                          options:@{
                                            kCIContextCacheIntermediates : @NO
                                          }];
      }
      srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
      if (device) {
        CVMetalTextureCacheCreate(kCFAllocatorDefault, nullptr, device, nullptr,
                                  &texture_cache);
      }
    }
    if (!device || !queue || !context || !texture_cache) {
      reason = "Metal initialization failed; displaying original frames";
      return false;
    }
    if (backend == "videotoolbox") {
      if (@available(macOS 26.0, *)) {
        if (![VTLowLatencySuperResolutionScalerConfiguration isSupported] ||
            ![[VTLowLatencySuperResolutionScalerConfiguration
                supportedScaleFactorsForFrameWidth:w
                                       frameHeight:h] containsObject:@2.0]) {
          reason = "VideoToolbox does not support 2x at this input size; "
                   "displaying original frames";
          return false;
        }
        config = [[VTLowLatencySuperResolutionScalerConfiguration alloc]
            initWithFrameWidth:w
                   frameHeight:h
                   scaleFactor:2.0];
        processor = [[VTFrameProcessor alloc] init];
        NSError* error = nil;
        if (![processor startSessionWithConfiguration:config error:&error]) {
          reason = "VideoToolbox setup failed: " +
                   std::string(error.localizedDescription.UTF8String
                                   ?: "unknown error");
          return false;
        }
      } else {
        reason = "VideoToolbox low-latency scaling requires macOS 26";
        return false;
      }
    } else if (backend == "metalfx") {
      if (![MTLFXSpatialScalerDescriptor supportsDevice:device]) {
        reason = "MetalFX spatial scaling is unsupported on this GPU";
        return false;
      }
      MTLFXSpatialScalerDescriptor* descriptor =
          [[MTLFXSpatialScalerDescriptor alloc] init];
      descriptor.inputWidth = w;
      descriptor.inputHeight = h;
      descriptor.outputWidth = w * 2;
      descriptor.outputHeight = h * 2;
      descriptor.colorTextureFormat = MTLPixelFormatBGRA8Unorm;
      descriptor.outputTextureFormat = MTLPixelFormatBGRA8Unorm;
      descriptor.colorProcessingMode =
          MTLFXSpatialScalerColorProcessingModePerceptual;
      scaler = [descriptor newSpatialScalerWithDevice:device];
      MTLTextureDescriptor* input = [MTLTextureDescriptor
          texture2DDescriptorWithPixelFormat:MTLPixelFormatBGRA8Unorm
                                       width:w
                                      height:h
                                   mipmapped:NO];
      input.storageMode = MTLStorageModePrivate;
      input.usage = MTLTextureUsageShaderRead | MTLTextureUsageShaderWrite |
                    MTLTextureUsageRenderTarget;
      input_texture = [device newTextureWithDescriptor:input];
      if (!scaler || !input_texture) {
        reason = "MetalFX allocation failed; displaying original frames";
        return false;
      }
    } else {
      reason = "Upscaling disabled";
      return false;
    }
    ready = true;
    reason = backend + " 2x active at " + std::to_string(w) + "x" +
             std::to_string(h);
    return true;
  }

  Buffer Run(CVPixelBufferRef source, CMTime timestamp, std::string& reason) {
    if (backend == "videotoolbox") {
      if (@available(macOS 26.0, *)) {
        // Use the documented format and attributes; decoder outputs can be
        // full-range NV12 or a different YUV layout.
        NSDictionary* attrs = config.sourcePixelBufferAttributes;
        id fmt = attrs[(id)kCVPixelBufferPixelFormatTypeKey];
        if ([fmt isKindOfClass:[NSArray class]]) {
          fmt = [fmt firstObject];
        }
        OSType pixel_format =
            fmt ? [fmt unsignedIntValue]
                : kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange;
        Buffer input = Allocate(width, height, pixel_format, attrs);
        NSDictionary* out_attrs = config.destinationPixelBufferAttributes;
        id out_fmt = out_attrs[(id)kCVPixelBufferPixelFormatTypeKey];
        if ([out_fmt isKindOfClass:[NSArray class]]) {
          out_fmt = [out_fmt firstObject];
        }
        Buffer output = Allocate(
            width * 2, height * 2,
            out_fmt ? [out_fmt unsignedIntValue] : pixel_format, out_attrs);
        if (!input || !output) {
          reason = "VideoToolbox pixel buffer allocation failed";
          return {};
        }
        Set709(input.get());
        Set709(output.get());
        [context render:[CIImage imageWithCVPixelBuffer:source]
            toCVPixelBuffer:input.get()];
        CVPixelBufferFillExtendedPixels(input.get());
        VTFrameProcessorFrame* in_frame =
            [[VTFrameProcessorFrame alloc] initWithBuffer:input.get()
                                    presentationTimeStamp:timestamp];
        VTFrameProcessorFrame* out_frame =
            [[VTFrameProcessorFrame alloc] initWithBuffer:output.get()
                                    presentationTimeStamp:timestamp];
        if (!in_frame || !out_frame) {
          reason = "VideoToolbox frame wrapping failed";
          return {};
        }
        VTLowLatencySuperResolutionScalerParameters* parameters =
            [[VTLowLatencySuperResolutionScalerParameters alloc]
                initWithSourceFrame:in_frame
                   destinationFrame:out_frame];
        NSError* error = nil;
        if (![processor processWithParameters:parameters error:&error]) {
          reason = "VideoToolbox processing failed: " +
                   std::string(error.localizedDescription.UTF8String
                                   ?: "unknown error");
          return {};
        }
        return output;
      }
    } else if (backend == "metalfx") {
      Buffer output =
          Allocate(width * 2, height * 2, kCVPixelFormatType_32BGRA);
      if (!output) {
        reason = "MetalFX output allocation failed";
        return {};
      }
      CVBufferSetAttachment(output.get(), kCVImageBufferCGColorSpaceKey, srgb,
                            kCVAttachmentMode_ShouldPropagate);
      CVMetalTextureRef wrapped = nullptr;
      CVReturn status = CVMetalTextureCacheCreateTextureFromImage(
          kCFAllocatorDefault, texture_cache, output.get(), nullptr,
          MTLPixelFormatBGRA8Unorm, width * 2, height * 2, 0, &wrapped);
      if (status != kCVReturnSuccess || !wrapped) {
        reason = "MetalFX IOSurface texture creation failed";
        return {};
      }
      id<MTLCommandBuffer> command = [queue commandBuffer];
      if (!command) {
        CFRelease(wrapped);
        reason = "MetalFX command buffer allocation failed";
        return {};
      }
      // Core Image uses a bottom-left texture origin; Chromium's IOSurface
      // presentation uses top-left. Flip before the MetalFX texture pass.
      CIImage* image = [[CIImage imageWithCVPixelBuffer:source]
          imageByApplyingTransform:CGAffineTransformMake(1, 0, 0, -1, 0,
                                                         height)];
      [context render:image
           toMTLTexture:input_texture
          commandBuffer:command
                 bounds:CGRectMake(0, 0, width, height)
             colorSpace:srgb];
      scaler.inputContentWidth = width;
      scaler.inputContentHeight = height;
      scaler.colorTexture = input_texture;
      scaler.outputTexture = CVMetalTextureGetTexture(wrapped);
      [scaler encodeToCommandBuffer:command];
      [command commit];
      [command waitUntilCompleted];  // Only on the dedicated worker sequence.
      bool succeeded =
          command && command.status == MTLCommandBufferStatusCompleted;
      CFRelease(wrapped);
      if (!succeeded) {
        reason = "MetalFX GPU command failed";
        return {};
      }
      return output;
    }
    return {};
  }
};

MacVideoUpscaler::MacVideoUpscaler(std::string backend)
    : impl_(std::make_unique<Impl>(std::move(backend))) {}
MacVideoUpscaler::~MacVideoUpscaler() = default;
bool MacVideoUpscaler::Prepare(size_t width,
                               size_t height,
                               std::string& reason) {
  @autoreleasepool {
    return impl_->Configure(width, height, reason);
  }
}
MacVideoUpscaler::Buffer MacVideoUpscaler::Retain(CVPixelBufferRef buffer) {
  return Buffer(CVPixelBufferRetain(buffer), CVPixelBufferRelease);
}
MacVideoUpscaler::Result MacVideoUpscaler::Process(Buffer source,
                                                   CMTime timestamp) {
  @autoreleasepool {
    Result result{source, false, {}};
    std::string reason;
    size_t w = CVPixelBufferGetWidth(source.get()),
           h = CVPixelBufferGetHeight(source.get());
    const OSType format = CVPixelBufferGetPixelFormatType(source.get());
    const CGRect clean = CVImageBufferGetCleanRect(source.get());
    // Limit the first implementation to uncropped 8-bit SDR. Preserve all
    // other frames untouched rather than silently clipping or tone mapping.
    CFTypeRef transfer = CVBufferCopyAttachment(
        source.get(), kCVImageBufferTransferFunctionKey, nullptr);
    bool hdr =
        transfer &&
        (CFEqual(transfer, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) ||
         CFEqual(transfer, kCVImageBufferTransferFunction_ITU_R_2100_HLG));
    if (transfer) {
      CFRelease(transfer);
    }
    if (hdr ||
        (format != kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
         format != kCVPixelFormatType_420YpCbCr8BiPlanarFullRange &&
         format != kCVPixelFormatType_32BGRA) ||
        !CGRectEqualToRect(clean, CGRectMake(0, 0, w, h)) || w % 2 || h % 2 ||
        w > 1920 || h > 1080) {
      reason = "Unsupported format, crop, HDR, or size (maximum 1920x1080); "
               "displaying original frames";
    } else {
      if (impl_->width != w || impl_->height != h) {
        impl_->Configure(w, h, reason);
      }
      if (impl_->ready) {
        Buffer enhanced = impl_->Run(source.get(), timestamp, reason);
        if (enhanced) {
          result.buffer = std::move(enhanced);
          result.enhanced = true;
        } else {
          impl_->ready =
              false;  // Do not retry a failing GPU operation every frame.
        }
      }
    }
    if (!reason.empty() && reason != impl_->last_status) {
      impl_->last_status = reason;
      result.status = std::move(reason);
    }
    return result;
  }
}
}  // namespace media
