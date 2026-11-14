// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.
#ifndef MEDIA_GPU_MAC_MAC_VIDEO_UPSCALER_H_
#define MEDIA_GPU_MAC_MAC_VIDEO_UPSCALER_H_

#include <CoreMedia/CoreMedia.h>
#include <CoreVideo/CoreVideo.h>
#include <memory>
#include <string>
#include <type_traits>

namespace media {
// Called only on a dedicated sequenced worker. Pixel buffers retain their
// IOSurfaces across the decoder, worker and compositor lifetimes.
class MacVideoUpscaler {
 public:
  using Buffer = std::shared_ptr<std::remove_pointer_t<CVPixelBufferRef>>;
  struct Result {
    Buffer buffer;
    bool enhanced = false;
    std::string status;
  };
  explicit MacVideoUpscaler(std::string backend);
  ~MacVideoUpscaler();
  Result Process(Buffer source, CMTime timestamp);
  static Buffer Retain(CVPixelBufferRef buffer);
 private:
  struct Impl;
  std::unique_ptr<Impl> impl_;
};
}  // namespace media
#endif  // MEDIA_GPU_MAC_MAC_VIDEO_UPSCALER_H_
