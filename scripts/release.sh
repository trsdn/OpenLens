#!/bin/bash
# Builds, notarizes and staples a distributable OpenLens DMG.
#
# SUPERSEDED — see AGENTS.md. Releases now go through the notarization broker at
# github.com/trsdn/macos-notarization-broker, which builds, signs and notarizes
# in isolated GitHub Actions jobs so that Apple credentials never reach a
# developer machine. There is deliberately no notarytool profile here, which is
# why the check below always fails.
#
# Kept for reference because it documents the signing constraints that the
# broker profile has to reproduce.
#
# Gatekeeper refuses to activate a camera system extension that is not notarized,
# so unlike most Mac apps there is no "just ship the zip" shortcut here.
#
# This does NOT reuse scripts/build.sh. That script signs for local development,
# and a development signature is exactly what the notary service rejects — the
# distinction is invisible until Apple returns "Invalid" several minutes in, so
# distribution goes through archive/export instead, which is the only path that
# applies a Developer ID certificate to the app *and* to the embedded extension.
#
# Requires a notarytool keychain profile:
#   xcrun notarytool store-credentials openlens-notary \
#       --apple-id <apple-id> --team-id G69Z5BNY97 --password <app-specific-password>
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$PROJECT_DIR/.build"
DIST="$PROJECT_DIR/dist"
PROFILE="${NOTARY_PROFILE:-openlens-notary}"
VERSION="${VERSION:-$(awk -F'"' '/MARKETING_VERSION/ {print $2; exit}' "$PROJECT_DIR/project.yml")}"
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M%S)}"
ARCHIVE="$BUILD/OpenLens.xcarchive"
EXPORT="$BUILD/export"
APP="$EXPORT/OpenLens.app"
DMG="$DIST/OpenLens-v$VERSION-macOS-arm64.dmg"

cd "$PROJECT_DIR"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen is required: brew install xcodegen" >&2
    exit 1
fi

# Fail before the build rather than after it: the archive and export take
# several minutes, and a missing profile is the one error that is certain in
# advance.
if ! xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1; then
    cat >&2 <<EOF
No notarytool keychain profile "$PROFILE".

Create it once with an app-specific password from appleid.apple.com:
  xcrun notarytool store-credentials $PROFILE \\
      --apple-id <apple-id> --team-id G69Z5BNY97 --password <app-specific-password>
EOF
    exit 1
fi

echo "==> Regenerating the Xcode project"
xcodegen generate --quiet

echo "==> Archiving ($VERSION, build $BUILD_NUMBER)"
rm -rf "$ARCHIVE" "$EXPORT"
xcodebuild \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    -project OpenLens.xcodeproj \
    -scheme OpenLens \
    -configuration Release \
    -destination 'platform=macOS' \
    -archivePath "$ARCHIVE" \
    -allowProvisioningUpdates \
    archive

echo "==> Exporting with Developer ID"
xcodebuild \
    -exportArchive \
    -archivePath "$ARCHIVE" \
    -exportOptionsPlist "$PROJECT_DIR/scripts/export-options.plist" \
    -exportPath "$EXPORT" \
    -allowProvisioningUpdates

echo "==> Verifying the signatures"
codesign --verify --deep --strict --verbose=2 "$APP"

# The check that would have saved a failed submission. The DMG wrapper being
# Developer ID signed says nothing about its contents, and the extension is
# signed separately from the app, so both are asserted by name.
EXTENSION="$APP/Contents/Library/SystemExtensions/com.trsdn.openlens.camera.systemextension"
for target in "$APP" "$EXTENSION"; do
    authority="$(codesign -dvv "$target" 2>&1 | awk -F= '/^Authority=/ {print $2; exit}')"
    case "$authority" in
        "Developer ID Application:"*) echo "    $(basename "$target"): $authority" ;;
        *)
            echo "$(basename "$target") is signed by \"$authority\"," >&2
            echo "not a Developer ID Application certificate. Notarization would fail." >&2
            exit 1
            ;;
    esac
done

mkdir -p "$DIST"
rm -f "$DMG"

echo "==> Building the disk image"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "OpenLens" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null

echo "==> Signing the disk image"
codesign --sign "Developer ID Application" --timestamp "$DMG"

echo "==> Notarizing (this takes a few minutes)"
xcrun notarytool submit "$DMG" --keychain-profile "$PROFILE" --wait

echo "==> Stapling"
xcrun stapler staple "$DMG"
xcrun stapler validate "$DMG"

# What a user's Mac actually evaluates on first launch. Stapling only proves
# the ticket is attached; this proves Gatekeeper accepts it.
echo "==> Checking Gatekeeper accepts the app"
spctl --assess --type execute --verbose=4 "$APP"

echo "==> Done: $DMG"
