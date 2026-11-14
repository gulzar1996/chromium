// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license.
#ifndef MEDIA_GPU_MAC_MAC_VIDEO_EFFECTS_SERVICE_H_
#define MEDIA_GPU_MAC_MAC_VIDEO_EFFECTS_SERVICE_H_
#include "base/functional/callback.h"
#include "media/gpu/mac/mac_video_processor.h"
#include "media/gpu/media_gpu_export.h"
#include "media/mojo/mojom/video_effects/video_effects.mojom.h"
#include "mojo/public/cpp/bindings/pending_receiver.h"
namespace media {
// Thread-safe registry. Callbacks must be BindPostTask callbacks targeting each
// decoder's sequence. No decoder or Apple API work runs under the registry
// lock.
class MEDIA_GPU_EXPORT MacVideoEffectsService {
 public:
  static void Bind(
      mojo::PendingReceiver<video_effects::mojom::GpuService> receiver);
  static uint64_t Register(
      base::RepeatingCallback<void(MacVideoEffectsSettings)> callback);
  static void Unregister(uint64_t id);
  static void Report(video_effects::mojom::PlayerPtr player);
};
}  // namespace media
#endif
