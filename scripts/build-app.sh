#!/usr/bin/env bash
# Builds "Bucket Browser.app" from the Swift package and signs it.
# Usage: scripts/build-app.sh [debug|release]   (default: release)
#
# The app runs in the App Sandbox (Resources/BucketBrowser.entitlements), as the Mac App Store
# requires. For an App Store build, see scripts/export-app.sh.
#
# VERSION is the marketing version (default 1.0.0). BUILD_NUMBER defaults to the commit count,
# so every build of a later commit has a higher number, which App Store Connect requires.
#
# By default the app is ad-hoc signed, which can't use iCloud Keychain. To build a copy
# that syncs accounts through iCloud, sign it with your team's Developer ID:
#   SIGN_IDENTITY="Developer ID Application: Your Name (4TK5PNR392)" \
#   PROVISIONING_PROFILE=path/to/BucketBrowser.provisionprofile \
#   scripts/build-app.sh
# TEAM_ID defaults to 4TK5PNR392 and must match the certificate and the profile.
#
# DIRECT=1 builds the direct-download edition: the same app plus Sparkle, which updates it from
# the appcast on the website. It builds in .build-direct so it never mixes with the App Store
# build, which has no Sparkle code at all. scripts/release-direct.sh uses it.
set -euo pipefail

CONFIG="${1:-release}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_NAME="Bucket Browser"
BUNDLE_ID="com.bucketbrowser.app"
TEAM_ID="${TEAM_ID:-4TK5PNR392}"
VERSION="${VERSION:-1.0.0}"
BUILD_NUMBER="${BUILD_NUMBER:-$(git -C "$ROOT" rev-list --count HEAD 2>/dev/null || echo 1)}"
COPYRIGHT="${COPYRIGHT:-Copyright © $(date +%Y) Chiranjeeb Jena. All rights reserved.}"
OUT="$ROOT/build"
APP="$OUT/$APP_NAME.app"
DIRECT="${DIRECT:-0}"
FEED_URL="${FEED_URL:-https://chiranjeebhub.github.io/bucket-browser-site/appcast.xml}"

cd "$ROOT"
BUILD_FLAGS=()
if [[ "$DIRECT" == "1" ]]; then
  # Package.swift adds Sparkle when this is set. The public key that verifies updates is safe to
  # commit; the private key stays in the login keychain of the Mac that signs releases.
  export BUCKET_BROWSER_DIRECT=1
  SPARKLE_PUBLIC_KEY="${SPARKLE_PUBLIC_KEY:-$(tr -d '[:space:]' < "$ROOT/Resources/SparklePublicKey.txt")}"
  BUILD_FLAGS+=(--scratch-path "$ROOT/.build-direct" -Xlinker -rpath -Xlinker @executable_path/../Frameworks)
fi
if [[ "${UNIVERSAL:-0}" == "1" ]]; then
  BUILD_FLAGS+=(--arch arm64 --arch x86_64)
fi
# SwiftPM records the deployment target as the SDK version in the binary, and App Store Connect
# rejects apps that look built with an old SDK, so pass the real SDK version to the linker.
SDK_VERSION="$(xcrun --sdk macosx --show-sdk-version)"
BUILD_FLAGS+=(-Xlinker -platform_version -Xlinker macos -Xlinker 14.0 -Xlinker "$SDK_VERSION")
# The ${a[@]+...} form keeps bash 3.2 (the macOS default) happy with an empty array under `set -u`.
swift build -c "$CONFIG" ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"}
BIN_DIR="$(swift build -c "$CONFIG" ${BUILD_FLAGS[@]+"${BUILD_FLAGS[@]}"} --show-bin-path)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/BucketBrowser" "$APP/Contents/MacOS/BucketBrowser"
if [[ "$DIRECT" == "1" ]]; then
  mkdir -p "$APP/Contents/Frameworks"
  ditto "$BIN_DIR/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
  # The sandbox already allows network access, so Sparkle can download in-process and doesn't
  # need its Downloader service (which would need its own entitlements).
  rm -rf "$APP/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices/Downloader.xpc"
fi

