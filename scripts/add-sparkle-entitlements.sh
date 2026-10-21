#!/usr/bin/env bash
# Lets a sandboxed app reach Sparkle's Installer service, which installs updates for it.
# Only the direct-download build uses these; the Mac App Store build has no Sparkle.
# Usage: scripts/add-sparkle-entitlements.sh <entitlements file> <bundle id>
set -euo pipefail

FILE="$1"
BUDDY=/usr/libexec/PlistBuddy
KEY=":com.apple.security.temporary-exception.mach-lookup.global-name"
"$BUDDY" -c "Add $KEY array" "$FILE"
"$BUDDY" -c "Add $KEY:0 string $2-spks" "$FILE"
"$BUDDY" -c "Add $KEY:1 string $2-spki" "$FILE"
