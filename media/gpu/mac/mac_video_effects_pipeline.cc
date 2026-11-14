// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license.
#include "media/gpu/mac/mac_video_effects_pipeline.h"

#include "base/functional/bind.h"
#include "base/task/bind_post_task.h"
#include "base/task/thread_pool.h"
namespace media {
MacVideoEffectsPipeline::MacVideoEffectsPipeline()
    : worker_(base::ThreadPool::CreateSequencedTaskRunner(
          {base::MayBlock(), base::TaskPriority::USER_VISIBLE})) {
  id_ = MacVideoEffectsService::Register(
      base::BindPostTaskToCurrentDefault(base::BindRepeating(
          &MacVideoEffectsPipeline::Configure, weak_factory_.GetWeakPtr())));
}
MacVideoEffectsPipeline::~MacVideoEffectsPipeline() {
  MacVideoEffectsService::Unregister(id_);
  if (processor_) {
    worker_->DeleteSoon(FROM_HERE, new std::shared_ptr<MacVideoProcessor>(
                                       std::move(processor_)));
  }
}
void MacVideoEffectsPipeline::Configure(MacVideoEffectsSettings settings) {
  if (settings.version < settings_.version) {
    return;
  }
  settings_ = settings;
  slow_intervals_ = 0;
  failed_stage_retry_.Stop();
  ++generation_;
  retry_at_ = {};
  // Retain the running session until its replacement is prepared. A bypass
  // takes effect immediately at the next frame boundary.
  if (!settings.enabled) {
    applied_version_ = settings.version;
    if (processor_) {
      worker_->DeleteSoon(FROM_HERE, new std::shared_ptr<MacVideoProcessor>(
                                         std::move(processor_)));
    }
  }
  if (width_ && !preparing_) {
    Prepare();
  }
}
void MacVideoEffectsPipeline::Prepare() {
  if (!settings_.enabled || !width_ || preparing_ ||
      (!retry_at_.is_null() && base::TimeTicks::Now() < retry_at_)) {
    return;
  }
  preparing_ = true;
  base::ThreadPool::PostTaskAndReplyWithResult(
      FROM_HERE, {base::MayBlock(), base::TaskPriority::USER_VISIBLE},
      base::BindOnce(
          [](MacVideoEffectsSettings settings, size_t width, size_t height,
             scoped_refptr<base::SequencedTaskRunner> worker) {
            // Even a stale reply destroyed after decoder teardown must end
            // its Apple sessions on a worker, never the decoder/GPU sequence.
            auto processor = std::shared_ptr<MacVideoProcessor>(
                new MacVideoProcessor(settings),
                [worker](MacVideoProcessor* value) {
                  worker->DeleteSoon(FROM_HERE, value);
                });
            processor->Prepare(width, height);
            return processor;
          },
          settings_, width_, height_, worker_),
      base::BindOnce(&MacVideoEffectsPipeline::OnPrepared,
                     weak_factory_.GetWeakPtr(), generation_));
}
void MacVideoEffectsPipeline::OnPrepared(
    uint64_t generation,
    std::shared_ptr<MacVideoProcessor> processor) {
  preparing_ = false;
  if (generation != generation_) {
    worker_->DeleteSoon(FROM_HERE, new std::shared_ptr<MacVideoProcessor>(
                                       std::move(processor)));
    Prepare();
    return;
  }
  if (processor_) {
    worker_->DeleteSoon(FROM_HERE, new std::shared_ptr<MacVideoProcessor>(
                                       std::move(processor_)));
  }
  processor_ = std::move(processor);
  applied_version_ = settings_.version;
  failed_stage_retry_.Stop();
}
void MacVideoEffectsPipeline::Reset() {
  ++generation_;
  failed_stage_retry_.Stop();
  slow_intervals_ = 0;
  queued_.clear();
  active_.reset();
  source_start_ = kCMTimeInvalid;
  source_count_ = output_count_ = 0;
  sample_start_ = {};
  source_fps_ = processed_fps_ = 0;
  if (processor_) {
    worker_->PostTask(
        FROM_HERE,
        base::BindOnce([](std::shared_ptr<MacVideoProcessor> p) { p->Reset(); },
                       processor_));
  }
}
void MacVideoEffectsPipeline::Submit(MacVideoProcessor::Buffer buffer,
                                     CMTime timestamp,
                                     bool allow_effects,
                                     Done done) {
  auto width = CVPixelBufferGetWidth(buffer.get()),
       height = CVPixelBufferGetHeight(buffer.get());
  if (width != width_ || height != height_) {
    width_ = width;
    height_ = height;
    ++generation_;
    if (processor_) {
      worker_->DeleteSoon(FROM_HERE, new std::shared_ptr<MacVideoProcessor>(
                                         std::move(processor_)));
    }
    retry_at_ = {};
    if (allow_effects && MacVideoProcessor::IsSupportedSource(buffer.get())) {
      Prepare();
    }
  }
  if (CMTIME_IS_NUMERIC(timestamp)) {
    double span = CMTimeGetSeconds(CMTimeSubtract(timestamp, source_start_));
    if (!CMTIME_IS_NUMERIC(source_start_) || span <= 0 || span > 2) {
      source_start_ = timestamp;
      source_count_ = 0;
    } else if (span >= .5) {
      source_fps_ = (source_count_ + 1) / span;
      source_start_ = timestamp;
      source_count_ = 0;
    } else {
      ++source_count_;
    }
  }
  Job job{std::move(buffer), timestamp, std::move(done)};
  if (!allow_effects ||
      !MacVideoProcessor::IsSupportedSource(job.buffer.get())) {
    if (processor_) {
      worker_->PostTask(
          FROM_HERE,
          base::BindOnce(
              [](std::shared_ptr<MacVideoProcessor> p) { p->Reset(); },
              processor_));
    }
    applied_version_ = settings_.version;
    Bypass(std::move(job), "Unsupported",
           "Requires uncropped, even-sized 8-bit SDR input up to 1080p");
    return;
  }
  if (!settings_.enabled) {
    Bypass(std::move(job), "Bypassed", "Master bypass");
    return;
  }
  if (!retry_at_.is_null() && !processor_) {
    if (base::TimeTicks::Now() < retry_at_) {
      Bypass(std::move(job), "Bypassed",
             "Processing overload; retry in five seconds");
      return;
    }
    retry_at_ = {};
    Prepare();
  }
  if (!processor_) {
    if (!preparing_) {
      Prepare();
    }
    Bypass(std::move(job), "Warming up",
           "Preparing effects while original video continues");
    return;
  }
  if (queued_.size() == 2) {
    Overload();
    Bypass(std::move(job), "Bypassed",
           "Processing overload; retry in five seconds");
    return;
  }
  queued_.push_back(std::move(job));
  Pump();
}
void MacVideoEffectsPipeline::Pump() {
  if (processing_ || queued_.empty()) {
    return;
  }
  active_ = std::move(queued_.front());
  queued_.pop_front();
  if (!processor_ || !settings_.enabled) {
    auto job = std::move(*active_);
    active_.reset();
    Bypass(std::move(job), "Bypassed", "Settings changed");
    Pump();
    return;
  }
  processing_ = true;
  active_version_ = applied_version_;
  // A source callback alone is not a wall-clock latency bound: the decoder
  // can throttle itself while an Apple call is stuck. Expire that work too.
  uint64_t job = ++job_id_;
  base::SequencedTaskRunner::GetCurrentDefault()->PostDelayedTask(
      FROM_HERE,
      base::BindOnce(
          [](base::WeakPtr<MacVideoEffectsPipeline> self, uint64_t job) {
            if (self && self->processing_ && self->active_ &&
                self->job_id_ == job) {
              self->Overload();
            }
          },
          weak_factory_.GetWeakPtr(), job),
      base::Milliseconds(source_fps_ > 0 ? std::max(50., 3000. / source_fps_)
                                         : 100.));
  worker_->PostTaskAndReplyWithResult(
      FROM_HERE,
      base::BindOnce(
          [](std::shared_ptr<MacVideoProcessor> processor,
             MacVideoProcessor::Buffer buffer, CMTime time) {
            return processor->Process(std::move(buffer), time);
          },
          processor_, active_->buffer, active_->timestamp),
      base::BindOnce(&MacVideoEffectsPipeline::OnProcessed,
                     weak_factory_.GetWeakPtr(), generation_));
}
void MacVideoEffectsPipeline::OnProcessed(uint64_t generation,
                                          MacVideoProcessor::Batch batch) {
  processing_ = false;
  if (active_ && generation == generation_) {
    // Decoder backpressure bounds memory but can conceal sustained slowness:
    // it stops asking for frames instead of overflowing the queue. Detect that
    // case against the measured source interval, not generated output FPS.
    slow_intervals_ =
        source_fps_ > 0 && batch.processing_ms > 1000. / source_fps_
            ? slow_intervals_ + 1
            : 0;
    if (slow_intervals_ >= 3) {
      Overload();
      return;
    }
  }
  if (active_) {
    auto job = std::move(*active_);
    active_.reset();
    if (generation == generation_) {
      Report(batch, active_version_);
      bool failed = batch.failed;
      std::move(job.done).Run(std::move(batch));
      if (failed && !preparing_ && !failed_stage_retry_.IsRunning()) {
        // Keep supported stages active while a failed stage cools down.
        failed_stage_retry_.Start(
            FROM_HERE, base::Seconds(5),
            base::BindOnce(&MacVideoEffectsPipeline::Prepare,
                           weak_factory_.GetWeakPtr()));
      } else if (!failed) {
        failed_stage_retry_.Stop();
      }
    } else {
      Bypass(std::move(job), "Bypassed", "Obsolete settings result discarded");
    }
  }
  Pump();
}
void MacVideoEffectsPipeline::Overload() {
  ++generation_;
  retry_at_ = base::TimeTicks::Now() + base::Seconds(5);
  if (processor_) {
    worker_->DeleteSoon(FROM_HERE, new std::shared_ptr<MacVideoProcessor>(
                                       std::move(processor_)));
  }
  if (active_) {
    auto job = std::move(*active_);
    active_.reset();
    Bypass(std::move(job), "Bypassed",
           "Processing overload; obsolete output discarded");
  }
  while (!queued_.empty()) {
    auto job = std::move(queued_.front());
    queued_.pop_front();
    Bypass(std::move(job), "Bypassed",
           "Processing overload; queued enhancement bypassed");
  }
}
void MacVideoEffectsPipeline::Bypass(Job job,
                                     const std::string& state,
                                     const std::string& reason) {
  MacVideoProcessor::Batch batch;
  batch.frames.push_back({job.buffer, job.timestamp, false});
  batch.state = state;
  batch.reason = reason;
  Report(batch, applied_version_);
  std::move(job.done).Run(std::move(batch));
}
void MacVideoEffectsPipeline::Report(const MacVideoProcessor::Batch& batch,
                                     uint64_t applied_version) {
  auto now = base::TimeTicks::Now();
  if (sample_start_.is_null()) {
    sample_start_ = now;
  }
  output_count_ += batch.frames.size();
  if ((now - sample_start_).InSecondsF() >= .5) {
    processed_fps_ = output_count_ / (now - sample_start_).InSecondsF();
    sample_start_ = now;
    output_count_ = 0;
  }
  auto player = video_effects::mojom::Player::New();
  player->id = id_;
  player->applied_version = applied_version;
  player->input_width = width_;
  player->input_height = height_;
  if (!batch.frames.empty()) {
    output_width_ = CVPixelBufferGetWidth(batch.frames.back().buffer.get());
    output_height_ = CVPixelBufferGetHeight(batch.frames.back().buffer.get());
  }
  player->output_width = output_width_;
  player->output_height = output_height_;
  player->source_fps = source_fps_;
  player->processed_fps = processed_fps_;
  player->processing_ms = batch.processing_ms;
  player->queue_depth = queued_.size() + (processing_ ? 1 : 0);
  player->state = preparing_ ? "Warming up" : batch.state;
  player->reason =
      preparing_ && batch.reason.empty()
          ? "Preparing replacement sessions; current playback continues"
          : batch.reason;
  player->active = batch.active;
  MacVideoEffectsService::Report(std::move(player));
}
}  // namespace media
