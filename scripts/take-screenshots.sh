#!/usr/bin/env bash
# Launches the app in demo mode with different views and captures its window.
# Needs a logged-in macOS GUI session (GitHub's macOS runners have one).
# Usage: scripts/build-app.sh debug && scripts/take-screenshots.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
APP_BIN="$ROOT/build/Bucket Browser.app/Contents/MacOS/BucketBrowser"
OUT="$ROOT/docs/screenshots"
WINDOW_ID="$ROOT/build/window-id"
mkdir -p "$OUT"

swiftc -O "$ROOT/scripts/window-id.swift" -o "$WINDOW_ID"

shoot() {
  local name="$1"
  shift
  rm -rf "$HOME/Library/Saved Application State/com.bucketbrowser.app.savedState"
  env BUCKET_BROWSER_DEMO=1 "$@" "$APP_BIN" &
  local pid=$!

  local id=""
  for _ in $(seq 1 30); do
    sleep 1
    if id="$("$WINDOW_ID" "$pid")"; then break; fi
  done
  if [[ -z "$id" ]]; then
    echo "No window appeared for $name" >&2
    kill "$pid" || true
    return 1
  fi
  # Give SwiftUI a moment to lay out and load icons.
  sleep 3
  screencapture -x -o -l "$id" "$OUT/$name.png"
  echo "Captured $OUT/$name.png"
  kill "$pid"
  wait "$pid" 2>/dev/null || true
}

shoot list-view BB_DEMO_VIEW=list BB_DEMO_PREFIX=photos/2025/ BB_DEMO_SELECT=product-launch-hero.png BB_DEMO_INSPECTOR=1 BB_DEMO_APPEARANCE=light
shoot icon-view BB_DEMO_VIEW=icons BB_DEMO_APPEARANCE=light
shoot column-view BB_DEMO_VIEW=columns BB_DEMO_PREFIX=photos/2025/ BB_DEMO_SELECT=storefront.jpg BB_DEMO_APPEARANCE=light
shoot welcome BB_DEMO_EMPTY=1 BB_DEMO_APPEARANCE=light
shoot welcome-dark BB_DEMO_EMPTY=1 BB_DEMO_APPEARANCE=dark
shoot list-view-dark BB_DEMO_VIEW=list BB_DEMO_PREFIX=videos/ BB_DEMO_APPEARANCE=dark
