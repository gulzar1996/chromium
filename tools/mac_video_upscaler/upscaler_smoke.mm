#import <Foundation/Foundation.h>
#import <CoreImage/CoreImage.h>
#include "media/gpu/mac/mac_video_upscaler.h"
#include <chrono>
#include <cstdio>

int main() {
  @autoreleasepool {
    CVPixelBufferRef raw = nullptr;
    NSDictionary* attrs = @{(id)kCVPixelBufferIOSurfacePropertiesKey:@{},
                            (id)kCVPixelBufferMetalCompatibilityKey:@YES};
    if (CVPixelBufferCreate(nullptr, 640, 360, kCVPixelFormatType_32BGRA,
                           (__bridge CFDictionaryRef)attrs, &raw)) return 1;
    auto source = media::MacVideoUpscaler::Retain(raw);
    CFRelease(raw);
    CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
    CVBufferSetAttachment(source.get(), kCVImageBufferCGColorSpaceKey, srgb, kCVAttachmentMode_ShouldPropagate);
    CGColorSpaceRelease(srgb);
    CVPixelBufferLockBaseAddress(source.get(), 0);
    auto* pixels = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(source.get()));
    for (int y = 0; y < 360; ++y) for (int x = 0; x < 640; ++x) {
      auto* p = pixels + y * CVPixelBufferGetBytesPerRow(source.get()) + x * 4;
      p[0] = y < 180 ? 0 : 255; p[1] = (x / 32 % 2) ? 100 : 0;
      p[2] = y < 180 ? 255 : 0; p[3] = 255;
    }
    CVPixelBufferUnlockBaseAddress(source.get(), 0);
    for (const char* backend : {"videotoolbox", "metalfx"}) {
      media::MacVideoUpscaler processor(backend);
      for (int i = 0; i < 4; ++i) {
        auto start = std::chrono::steady_clock::now();
        auto result = processor.Process(source, CMTimeMake(i, 30));
        double ms = std::chrono::duration<double, std::milli>(std::chrono::steady_clock::now()-start).count();
        fprintf(stderr, "%s frame=%d enhanced=%d %zux%zu %.2fms %s\n", backend, i, result.enhanced,
                CVPixelBufferGetWidth(result.buffer.get()), CVPixelBufferGetHeight(result.buffer.get()), ms, result.status.c_str());
        if (!result.enhanced || CVPixelBufferGetWidth(result.buffer.get()) != 1280 ||
            CVPixelBufferGetHeight(result.buffer.get()) != 720 || !CVPixelBufferGetIOSurface(result.buffer.get())) return 2;
        if (i == 3) {
          CIContext* context = [CIContext context];
          CVPixelBufferRef check = nullptr;
          if (CVPixelBufferCreate(nullptr,1280,720,kCVPixelFormatType_32BGRA,
              (__bridge CFDictionaryRef)attrs,&check)) return 5;
          [context render:[CIImage imageWithCVPixelBuffer:result.buffer.get()] toCVPixelBuffer:check];
          CVPixelBufferLockBaseAddress(check,kCVPixelBufferLock_ReadOnly);
          auto* top = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(check)) + 50*CVPixelBufferGetBytesPerRow(check) + 20*4;
          bool orientation_ok = top[2] > 180 && top[0] < 60;
          CVPixelBufferUnlockBaseAddress(check,kCVPixelBufferLock_ReadOnly);
          CFRelease(check);
          if (!orientation_ok) { fprintf(stderr,"Incorrect orientation or color channels\n"); return 6; }
          NSURL* url = [NSURL fileURLWithPath:[NSString stringWithFormat:@"/tmp/chromium-upscaler-%s.png", backend]];
          CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
          NSError* error = nil;
          BOOL ok = [context writePNGRepresentationOfImage:[CIImage imageWithCVPixelBuffer:result.buffer.get()]
                                                   toURL:url format:kCIFormatRGBA8 colorSpace:space options:@{} error:&error];
          CGColorSpaceRelease(space);
          if (!ok) { NSLog(@"%@", error); return 3; }
        }
      }
      // Exercise the decoder's NV12 path as well as RGB input.
      CVPixelBufferRef nv12 = nullptr;
      if (CVPixelBufferCreate(nullptr,640,360,kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
          (__bridge CFDictionaryRef)attrs,&nv12)) return 7;
      CVBufferSetAttachment(nv12,kCVImageBufferColorPrimariesKey,kCVImageBufferColorPrimaries_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
      CVBufferSetAttachment(nv12,kCVImageBufferTransferFunctionKey,kCVImageBufferTransferFunction_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
      CVBufferSetAttachment(nv12,kCVImageBufferYCbCrMatrixKey,kCVImageBufferYCbCrMatrix_ITU_R_709_2,kCVAttachmentMode_ShouldPropagate);
      [[CIContext context] render:[CIImage imageWithCVPixelBuffer:source.get()] toCVPixelBuffer:nv12];
      auto yuv = processor.Process(media::MacVideoUpscaler::Retain(nv12),CMTimeMake(20,30));
      CFRelease(nv12);
      if (!yuv.enhanced) return 8;
      // Reconfigure to 1080p. On this M4 Pro the low-latency scaler must
      // explicitly fall back; MetalFX should produce a 4K IOSurface.
      CVPixelBufferRef large = nullptr;
      if (CVPixelBufferCreate(nullptr,1920,1080,kCVPixelFormatType_32BGRA,
          (__bridge CFDictionaryRef)attrs,&large)) return 9;
      [[CIContext context] render:[[CIImage imageWithColor:[CIColor colorWithRed:1 green:0 blue:0]]
          imageByCroppingToRect:CGRectMake(0,0,1920,1080)] toCVPixelBuffer:large];
      auto resized = processor.Process(media::MacVideoUpscaler::Retain(large),CMTimeMake(21,30));
      if (std::string(backend) == "metalfx" && (!resized.enhanced || CVPixelBufferGetWidth(resized.buffer.get()) != 3840)) return 10;
      if (!resized.enhanced && resized.buffer.get() != large) return 11;
      fprintf(stderr,"%s 1080p enhanced=%d %s\n",backend,resized.enhanced,resized.status.c_str());
      CFRelease(large);
      // A seek back and resolution change must recreate a usable session.
      if (!processor.Process(source,CMTimeMake(0,30)).enhanced) return 12;
      CVBufferSetAttachment(source.get(), kCVImageBufferTransferFunctionKey,
                            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ, kCVAttachmentMode_ShouldPropagate);
      auto hdr = processor.Process(source, CMTimeMake(4,30));
      if (hdr.enhanced || hdr.buffer.get() != source.get()) return 4;
      CVBufferRemoveAttachment(source.get(), kCVImageBufferTransferFunctionKey);
    }
  }
  return 0;
}
