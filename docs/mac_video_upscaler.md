# Live Mac video effects

This experimental Chromium fork adds `chrome://video-effects/` for live video
upscaling across tabs. Enable effects and choose VideoToolbox low-latency 2× or
MetalFX 2×. The master toggle bypasses all effects without losing saved choices.
Motion processing, output frame rate, and temporal noise filtering controls,
including filtering strength, are hidden in this release. Their saved settings
and underlying processing remain available internally.

## Install

Download the Apple silicon DMG from this repository's GitHub Releases, open it,
and drag `Chromium.app` to Applications. Requires macOS 26 or later. Open
`chrome://video-effects/` beside a supported video. Fresh profiles start with
effects disabled.

The app is ad-hoc signed, **not notarized by Apple**. macOS may require explicit
approval in System Settings → Privacy & Security. No automatic updates are
configured. It uses the standard Chromium profile, so back up an existing
Chromium profile before using this experimental build. Third-party license
notices are included at `chrome://credits/`.

## Build

Requires Apple silicon, macOS 26+, full Xcode, and `depot_tools` on PATH.
Follow [Chromium's macOS prerequisites](mac_build_instructions.md).
From a new checkout directory:

```sh
gclient config https://github.com/gulzar1996/chromium.git
gclient sync --no-history --revision src@refs/heads/mac-video-upscaler
cd src
mkdir -p out/Upscale
cp tools/mac_video_upscaler/args.gn out/Upscale/args.gn
gn gen out/Upscale
autoninja -C out/Upscale -j 8 chrome
out/Upscale/Chromium.app/Contents/MacOS/Chromium --user-data-dir="$PWD/out/video-effects-profile" chrome://video-effects/
```

The Chromium base is `76224fa6bd643dc793378bd1f2df4d4797e0b390`.
The configuration uses an arm64 release component build with H.264 enabled.
Keep the output directory intact for development; the installer packages the
required libraries inside the app so that the installed copy is self-contained.

## Package

Python 3.11+ and the built Chromium app are required:

```sh
python3 tools/mac_video_upscaler/package-chromium.py --build-dir out/Upscale --output-dir out/releases --version 0.1.0
```

The packager follows the app and helper library dependencies, adds relative
in-bundle links for standalone helpers, preserves entitlements, ad-hoc signs
nested code and bundles, and verifies the signatures. It produces a compressed
DMG with an Applications shortcut, installation notes, Chromium's license, and a
separate SHA-256 checksum. It does not notarize the app.

## Processing and scope

Supported inputs are uncropped, even-sized, 8-bit SDR video up to 1920×1080
from the VideoToolbox decoder. Unsupported configurations pass through. Software
decoding, protected content, and HDR enhancement are outside this scope. Runtime
support depends on Apple's configuration checks; on the development M4 Pro,
VideoToolbox 2× accepts 640×360 and 854×480 but rejects 1920×1080, while MetalFX
supports 1080p → 4K.

The page reports requested and active effects, input/output dimensions, source
FPS, processed FPS, processing time, queue depth, applied settings versions, and
fallback reasons. Processed FPS describes worker output, not display presentation.
Chromium can suspend background videos.

Decoded pictures are reordered before processing. The pipeline is temporal noise
filtering → motion processing → upscaling → IOSurface conversion → Chromium's
normal playback scheduler. Low-latency interpolation inserts midpoints; quality
conversion supports 2× source or fixed 60/120 FPS grids. Seeks and discontinuities
clear temporal history. Replacement sessions prepare asynchronously while video
continues; overload bypasses enhancement and retries later. Retry bypassed effects
requests immediate recovery. Settings persist in Local State and are restored
following GPU reconnection. The retired `chrome://flags/#mac-video-upscaler` choice
is migrated once when no new settings exist.

## Validate

Node 22+ and FFmpeg are required for browser validation:

```sh
./tools/mac_video_upscaler/test-native.sh
./tools/mac_video_upscaler/test-video-effects.sh
CHROMIUM_BINARY="$PWD/out/Upscale/Chromium.app/Contents/MacOS/Chromium" node tools/mac_video_upscaler/video-effects-browser.mjs
# Add --headed for fullscreen and picture-in-picture checks.
autoninja -C out/Upscale -j 8 video_effects_unittests
out/Upscale/video_effects_unittests
```

Set `CHROMIUM_BINARY` to an installed app executable to validate a release.
The browser suite checks hidden controls, live changes during playback, two
players, master bypass, seek/EOS, persistence, legacy migration, and GPU recovery.
It can exercise hidden controls programmatically to retain pipeline coverage.
The GPU sandbox remains enabled. Browser artifacts are written under
`chromium-work/video-effects-validation/` (with `-headed` for headed runs).
