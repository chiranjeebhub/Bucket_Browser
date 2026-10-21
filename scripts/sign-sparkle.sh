#!/usr/bin/env bash
# Signs the Sparkle framework inside an app, innermost code first, as Sparkle's docs describe.
# Does nothing when the app has no Sparkle (the Mac App Store build).
# Usage: scripts/sign-sparkle.sh <app> <identity> [extra codesign options]
set -euo pipefail

APP="$1"
IDENTITY="$2"
shift 2
FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
[[ -d "$FRAMEWORK" ]] || exit 0

SIGN=(codesign --force --options runtime --sign "$IDENTITY" "$@")
for code in \
  "$FRAMEWORK/Versions/B/XPCServices/Installer.xpc" \
  "$FRAMEWORK/Versions/B/XPCServices/Downloader.xpc" \
  "$FRAMEWORK/Versions/B/Autoupdate" \
  "$FRAMEWORK/Versions/B/Updater.app" \
  "$FRAMEWORK"; do
  if [[ -e "$code" ]]; then
    "${SIGN[@]}" "$code"
  fi
done
