// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license.
#include "chrome/browser/ui/webui/video_effects/video_effects_service.h"

#include <algorithm>
#include <cmath>

#include "base/command_line.h"
#include "base/functional/bind.h"
#include "chrome/browser/browser_process.h"
#include "components/prefs/pref_service.h"
#include "content/public/browser/gpu_service_registry.h"
namespace {
constexpr char kSettings[] = "video_effects.settings";
constexpr char kLabs[] = "browser.enabled_labs_experiments";
}  // namespace
VideoEffectsService& VideoEffectsService::Get() {
  static base::NoDestructor<VideoEffectsService> service;
  return *service;
}
VideoEffectsService::VideoEffectsService() = default;
VideoEffectsService::~VideoEffectsService() = default;
void VideoEffectsService::Start() {
  if (started_) {
    return;
  }
  started_ = true;
  settings_ = video_effects::mojom::Settings::New();
  settings_->version = 1;
  PrefService* prefs = g_browser_process->local_state();
  const auto& saved = prefs->GetDict(kSettings);
  if (!saved.empty()) {
    settings_->enabled = saved.FindBool("enabled").value_or(false);
    settings_->upscaling = static_cast<video_effects::mojom::Upscaling>(
        std::clamp(saved.FindInt("upscaling").value_or(0), 0, 2));
    settings_->motion = static_cast<video_effects::mojom::Motion>(
        std::clamp(saved.FindInt("motion").value_or(0), 0, 2));
    settings_->cadence = static_cast<video_effects::mojom::Cadence>(
        std::clamp(saved.FindInt("cadence").value_or(0), 0, 2));
    settings_->noise = saved.FindBool("noise").value_or(false);
    settings_->strength =
        std::clamp(saved.FindDouble("strength").value_or(.5), 0., 1.);
  } else {
    // Only seed a new installation. Live selections win on subsequent launches.
    for (const auto& flag : prefs->GetList(kLabs)) {
      if (!flag.is_string()) {
        continue;
      }
      if (flag.GetString() == "mac-video-upscaler@1") {
        settings_->upscaling = video_effects::mojom::Upscaling::kVideoToolbox;
      }
      if (flag.GetString() == "mac-video-upscaler@2") {
        settings_->upscaling = video_effects::mojom::Upscaling::kMetalFX;
      }
    }
    auto mode = base::CommandLine::ForCurrentProcess()->GetSwitchValueASCII(
        "mac-video-upscaler");
    if (mode == "videotoolbox") {
      settings_->upscaling = video_effects::mojom::Upscaling::kVideoToolbox;
    }
    if (mode == "metalfx") {
      settings_->upscaling = video_effects::mojom::Upscaling::kMetalFX;
    }
    if (mode == "off") {
      settings_->upscaling = video_effects::mojom::Upscaling::kOff;
    }
    settings_->enabled =
        settings_->upscaling != video_effects::mojom::Upscaling::kOff;
  }
  auto flags = prefs->GetList(kLabs).Clone();
  flags.EraseIf([](const base::Value& value) {
    return value.is_string() &&
           value.GetString().starts_with("mac-video-upscaler@");
  });
  prefs->SetList(kLabs, std::move(flags));
  Persist();
  Tick();
  timer_.Start(FROM_HERE, base::Milliseconds(500), this,
               &VideoEffectsService::Tick);
}
void VideoEffectsService::Shutdown() {
  timer_.Stop();
  gpu_.reset();
  players_.clear();
  started_ = false;
}
void VideoEffectsService::Tick() {
  if (!gpu_.is_bound()) {
    content::BindInterfaceInGpuProcess(gpu_.BindNewPipeAndPassReceiver());
    gpu_.set_disconnect_handler(base::BindOnce(
        [](VideoEffectsService* self) {
          self->gpu_.reset();
          self->acknowledged_ = 0;
          self->polling_ = false;
          self->players_.clear();
        },
        base::Unretained(this)));
    Apply();
  }
  if (!polling_) {
    polling_ = true;
    gpu_->GetPlayers(base::BindOnce(
        [](VideoEffectsService* self,
           std::vector<video_effects::mojom::PlayerPtr> players) {
          self->polling_ = false;
          self->players_ = std::move(players);
        },
        base::Unretained(this)));
  }
}
void VideoEffectsService::Apply() {
  if (!gpu_.is_bound()) {
    return;
  }
  gpu_->Apply(settings_.Clone(),
              base::BindOnce(
                  [](VideoEffectsService* self, uint64_t version) {
                    self->acknowledged_ =
                        std::max(self->acknowledged_, version);
                  },
                  base::Unretained(this)));
}
void VideoEffectsService::Persist() {
  base::DictValue saved;
  saved.Set("enabled", settings_->enabled);
  saved.Set("upscaling", static_cast<int>(settings_->upscaling));
  saved.Set("motion", static_cast<int>(settings_->motion));
  saved.Set("cadence", static_cast<int>(settings_->cadence));
  saved.Set("noise", settings_->noise);
  saved.Set("strength", settings_->strength);
  g_browser_process->local_state()->SetDict(kSettings, std::move(saved));
}
uint64_t VideoEffectsService::Set(video_effects::mojom::SettingsPtr settings) {
  settings->version = settings_->version + 1;
  settings->retry = settings_->retry;
  settings->strength = std::isfinite(settings->strength)
                           ? std::clamp(settings->strength, 0., 1.)
                           : .5;
  if (settings->motion != video_effects::mojom::Motion::kQuality) {
    settings->cadence = video_effects::mojom::Cadence::kDouble;
  }
  settings_ = std::move(settings);
  Persist();
  Apply();
  return settings_->version;
}
uint64_t VideoEffectsService::Retry() {
  ++settings_->version;
  ++settings_->retry;
  Apply();
  return settings_->version;
}
video_effects::mojom::SnapshotPtr VideoEffectsService::Snapshot() {
  auto snapshot = video_effects::mojom::Snapshot::New();
  snapshot->settings = settings_.Clone();
  snapshot->acknowledged_version = acknowledged_;
  snapshot->gpu_connected = gpu_.is_bound() && gpu_.is_connected();
  for (const auto& player : players_) {
    snapshot->players.push_back(player.Clone());
  }
  return snapshot;
}
