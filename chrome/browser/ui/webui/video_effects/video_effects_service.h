// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license.
#ifndef CHROME_BROWSER_UI_WEBUI_VIDEO_EFFECTS_VIDEO_EFFECTS_SERVICE_H_
#define CHROME_BROWSER_UI_WEBUI_VIDEO_EFFECTS_VIDEO_EFFECTS_SERVICE_H_
#include "base/no_destructor.h"
#include "base/timer/timer.h"
#include "media/mojo/mojom/video_effects/video_effects.mojom.h"
#include "mojo/public/cpp/bindings/remote.h"
class VideoEffectsService {
 public:
  static VideoEffectsService& Get();
  void Start();
  void Shutdown();
  video_effects::mojom::SnapshotPtr Snapshot();
  uint64_t Set(video_effects::mojom::SettingsPtr settings);
  uint64_t Retry();

 private:
  friend class base::NoDestructor<VideoEffectsService>;
  VideoEffectsService();
  ~VideoEffectsService();
  void Tick();
  void Apply();
  void Persist();
  bool started_ = false, polling_ = false;
  uint64_t acknowledged_ = 0;
  video_effects::mojom::SettingsPtr settings_;
  std::vector<video_effects::mojom::PlayerPtr> players_;
  mojo::Remote<video_effects::mojom::GpuService> gpu_;
  base::RepeatingTimer timer_;
};
#endif