# App icon: the asset catalog (from scripts/render-icon.py) compiles to Assets.car and AppIcon.icns.
xcrun actool "$ROOT/Resources/Assets.xcassets" --compile "$APP/Contents/Resources" \
  --platform macosx --target-device mac --minimum-deployment-target 14.0 \
  --app-icon AppIcon --output-partial-info-plist "$OUT/assets-info.plist" \
  --errors --warnings --output-format human-readable-text >/dev/null

# Required-reason API declarations for App Store review.
cp "$ROOT/Resources/PrivacyInfo.xcprivacy" "$APP/Contents/Resources/PrivacyInfo.xcprivacy"

# The toolchain keys Xcode writes into every app. App Store Connect reads them to check that
# the app was built with a supported Xcode and SDK.
XCODE_VERSION="$(xcodebuild -version | awk 'NR == 1 { print $2 }')"
IFS=. read -r XCODE_MAJOR XCODE_MINOR XCODE_PATCH <<< "$XCODE_VERSION"
DT_XCODE="$(printf '%d%d%d' "$XCODE_MAJOR" "${XCODE_MINOR:-0}" "${XCODE_PATCH:-0}")"
DT_XCODE_BUILD="$(xcodebuild -version | awk 'NR == 2 { print $3 }')"
SDK_BUILD="$(xcrun --sdk macosx --show-sdk-build-version)"

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
  <key>CFBundleIconName</key><string>AppIcon</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
  <key>NSHumanReadableCopyright</key><string>$COPYRIGHT</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>ITSAppUsesNonExemptEncryption</key><false/>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSPrincipalClass</key><string>NSApplication</string>
  <key>NSSupportsAutomaticTermination</key><false/>
  <key>BuildMachineOSBuild</key><string>$(sw_vers -buildVersion)</string>
  <key>DTCompiler</key><string>com.apple.compilers.llvm.clang.1_0</string>
  <key>DTPlatformName</key><string>macosx</string>
  <key>DTPlatformVersion</key><string>$SDK_VERSION</string>
  <key>DTPlatformBuild</key><string>$SDK_BUILD</string>
  <key>DTSDKName</key><string>macosx$SDK_VERSION</string>
  <key>DTSDKBuild</key><string>$SDK_BUILD</string>
  <key>DTXcode</key><string>$DT_XCODE</string>
  <key>DTXcodeBuild</key><string>$DT_XCODE_BUILD</string>
</dict>
</plist>
PLIST

if [[ "$DIRECT" == "1" ]]; then
  BUDDY=/usr/libexec/PlistBuddy
  "$BUDDY" -c "Add :SUFeedURL string $FEED_URL" "$APP/Contents/Info.plist"
  "$BUDDY" -c "Add :SUPublicEDKey string $SPARKLE_PUBLIC_KEY" "$APP/Contents/Info.plist"
  # A sandboxed app installs updates through Sparkle's Installer service.
  "$BUDDY" -c "Add :SUEnableInstallerLauncherService bool true" "$APP/Contents/Info.plist"
fi

ENTITLEMENTS="$OUT/BucketBrowser.entitlements"
cp "$ROOT/Resources/BucketBrowser.entitlements" "$ENTITLEMENTS"
if [[ "$DIRECT" == "1" ]]; then
  "$ROOT/scripts/add-sparkle-entitlements.sh" "$ENTITLEMENTS" "$BUNDLE_ID"
fi

if [[ -z "${SIGN_IDENTITY:-}" ]]; then
  "$ROOT/scripts/sign-sparkle.sh" "$APP" -
  codesign --force --entitlements "$ENTITLEMENTS" --sign - "$APP"
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

"$ROOT/scripts/add-team-entitlements.sh" "$ENTITLEMENTS" "$TEAM_ID" "$BUNDLE_ID"

"$ROOT/scripts/sign-sparkle.sh" "$APP" "$SIGN_IDENTITY" --timestamp
codesign --force --options runtime --timestamp \
  --entitlements "$ENTITLEMENTS" --sign "$SIGN_IDENTITY" "$APP"
codesign --verify --strict --verbose=2 "$APP"
echo "Built $APP"
