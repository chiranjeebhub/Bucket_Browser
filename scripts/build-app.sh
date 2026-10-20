#!/usr/bin/env bash
# Builds "Bucket Browser.app" from the Swift package and signs it.
# Usage: scripts/build-app.sh [debug|release]   (default: release)
#
# By default the app is ad-hoc signed, which can't use iCloud Keychain. To build a copy
# that syncs accounts through iCloud, sign it with your team's Developer ID:
#   SIGN_IDENTITY="Developer ID Application: Your Name (4TK5PNR392)" \
#   PROVISIONING_PROFILE=path/to/BucketBrowser.provisionprofile \
#   scripts/build-app.sh
# TEAM_ID defaults to 4TK5PNR392 and must match the certificate and the profile.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Bucket Browser"
BUNDLE_ID="com.bucketbrowser.app"
TEAM_ID="${TEAM_ID:-4TK5PNR392}"
VERSION="${VERSION:-0.1.0}"
BUILD_NUMBER="${BUILD_NUMBER:-1}"
OUT="$ROOT/build"
APP="$OUT/$APP_NAME.app"

cd "$ROOT"
ARCH_FLAGS=()
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  ARCH_FLAGS=(--arch arm64 --arch x86_64)
fi
# The ${a[@]+...} form keeps bash 3.2 (the macOS default) happy with an empty array under `set -u`.
swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" ${ARCH_FLAGS[@]+"${ARCH_FLAGS[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/BucketBrowser" "$APP/Contents/MacOS/BucketBrowser"

# App icon: Resources/AppIcon.png (1024x1024, from scripts/render-icon.py) -> AppIcon.icns
ICONSET="$OUT/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
  double=$((size * 2))
  sips -z "$double" "$double" "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
rm -rf "$ICONSET"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleExecutable</key><string>BucketBrowser</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
</dict>
</plist>
PLIST

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  codesign --force --deep --sign - "$APP"
  echo "Built $APP (ad-hoc signed; iCloud sync is off)"
  exit 0
fi

# The data protection keychain and iCloud Keychain need an application identifier and a
# keychain access group, and macOS only honours those when a provisioning profile allows them.
if [[ -z "${PROVISIONING_PROFILE:-}" ]]; then
  echo "PROVISIONING_PROFILE must point to a Developer ID profile for $BUNDLE_ID" >&2
  exit 1
fi
cp "$PROVISIONING_PROFILE" "$APP/Contents/embedded.provisionprofile"

ENTITLEMENTS="$OUT/BucketBrowser.entitlements"
cat > "$ENTITLEMENTS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>com.apple.application-identifier</key><string>$TEAM_ID.$BUNDLE_ID</string>
  <key>com.apple.developer.team-identifier</key><string>$TEAM_ID</string>
  <key>keychain-access-groups</key>
  <array><string>$TEAM_ID.$BUNDLE_ID</string></array>
</dict>
</plist>
PLIST

codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "Built $APP"
