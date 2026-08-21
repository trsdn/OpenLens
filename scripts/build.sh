#!/bin/bash
# Builds a signed OpenLens.app and installs it to /Applications.
#
# macOS refuses to activate a camera system extension from anywhere other than
# /Applications, so "build" and "install" are one step on purpose.
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${CONFIGURATION:-Release}"
DERIVED_DATA="$PROJECT_DIR/.build/DerivedData"
APP_NAME="OpenLens.app"

cd "$PROJECT_DIR"

if ! command -v xcodegen >/dev/null 2>&1; then
    echo "xcodegen is required: brew install xcodegen" >&2
    exit 1
fi

echo "==> Regenerating the Xcode project"
xcodegen generate --quiet

# macOS only re-stages a system extension when its version changes, so every
# development build gets a fresh build number. Without this the old extension
# keeps running and changes appear to have no effect.
BUILD_NUMBER="${BUILD_NUMBER:-$(date +%Y%m%d%H%M%S)}"

echo "==> Building ($CONFIGURATION, build $BUILD_NUMBER)"
xcodebuild \
    CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
    -project OpenLens.xcodeproj \
    -scheme OpenLens \
    -configuration "$CONFIGURATION" \
    -destination 'platform=macOS' \
    -derivedDataPath "$DERIVED_DATA" \
    -allowProvisioningUpdates \
    -allowProvisioningDeviceRegistration \
    build

BUILT_APP="$DERIVED_DATA/Build/Products/$CONFIGURATION/$APP_NAME"
if [[ ! -d "$BUILT_APP" ]]; then
    echo "Build did not produce $BUILT_APP" >&2
    exit 1
fi

if [[ "${INSTALL_TO_APPLICATIONS:-1}" != "1" ]]; then
    echo "==> Skipping installation (INSTALL_TO_APPLICATIONS=0)"
    echo "$BUILT_APP"
    exit 0
fi

if pgrep -x OpenLens >/dev/null 2>&1; then
    echo "==> Quitting the running copy"
    osascript -e 'quit app "OpenLens"' || true
    sleep 1
fi

echo "==> Installing to /Applications"
rm -rf "/Applications/$APP_NAME"
ditto "$BUILT_APP" "/Applications/$APP_NAME"

echo "==> Verifying the signature"
codesign --verify --deep --strict --verbose=2 "/Applications/$APP_NAME"

cat <<'EOF'

Done. Launch OpenLens from /Applications and approve the camera extension in
System Settings › General › Login Items & Extensions when prompted.

Useful during development:
  systemextensionsctl developer on   # allow unnotarized builds
  systemextensionsctl list           # check activation state
  log stream --predicate 'subsystem BEGINSWITH "com.trsdn.openlens"' --level info
EOF
