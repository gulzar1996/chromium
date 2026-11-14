// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license.
#include "mac_video_processor.h"

#import <CoreImage/CoreImage.h>
#import <Metal/Metal.h>
#import <VideoToolbox/VideoToolbox.h>

#include <algorithm>
#include <chrono>
#include <deque>
#include <utility>

namespace media {
namespace {
using Buffer = MacVideoProcessor::Buffer;
Buffer Allocate(size_t w, size_t h, NSDictionary* attributes) {
  if (!attributes) {
    return {};
  }
  id format = attributes[(id)kCVPixelBufferPixelFormatTypeKey];
  if ([format isKindOfClass:[NSArray class]]) {
    format = [format firstObject];
  }
  if (!format) {
    return {};
  }
  NSMutableDictionary* attrs = [attributes mutableCopy];
  attrs[(id)kCVPixelBufferIOSurfacePropertiesKey] = @{};
  attrs[(id)kCVPixelBufferMetalCompatibilityKey] = @YES;
  CVPixelBufferRef buffer = nullptr;
  if (CVPixelBufferCreate(kCFAllocatorDefault, w, h, [format unsignedIntValue],
                          (__bridge CFDictionaryRef)attrs,
                          &buffer) != kCVReturnSuccess) {
    return {};
  }
  return Buffer(buffer, CVPixelBufferRelease);
}
API_AVAILABLE(macos(26.0))
VTFrameProcessorFrame* Wrap(const Buffer& buffer, CMTime time) {
  if (!buffer) {
    return nil;
  }
  return [[VTFrameProcessorFrame alloc] initWithBuffer:buffer.get()
                                 presentationTimeStamp:time];
}
bool Supported(CVPixelBufferRef source) {
  auto w = CVPixelBufferGetWidth(source), h = CVPixelBufferGetHeight(source);
  auto format = CVPixelBufferGetPixelFormatType(source);
  auto transfer = CVBufferCopyAttachment(
      source, kCVImageBufferTransferFunctionKey, nullptr);
  bool hdr =
      transfer &&
      (CFEqual(transfer, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ) ||
       CFEqual(transfer, kCVImageBufferTransferFunction_ITU_R_2100_HLG));
  if (transfer) {
    CFRelease(transfer);
  }
  return !hdr && w && h && w <= 1920 && h <= 1080 && !(w % 2) && !(h % 2) &&
         CGRectEqualToRect(CVImageBufferGetCleanRect(source),
                           CGRectMake(0, 0, w, h)) &&
         (format == kCVPixelFormatType_32BGRA ||
          format == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange ||
          format == kCVPixelFormatType_420YpCbCr8BiPlanarFullRange);
}
std::string Error(NSError* error) {
  return error ? std::string(error.localizedDescription.UTF8String
                                 ?: "Apple processing error")
               : "Unsupported configuration or buffer requirements";
}
}  // namespace

struct MacVideoProcessor::Impl {
  explicit Impl(MacVideoEffectsSettings value) : settings(value) {}
  ~Impl() {
    if (@available(macOS 26.0, *)) {
      [noise endSession];
      [motion endSession];
    }
  }
  MacVideoEffectsSettings settings;
  size_t width = 0, height = 0;
  CIContext* context;
  VTFrameProcessor* noise API_AVAILABLE(macos(26.0));
  VTTemporalNoiseFilterConfiguration* noise_config API_AVAILABLE(macos(26.0));
  VTFrameProcessor* motion API_AVAILABLE(macos(26.0));
  VTLowLatencyFrameInterpolationConfiguration* low_config
      API_AVAILABLE(macos(26.0));
  VTFrameRateConversionConfiguration* quality_config API_AVAILABLE(macos(26.0));
  std::unique_ptr<MacVideoUpscaler> scaler;
  bool scale_ready = false;
  bool failed = false;
  std::string reason;
  std::deque<std::pair<Buffer, CMTime>> history;
  Buffer previous;
  CMTime previous_time = kCMTimeInvalid;
  MacVideoCadence cadence;
  bool discontinuity = true;
  bool noise_discontinuity = true;
  NSDictionary* last_attachments;
  OSType last_format = 0;

