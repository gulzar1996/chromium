// Copyright 2023 The Chromium Authors
// Use of this source code is governed by a BSD-style license that can be
// found in the LICENSE file.

#ifndef MEDIA_GPU_MAC_VIDEO_TOOLBOX_VIDEO_DECODER_H_
#define MEDIA_GPU_MAC_VIDEO_TOOLBOX_VIDEO_DECODER_H_

#include <CoreMedia/CoreMedia.h>
#include <VideoToolbox/VideoToolbox.h>

#include <memory>
#include <utility>
#include <vector>

#include "base/apple/scoped_cftyperef.h"
#include "base/containers/flat_map.h"
#include "base/containers/queue.h"
#include "base/functional/callback.h"
#include "base/functional/callback_forward.h"
#include "base/memory/scoped_refptr.h"
#include "base/task/sequenced_task_runner.h"
#include "base/time/time.h"
#include "build/build_config.h"
#if BUILDFLAG(IS_MAC)
#include "media/gpu/mac/mac_video_effects_pipeline.h"
#include "media/gpu/mac/mac_video_presentation_queue.h"
#endif
#include "gpu/config/gpu_driver_bug_workarounds.h"
#include "media/base/decoder_buffer.h"
#include "media/base/supported_video_decoder_config.h"
#include "media/base/video_decoder.h"
#include "media/base/video_decoder_config.h"
#include "media/gpu/codec_picture.h"
#include "media/gpu/mac/video_toolbox_decompression_session_manager.h"
#include "media/gpu/mac/video_toolbox_frame_converter.h"
#include "media/gpu/mac/video_toolbox_output_queue.h"
#include "media/gpu/media_gpu_export.h"

namespace gpu {
class CommandBufferStub;
}  // namespace gpu

namespace media {

class AcceleratedVideoDecoder;
class MediaLog;
struct VideoToolboxDecodeMetadata;
struct VideoToolboxDecompressionSessionMetadata;

class MEDIA_GPU_EXPORT VideoToolboxVideoDecoder : public VideoDecoder {
 public:
  using GetCommandBufferStubCB =
      base::RepeatingCallback<gpu::CommandBufferStub*()>;

  VideoToolboxVideoDecoder(
      scoped_refptr<base::SequencedTaskRunner> task_runner,
      std::unique_ptr<MediaLog> media_log,
      const gpu::GpuDriverBugWorkarounds& gpu_workarounds,
      scoped_refptr<base::SequencedTaskRunner> gpu_task_runner,
      GetCommandBufferStubCB get_stub_cb);

  ~VideoToolboxVideoDecoder() override;

  // VideoDecoder implementation.
  void Initialize(const VideoDecoderConfig& config,
                  bool low_delay,
                  CdmContext* cdm_context,
                  InitCB init_cb,
                  const OutputCB& output_cb,
                  const WaitingCB& waiting_cb) override;
  void Decode(scoped_refptr<DecoderBuffer> buffer, DecodeCB decode_cb) override;
  void Reset(base::OnceClosure reset_cb) override;
  bool NeedsBitstreamConversion() const override;
  int GetMaxDecodeRequests() const override;
  VideoDecoderType GetDecoderType() const override;

  static std::vector<SupportedVideoDecoderConfig>
  GetSupportedVideoDecoderConfigs(
      const gpu::GpuDriverBugWorkarounds& gpu_workarounds);

 private:
  // Shut down and enter a permanent error state.
  void NotifyError(DecoderStatus status);

  // Drop all state, calling decode callbacks with |status|.
  void ResetInternal(DecoderStatus status);

  // Call |decode_cb_| entries until the correct backpressure is achieved.
  void ReleaseDecodeCallbacks();

  // |accelerator_| callbacks.
  void OnAcceleratorDecode(
      base::apple::ScopedCFTypeRef<CMSampleBufferRef> sample,
      VideoToolboxDecompressionSessionMetadata session_metadata,
      scoped_refptr<CodecPicture> picture);
  void OnAcceleratorOutput(scoped_refptr<CodecPicture> picture);

  // |video_toolbox_| callbacks.
  void OnVideoToolboxOutput(
      base::apple::ScopedCFTypeRef<CVImageBufferRef> image,
      std::unique_ptr<VideoToolboxDecodeMetadata> metadata);
  void OnVideoToolboxError(DecoderStatus status);

#if BUILDFLAG(IS_MAC)
  struct Source {
    base::apple::ScopedCFTypeRef<CVImageBufferRef> image;
    std::unique_ptr<VideoToolboxDecodeMetadata> metadata;
  };
  struct Completed {
    std::unique_ptr<VideoToolboxDecodeMetadata> metadata;
    MacVideoProcessor::Batch batch;
  };
  void DrainPresentationOrder();
  void OnEffectsOutput(uint64_t serial,
                       std::unique_ptr<VideoToolboxDecodeMetadata> metadata,
                       MacVideoProcessor::Batch batch);
  void MaybeFinishEffectsFlush();
  std::unique_ptr<MacVideoEffectsPipeline> effects_;
  MacVideoPresentationQueue<scoped_refptr<CodecPicture>, Source>
      presentation_order_;
  base::flat_map<uint64_t, Completed> completed_effects_;
  uint64_t submitted_serial_ = 0, completed_serial_ = 0;
  size_t num_effects_ = 0;
  std::string effects_status_;
  DecodeCB effects_flush_cb_;
#endif
  void ConvertImage(base::apple::ScopedCFTypeRef<CVImageBufferRef> image,
                    std::unique_ptr<VideoToolboxDecodeMetadata> metadata);

  // |converter_| callbacks.
  void OnConverterOutput(scoped_refptr<VideoFrame> frame,
                         std::unique_ptr<VideoToolboxDecodeMetadata> metadata);

  scoped_refptr<base::SequencedTaskRunner> task_runner_;
  std::unique_ptr<MediaLog> media_log_;
  gpu::GpuDriverBugWorkarounds gpu_workarounds_;
  scoped_refptr<base::SequencedTaskRunner> gpu_task_runner_;
  GetCommandBufferStubCB get_stub_cb_;

  bool has_error_ = false;

  std::unique_ptr<AcceleratedVideoDecoder> accelerator_;
  VideoToolboxDecompressionSessionManager video_toolbox_;
  scoped_refptr<VideoToolboxFrameConverter> converter_;
  VideoToolboxOutputQueue output_queue_;

  VideoDecoderConfig config_;

  // Used to link re-entrant OnAcceleratorDecode() callbacks to Decode() calls.
  scoped_refptr<DecoderBuffer> active_decode_;

  // Accounts for frames that have been decoded but not yet converted. These
  // contribute to backpressure.
  size_t num_conversions_ = 0;

  // Decode callbacks, which are released in decode order. There is no mapping
  // to decode requests or frames, it is simply a backpressure mechanism.
  base::queue<DecodeCB> decode_cbs_;

  // Converter callbacks are invalidated during resets.
  base::WeakPtrFactory<VideoToolboxVideoDecoder> converter_weak_this_factory_{
      this};
};

}  // namespace media

#endif  // MEDIA_GPU_MAC_VIDEO_TOOLBOX_VIDEO_DECODER_H_
