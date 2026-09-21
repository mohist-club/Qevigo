#!/bin/bash
# Builds dist/Qevigo.app (ad-hoc signed).
#   ./scripts/build-app.sh            release build
#   CONFIG=debug ./scripts/build-app.sh   faster debug build
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${CONFIG:-release}"
APP="dist/Qevigo.app"

echo "==> swift build ($CONFIG)"
swift build -c "$CONFIG" --product Qevigo
BIN_DIR="$(swift build -c "$CONFIG" --show-bin-path)"

echo "==> assemble $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/Qevigo" "$APP/Contents/MacOS/Qevigo"
cp Resources/Info.plist "$APP/Contents/Info.plist"

if command -v iconutil >/dev/null; then
    iconutil -c icns Resources/AppIcon.iconset -o "$APP/Contents/Resources/AppIcon.icns"
fi

shopt -s nullglob
for bundle in "$BIN_DIR"/*.bundle; do
    cp -R "$bundle" "$APP/Contents/Resources/"
done

echo "==> ad-hoc sign"
codesign --force --deep --sign - "$APP"
echo "==> done: $APP"
