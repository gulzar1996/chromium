// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license.
#ifndef CHROME_BROWSER_UI_WEBUI_VIDEO_EFFECTS_VIDEO_EFFECTS_UI_H_
#define CHROME_BROWSER_UI_WEBUI_VIDEO_EFFECTS_VIDEO_EFFECTS_UI_H_
#include "content/public/browser/webui_config.h"
#include "media/mojo/mojom/video_effects/video_effects.mojom.h"
#include "mojo/public/cpp/bindings/receiver_set.h"
#include "ui/webui/mojo_web_ui_controller.h"
class VideoEffectsUI : public ui::MojoWebUIController,
                       public video_effects::mojom::PageHandler {
 public:
  explicit VideoEffectsUI(content::WebUI* web_ui);
  ~VideoEffectsUI() override;
  void BindInterface(
      mojo::PendingReceiver<video_effects::mojom::PageHandler> receiver);
  void GetSnapshot(GetSnapshotCallback callback) override;
  void SetSettings(video_effects::mojom::SettingsPtr settings,
                   SetSettingsCallback callback) override;
  void Retry(RetryCallback callback) override;

 private:
  mojo::ReceiverSet<video_effects::mojom::PageHandler> receivers_;
  WEB_UI_CONTROLLER_TYPE_DECL();
};
class VideoEffectsUIConfig
    : public content::DefaultWebUIConfig<VideoEffectsUI> {
 public:
  VideoEffectsUIConfig() : DefaultWebUIConfig("chrome", "video-effects") {}
};
#endif