  void Note(const std::string& stage, const std::string& detail) {
    if (!reason.empty()) {
      reason += "; ";
    }
    reason += stage + ": " + detail;
  }
  Buffer Convert(const Buffer& source, NSDictionary* attributes) {
    Buffer buffer = Allocate(width, height, attributes);
    if (!buffer || !context) {
      return {};
    }
    CVBufferPropagateAttachments(source.get(), buffer.get());
    if (CVPixelBufferGetPixelFormatType(buffer.get()) ==
        kCVPixelFormatType_32BGRA) {
      CGColorSpaceRef space = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
      CVBufferSetAttachment(buffer.get(), kCVImageBufferCGColorSpaceKey, space,
                            kCVAttachmentMode_ShouldPropagate);
      [context render:[CIImage imageWithCVPixelBuffer:source.get()]
          toCVPixelBuffer:buffer.get()
                   bounds:CGRectMake(0, 0, width, height)
               colorSpace:space];
      CGColorSpaceRelease(space);
    } else {
      [context render:[CIImage imageWithCVPixelBuffer:source.get()]
          toCVPixelBuffer:buffer.get()];
    }
    CVPixelBufferFillExtendedPixels(buffer.get());
    return buffer;
  }
  void Reset() {
    history.clear();
    previous.reset();
    previous_time = kCMTimeInvalid;
    cadence.Reset();
    discontinuity = noise_discontinuity = true;
    last_attachments = nil;
    last_format = 0;
  }
  void Prepare(size_t w, size_t h) API_AVAILABLE(macos(26.0)) {
    width = w;
    height = h;
    Reset();
    [noise endSession];
    [motion endSession];
    noise = nil;
    motion = nil;
    noise_config = nil;
    low_config = nil;
    quality_config = nil;
    scaler.reset();
    scale_ready = false;
    reason.clear();
    failed = false;
    if (!settings.enabled || !w || !h || w > 1920 || h > 1080 || w % 2 ||
        h % 2) {
      return;
    }
    id<MTLDevice> device = MTLCreateSystemDefaultDevice();
    if (!device) {
      failed = true;
      Note("Effects", "Metal device unavailable");
      return;
    }
    context = [CIContext contextWithMTLDevice:device
                                      options:@{
                                        kCIContextCacheIntermediates : @NO
                                      }];
    if (settings.noise) {
      if ([VTTemporalNoiseFilterConfiguration isSupported]) {
        auto lo = VTTemporalNoiseFilterConfiguration.minimumDimensions;
        auto hi = VTTemporalNoiseFilterConfiguration.maximumDimensions;
        if (w >= static_cast<size_t>(lo.width) &&
            h >= static_cast<size_t>(lo.height) &&
            w <= static_cast<size_t>(hi.width) &&
            h <= static_cast<size_t>(hi.height)) {
          NSArray<NSNumber*>* formats =
              VTTemporalNoiseFilterConfiguration.supportedSourcePixelFormats;
          OSType fmt =
              [formats containsObject:
                           @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)]
                  ? kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
                  : formats.firstObject.unsignedIntValue;
          noise_config = [[VTTemporalNoiseFilterConfiguration alloc]
              initWithFrameWidth:w
                     frameHeight:h
               sourcePixelFormat:fmt];
        }
      }
      NSError* error = nil;
      if (noise_config && noise_config.previousFrameCount > 0) {
        noise = [[VTFrameProcessor alloc] init];
        if (![noise startSessionWithConfiguration:noise_config error:&error]) {
          noise = nil;
          failed = true;
        }
      }
      if (!noise) {
        Note("Noise filtering", Error(error));
      }
    }
    if (settings.motion) {
      id<VTFrameProcessorConfiguration> configuration = nil;
      if (settings.motion == 1 &&
          [VTLowLatencyFrameInterpolationConfiguration isSupported]) {
        low_config = [[VTLowLatencyFrameInterpolationConfiguration alloc]
                    initWithFrameWidth:w
                           frameHeight:h
            numberOfInterpolatedFrames:1];
        configuration = low_config;
      } else if (settings.motion == 2 &&
                 [VTFrameRateConversionConfiguration isSupported]) {
        quality_config = [[VTFrameRateConversionConfiguration alloc]
               initWithFrameWidth:w
                      frameHeight:h
               usePrecomputedFlow:NO
            qualityPrioritization:
                VTFrameRateConversionConfigurationQualityPrioritizationQuality
                         revision:VTFrameRateConversionConfiguration
                                      .defaultRevision];
        configuration = quality_config;
      }
      NSError* error = nil;
      if (configuration) {
        motion = [[VTFrameProcessor alloc] init];
        if (![motion startSessionWithConfiguration:configuration
                                             error:&error]) {
          motion = nil;
          failed = true;
        }
      }
      if (!motion) {
        Note("Motion", Error(error));
      }
    }
    if (settings.upscaling) {
      scaler = std::make_unique<MacVideoUpscaler>(
          settings.upscaling == 1 ? "videotoolbox" : "metalfx");
      std::string why;
      scale_ready = scaler->Prepare(w, h, why);
      if (!scale_ready) {
        Note("Upscaling", why);
      }
    }
  }
  Buffer Filter(const Buffer& source, CMTime timestamp, bool& enhanced)
      API_AVAILABLE(macos(26.0)) {
    if (!noise) {
      return source;
    }
    Buffer input = Convert(source, noise_config.sourcePixelBufferAttributes);
    if (!input) {
      Note("Noise filtering", "Buffer conversion failed");
      noise = nil;
      failed = true;
      return source;
    }
    Buffer result = source;
    if (!history.empty()) {
      NSMutableArray<VTFrameProcessorFrame*>* past = [NSMutableArray array];
      for (const auto& entry : history) {
        [past addObject:Wrap(entry.first, entry.second)];
      }
      Buffer output = Allocate(width, height,
                               noise_config.destinationPixelBufferAttributes);
      if (output) {
        CVBufferPropagateAttachments(input.get(), output.get());
      }
      auto parameters =
          output
              ? [[VTTemporalNoiseFilterParameters alloc]
                    initWithSourceFrame:Wrap(input, timestamp)
                             nextFrames:@[]
                         previousFrames:past
                       destinationFrame:Wrap(output, timestamp)
                         filterStrength:std::clamp(settings.strength, 0.f, 1.f)
                       hasDiscontinuity:noise_discontinuity]
              : nil;
      NSError* error = nil;
      if (parameters && [noise processWithParameters:parameters error:&error]) {
        result = output;
        enhanced = true;
        noise_discontinuity = false;
      } else {
        Note("Noise filtering", Error(error));
        [noise endSession];
        noise = nil;
        failed = true;
      }
    }
    history.emplace_back(input, timestamp);
    while (history.size() >
           static_cast<size_t>(noise_config.previousFrameCount)) {
      history.pop_front();
    }
    return result;
  }
  Batch Process(Buffer source, CMTime timestamp) API_AVAILABLE(macos(26.0)) {
    auto start = std::chrono::steady_clock::now();
    Batch result;
    if (!settings.enabled || !Supported(source.get()) ||
        CVPixelBufferGetWidth(source.get()) != width ||
        CVPixelBufferGetHeight(source.get()) != height) {
      Reset();
      result.frames.push_back({source, timestamp, false});
      result.state = settings.enabled ? "Unsupported" : "Bypassed";
      result.reason =
          settings.enabled
              ? "Requires uncropped, even-sized 8-bit SDR input up to 1080p"
              : "Master bypass";
      return result;
    }
    if (!CMTIME_IS_NUMERIC(timestamp)) {
      Reset();
      result.frames.push_back({source, timestamp, false});
      result.state = "Bypassed";
      result.reason = "Invalid source timestamp";
      return result;
    }
    NSDictionary* attachments = CFBridgingRelease(CVBufferCopyAttachments(
        source.get(), kCVAttachmentMode_ShouldPropagate));
    OSType format = CVPixelBufferGetPixelFormatType(source.get());
    if (last_format &&
        (format != last_format || (attachments != last_attachments &&
                                   ![attachments isEqual:last_attachments]))) {
      Reset();
    }
    last_format = format;
    last_attachments = attachments;
    CMTime old_time = cadence.previous();
    auto times = cadence.Advance(
        timestamp, settings.motion == 2 ? settings.target_fps : 0);
    if (cadence.discontinuity()) {
      history.clear();
      previous.reset();
      discontinuity = noise_discontinuity = true;
    }
    bool filtered = false;
    Buffer current = Filter(source, timestamp, filtered);
    if (!motion) {
      times = {timestamp};
    }
    NSDictionary* input_attrs =
        low_config ? low_config.sourcePixelBufferAttributes
                   : quality_config.sourcePixelBufferAttributes;
    NSDictionary* output_attrs =
        low_config ? low_config.destinationPixelBufferAttributes
                   : quality_config.destinationPixelBufferAttributes;
    Buffer input = motion ? Convert(current, input_attrs) : Buffer{};
    std::vector<Buffer> generated;
    NSMutableArray<NSNumber*>* phases = [NSMutableArray array];
    NSMutableArray<VTFrameProcessorFrame*>* destinations =
        [NSMutableArray array];
    if (motion && previous && input) {
      bool allocation_failed = false;
      for (auto time : times) {
        if (CMTimeCompare(time, timestamp) == 0) {
          continue;
        }
        Buffer output = Allocate(width, height, output_attrs);
        if (!output) {
          allocation_failed = true;
          break;
        }
        CVBufferPropagateAttachments(input.get(), output.get());
        double phase = CMTimeGetSeconds(CMTimeSubtract(time, old_time)) /
                       CMTimeGetSeconds(CMTimeSubtract(timestamp, old_time));
        [phases addObject:@(phase)];
        [destinations addObject:Wrap(output, time)];
        generated.push_back(std::move(output));
      }
      if (allocation_failed) {
        Note("Motion", "Destination buffer allocation failed");
        [motion endSession];
        motion = nil;
        failed = true;
        generated.clear();
        [phases removeAllObjects];
        times = {timestamp};
      }
      if (phases.count) {
        id<VTFrameProcessorParameters> parameters;
        if (low_config) {
          parameters = [[VTLowLatencyFrameInterpolationParameters alloc]
              initWithSourceFrame:Wrap(input, timestamp)
                    previousFrame:Wrap(previous, previous_time)
               interpolationPhase:phases
                destinationFrames:destinations];
        } else {
          parameters = [[VTFrameRateConversionParameters alloc]
              initWithSourceFrame:Wrap(previous, previous_time)
                        nextFrame:Wrap(input, timestamp)
                      opticalFlow:nil
               interpolationPhase:phases
                   submissionMode:
                       discontinuity
                           ? VTFrameRateConversionParametersSubmissionModeRandom
                           : VTFrameRateConversionParametersSubmissionModeSequential
                destinationFrames:destinations];
        }
        NSError* error = nil;
        if (!parameters || ![motion processWithParameters:parameters
                                                    error:&error]) {
          Note("Motion", Error(error));
          [motion endSession];
          motion = nil;
          failed = true;
          generated.clear();
          times = {timestamp};
        } else {
          discontinuity = false;
        }
      }
    }
    if (motion && !input) {
      Note("Motion", "Buffer conversion failed");
      [motion endSession];
      motion = nil;
      failed = true;
      generated.clear();
      times = {timestamp};
    }
    size_t index = 0;
    for (CMTime time : times) {
      bool interpolated = CMTimeCompare(time, timestamp) != 0;
      if (interpolated && index >= generated.size()) {
        continue;
      }
      Buffer output = interpolated ? generated[index++] : current;
      bool enhanced = filtered || interpolated;
      // Apple temporal processors can produce formats (for example 10-bit
      // intermediates) outside the decoder input scope. Convert those to
      // 8-bit SDR before the independently selected spatial stage.
      auto intermediate_format = CVPixelBufferGetPixelFormatType(output.get());
      if (intermediate_format != kCVPixelFormatType_32BGRA &&
          intermediate_format !=
              kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange &&
          intermediate_format !=
              kCVPixelFormatType_420YpCbCr8BiPlanarFullRange) {
        auto converted = Convert(
            output, @{
              (id)
              kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)
            });
        if (converted) {
          output = converted;
        }
      }
      if (scale_ready) {
        auto scaled = scaler->Process(output, time);
        if (scaled.enhanced) {
          output = scaled.buffer;
          enhanced = true;
        } else {
          scale_ready = false;
          failed = true;
          Note("Upscaling", scaled.status);
        }
      }
      result.frames.push_back({output, time, enhanced});
    }
    if (motion && CMTIME_IS_NUMERIC(old_time) && !cadence.discontinuity()) {
      CMTime duration = settings.motion == 2 && settings.target_fps
                            ? CMTimeMake(1, settings.target_fps)
                            : CMTimeMultiplyByRatio(
                                  CMTimeSubtract(timestamp, old_time), 1, 2);
      for (auto& frame : result.frames) {
        frame.duration = duration;
      }
    }
    previous = input;
    previous_time = timestamp;
    if (noise) {
      result.active += "Noise filtering; ";
    }
    if (motion) {
      result.active += settings.motion == 1 ? "Low-latency interpolation; "
                                            : "Quality conversion; ";
    }
    if (scale_ready) {
      result.active +=
          settings.upscaling == 1 ? "VideoToolbox 2x" : "MetalFX 2x";
    }
    result.state = !result.active.empty()
                       ? "Active"
                       : (failed ? "Bypassed" : "Unsupported");
    if (!settings.noise && !settings.motion && !settings.upscaling) {
      result.state = "Bypassed";
      result.reason = "No effects selected";
    }
    if (!reason.empty()) {
      result.reason = reason;
    }
    result.failed = failed;
    result.processing_ms = std::chrono::duration<double, std::milli>(
                               std::chrono::steady_clock::now() - start)
                               .count();
    return result;
  }
};
MacVideoProcessor::MacVideoProcessor(MacVideoEffectsSettings settings)
    : impl_(std::make_unique<Impl>(settings)) {}
MacVideoProcessor::~MacVideoProcessor() = default;
bool MacVideoProcessor::IsSupportedSource(CVPixelBufferRef source) {
  return source && Supported(source);
}
void MacVideoProcessor::Prepare(size_t width, size_t height) {
  @autoreleasepool {
    if (@available(macOS 26.0, *)) {
      impl_->Prepare(width, height);
    }
  }
}
MacVideoProcessor::Batch MacVideoProcessor::Process(Buffer source,
                                                    CMTime timestamp) {
  @autoreleasepool {
    if (@available(macOS 26.0, *)) {
      return impl_->Process(std::move(source), timestamp);
    }
    Batch batch;
    batch.frames.push_back({source, timestamp, false});
    batch.state = "Unsupported";
    batch.reason = "Video effects require macOS 26";
    return batch;
  }
}
MacVideoProcessor::Batch MacVideoProcessor::Flush() {
  impl_->Reset();
  return {};
}
void MacVideoProcessor::Reset() {
  impl_->Reset();
}
}  // namespace media
