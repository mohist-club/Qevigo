#!/bin/bash
# Builds dist/Qevigo.app.
#   ./scripts/build-app.sh                  release build
#   CONFIG=debug ./scripts/build-app.sh     faster debug build
#   QEVIGO_REQUIRE_SIGNING=1 ...            fail instead of falling back to ad-hoc signing (releases)
#
# Builds are signed with the identity created by scripts/setup-signing.sh. A
# stable identity keeps the Accessibility permission across updates, and Sparkle
# only installs updates signed with the same identity as the running app.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="dist/Qevigo.app"
SIGNING_DIR="${QEVIGO_SIGNING_DIR:-$HOME/.qevigo-signing}"
KEYCHAIN="$SIGNING_DIR/signing.keychain-db"
IDENTITY="Qevigo Self-Signed Code Signing"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG" --product Qevigo
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> assemble $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$APP/Contents/Frameworks"
cp "$BIN_DIR/Qevigo" "$APP/Contents/MacOS/Qevigo"
cp Resources/Info.plist "$APP/Contents/Info.plist"
iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do cp -R "$bundle" "$APP/Contents/Resources/"; done
shopt -u nullglob

FRAMEWORK="$APP/Contents/Frameworks/Sparkle.framework"
cp -R "$BIN_DIR/Sparkle.framework" "$FRAMEWORK"
# Sparkle's XPC services are only needed by sandboxed apps.
rm -rf "$FRAMEWORK/XPCServices" "$FRAMEWORK/Versions/B/XPCServices"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$APP/Contents/MacOS/Qevigo"

if [ -f "$KEYCHAIN" ]; then
    echo "==> sign with \"$IDENTITY\""
    security unlock-keychain -p "$(cat "$SIGNING_DIR/keychain-password")" "$KEYCHAIN"
    SIGN=(codesign --force --timestamp=none --keychain "$KEYCHAIN" --sign "$IDENTITY")
elif [ "${QEVIGO_REQUIRE_SIGNING:-0}" = 1 ]; then
    echo "error: signing identity not found; run scripts/setup-signing.sh" >&2
    exit 1
else
    echo "==> WARNING: no signing identity, using ad-hoc signing (auto-update and Accessibility will not carry over)"
    SIGN=(codesign --force --sign -)
fi
# Inside-out: nested helpers first, then the framework, then the app.
"${SIGN[@]}" "$FRAMEWORK/Versions/B/Autoupdate"
"${SIGN[@]}" "$FRAMEWORK/Versions/B/Updater.app"
"${SIGN[@]}" "$FRAMEWORK"
"${SIGN[@]}" "$APP"
codesign --verify --deep --strict "$APP"
echo "==> done: $APP"
