#!/usr/bin/env bash
# Signs "Bucket Browser.app" with your team's Developer ID through Xcode's cloud signing, for
# when Xcode manages the Developer ID certificate and its private key isn't in your keychain
# (so scripts/build-app.sh can't sign with SIGN_IDENTITY).
#
# Usage: DEV_PROFILE=path/to/development.provisionprofile scripts/export-developer-id.sh
#
# Run scripts/build-app.sh first; the ad-hoc build is the input. Xcode must be signed in to an
# account on team TEAM_ID (default 4TK5PNR392) that can create Developer ID signatures.
# DEV_PROFILE is a Mac development profile that covers com.bucketbrowser.app and the keychain
# access group, such as the "Mac Team Provisioning Profile: *" Xcode keeps in
# ~/Library/Developer/Xcode/UserData/Provisioning Profiles. The exporter replaces it with a
# Developer ID profile. The result lands in build/export/Bucket Browser.app.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Bucket Browser"
BUNDLE_ID="com.bucketbrowser.app"
TEAM_ID="${TEAM_ID:-4TK5PNR392}"
DEV_IDENTITY="${DEV_IDENTITY:-Apple Development}"
OUT="$ROOT/build"
SOURCE_APP="$OUT/$APP_NAME.app"
ARCHIVE="$OUT/BucketBrowser.xcarchive"
EXPORT="$OUT/export"

if [[ ! -d "$SOURCE_APP" ]]; then
  echo "Run scripts/build-app.sh first" >&2
  exit 1
fi
if [[ -z "${DEV_PROFILE:-}" ]]; then
  echo "DEV_PROFILE must point to a Mac development profile for $BUNDLE_ID on team $TEAM_ID" >&2
  exit 1
fi

rm -rf "$ARCHIVE" "$EXPORT"
mkdir -p "$ARCHIVE/Products/Applications"
ARCHIVED_APP="$ARCHIVE/Products/Applications/$APP_NAME.app"
cp -R "$SOURCE_APP" "$ARCHIVED_APP"
cp "$DEV_PROFILE" "$ARCHIVED_APP/Contents/embedded.provisionprofile"

# The exporter keeps the entitlements the archived app is signed with, so sign it with them here.
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
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$DEV_IDENTITY" "$ARCHIVED_APP"
SIGNED_BY="$(codesign -dvv "$ARCHIVED_APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"

PLIST_INFO="$ARCHIVED_APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST_INFO")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST_INFO")"
ARCHS=""
for arch in $(lipo -archs "$ARCHIVED_APP/Contents/MacOS/BucketBrowser"); do
  ARCHS="$ARCHS<string>$arch</string>"
done

cat > "$ARCHIVE/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>ApplicationProperties</key>
  <dict>
    <key>ApplicationPath</key><string>Applications/$APP_NAME.app</string>
    <key>Architectures</key><array>$ARCHS</array>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
    <key>SigningIdentity</key><string>$SIGNED_BY</string>
    <key>Team</key><string>$TEAM_ID</string>
  </dict>
  <key>ArchiveVersion</key><integer>2</integer>
  <key>CreationDate</key><date>$(date -u +%Y-%m-%dT%H:%M:%SZ)</date>
  <key>Name</key><string>$APP_NAME</string>
  <key>SchemeName</key><string>BucketBrowser</string>
</dict>
</plist>
PLIST

EXPORT_OPTIONS="$OUT/ExportOptions.plist"
cat > "$EXPORT_OPTIONS" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>developer-id</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM_ID</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$EXPORT_OPTIONS" -allowProvisioningUpdates
codesign --verify --strict --verbose=2 "$EXPORT/$APP_NAME.app"
echo "Exported $EXPORT/$APP_NAME.app"
