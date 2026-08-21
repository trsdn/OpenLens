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
  has a slider, an editable number field and **⌘+ / ⌘− / ⌘0**, all moving in
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
- **PNG overlay with alpha,** placed on a nine-position grid with an opacity
  slider and composited in the same GPU pass.
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
| The camera never appears in Zoom | The extension is not approved yet, or the app was launched from outside `/Applications`. |
| "Camera is in use" | Some UVC devices (Cam Link 4K among them) refuse concurrent access. Quit OBS or any other app holding the camera. |
| A static card instead of the picture | The app is not running. The extension keeps the device alive on its own so calls do not break. |
| Zoom looks soft | You are past the "Stays sharp up to" limit in the inspector, and the badge says `soft`. Raise **Capture quality**. |

## License

MIT — see [LICENSE](LICENSE).
