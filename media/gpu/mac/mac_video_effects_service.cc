// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license.
#include "media/gpu/mac/mac_video_effects_service.h"

#include <map>

#include "base/no_destructor.h"
#include "base/synchronization/lock.h"
#include "mojo/public/cpp/bindings/self_owned_receiver.h"
namespace media {
namespace {
struct Entry {
  base::RepeatingCallback<void(MacVideoEffectsSettings)> callback;
  video_effects::mojom::PlayerPtr player;
};
struct Registry {
  base::Lock lock;
  MacVideoEffectsSettings settings;
  uint64_t next_id = 1;
  std::map<uint64_t, Entry> entries;
};
Registry& GetRegistry() {
  static base::NoDestructor<Registry> value;
  return *value;
}
class Service : public video_effects::mojom::GpuService {
 public:
  void Apply(video_effects::mojom::SettingsPtr value,
             ApplyCallback done) override {
    auto& registry = GetRegistry();
    std::vector<base::RepeatingCallback<void(MacVideoEffectsSettings)>>
        callbacks;
    MacVideoEffectsSettings settings;
    {
      base::AutoLock lock(registry.lock);
      if (value->version >= registry.settings.version) {
        settings.version = value->version;
        settings.enabled = value->enabled;
        settings.upscaling = static_cast<int>(value->upscaling);
        settings.motion = static_cast<int>(value->motion);
        settings.target_fps =
            value->cadence == video_effects::mojom::Cadence::k60    ? 60
            : value->cadence == video_effects::mojom::Cadence::k120 ? 120
                                                                    : 0;
        settings.noise = value->noise;
        settings.strength = value->strength;
        settings.retry = value->retry;
        registry.settings = settings;
        for (auto& [id, entry] : registry.entries) {
          callbacks.push_back(entry.callback);
        }
      }
      settings = registry.settings;
    }
    for (auto& callback : callbacks) {
      callback.Run(settings);
    }
    std::move(done).Run(settings.version);
  }
  void GetPlayers(GetPlayersCallback done) override {
    std::vector<video_effects::mojom::PlayerPtr> players;
    auto& registry = GetRegistry();
    {
      base::AutoLock lock(registry.lock);
      for (const auto& [id, entry] : registry.entries) {
        if (entry.player) {
          players.push_back(entry.player.Clone());
        }
      }
    }
    std::move(done).Run(std::move(players));
  }
};
}  // namespace
void MacVideoEffectsService::Bind(
    mojo::PendingReceiver<video_effects::mojom::GpuService> receiver) {
  mojo::MakeSelfOwnedReceiver(std::make_unique<Service>(), std::move(receiver));
}
uint64_t MacVideoEffectsService::Register(
    base::RepeatingCallback<void(MacVideoEffectsSettings)> callback) {
  auto& registry = GetRegistry();
  base::AutoLock lock(registry.lock);
  auto id = registry.next_id++;
  registry.entries.emplace(id, Entry{callback, {}});
  // BindPostTask only posts; it cannot re-enter the registry while locked.
  callback.Run(registry.settings);
  return id;
}
void MacVideoEffectsService::Unregister(uint64_t id) {
  auto& registry = GetRegistry();
  base::AutoLock lock(registry.lock);
  registry.entries.erase(id);
}
void MacVideoEffectsService::Report(video_effects::mojom::PlayerPtr player) {
  auto& registry = GetRegistry();
  base::AutoLock lock(registry.lock);
  auto it = registry.entries.find(player->id);
  if (it != registry.entries.end()) {
    it->second.player = std::move(player);
  }
}
}  // namespace media
