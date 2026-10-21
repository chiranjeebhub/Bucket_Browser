#!/usr/bin/env bash
# Wraps "Bucket Browser.app" in an Xcode archive and has Xcode sign and export it, using the
# certificates Xcode manages in the cloud for your team.
#
# Usage: DEV_PROFILE=path/to/development.provisionprofile scripts/export-app.sh [developer-id|app-store]
#
#   developer-id (default)  An app signed with your Developer ID, for running outside the App
#                           Store, in build/export/Bucket Browser.app.
#   app-store               An installer package signed for the Mac App Store, in
#                           build/export/Bucket Browser.pkg. With UPLOAD=1, Xcode uploads it to
#                           App Store Connect instead; the app record must already exist there.
#
# Run scripts/build-app.sh first; the ad-hoc build is the input. For the App Store, build it
# with UNIVERSAL=1 so it runs on Intel Macs too. A DIRECT=1 build (with Sparkle) can only be
# exported for developer-id; scripts/release-direct.sh does that and notarizes it.
# Xcode must be signed in to an account on team TEAM_ID (default 4TK5PNR392) that can create
# Developer ID signatures.
# DEV_PROFILE is a Mac development profile that covers com.bucketbrowser.app and the keychain
# access group, such as the "Mac Team Provisioning Profile: *" Xcode keeps in
# ~/Library/Developer/Xcode/UserData/Provisioning Profiles. The exporter replaces it with a
# Developer ID or Mac App Store profile.
set -euo pipefail

METHOD="${1:-developer-id}"
case "$METHOD" in
  developer-id) EXPORT_METHOD=developer-id ;;
  app-store) EXPORT_METHOD=app-store-connect ;;
  *) echo "Usage: scripts/export-app.sh [developer-id|app-store]" >&2; exit 1 ;;
esac

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
HAS_SPARKLE=0
[[ -d "$ARCHIVED_APP/Contents/Frameworks/Sparkle.framework" ]] && HAS_SPARKLE=1
if [[ "$HAS_SPARKLE" == 1 && "$METHOD" == app-store ]]; then
  echo "This build includes Sparkle, which the App Store doesn't allow. Rebuild without DIRECT=1." >&2
  exit 1
fi

# The exporter keeps the entitlements the archived app is signed with, so sign it with them here.
ENTITLEMENTS="$OUT/BucketBrowser.entitlements"
cp "$ROOT/Resources/BucketBrowser.entitlements" "$ENTITLEMENTS"
"$ROOT/scripts/add-team-entitlements.sh" "$ENTITLEMENTS" "$TEAM_ID" "$BUNDLE_ID"
if [[ "$HAS_SPARKLE" == 1 ]]; then
  "$ROOT/scripts/add-sparkle-entitlements.sh" "$ENTITLEMENTS" "$BUNDLE_ID"
fi
"$ROOT/scripts/sign-sparkle.sh" "$ARCHIVED_APP" "$DEV_IDENTITY"
codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$DEV_IDENTITY" "$ARCHIVED_APP"
SIGNED_BY="$(codesign -dvv "$ARCHIVED_APP" 2>&1 | sed -n 's/^Authority=//p' | head -1)"

PLIST_INFO="$ARCHIVED_APP/Contents/Info.plist"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$PLIST_INFO")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$PLIST_INFO")"
ARCHS=""
if [[ "$METHOD" == app-store ]] && ! lipo -archs "$ARCHIVED_APP/Contents/MacOS/BucketBrowser" | grep -q x86_64; then
  echo "Warning: this build is Apple silicon only. Run UNIVERSAL=1 scripts/build-app.sh to support Intel Macs too." >&2
fi
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
  <key>method</key><string>$EXPORT_METHOD</string>
  <key>destination</key><string>$([[ "${UPLOAD:-0}" == 1 ]] && echo upload || echo export)</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>$TEAM_ID</string>
</dict>
</plist>
PLIST

xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportPath "$EXPORT" \
  -exportOptionsPlist "$EXPORT_OPTIONS" -allowProvisioningUpdates
if [[ "${UPLOAD:-0}" == 1 ]]; then
  echo "Uploaded build $BUILD_NUMBER to App Store Connect"
elif [[ "$METHOD" == app-store ]]; then
  pkgutil --check-signature "$EXPORT/$APP_NAME.pkg"
  echo "Exported $EXPORT/$APP_NAME.pkg"
else
  codesign --verify --deep --strict --verbose=2 "$EXPORT/$APP_NAME.app"
  echo "Exported $EXPORT/$APP_NAME.app"
fi
