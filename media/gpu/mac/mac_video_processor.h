// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license.
#ifndef MEDIA_GPU_MAC_MAC_VIDEO_PROCESSOR_H_
#define MEDIA_GPU_MAC_MAC_VIDEO_PROCESSOR_H_

#include <cstdint>
#include <vector>

#include "mac_video_upscaler.h"

#if defined(COMPONENT_BUILD)
#include "media/gpu/media_gpu_export.h"
#define MAC_VIDEO_PROCESSOR_EXPORT MEDIA_GPU_EXPORT
#else
#define MAC_VIDEO_PROCESSOR_EXPORT
#endif

namespace media {
struct MacVideoEffectsSettings {
  uint64_t version = 0;
  bool enabled = false;
  int upscaling = 0;   // Off, VideoToolbox, MetalFX.
  int motion = 0;      // Off, low latency, quality.
  int target_fps = 0;  // 0 = twice source; otherwise 60 or 120 (quality only).
  bool noise = false;
  float strength = .5f;
  uint64_t retry = 0;
};

// Rational cadence: no accumulated floating point rounding, no off-grid
// originals in fixed-rate mode. A discontinuity starts a new timeline.
class MacVideoCadence {
 public:
  std::vector<CMTime> Advance(CMTime timestamp, int target_fps);
  void Reset();
  bool discontinuity() const { return discontinuity_; }
  CMTime previous() const { return previous_; }

 private:
  CMTime previous_ = kCMTimeInvalid;
  CMTime origin_ = kCMTimeInvalid;
  int64_t tick_ = 1;
  bool discontinuity_ = true;
};

// Prepare on a background sequence; transfer exclusively to the processing
// sequence after preparation. Never call this object concurrently.
class MAC_VIDEO_PROCESSOR_EXPORT MacVideoProcessor {
 public:
  using Buffer = MacVideoUpscaler::Buffer;
  struct Frame {
    Buffer buffer;
    CMTime timestamp;
    bool enhanced = false;
    CMTime duration = kCMTimeInvalid;
  };
  struct Batch {
    std::vector<Frame> frames;
    std::string state;
    std::string reason;
    std::string active;
    double processing_ms = 0;
    bool failed = false;
  };
  explicit MacVideoProcessor(MacVideoEffectsSettings settings);
  ~MacVideoProcessor();
  static bool IsSupportedSource(CVPixelBufferRef source);
  void Prepare(size_t width, size_t height);
  Batch Process(Buffer source, CMTime timestamp);
  // Outputs are emitted through the newest known source timestamp, including
  // the final original in 2x mode. EOS must not synthesize unknown motion.
  Batch Flush();
  void Reset();

 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
}  // namespace media
#undef MAC_VIDEO_PROCESSOR_EXPORT
#endif
