// Copyright 2026 The Chromium Authors
// Use of this source code is governed by a BSD-style license.
#include "chrome/browser/ui/webui/video_effects/video_effects_ui.h"

#include "chrome/browser/ui/webui/video_effects/video_effects_service.h"
#include "chrome/grit/video_effects_resources.h"
#include "chrome/grit/video_effects_resources_map.h"
#include "content/public/browser/web_contents.h"
#include "content/public/browser/web_ui.h"
#include "content/public/browser/web_ui_data_source.h"
#include "ui/webui/webui_util.h"
VideoEffectsUI::VideoEffectsUI(content::WebUI* web_ui)
    : ui::MojoWebUIController(web_ui) {
  auto* source = content::WebUIDataSource::CreateAndAdd(
      web_ui->GetWebContents()->GetBrowserContext(), "video-effects");
  webui::SetupWebUIDataSource(source, kVideoEffectsResources,
                              IDR_VIDEO_EFFECTS_VIDEO_EFFECTS_HTML);
  VideoEffectsService::Get().Start();
}
VideoEffectsUI::~VideoEffectsUI() = default;
WEB_UI_CONTROLLER_TYPE_IMPL(VideoEffectsUI)
void VideoEffectsUI::BindInterface(
    mojo::PendingReceiver<video_effects::mojom::PageHandler> receiver) {
  receivers_.Add(this, std::move(receiver));
}
void VideoEffectsUI::GetSnapshot(GetSnapshotCallback callback) {
  std::move(callback).Run(VideoEffectsService::Get().Snapshot());
}
void VideoEffectsUI::SetSettings(video_effects::mojom::SettingsPtr settings,
                                 SetSettingsCallback callback) {
  std::move(callback).Run(VideoEffectsService::Get().Set(std::move(settings)));
}
void VideoEffectsUI::Retry(RetryCallback callback) {
  std::move(callback).Run(VideoEffectsService::Get().Retry());
}
