#!/usr/bin/env bash
# Builds Tagen.app (and the TagenFixture.app test fixture) as an ad-hoc-signed development
# bundle and zips it into dist/. Not notarized: see docs/known-limitations.md.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
CONFIG="${CONFIG:-release}"
VERSION="${TAGEN_VERSION:-0.1.0}"
BUILD_NUMBER="${GITHUB_RUN_NUMBER:-1}"
BUNDLE_ID="${TAGEN_BUNDLE_ID:-dev.tagen.Tagen}"

for p in Tagen tagen-approval-mcp tagen-cli TagenFixtureApp tagen-gui-check tagen-live-probe; do
  swift build -c "$CONFIG" --product "$p"
done
BIN="$(swift build -c "$CONFIG" --show-bin-path)"

rm -rf dist && mkdir -p dist

make_bundle() {
  local name="$1" exe="$2" id="$3" plist_extra="$4"
  local app="dist/$name.app"
  mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
  cp "$BIN/$exe" "$app/Contents/MacOS/$name"
  cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleName</key><string>$name</string>
  <key>CFBundleDisplayName</key><string>$name</string>
  <key>CFBundleIdentifier</key><string>$id</string>
  <key>CFBundleExecutable</key><string>$name</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleLocalizations</key><array><string>en</string><string>ko</string></array>
$plist_extra
</dict>
</plist>
PLIST
}

make_bundle "Tagen" "Tagen" "$BUNDLE_ID" "  <key>LSUIElement</key><true/>
  <key>NSMicrophoneUsageDescription</key><string>Tagen listens only while you hold the push-to-talk key, to transcribe your question.</string>
  <key>NSSpeechRecognitionUsageDescription</key><string>Tagen transcribes push-to-talk audio, on-device when available.</string>
  <key>NSAppleEventsUsageDescription</key><string>Tagen sends commands to other apps only for actions you approve.</string>"
cp "$BIN/tagen-approval-mcp" "dist/Tagen.app/Contents/MacOS/"
cp "$BIN/tagen-cli" "dist/Tagen.app/Contents/MacOS/"

make_bundle "TagenFixture" "TagenFixtureApp" "dev.tagen.Fixture" ""
cp "$BIN/tagen-gui-check" "$BIN/tagen-live-probe" "dist/"

# Signature (development only; not notarized). With the local identity from
# scripts/macos/setup-dev-signing.sh every build has the same designated requirement, so macOS
# permissions survive rebuilds; without it (CI) builds are ad-hoc signed and lose them on rebuild.
SIGN_DIR="${TAGEN_SIGNING_DIR:-$HOME/Library/Application Support/Tagen-dev-signing}"
SIGN_ARGS=(--sign -)
SIGNATURE_DESC="ad-hoc (codesign -s -)"
if [[ -z "${CI:-}" && -f "$SIGN_DIR/tagen-dev.keychain-db" && -f "$SIGN_DIR/keychain-password" ]]; then
  security unlock-keychain -p "$(cat "$SIGN_DIR/keychain-password")" "$SIGN_DIR/tagen-dev.keychain-db"
  SIGN_ARGS=(--keychain "$SIGN_DIR/tagen-dev.keychain-db" --sign "Tagen Local Development")
  SIGNATURE_DESC="local identity \"Tagen Local Development\" (stable across rebuilds)"
fi
for h in tagen-approval-mcp tagen-cli; do codesign --force "${SIGN_ARGS[@]}" --options runtime "dist/Tagen.app/Contents/MacOS/$h"; done
codesign --force "${SIGN_ARGS[@]}" --options runtime --entitlements Resources/Tagen.entitlements "dist/Tagen.app"
codesign --force "${SIGN_ARGS[@]}" "dist/TagenFixture.app"
codesign --force "${SIGN_ARGS[@]}" "dist/tagen-gui-check"
codesign --force "${SIGN_ARGS[@]}" "dist/tagen-live-probe"

(cd dist && ditto -c -k --keepParent Tagen.app Tagen.zip && ditto -c -k --keepParent TagenFixture.app TagenFixture.zip)
{
  echo "Tagen development build"
  echo "version: $VERSION ($BUILD_NUMBER)"
  echo "commit: $(git rev-parse HEAD 2>/dev/null || echo unknown)"
  echo "built: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "toolchain: $(swift --version 2>&1 | head -1)"
  echo "macOS: $(sw_vers -productVersion)  arch: $(uname -m)"
  echo "signature: $SIGNATURE_DESC, hardened runtime, NOT notarized"
  shasum -a 256 dist/Tagen.zip dist/TagenFixture.zip
} > dist/BUILD-INFO.txt
cat dist/BUILD-INFO.txt
