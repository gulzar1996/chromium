#!/bin/bash
set -euo pipefail
ROOT=$(cd "$(dirname "$0")/../.." && pwd)
mkdir -p "$ROOT/out/Upscale/upscaler-tests"
xcrun clang++ -I"$ROOT" -std=c++20 -O2 -fobjc-arc -Wall -Wextra -Werror \
  -mmacosx-version-min=26.0 \
  "$ROOT/media/gpu/mac/mac_video_upscaler.mm" \
  "$ROOT/tools/mac_video_upscaler/upscaler_smoke.mm" \
  -framework Foundation -framework CoreImage -framework CoreGraphics \
  -framework CoreVideo -framework CoreMedia -framework Metal \
  -framework MetalFX -framework VideoToolbox \
  -o "$ROOT/out/Upscale/upscaler-tests/upscaler-smoke"
"$ROOT/out/Upscale/upscaler-tests/upscaler-smoke"
