#!/bin/bash
# Builds build/TeamsLite.app (release, ad-hoc signed).
#   scripts/build.sh            build only
#   scripts/build.sh --install  also copy to /Applications (quits a running copy first)
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f Resources/AppIcon.icns ] || swift scripts/make-icon.swift .

swift build -c release -Xswiftc -Osize 2>&1 | grep -v -E "PlatformPath|XCTest|show-sdk-platform-path" || true
BIN="$(swift build -c release --show-bin-path 2>/dev/null)/TeamsLite"
[ -x "$BIN" ] || { echo "build failed"; exit 1; }

APP=build/TeamsLite.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/TeamsLite"
strip -x "$APP/Contents/MacOS/TeamsLite"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --sign - "$APP"
echo "Built $APP ($(du -sh "$APP" | cut -f1))"

if [ "${1:-}" = "--install" ]; then
  osascript -e 'tell application id "com.devnetio.TeamsLite" to quit' 2>/dev/null || true
  sleep 1
  rm -rf /Applications/TeamsLite.app
  cp -R "$APP" /Applications/
  echo "Installed /Applications/TeamsLite.app"
fi
