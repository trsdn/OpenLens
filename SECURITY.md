# Security policy

## Reporting a vulnerability

Report privately through
[GitHub Security Advisories](https://github.com/trsdn/OpenLens/security/advisories/new).
**Do not open a public issue.**

Please include the macOS version, the OpenLens version (`Contents/Info.plist` →
`CFBundleShortVersionString`), and the smallest reproduction you can manage. You
should get an acknowledgement within seven days and an assessment within thirty.

## What is in scope

OpenLens is two pieces of code, and only one of them is an ordinary app. The
other is a camera extension that macOS keeps running on its own so that calls do
not break when the app quits.

| Component | Runs in | Privilege |
|---|---|---|
| `com.trsdn.openlens.camera.systemextension` | Its own process, managed by the system, outliving the app | Hardened runtime; publishes a virtual camera every app on the machine can open |
| `OpenLens.app` | The logged-in user | Hardened runtime, camera and local-network entitlements |

Taken seriously:

- Anything that lets a process other than OpenLens push frames into the virtual
  camera, or read frames out of the transport between the app and the extension.
- Anything that makes the extension crash, hang or corrupt memory. It is a
  long-lived process that other applications open, so a fault there is not
  contained to OpenLens.
- A way to make the extension keep publishing after it should have stopped, or
  to keep a frame visible after the user paused or quit — a pause that does not
  actually stop the picture is a privacy failure, not a cosmetic bug.
- Signature or entitlement weaknesses that would let a substituted bundle
  inherit the camera grant.
- Anything in the Key Light support that lets a device on the network influence
  the app beyond the lamp state it is supposed to report: unbounded reads,
  parsing that trusts length fields, or a response that can reach outside the
  lighting model.
- Scene files that can do more than describe a scene. They are JSON in the
  user's container, but a crafted file must not be able to make the app write
  outside it or execute anything.

## What is out of scope

- Physical access to an unlocked machine.
- The user deliberately pointing OpenLens at a camera they should not be using.
  OpenLens asks macOS for camera access like any other app and inherits its
  permission model.
- Elgato lamps being controllable by anyone on the same network. That is the
  lamps' own design: their HTTP API has no authentication, and OpenLens neither
  adds nor can add one.
- Denial of service that needs an attacker already able to run code as the
  logged-in user.
- Reports that amount to "an unsigned build behaves differently". Only the
  notarized release is supported; see below.

## Release integrity

Releases are built, signed, notarized and stapled by
[trsdn/macos-notarization-broker](https://github.com/trsdn/macos-notarization-broker).
Apple credentials do not exist in this repository or on any developer machine
used for a release.

The broker builds and validates in jobs that hold no secrets, and signs only the
bytes that validation already described. Each release carries `provenance.json`
and `preflight-manifest.json` recording the exact source commit, the bundle
layout and the digests. Verify a download with:

```bash
spctl -a -vvv -t open --context context:primary-signature OpenLens-*.dmg
shasum -a 256 -c OpenLens-*.dmg.sha256
```

A build that Gatekeeper rejects, or whose digest does not match the release, did
not come from the broker. Please report it.

## Supported versions

The latest release is supported. Fixes go into the next release rather than
into patches of older tags.
