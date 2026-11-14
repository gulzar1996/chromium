#import <CoreImage/CoreImage.h>
#import <Foundation/Foundation.h>

#include <algorithm>
#include <cassert>
#include <cmath>
#include <cstdio>
#include <random>

#include "../overlay/media/gpu/mac/mac_video_presentation_queue.h"
#include "../overlay/media/gpu/mac/mac_video_processor.h"
using namespace media;
void ReorderTests() {
  std::vector<int> decode = {0, 1, 2, 3};
  do {
    MacVideoPresentationQueue<int, std::optional<int>> queue;
    queue.Schedule(0);
    queue.Schedule(1);
    queue.Schedule(2);
    queue.Schedule(3);
    std::vector<int> output;
    for (int key : decode) {
      queue.Fulfill(key, key == 2 ? std::optional<int>() : key);
      while (auto frame = queue.Pop()) {
        output.push_back(frame->value_or(-1));
      }
    }
    assert((output == std::vector<int>{0, 1, -1, 3}));
    assert(queue.empty());
    queue.Fulfill(8, 8);
    queue.Schedule(8);
    queue.Clear();
    assert(!queue.Pop());
    queue.Fulfill(9, 9);
    queue.Schedule(9);
    assert(queue.Pop()->value() == 9);
  } while (std::next_permutation(decode.begin(), decode.end()));
  fprintf(stderr, "PASS presentation order: all decode permutations, dropped "
                  "frames, fulfill before schedule, reset\n");
}
void CadenceTests() {
  for (int rate : {24, 25, 30, 60}) {
    for (int target : {0, 60, 120}) {
      MacVideoCadence cadence;
      CMTime last = kCMTimeInvalid;
      size_t count = 0;
      for (int i = 0; i <= rate * 10; ++i) {
        auto outputs = cadence.Advance(CMTimeMake(i, rate), target);
        for (auto time : outputs) {
          assert(!CMTIME_IS_NUMERIC(last) || CMTimeCompare(time, last) > 0);
          if (target) {
            assert(CMTimeCompare(time, CMTimeMake(count, target)) == 0);
          }
          last = time;
          ++count;
        }
      }
      assert(count ==
             static_cast<size_t>((target ? target : rate * 2) * 10 + 1));
      cadence.Advance(CMTimeMake(1, 30), target);
      assert(cadence.discontinuity());
      cadence.Advance(CMTimeMake(1, 30), target);
      assert(cadence.discontinuity());
      cadence.Advance(kCMTimeInvalid, target);
      assert(cadence.discontinuity());
      cadence.Advance(CMTimeMake(1, 1), target);
      assert(cadence.discontinuity());
      cadence.Reset();
      assert(cadence.Advance(CMTimeMake(0, 30), target).size() == 1);
    }
  }
  for (int rate : {24000, 30000, 60000}) {
    MacVideoCadence cadence;
    size_t count = 0;
    for (int i = 0; i <= 10000; ++i) {
      count += cadence.Advance(CMTimeMake(i * 1001LL, rate), 120).size();
    }
    assert(count == static_cast<size_t>(10000LL * 1001 * 120 / rate + 1));
  }
  MacVideoCadence half_microsecond;
  half_microsecond.Advance(CMTimeMake(0, 1000000), 0);
  auto exact_midpoint = half_microsecond.Advance(CMTimeMake(33367, 1000000), 0);
  assert(CMTimeCompare(exact_midpoint.front(), CMTimeMake(33367, 2000000)) ==
         0);
  MacVideoCadence variable;
  size_t count = 0;
  for (int ms : {0, 31, 69, 100, 157, 199, 250}) {
    count += variable.Advance(CMTimeMake(ms, 1000), 120).size();
  }
  assert(count == 31);
  variable.Advance(CMTimeMake(501, 1000), 120);
  assert(variable.discontinuity());
  fprintf(stderr, "PASS rational cadence: 24/25/30/60, fractional, variable, "
                  "60/120 grids, discontinuities\n");
}
MacVideoProcessor::Buffer Source(int seed) {
  CVPixelBufferRef raw = nullptr;
  NSDictionary* attrs = @{
    (id)kCVPixelBufferIOSurfacePropertiesKey : @{},
    (id)kCVPixelBufferMetalCompatibilityKey : @YES
  };
  assert(!CVPixelBufferCreate(nullptr, 640, 360, kCVPixelFormatType_32BGRA,
                              (__bridge CFDictionaryRef)attrs, &raw));
  MacVideoProcessor::Buffer buffer(raw, CVPixelBufferRelease);
  CGColorSpaceRef srgb = CGColorSpaceCreateWithName(kCGColorSpaceSRGB);
  CVBufferSetAttachment(raw, kCVImageBufferCGColorSpaceKey, srgb,
                        kCVAttachmentMode_ShouldPropagate);
  CGColorSpaceRelease(srgb);
  std::mt19937 rng(seed);
  CVPixelBufferLockBaseAddress(raw, 0);
  for (int y = 0; y < 360; ++y) {
    for (int x = 0; x < 640; ++x) {
      auto* p = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(raw)) +
                y * CVPixelBufferGetBytesPerRow(raw) + x * 4;
      int noise = static_cast<int>(rng() % 31) - 15;
      p[0] = (y < 180 ? 40 : 210) + noise;
      p[1] = 90 + noise;
      p[2] = (y < 180 ? 210 : 40) + noise;
      p[3] = 255;
    }
  }
  CVPixelBufferUnlockBaseAddress(raw, 0);
  return buffer;
}
double CheckImage(const MacVideoProcessor::Buffer& buffer) {
  CVPixelBufferRef raw = nullptr;
  int w = CVPixelBufferGetWidth(buffer.get()),
      h = CVPixelBufferGetHeight(buffer.get());
  assert(!CVPixelBufferCreate(nullptr, w, h, kCVPixelFormatType_32BGRA, nullptr,
                              &raw));
  [[CIContext context] render:[CIImage imageWithCVPixelBuffer:buffer.get()]
              toCVPixelBuffer:raw];
  CVPixelBufferLockBaseAddress(raw, kCVPixelBufferLock_ReadOnly);
  double sum = 0, squares = 0;
  for (int y = 30; y < 130; ++y) {
    for (int x = 30; x < 130; ++x) {
      auto* p = static_cast<uint8_t*>(CVPixelBufferGetBaseAddress(raw)) +
                y * CVPixelBufferGetBytesPerRow(raw) + x * 4;
      assert(p[2] > p[0] + 80);  // Orientation and channels.
      sum += p[1];
      squares += p[1] * p[1];
    }
  }
  CVPixelBufferUnlockBaseAddress(raw, kCVPixelBufferLock_ReadOnly);
  CFRelease(raw);
  return squares / 10000 - (sum / 10000) * (sum / 10000);
}
int main() {
  @autoreleasepool {
    ReorderTests();
    CadenceTests();
    for (int mode : {0, 1, 2}) {
      for (bool noise : {false, true}) {
        for (int scale : {0, 1, 2}) {
          if (!mode && !noise && !scale) {
            continue;
          }
          MacVideoEffectsSettings settings;
          settings.enabled = true;
          settings.motion = mode;
          settings.noise = noise;
          settings.upscaling = scale;
          settings.strength = 1;
          MacVideoProcessor processor(settings);
          processor.Prepare(640, 360);
          double source_variance = 0, output_variance = 0;
          for (int i = 0; i < 5; ++i) {
            auto source = Source(i);
            auto batch = processor.Process(source, CMTimeMake(i, 30));
            fprintf(stderr,
                    "motion=%d noise=%d scale=%d frame=%d outputs=%zu %.2fms "
                    "%s %s active=%s\n",
                    mode, noise, scale, i, batch.frames.size(),
                    batch.processing_ms, batch.state.c_str(),
                    batch.reason.c_str(), batch.active.c_str());
            assert(!batch.failed);
            assert(batch.state == "Active");
            assert(batch.frames.size() ==
                   static_cast<size_t>((mode && i) ? 2 : 1));
            for (const auto& frame : batch.frames) {
              assert(CVPixelBufferGetIOSurface(frame.buffer.get()));
              assert(CVPixelBufferGetWidth(frame.buffer.get()) ==
                     static_cast<size_t>(scale ? 1280 : 640));
              CheckImage(frame.buffer);
            }
            if (i && noise && !scale) {
              source_variance += CheckImage(source);
              output_variance += CheckImage(batch.frames.back().buffer);
            }
          }
          if (noise && !scale) {
            fprintf(stderr, "noise variance input=%.3f output=%.3f\n",
                    source_variance, output_variance);
            assert(output_variance < source_variance);
          }
          assert(processor.Flush().frames.empty());
          auto first = processor.Process(Source(0), CMTimeMake(0, 30));
          assert(first.frames.size() == 1);
          processor.Reset();
          assert(
              processor.Process(Source(1), CMTimeMake(3, 30)).frames.size() ==
              1);
        }
      }
    }
    {
      MacVideoEffectsSettings settings;
      settings.enabled = true;
      settings.noise = true;
      MacVideoProcessor processor(settings);
      processor.Prepare(640, 360);
      auto source = Source(5);
      assert(!processor.Process(source, CMTimeMake(0, 30))
                  .frames.front()
                  .enhanced);
      assert(processor.Process(Source(6), CMTimeMake(1, 30))
                 .frames.front()
                 .enhanced);
      assert(!processor.Process(source, CMTimeMake(1, 30))
                  .frames.front()
                  .enhanced);
      assert(
          !processor.Process(source, CMTimeMake(1, 1)).frames.front().enhanced);
      assert(
          !processor.Process(source, kCMTimeInvalid).frames.front().enhanced);
      CVBufferSetAttachment(source.get(), kCVImageBufferTransferFunctionKey,
                            kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                            kCVAttachmentMode_ShouldPropagate);
      assert(!MacVideoProcessor::IsSupportedSource(source.get()));
      auto hdr = processor.Process(source, CMTimeMake(2, 1));
      assert(hdr.state == "Unsupported" && hdr.frames.front().buffer == source);
      CVBufferRemoveAttachment(source.get(), kCVImageBufferTransferFunctionKey);
      CVBufferSetAttachment(
          source.get(), kCVImageBufferCleanApertureKey, (__bridge CFTypeRef) @{
            (id)kCVImageBufferCleanApertureWidthKey : @638,
            (id)kCVImageBufferCleanApertureHeightKey : @358,
            (id)kCVImageBufferCleanApertureHorizontalOffsetKey : @0,
            (id)kCVImageBufferCleanApertureVerticalOffsetKey : @0
          },
          kCVAttachmentMode_ShouldPropagate);
      assert(!MacVideoProcessor::IsSupportedSource(source.get()));
      assert(processor.Process(source, CMTimeMake(3, 1)).state ==
             "Unsupported");
    }
    for (int fps : {60, 120}) {
      MacVideoEffectsSettings settings;
      settings.enabled = true;
      settings.motion = 2;
      settings.target_fps = fps;
      MacVideoProcessor processor(settings);
      processor.Prepare(640, 360);
      size_t count = 0;
      for (int i = 0; i <= 5; ++i) {
        auto batch = processor.Process(Source(i), CMTimeMake(i, 25));
        assert(!batch.failed);
        for (const auto& frame : batch.frames) {
          assert(CMTimeCompare(frame.timestamp, CMTimeMake(count++, fps)) == 0);
        }
      }
      assert(count == static_cast<size_t>(fps / 5 + 1));
    }
    fprintf(stderr, "PASS native effects and combinations, IOSurfaces, "
                    "color/orientation, noise reduction, resets, EOS\n");
  }
}
