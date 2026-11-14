// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license.
#ifndef MEDIA_GPU_MAC_MAC_VIDEO_EFFECTS_PIPELINE_H_
#define MEDIA_GPU_MAC_MAC_VIDEO_EFFECTS_PIPELINE_H_
#include <deque>
#include <optional>

#include "base/memory/weak_ptr.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "base/timer/timer.h"
#include "media/gpu/mac/mac_video_effects_service.h"
namespace media {
class MEDIA_GPU_EXPORT MacVideoEffectsPipeline {
 public:
  using Done = base::OnceCallback<void(MacVideoProcessor::Batch)>;
  MacVideoEffectsPipeline();
  ~MacVideoEffectsPipeline();
  void Submit(MacVideoProcessor::Buffer buffer,
              CMTime timestamp,
              bool allow_effects,
              Done done);
  void Reset();

 private:
  friend class MacVideoEffectsPipelineTest;
  struct Job {
    MacVideoProcessor::Buffer buffer;
    CMTime timestamp;
    Done done;
  };
  void Configure(MacVideoEffectsSettings settings);
  void Prepare();
  void OnPrepared(uint64_t generation,
                  std::shared_ptr<MacVideoProcessor> processor);
  void Pump();
  void OnProcessed(uint64_t generation, MacVideoProcessor::Batch batch);
  void Bypass(Job job, const std::string& state, const std::string& reason);
  void Report(const MacVideoProcessor::Batch& batch, uint64_t applied_version);
  void Overload();
  uint64_t id_ = 0, generation_ = 0, applied_version_ = 0, job_id_ = 0;
  MacVideoEffectsSettings settings_;
  size_t width_ = 0, height_ = 0;
  size_t output_width_ = 0, output_height_ = 0;
  bool preparing_ = false, processing_ = false;
  unsigned slow_intervals_ = 0;
  uint64_t active_version_ = 0;
  std::shared_ptr<MacVideoProcessor> processor_;
  std::optional<Job> active_;
  std::deque<Job> queued_;
  base::TimeTicks retry_at_;
  base::OneShotTimer failed_stage_retry_;
  base::TimeTicks sample_start_;
  CMTime source_start_ = kCMTimeInvalid;
  double source_fps_ = 0, processed_fps_ = 0;
  size_t source_count_ = 0, output_count_ = 0;
  scoped_refptr<base::SequencedTaskRunner> worker_;
  base::WeakPtrFactory<MacVideoEffectsPipeline> weak_factory_{this};
};
}  // namespace media
#endif
