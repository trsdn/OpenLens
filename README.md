# OpenLens

[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)
[![macOS](https://img.shields.io/badge/macOS-14%2B-black?logo=apple)](https://github.com/trsdn/OpenLens)
[![Swift 6](https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white)](https://swift.org)
[![Apple Silicon](https://img.shields.io/badge/Apple%20Silicon-M1%2B-333?logo=apple)](https://github.com/trsdn/OpenLens)

A lightweight virtual camera for video calls. Point it at a camera, zoom into the
part of the frame that matters, and pick **OpenLens** as your camera in Zoom,
Teams or Meet.

It does one job — framing a live camera — and deliberately does not record, does
not touch audio, and has no timeline, no projects and no accounts.

## What it does

- **Zoom and pan into any area of the frame.** Scroll or pinch over the picture
  to zoom around the pointer, drag to pan, double-click to reset. The inspector
  has a slider, an editable number field, a stepper and **⌘+ / ⌘− / ⌘0**, all moving in
  steps of 0.1×, if you would rather not aim with the mouse. The crop is a
  texture-coordinate remap inside a single Metal pass, so it costs nothing.
- **Sharp zoom.** Capture above 1080p and the crop still fills the 1080p output
  with real pixels — no upscaling. The inspector shows how far that reaches
  ("Stays sharp up to"), and the badge on the picture says `soft` once you pass
  it.
- **Scenes are the presets.** Camera, zoom, mirror and overlay are saved into
  the selected scene as you change them — there is no save button. Duplicate
  snapshots the current look, and **⌥1…⌥9** switch between scenes system-wide,
  so it works while you are in a call.
- **PNG overlay with alpha.** Drag it in the picture to move it, pull a corner
  to resize it, double-click to reset the size — or type exact percentages in
  the inspector and snap it to any of nine positions. The aspect ratio comes
  from the image, and it is composited in the same GPU pass.
- **Tone and colour correction** for cameras that have no controls of their own —
  HDMI grabbers like a Cam Link expose none, and macOS offers no manual values
  either. Exposure, black point, white point, midtones and an S-curve contrast,
  plus white balance on both axes — amber/blue and green/magenta — separate
  shadow and highlight tints, and saturation. Ten sliders that snap back to
  neutral in the middle, each with a field you can type an exact value into,
  folded into the render pass that already runs, so they cost nothing
  measurable.
- **Cheap.** Around 17 % of a single core — roughly 1.4 % of an M4 Pro — at
  1080p30 while a conferencing app is actually pulling frames. The capture
  session does not run at all when nobody is looking, and the preview pass is
  skipped when the window is hidden or the preview is switched off (**⌘P**),
  though on Apple silicon that pass is nearly free, so expect a fraction of a
  percent rather than a dramatic saving.

## How it works

```
OpenLens.app                          OpenLensCamera.systemextension
┌──────────────────────────┐          ┌──────────────────────────────┐
│ AVCaptureSession         │          │                              │
│   ↓ CVPixelBuffer        │          │                              │
│ Metal pass               │  sink    │  CMIOExtensionStream          │
│   crop + mirror + overlay│ ──────►  │    ↓                          │
│   ↓                      │  stream  │  "OpenLens" camera            │
│ CAMetalLayer preview     │          │                              │
└──────────────────────────┘          └──────────────────────────────┘
                                                    ↓
                                          Zoom / Teams / Meet
```

The app never reads a pixel on the CPU. Camera buffers arrive IOSurface-backed,
are wrapped as Metal textures, rendered once, and the result is handed to the
camera extension through a CoreMediaIO **sink stream**. The extension republishes
it on the virtual camera device, and falls back to a placeholder card whenever the
app is not running.

## Performance

Measured on an M4 Pro at 1080p30 with a Cam Link 4K, streaming to a real consumer,
as a percentage of **one** CPU core:

| | app | extension | total |
| --- | --- | --- | --- |
| Preview visible | 7.7 % | 3.6 % | **11.3 %** |
| Preview hidden | 6.3 % | 3.6 % | **9.9 %** |

Hiding the preview (inspector → Preview → Show preview) saves about 1.4 points.
It is worth switching off once a call is running, but it is not the main cost —
the virtual camera keeps streaming either way.

Two findings worth recording, because both were counter-intuitive:

- The extension used to burn **a third of a core doing nothing**.
  `CMIOExtensionStream.consumeSampleBuffer(from:)` does *not* block on an empty
  sink queue — it calls back immediately with a `nil` buffer. Re-arming from the
  completion handler, which is the shape Apple's sample code suggests, is therefore
  a busy loop. Successful reads now re-arm immediately, empty reads back off 4 ms.
  This alone took the total from 52 % to 11 % and cost no frames: still exactly
  30.00 fps.
- Sending **NV12 instead of BGRA** moves 62 % fewer bytes per frame and measured as
  **zero** improvement. It is kept because it is the format the rest of the stack
  wants, but it is not why this is fast. CoreMediaIO hands consumers `2vuy`
  regardless of what we send.

The lesson both times: measure the states, don't trust the theory. `ps %cpu` is a
lifetime average and will hide all of this — diff `ps -o time=` over a fixed window
instead.

### Capture quality: sharpness costs frames, not CPU

"Up to 4K" is worth it if you zoom. Cropping a 4K frame to 1.4× and scaling it into a
1080p output measured **1.63× more fine detail** than doing the same crop on a 1080p
source, and 2.06× more energy at half the Nyquist frequency. It is real, but it is
subtle: visible on edges and texture, not a different picture.

The catch is bandwidth, not processing. Uncompressed 4K 4:2:0 at 30 fps is ~373 MB/s,
which a USB 3 capture device cannot carry. A Cam Link 4K therefore delivers about
**20 fps** at 4K against a solid 30 fps at 1080p — sharper stills, choppier motion.
Both 4K formats it advertises behave the same way, so this is the link, not the format
choice. The inspector shows a live "Receiving" readout of what actually arrives, which
is the only honest way to make that call on an unknown camera.

Three AVFoundation traps sit between asking for 4K and getting it, all found the hard way:

- `device.activeFormat` is **outranked by the session preset**. With the default `.high`
  a 4K device still hands back 1080p. macOS has no `.inputPriority`, so a size-specific
  preset like `.hd4K3840x2160` has to be set, and the video output has to be attached
  *before* it or the session renegotiates straight back to 1080p.
- `output.videoSettings` naming a pixel format **without** `kCVPixelBufferWidthKey` and
  `HeightKey` silently inserts a scaler that returns 1080p — whatever the preset and
  `activeFormat` say. This one is invisible: nothing logs, nothing fails.
- Frame rate ranges are **never round numbers** (a Cam Link reports 30.00003 and
  60.00024), the **first** range is the fastest one, and a rate pinned inside
  `beginConfiguration`/`commitConfiguration` is wiped when the preset is committed.
  Pinning has to happen again *after* `startRunning()`, clamped into the range the
  device actually published. Missing this ran "1080p" at 60 fps, which made the
  supposedly cheap mode cost **13.2 %** of a core against 4K's 5 %; pinned properly it
  is 8 %, and the capture path alone drops from 4.3 % to 1.3 %.

### Colour correction is free

Exposure, levels, contrast, white balance, tint, split tinting and saturation happen inside the
fragment shader that already runs, so they cost no extra pass, no extra buffer and no extra
CPU work. Measured
over two 60-second windows at 1080p30 with the preview visible: **7.52 %** and **7.63 %**
of one core, against **7.97 %** for the same build without the colour code — a difference
inside the noise.

The shader is deliberately **branchless**: the coefficients are computed once on the CPU
when a slider moves, and the per-pixel maths runs identically whether the sliders sit at
neutral or at their extremes. There is no "off" fast path to fall back to, which also
means neutral settings are already the worst case for measurement.

This is why the correction lives here at all. A Cam Link is an HDMI grabber, not a camera —
it exposes no exposure or white-balance controls, and macOS `AVCaptureDevice` offers no
manual values on macOS either. The render pass is the only place left, and it happens to
be the cheapest one.

## Install

Requires macOS 14 or newer on Apple Silicon.

1. Download the DMG from [Releases](https://github.com/trsdn/OpenLens/releases)
   and drag OpenLens to **Applications** — macOS will not activate a camera
   extension from anywhere else.
2. Launch it and approve the camera extension in
   **System Settings › General › Login Items & Extensions**.
3. In your conferencing app, choose **OpenLens** as the camera.

## Build from source

```bash
brew install xcodegen
./scripts/build.sh          # builds, signs and installs to /Applications
```

During development, allow unnotarized extensions once per machine:

```bash
systemextensionsctl developer on
systemextensionsctl list                 # check activation state
```

macOS only re-stages an extension when its version changes, so `build.sh` stamps
every build with a timestamped build number. Quit and relaunch the app after
installing — replacing the extension underneath a running app drops the frame
transport.

Tests, including GPU tests that read back the rendered output and assert the crop
and overlay compositing:

```bash
xcodebuild test -project OpenLens.xcodeproj -scheme OpenLens \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

Release build (notarized, stapled DMG):

```bash
xcrun notarytool store-credentials openlens-notary \
  --apple-id <apple-id> --team-id <team-id> --password <app-specific-password>
./scripts/release.sh
```

## Troubleshooting

| Symptom | Cause |
| --- | --- |
| The camera never appears in Zoom | The extension is not approved yet, or the app was launched from outside `/Applications`. Conferencing apps also enumerate cameras **at launch** — quit and reopen Zoom/Teams/Meet after installing OpenLens. |
| Picked OpenLens, but the app shows no picture | Selecting a camera in a settings menu does not open it. Start a call or open the app's device preview and switch video on; the OpenLens banner turns green the moment a consumer attaches. |
| "Lost contact with the camera extension" | The extension was replaced while the app was running (an update does this). That kills the app's CoreMediaIO client state for good, so the banner offers a **Restart OpenLens** button; a fresh process reconnects instantly. |
| "Camera is in use" | Some UVC devices (Cam Link 4K among them) refuse concurrent access. Quit OBS or any other app holding the camera. |
| A static card instead of the picture | The app is not running. The extension keeps the device alive on its own so calls do not break. |
| Zoom looks soft | You are past the "Stays sharp up to" limit in the inspector, and the badge says `soft`. Raise **Capture quality**. |

## License

MIT — see [LICENSE](LICENSE).
