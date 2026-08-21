#!/bin/bash
# Builds, notarizes and staples a distributable OpenLens DMG.
#
# Gatekeeper refuses to activate a camera system extension that is not notarized,
# so unlike most Mac apps there is no "just ship the zip" shortcut here.
#
# Requires a notarytool keychain profile:
#   xcrun notarytool store-credentials openlens-notary \
#       --apple-id <apple-id> --team-id G69Z5BNY97 --password <app-specific-password>
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
DERIVED_DATA="$PROJECT_DIR/.build/DerivedData"
DIST="$PROJECT_DIR/dist"
PROFILE="${NOTARY_PROFILE:-openlens-notary}"
VERSION="${VERSION:-$(awk -F'"' '/MARKETING_VERSION/ {print $2; exit}' "$PROJECT_DIR/project.yml")}"
APP="$DERIVED_DATA/Build/Products/Release/OpenLens.app"
DMG="$DIST/OpenLens-v$VERSION-macOS-arm64.dmg"

cd "$PROJECT_DIR"

echo "==> Building the release app"
INSTALL_TO_APPLICATIONS=0 CONFIGURATION=Release ./scripts/build.sh

echo "==> Verifying the embedded extension is signed and sealed"
codesign --verify --deep --strict --verbose=2 "$APP"

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

echo "==> Done: $DMG"
