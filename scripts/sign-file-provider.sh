#!/usr/bin/env bash
# Signs the File Provider extension inside an app. Run before signing the app itself, since the
# app's signature covers the extension.
# Usage: scripts/sign-file-provider.sh <app> <identity> [team id] [provisioning profile] [extra codesign options]
#
# With a team id, the extension gets its application identifier and the app's keychain access
# group, which is how it reads the accounts and keys the app saved in iCloud Keychain. That
# group is only honoured with a provisioning profile that allows it (any team profile does).
# Without a team id (ad-hoc builds) the extension is signed but can't reach the keys, so the
# app doesn't offer to mount buckets.
set -euo pipefail

APP="$1"
IDENTITY="$2"
TEAM_ID="${3:-}"
PROFILE="${4:-}"
shift $(( $# < 4 ? $# : 4 ))
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUNDLE_ID="com.bucketbrowser.app"
EXT="$APP/Contents/PlugIns/BucketBrowserFileProvider.appex"
[[ -d "$EXT" ]] || exit 0

ENTITLEMENTS="$(mktemp -t fileprovider-entitlements).plist"
cp "$ROOT/Resources/FileProvider.entitlements" "$ENTITLEMENTS"
if [[ -n "$TEAM_ID" ]]; then
  BUDDY=/usr/libexec/PlistBuddy
  "$BUDDY" -c "Add :com.apple.application-identifier string $TEAM_ID.$APP_BUNDLE_ID.FileProvider" "$ENTITLEMENTS"
  "$BUDDY" -c "Add :com.apple.developer.team-identifier string $TEAM_ID" "$ENTITLEMENTS"
  "$BUDDY" -c "Add :keychain-access-groups array" "$ENTITLEMENTS"
  "$BUDDY" -c "Add :keychain-access-groups:0 string $TEAM_ID.$APP_BUNDLE_ID" "$ENTITLEMENTS"
fi
if [[ -n "$PROFILE" ]]; then
  cp "$PROFILE" "$EXT/Contents/embedded.provisionprofile"
fi

OPTIONS=(--force)
[[ "$IDENTITY" != "-" ]] && OPTIONS+=(--options runtime)
codesign "${OPTIONS[@]}" "$@" --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$EXT"
rm -f "$ENTITLEMENTS"
