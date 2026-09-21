#!/bin/bash
# Packages dist/Poptro.app into dist/Poptro.dmg and dist/Poptro.zip.
set -euo pipefail
cd "$(dirname "$0")/.."

[ -d dist/Poptro.app ] || ./scripts/build-app.sh

STAGE="$(mktemp -d)"
ditto dist/Poptro.app "$STAGE/Poptro.app"
ln -s /Applications "$STAGE/Applications"
rm -f dist/Poptro.dmg dist/Poptro.zip
hdiutil create -volname "Poptro" -srcfolder "$STAGE" -ov -format UDZO dist/Poptro.dmg
rm -rf "$STAGE"
ditto -c -k --sequesterRsrc --keepParent dist/Poptro.app dist/Poptro.zip
echo "==> dist/Poptro.dmg, dist/Poptro.zip"
