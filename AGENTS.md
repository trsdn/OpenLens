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

### OpenLens is allowlisted as the `openlens` profile

The broker only signs applications listed in its `profiles/apps.json`. OpenLens
was added there in
[broker#25](https://github.com/trsdn/macos-notarization-broker/pull/25), which
declares:

- the bundle identifier `com.trsdn.openlens`, the executable, `arm64`, and the
  minimum system version;
- a `nested_executables` entry for the camera system extension
  `Contents/Library/SystemExtensions/com.trsdn.openlens.camera.systemextension`,
  pinned as a `plugin_bundle` with package type `SYSX` — anything Mach-O or any
  nested bundle that is not declared is rejected by the preflight;
- broker-owned entitlements plists for both the app and the extension;
- the `openlens-xcode` build adapter, because the broker never runs scripts from
  the source repository.

Since
[broker#29](https://github.com/trsdn/macos-notarization-broker/pull/29) it also
declares a `provisioning_profile`. `com.apple.developer.system-extension.install`
is a *restricted* entitlement: macOS honours it only if the app bundle contains
`Contents/embedded.provisionprofile` granting it. Nothing about signing reveals
a missing profile — codesign, notarization, stapling and Gatekeeper all pass,
and the app dies at launch with `Launch failed` and, in the log,
`AppleMobileFileIntegrityError -413`. Releases v0.1.0 and v0.1.1 shipped that
way and cannot be started on any Mac.

The profile lives in the broker's `macos-signing` environment as
`OPENLENS_PROVISIONING_PROFILE` and must be a **Developer ID** profile from the
Apple Developer portal. The Xcode "Mac Team Provisioning Profile" that a local
build embeds is not usable: it names the Macs it was issued for, so it works on
the machine that built the app and nowhere else. The broker rejects it.

Any change to the app's identity, layout, architecture, entitlements, or minimum
macOS version needs a reviewed pull request against the broker **before** the
next release, or the preflight will reject the build.

Two consequences for this repository:

- `OpenLens.xcodeproj` is committed on purpose. The broker's build job uses only
  the preinstalled runner toolchain, so it cannot fetch `xcodegen`. Regenerate
  **and commit** the project after changing `project.yml`.
- The source repository must stay readable by the broker workflow, which
  authenticates with its own `github.token`.

`scripts/release.sh` in this repository predates the broker. It still describes
the local path and is kept only for reference.

## Why notarization is not optional here

Gatekeeper refuses to activate a camera system extension that is not notarized,
so there is no "just ship the zip" shortcut. The app and the embedded extension
are signed separately, and both must carry a Developer ID Application
certificate.

A notarized build is not necessarily a working one. Before publishing a release,
download the artifact and actually start it — the local development build is
signed differently and proves nothing about it:

```bash
ls OpenLens.app/Contents/embedded.provisionprofile   # must exist
spctl -a -vvv -t exec OpenLens.app                   # must say "accepted"
open OpenLens.app                                    # must actually open
```

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

## Scenes that cannot be read are never overwritten

`SceneStore.load` reports a decoding failure as `readability == .unreadable`
instead of swallowing it, copies the bytes to `scenes.v1.unreadable`, and `save`
refuses to write for as long as that lasts. `AppModel` correspondingly only
creates a starter scene when nothing was ever saved.

Together these close a total data-loss path: a scene the app could not decode
used to leave `scenes` empty, which made `AppModel` create a blank scene and
save it over the user's entire library on launch. `SceneStorePreservationTests`
pins all of it — do not relax the guard in `save` to "simplify" it.

Discarding the data stays possible, but only through `startFresh()`, which the
user triggers from `SceneRecoveryBanner`. Nothing may discard scenes on the
user's behalf.

## The app is sandboxed, so debug builds write somewhere else

Preferences live in
`~/Library/Containers/com.trsdn.openlens/Data/Library/Preferences/`. A build made
with `CODE_SIGNING_ALLOWED=NO` has no sandbox entitlement and uses
`~/Library/Preferences/` instead, where it looks like an app with no saved
scenes. Check the container before concluding anything about missing settings.
