#!/usr/bin/env bash
# Builds, notarizes and packages the direct-download edition of a release, in build/release:
#
#   BucketBrowser.dmg            the disk image people download, notarized and stapled
#   BucketBrowser-<version>.zip  the update archive Sparkle downloads (the stapled app)
#   appcast-item.xml             this version's entry for appcast.xml, signed with the EdDSA key
#   bucket-browser.rb            the Homebrew cask for this version
#
# Usage:
#   VERSION=1.0.0 DEV_PROFILE=path/to/development.provisionprofile scripts/release-direct.sh
#
# It needs, on this Mac:
#   - Xcode signed in to team TEAM_ID, as for scripts/export-app.sh.
#   - A notarytool keychain profile named NOTARY_PROFILE (default bucket-browser-notary):
#       xcrun notarytool store-credentials bucket-browser-notary \
#         --apple-id you@example.com --team-id 4TK5PNR392
#     It asks for an app-specific password from account.apple.com.
#   - The Sparkle EdDSA private key in the login keychain. Sparkle's generate_keys creates it once;
#     its public half is Resources/SparklePublicKey.txt. Back it up with generate_keys -x.
#
# Optional: SITE=path/to/bucket-browser-site adds the new entry to that checkout's appcast.xml.
# NOTES_HTML=file puts that HTML in the entry as release notes. DMG_IDENTITY signs the disk image
# (default: the first Developer ID Application identity in the keychain, if there is one).
# Nothing is published; see "Direct download" in the README for that.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="${VERSION:?Set VERSION, for example VERSION=1.0.0}"
NOTARY_PROFILE="${NOTARY_PROFILE:-bucket-browser-notary}"
REPO_URL="${REPO_URL:-https://github.com/chiranjeebhub/bucket-browser-site}"
APP_NAME="Bucket Browser"
TAG="v$VERSION"
OUT="$ROOT/build/release"
APP="$ROOT/build/export/$APP_NAME.app"
DMG="$OUT/BucketBrowser.dmg"
ZIP="$OUT/BucketBrowser-$VERSION.zip"
BUDDY=/usr/libexec/PlistBuddy

# Submits a file to the notary service and waits. Prints Apple's log and stops if it's rejected.
notarize() {
  local result="$OUT/notary-result.plist"
  xcrun notarytool submit "$1" --keychain-profile "$NOTARY_PROFILE" --wait --output-format plist \
    > "$result" || true
  if [[ "$("$BUDDY" -c 'Print :status' "$result" 2>/dev/null)" != Accepted ]]; then
    cat "$result" >&2
    local id
    if id="$("$BUDDY" -c 'Print :id' "$result" 2>/dev/null)"; then
      xcrun notarytool log "$id" --keychain-profile "$NOTARY_PROFILE" >&2 || true
    fi
    echo "Notarization of $(basename "$1") failed" >&2
    exit 1
  fi
  rm "$result"
}

rm -rf "$OUT"
mkdir -p "$OUT"

DIRECT=1 UNIVERSAL=1 VERSION="$VERSION" "$ROOT/scripts/build-app.sh" release
"$ROOT/scripts/export-app.sh" developer-id
BUILD_NUMBER="$("$BUDDY" -c 'Print CFBundleVersion' "$APP/Contents/Info.plist")"

# Notarize the app and staple the ticket to it, so it opens without a network check too.
ditto -c -k --keepParent "$APP" "$OUT/notarize.zip"
notarize "$OUT/notarize.zip"
rm "$OUT/notarize.zip"
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

# The archive Sparkle downloads for updates.
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"

# The disk image: the app and a link to /Applications to drag it onto.
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
ditto "$APP" "$STAGE/$APP_NAME.app"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGE" -format UDZO -ov "$DMG"
rm -rf "$STAGE"
DMG_IDENTITY="${DMG_IDENTITY:-$(security find-identity -v -p codesigning \
  | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)}"
if [[ -n "$DMG_IDENTITY" ]]; then
  codesign --sign "$DMG_IDENTITY" --timestamp "$DMG"
fi
notarize "$DMG"
xcrun stapler staple "$DMG"

# Sign the update archive with the EdDSA key. sign_update prints the signature and length
# attributes for the enclosure. The first run asks to use the key in the keychain.
SIGN_UPDATE="$(find "$ROOT/.build-direct/artifacts" -path '*/bin/sign_update' -type f | head -1)"
SIGNATURE="$("$SIGN_UPDATE" "$ZIP")"
NOTES=""
if [[ -n "${NOTES_HTML:-}" ]]; then
  NOTES="      <description><![CDATA[$(cat "$NOTES_HTML")]]></description>"
fi
cat > "$OUT/appcast-item.xml" <<XML
    <item>
      <title>Version $VERSION</title>
      <pubDate>$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <link>$REPO_URL/releases/tag/$TAG</link>
$NOTES
      <enclosure url="$REPO_URL/releases/download/$TAG/$(basename "$ZIP")" type="application/octet-stream" $SIGNATURE/>
    </item>
XML
sed -i '' '/^$/d' "$OUT/appcast-item.xml"

if [[ -n "${SITE:-}" ]]; then
  # Newest first: the entry goes before the first existing item.
  awk -v item="$OUT/appcast-item.xml" '
    !done && (/<item>/ || /<\/channel>/) { while ((getline line < item) > 0) print line; done = 1 }
    { print }
  ' "$SITE/appcast.xml" > "$OUT/appcast.xml"
  mv "$OUT/appcast.xml" "$SITE/appcast.xml"
fi

SHA256="$(shasum -a 256 "$DMG" | awk '{ print $1 }')"
sed -e "s/^  version \".*\"/  version \"$VERSION\"/" -e "s/^  sha256 \".*\"/  sha256 \"$SHA256\"/" \
  "$ROOT/packaging/homebrew/bucket-browser.rb" > "$OUT/bucket-browser.rb"

echo
echo "Release $VERSION (build $BUILD_NUMBER) is in $OUT:"
ls -l "$OUT"
