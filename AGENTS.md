# Working on OpenLens

## Releases are notarized by the broker, never locally

**Do not run `xcrun notarytool`, do not ask for an app-specific password, and do
not suggest creating a `notarytool` keychain profile.** Apple credentials
deliberately do not exist on this machine.

Notarization goes through **[trsdn/macos-notarization-broker](https://github.com/trsdn/macos-notarization-broker)**,
a manual GitHub Actions workflow that builds, signs, notarizes and staples in
isolated jobs so that source-repository code never touches the signing secrets.

To cut a release:

1. Tag the commit in this repository as `vX.Y.Z` and push the tag.
2. From a checkout of the broker: `scripts/request.sh openlens vX.Y.Z`
   (or **Actions → Notarize macOS release → Run workflow** from `main`).

`request.sh` correlates the exact run, downloads only that artifact, and
verifies `provenance.json` plus the release digests.

### OpenLens must be allowlisted first

The broker only signs applications listed in `profiles/apps.json`. As of this
writing **OpenLens has no profile**, so a release request will be rejected.
Adding one is a reviewed pull request against the broker and needs:

- an entry in `profiles/apps.json` naming `trsdn/OpenLens`, the bundle
  identifier `com.trsdn.openlens`, the executable, architectures and minimum
  system version;
- a `nested_executables` entry for the camera system extension
  `Contents/Library/SystemExtensions/com.trsdn.openlens.camera.systemextension`
  — anything Mach-O that is not declared is rejected by the preflight;
- broker-owned entitlements plists for both the app and the extension;
- a new build adapter in `scripts/broker.py` (the existing ones are named
  like `spacemender-xcode`), because the broker never runs scripts from the
  source repository.

`scripts/release.sh` in this repository predates the broker. It still describes
the local path and is kept only for reference.

## Why notarization is not optional here

Gatekeeper refuses to activate a camera system extension that is not notarized,
so there is no "just ship the zip" shortcut. The app and the embedded extension
are signed separately, and both must carry a Developer ID Application
certificate.

## Build and test

```bash
xcodebuild test -project OpenLens.xcodeproj -scheme OpenLens -destination 'platform=macOS'
```

The Xcode project is generated from `project.yml` by `xcodegen`; regenerate it
after adding or removing files.

## The scene format is hand-written

`CameraScene` has a `CodingKeys` list, a spelled-out initialiser and two private
optional properties. Adding a property and forgetting any of the three compiles
cleanly and silently drops the value from every saved scene.
`CameraSceneCodingTests.testTheStoredKeysAreExactlyTheOnesWeExpect` pins the key
set so that mistake fails a test instead of a user's presets.

Whatever sets the new property in `AppModel` must also persist it — either
`scenes.save()` directly, or `schedulePersist()` for anything driven by a slider.
