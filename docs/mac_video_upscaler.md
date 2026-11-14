# Native Mac video upscaling

This experimental fork adds two selectable 2× video enhancement backends:

- VideoToolbox low-latency super resolution (`VTFrameProcessor`).
- MetalFX spatial scaling (`MTLFXSpatialScaler`).

Processing runs after VideoToolbox decoding on a dedicated sequenced worker.
Enhanced IOSurfaces feed Chromium's existing shared-image converter and compositor.
Intrinsic video dimensions and timestamps remain unchanged, preserving page layout.
Unsupported inputs use the original decoded frame.

## Build

The tested configuration requires Apple silicon, macOS 26+, and full Xcode with a
macOS 26 SDK. The development machine used M4 Pro, macOS 26.4 and Xcode 26.3.
Follow [Chromium's macOS prerequisites](mac_build_instructions.md), including
installing `depot_tools` on PATH. Start in a new empty checkout directory:

```sh
gclient config https://github.com/gulzar1996/chromium.git
gclient sync --no-history --revision src@refs/heads/mac-video-upscaler
cd src
mkdir -p out/Upscale
cp tools/mac_video_upscaler/args.gn out/Upscale/args.gn
gn gen out/Upscale
autoninja -C out/Upscale -j 8 chrome
```

If local Git configuration enables LFS, its helper must be installed; upstream
LFS test fixtures are not needed for the `chrome` target. The base revision is
`76224fa6bd643dc793378bd1f2df4d4797e0b390`. The provided GN configuration uses
an arm64 release component build with H.264 enabled. Keep the output directory
intact because the app depends on the accompanying component libraries.

## Select a backend

```sh
out/Upscale/Chromium.app/Contents/MacOS/Chromium \
  --user-data-dir="$PWD/out/Upscale/upscaler-profile" \
  'chrome://flags/#mac-video-upscaler'
```

Choose **Off**, **VideoToolbox low-latency super resolution (2x)** or
**MetalFX spatial scaling (2x)** and relaunch. Alternatively, pass
`--mac-video-upscaler=off`, `--mac-video-upscaler=videotoolbox` or
`--mac-video-upscaler=metalfx`. Use a separate browser profile for comparisons.

The first supported frame can take longer while Apple initializes its processor.
This implementation enhances eligible frames regardless of the player display size.

## Verify actual compositor frames

Open `chrome://media-internals` and inspect the playing video. Its decoder should
remain `VideoToolboxVideoDecoder`, with an active backend message and no subsequent
decoder fallback. An active message alone only proves processing succeeded once.

While the video plays, run this in that page's DevTools Console:

```js
document.querySelector('video').requestVideoFrameCallback((_, frame) => {
  console.table({
    compositorSize: `${frame.width}x${frame.height}`,
    submittedFrames: frame.presentedFrames,
    videoTime: frame.mediaTime,
  });
});
```

Repeat to verify the frame count and timestamp advance. For a supported 854×480
source, Off reports 854×480 and either upscaler reports 1708×960. The page's
`videoWidth`/`videoHeight` intentionally remain 854×480. In this revision, callback
width and height come from the compositor's current frame visible rectangle.
This is evidence of submission to composition, not physical display scanout.

## Validation scripts

```sh
./tools/mac_video_upscaler/test-native.sh
node tools/mac_video_upscaler/browser-smoke.mjs
node tools/mac_video_upscaler/youtube-compare.mjs
node tools/mac_video_upscaler/render-youtube-report.mjs
open out/Upscale/upscaler-tests/youtube-comparison/comparison.html
```

The browser scripts need Node 22+; the local browser smoke test also needs FFmpeg.
They use isolated headless profiles with the normal GPU sandbox enabled.

- Native checks exercise both real Apple APIs, output dimensions and IOSurface
  backing, orientation, color channels, NV12 input, HDR passthrough, resolution
  changes and backward timestamps. MetalFX 1080p→4K output is covered.
- The local H.264 test checks the flags selector, backend activation, 640×360
  intrinsic dimensions, compositor dimensions (1280×720 with enhancement),
  seeking, GPU crashes and decoder fallback.
- The live YouTube comparison targets `x22TJMv2RYo` at 480p, capturing exact
  timestamps 00:30 and 00:45. It checks source format and dimensions as well as
  compositor dimensions, rejecting cached 360p frames after quality changes.
  The offline viewer includes an A/B divider and detail crops.

The development build passed the native and local browser checks. The live
YouTube comparison verified both upscalers at 854×480→1708×960, with about 30
submitted frames/second and zero dropped frames in individual 10-second windows.
These short samples do not establish sustained performance, energy use or
motion/temporal quality. Seeking to 01:00 encountered a YouTube player error even
with enhancement Off; arbitrary seeking and full-length playback are unverified.

## Limits

Only uncropped, even-sized, 8-bit SDR frames up to 1920×1080 decoded through
VideoToolbox are eligible. HDR, other formats, crops and larger inputs pass
through. VideoToolbox additionally checks Apple's supported dimensions and scale
factors at runtime: on the development M4 Pro, 640×360 and 854×480 work, while
1920×1080 is rejected by the low-latency scaler. MetalFX supports 1080p→4K.

Processing failures return the original frame and report a status message. A
failed backend is retried when input dimensions change. Decoder backpressure
bounds in-flight work; reset invalidates stale conversion callbacks.

The upstream hardware-decoder `power_efficient` metadata invariant is retained:
setting it false crashes this revision's Mojo decoder service. It does not measure
the additional energy used by enhancement.

Protected video, software decoder paths, HDR enhancement, automatic backend
selection and per-tab switching are outside this implementation. No separate
model download, canvas extraction, frame upload server or CPU pixel readback is
used by the browser enhancement pipeline.
