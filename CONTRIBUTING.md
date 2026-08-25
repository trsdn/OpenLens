# Contributing

Thanks for your interest in OpenLens. It is a small, deliberately narrow app —
framing a live camera for video calls — and the quickest way to get a change
merged is to keep it inside that scope.

## Before you start

- Open an issue first for anything that adds a feature or changes behaviour.
  Bug fixes and documentation can go straight to a pull request.
- Do **not** report vulnerabilities in a public issue. Follow
  [SECURITY.md](SECURITY.md).
- Things that are out of scope by design: recording, audio, a timeline,
  projects, accounts, and anything that needs a server.

## Building

```bash
brew install xcodegen          # only needed if you change project.yml
./scripts/build.sh             # builds, signs and installs to /Applications
```

During development, allow unnotarized extensions once per machine:

```bash
systemextensionsctl developer on
```

macOS only re-stages an extension when its version changes, so `build.sh` stamps
every build with a timestamped build number. Quit and relaunch the app after
installing — replacing the extension underneath a running app drops the frame
transport.

**If you change `project.yml`, regenerate `OpenLens.xcodeproj` and commit it.**
The project file is checked in on purpose: releases are built by a job that has
only the preinstalled toolchain and cannot fetch XcodeGen. See
[Releasing](README.md#releasing).

## Testing

```bash
xcodebuild test -project OpenLens.xcodeproj -scheme OpenLens \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO
```

The suite includes GPU tests that read back rendered output and assert the crop
and overlay compositing, so it needs a real Mac rather than a simulator.

Add tests for behaviour you change. The test target deliberately pulls in
individual source files rather than the whole app, so logic worth testing should
live somewhere it can be reached without a camera or a network — the existing
split between `LightController` (network) and `SceneLighting` (rules) is the
pattern to follow.

Two areas where a test is not optional:

- **The scene format.** `CameraScene` has a hand-written `CodingKeys` list and a
  spelled-out initialiser. Adding a property and forgetting either compiles
  cleanly and silently drops the value from every saved scene.
  `CameraSceneCodingTests` pins the key set so that mistake fails a test instead
  of a user's presets.
- **Key Light arithmetic.** The lamps speak mired, not kelvin, and the scale runs
  backwards. `KeyLightTests` covers the conversion and the partial PUT body.

## Pull requests

1. Keep the change focused; unrelated cleanups belong in their own pull request.
2. Explain *why* in the commit message, not just what. The history is meant to
   be readable later by someone wondering why a thing is the way it is.
3. Make sure the full test suite passes.
4. Update `README.md` when behaviour or setup changes.

## Style

The codebase comments the reasoning, not the mechanics. A comment explaining
what a line does is noise; a comment explaining why a non-obvious choice was
made — a debounce window, an ordering constraint, a workaround for how macOS
behaves — is the point. Several bugs in this project were caused by assumptions
that were obvious to the author and to nobody else.
