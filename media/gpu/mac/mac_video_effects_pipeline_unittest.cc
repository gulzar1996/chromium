// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license.
#include "media/gpu/mac/mac_video_effects_pipeline.h"

#include "base/functional/bind.h"
#include "base/test/task_environment.h"
#include "base/test/test_simple_task_runner.h"
#include "testing/gtest/include/gtest/gtest.h"

namespace media {
// Control worker completion independently of decoder time. Tests drive the
// actual queue/epoch/cooldown implementation without timing Apple GPU calls.
class MacVideoEffectsPipelineTest : public testing::Test {
 protected:
  void SetUp() override {
    pipeline_ = std::make_unique<MacVideoEffectsPipeline>();
    environment_.RunUntilIdle();  // Initial registry settings broadcast.
    pipeline_->worker_ = worker_;
    pipeline_->width_ = 640;
    pipeline_->height_ = 360;
    pipeline_->settings_.enabled = true;
    pipeline_->settings_.version = 10;
    pipeline_->applied_version_ = 10;
    pipeline_->source_fps_ = 30;
    pipeline_->processor_ =
        std::make_shared<MacVideoProcessor>(pipeline_->settings_);
    CVPixelBufferRef buffer = nullptr;
    ASSERT_EQ(CVPixelBufferCreate(nullptr, 640, 360, kCVPixelFormatType_32BGRA,
                                  nullptr, &buffer),
              kCVReturnSuccess);
    source_ = MacVideoProcessor::Buffer(buffer, CVPixelBufferRelease);
  }
  void TearDown() override {
    // No Apple work was run; destroy pending task closures on their origin.
    worker_->ClearPendingTasks();
    pipeline_.reset();
    worker_->ClearPendingTasks();
    environment_.RunUntilIdle();
  }
  void Submit(int index) {
    pipeline_->Submit(source_, CMTimeMake(index, 30), true,
                      base::BindOnce(
                          [](MacVideoEffectsPipelineTest* self, int index,
                             MacVideoProcessor::Batch batch) {
                            self->completed_.push_back(index);
                            self->states_.push_back(batch.state);
                          },
                          base::Unretained(this), index));
  }
  size_t Queued() const { return pipeline_->queued_.size(); }
  uint64_t Generation() const { return pipeline_->generation_; }
  void Complete(uint64_t generation, double milliseconds = 0) {
    worker_->ClearPendingTasks();
    MacVideoProcessor::Batch batch;
    batch.frames.push_back({source_, CMTimeMake(0, 30), true});
    batch.state = "Active";
    batch.processing_ms = milliseconds;
    pipeline_->OnProcessed(generation, std::move(batch));
  }
  void HoldPreparation() { pipeline_->preparing_ = true; }
  void Disable() {
    auto settings = pipeline_->settings_;
    settings.enabled = false;
    ++settings.version;
    pipeline_->Configure(settings);
  }
  bool HasProcessor() const { return !!pipeline_->processor_; }
  void StalePreparation(uint64_t generation) {
    pipeline_->OnPrepared(
        generation, std::make_shared<MacVideoProcessor>(pipeline_->settings_));
  }
  void Reset() { pipeline_->Reset(); }
  base::test::TaskEnvironment environment_{
      base::test::TaskEnvironment::TimeSource::MOCK_TIME};
  scoped_refptr<base::TestSimpleTaskRunner> worker_ =
      base::MakeRefCounted<base::TestSimpleTaskRunner>();
  std::unique_ptr<MacVideoEffectsPipeline> pipeline_;
  MacVideoProcessor::Buffer source_;
  std::vector<int> completed_;
  std::vector<std::string> states_;
};

TEST_F(MacVideoEffectsPipelineTest, OneJobTwoQueuedAndStaleResultDiscarded) {
  auto generation = Generation();
  Submit(0);
  Submit(1);
  Submit(2);
  EXPECT_EQ(Queued(), 2u);
  EXPECT_TRUE(completed_.empty());
  Submit(3);
  EXPECT_EQ(Queued(), 0u);
  EXPECT_EQ(completed_, (std::vector<int>{0, 1, 2, 3}));
  EXPECT_EQ(states_, (std::vector<std::string>(4, "Bypassed")));
  EXPECT_GT(Generation(), generation);
  Complete(generation);
  EXPECT_EQ(completed_.size(), 4u);  // Expired enhanced output never reappears.
}

TEST_F(MacVideoEffectsPipelineTest, DeadlineAndFiveSecondCooldown) {
  auto generation = Generation();
  Submit(0);
  environment_.FastForwardBy(base::Milliseconds(101));
  ASSERT_EQ(states_, (std::vector<std::string>{"Bypassed"}));
  Complete(generation);
  Submit(1);
  EXPECT_EQ(states_.back(), "Bypassed");
  environment_.FastForwardBy(base::Seconds(4));
  Submit(2);
  EXPECT_EQ(states_.back(), "Bypassed");
  HoldPreparation();
  environment_.FastForwardBy(base::Seconds(1));
  Submit(3);
  EXPECT_EQ(states_.back(), "Warming up");
}

TEST_F(MacVideoEffectsPipelineTest, ResetDiscardsOldWorkAndReleasesNewWork) {
  auto generation = Generation();
  Submit(0);
  Submit(1);
  Reset();
  Submit(2);
  Complete(generation);
  EXPECT_TRUE(completed_.empty());
  Complete(Generation());
  EXPECT_EQ(completed_, (std::vector<int>{2}));
}

TEST_F(MacVideoEffectsPipelineTest, SustainedSlowProcessingTriggersBypass) {
  for (int i = 0; i < 3; ++i) {
    Submit(i);
    Complete(Generation(), 40);
  }
  EXPECT_EQ(states_,
            (std::vector<std::string>{"Active", "Active", "Bypassed"}));
  Submit(3);
  EXPECT_EQ(states_.back(), "Bypassed");
}

TEST_F(MacVideoEffectsPipelineTest,
       StalePreparationCannotSkipOverloadCooldown) {
  auto generation = Generation();
  Submit(0);
  Submit(1);
  Submit(2);
  Submit(3);
  HoldPreparation();
  StalePreparation(generation);
  EXPECT_FALSE(HasProcessor());
  Complete(generation);
  Submit(4);
  EXPECT_EQ(states_.back(), "Bypassed");
}

TEST_F(MacVideoEffectsPipelineTest, BypassRejectsOldPreparation) {
  auto generation = Generation();
  HoldPreparation();
  Disable();
  StalePreparation(generation);
  EXPECT_FALSE(HasProcessor());
  Submit(0);
  EXPECT_EQ(states_, (std::vector<std::string>{"Bypassed"}));
}
}  // namespace media
