#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$ROOT/out"
xcrun clang++ -std=c++20 -O2 -fobjc-arc -Wall -Wextra -Werror \
  -mmacosx-version-min=26.0 \
  "$ROOT/media/gpu/mac/mac_video_upscaler.mm" \
  "$ROOT/media/gpu/mac/mac_video_processor.mm" \
  "$ROOT/media/gpu/mac/mac_video_cadence.cc" \
  "$ROOT/tools/mac_video_upscaler/video_effects_smoke.mm" \
  -framework Foundation -framework CoreImage -framework CoreGraphics \
  -framework CoreVideo -framework CoreMedia -framework Metal \
  -framework MetalFX -framework VideoToolbox \
  -o "$ROOT/out/video-effects-smoke"
"$ROOT/out/video-effects-smoke"
