#!/bin/bash
# Packages dist/Qevigo.app into dist/Qevigo.dmg and dist/Qevigo.zip.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -d dist/Qevigo.app ] || ./scripts/build-app.sh

STAGE="$(mktemp -d)"
ditto dist/Qevigo.app "$STAGE/Qevigo.app"
ln -s /Applications "$STAGE/Applications"
rm -f dist/Qevigo.dmg dist/Qevigo.zip
hdiutil create -volname "Qevigo" -srcfolder "$STAGE" -ov -format UDZO dist/Qevigo.dmg
rm -rf "$STAGE"
ditto -c -k --sequesterRsrc --keepParent dist/Qevigo.app dist/Qevigo.zip
echo "==> dist/Qevigo.dmg, dist/Qevigo.zip"
