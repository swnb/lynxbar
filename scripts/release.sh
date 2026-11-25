#!/usr/bin/env bash
#
# Release pipeline: generate Xcode project -> Release archive -> signed export ->
# Apple notarization -> staple ticket -> package DMG + SHA256SUMS.txt.
#
# Required environment variables:
#   APPLE_ID       - Apple ID email address
#   TEAM_ID        - Apple Developer Team ID (10 characters)
#   APP_PASSWORD   - App-specific password (https://appleid.apple.com)
#
# Usage:
#   APPLE_ID=you@example.com TEAM_ID=XXXXXXXXXX APP_PASSWORD=xxxx-xxxx-xxxx-xxxx \
#     ./scripts/release.sh 0.1.0
#
set -euo pipefail

APP_NAME="LynxBar"
SCHEME="LynxBar"
BUILD_DIR="build"
ARCHIVE="$BUILD_DIR/$APP_NAME.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
VERSION="${1:-}"
VERSION="${VERSION#v}"
TEMP_EXPORT_PLIST=""

cleanup() {
  if [[ -n "$TEMP_EXPORT_PLIST" && -f "$TEMP_EXPORT_PLIST" ]]; then
    rm -f "$TEMP_EXPORT_PLIST"
  fi
}
trap cleanup EXIT

: "${APPLE_ID:?Please set APPLE_ID}"
: "${TEAM_ID:?Please set TEAM_ID}"
: "${APP_PASSWORD:?Please set APP_PASSWORD (app-specific password)}"

echo "==> Generating Xcode project"
xcodegen generate

VERSION_ARGS=()
if [[ -n "$VERSION" ]]; then
  echo "==> Using release version $VERSION"
  VERSION_ARGS+=(MARKETING_VERSION="$VERSION")
fi

mkdir -p "$BUILD_DIR"
TEMP_EXPORT_PLIST="$(mktemp "$BUILD_DIR/exportOptions.XXXXXX")"
sed "s/TEAM_ID_PLACEHOLDER/$TEAM_ID/g" exportOptions.plist > "$TEMP_EXPORT_PLIST"
plutil -lint "$TEMP_EXPORT_PLIST" >/dev/null

echo "==> Archiving (Release)"
set -o pipefail
xcodebuild \
  -project "$APP_NAME.xcodeproj" \
  -scheme "$SCHEME" \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  ${VERSION_ARGS[@]+"${VERSION_ARGS[@]}"} \
  archive | tail -5

echo "==> Exporting signed app"
xcodebuild \
  -archivePath "$ARCHIVE" \
  -exportArchive \
  -exportOptionsPlist "$TEMP_EXPORT_PLIST" \
  -exportPath "$EXPORT_DIR" | tail -5

APP="$EXPORT_DIR/$APP_NAME.app"
[[ -d "$APP" ]] || { echo "Missing exported app at $APP"; exit 1; }

ZIP="$BUILD_DIR/$APP_NAME.zip"
echo "==> Compressing for notarization -> $ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Submitting for notarization (notarytool)"
xcrun notarytool submit "$ZIP" \
  --apple-id "$APPLE_ID" \
  --team-id "$TEAM_ID" \
  --password "$APP_PASSWORD" \
  --wait

echo "==> Stapling notarization ticket (stapler)"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Creating DMG"
if [[ -n "$VERSION" ]]; then
  DMG="$BUILD_DIR/$APP_NAME-$VERSION.dmg"
else
  DMG="$BUILD_DIR/$APP_NAME.dmg"
fi
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$APP" -ov -fs APFS "$DMG"

(cd "$BUILD_DIR" && shasum -a 256 "$(basename "$DMG")" > SHA256SUMS.txt)

echo "==> Done"
echo "    DMG: $DMG"
echo "    SHA256: $BUILD_DIR/SHA256SUMS.txt"
echo "    Verify: xcrun stapler validate '$APP'"
