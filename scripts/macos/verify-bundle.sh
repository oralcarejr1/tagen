#!/usr/bin/env bash
# Structural verification of a packaged app bundle.
set -euo pipefail
APP="${1:-dist/Tagen.app}"
fail() { echo "FAIL: $*"; exit 1; }
[ -x "$APP/Contents/MacOS/Tagen" ] || fail "main executable missing"
[ -x "$APP/Contents/MacOS/tagen-approval-mcp" ] || fail "approval relay helper missing"
plutil -lint "$APP/Contents/Info.plist" || fail "Info.plist invalid"
for k in CFBundleIdentifier LSUIElement NSMicrophoneUsageDescription NSSpeechRecognitionUsageDescription; do
  /usr/libexec/PlistBuddy -c "Print :$k" "$APP/Contents/Info.plist" >/dev/null || fail "Info.plist missing $k"
done
codesign --verify --deep --strict --verbose=2 "$APP" || fail "codesign verification failed"
codesign -d --entitlements - "$APP" 2>/dev/null | grep -q audio-input || fail "audio-input entitlement missing"
file "$APP/Contents/MacOS/Tagen"
echo "PASS: bundle structure, Info.plist keys, signature and entitlements verified"
