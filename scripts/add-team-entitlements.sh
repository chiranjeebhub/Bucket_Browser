#!/usr/bin/env bash
# Adds the entitlements that tie the app to a developer team to an entitlements file:
# the application identifier and the keychain access group that iCloud Keychain sync uses.
# Usage: scripts/add-team-entitlements.sh <entitlements file> <team id> <bundle id>
set -euo pipefail

FILE="$1"
APP_ID="$2.$3"
BUDDY=/usr/libexec/PlistBuddy
"$BUDDY" -c "Add :com.apple.application-identifier string $APP_ID" "$FILE"
"$BUDDY" -c "Add :com.apple.developer.team-identifier string $2" "$FILE"
"$BUDDY" -c "Add :keychain-access-groups array" "$FILE"
"$BUDDY" -c "Add :keychain-access-groups:0 string $APP_ID" "$FILE"
