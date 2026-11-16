#!/bin/bash
# Signs dist/Qevigo.zip with the Sparkle EdDSA key and writes dist/appcast.xml.
#   ./scripts/make-appcast.sh [download-base-url]
# The default base URL is this version's GitHub release.
set -euo pipefail
cd "$(dirname "$0")/.."

PLIST=dist/Qevigo.app/Contents/Info.plist
VERSION="$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$PLIST")"
BUILD="$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST")"
MINIMUM="$(/usr/libexec/PlistBuddy -c "Print LSMinimumSystemVersion" "$PLIST")"
BASE_URL="${1:-https://github.com/mohist-club/Qevigo/releases/download/v$VERSION}"
KEY="${QEVIGO_SIGNING_DIR:-$HOME/.qevigo-signing}/sparkle_private_key"
SIGN_UPDATE=".build/artifacts/sparkle/Sparkle/bin/sign_update"
# Builds below this were signed with a certificate and Sparkle key that were
# lost. They cannot verify anything newer, so the item is an informational
# update for them: Sparkle shows that a new version exists and opens the
# release page instead of downloading. Builds from here on update normally.
FIRST_BUILD_WITH_CURRENT_KEY=29

[ -f dist/Qevigo.zip ] || { echo "error: dist/Qevigo.zip missing; run scripts/make-dmg.sh" >&2; exit 1; }
[ -x "$SIGN_UPDATE" ] || swift package resolve
ATTRIBUTES="$("$SIGN_UPDATE" --ed-key-file "$KEY" dist/Qevigo.zip)"

cat > dist/appcast.xml <<XML
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Qevigo</title>
    <link>https://github.com/mohist-club/Qevigo</link>
    <item>
      <title>Qevigo $VERSION</title>
      <pubDate>$(LC_ALL=C date -u "+%a, %d %b %Y %H:%M:%S +0000")</pubDate>
      <sparkle:version>$BUILD</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>$MINIMUM</sparkle:minimumSystemVersion>
      <link>https://github.com/mohist-club/Qevigo/releases/tag/v$VERSION</link>
      <sparkle:releaseNotesLink>https://github.com/mohist-club/Qevigo/releases/tag/v$VERSION</sparkle:releaseNotesLink>
      <sparkle:informationalUpdate>
        <sparkle:belowVersion>$FIRST_BUILD_WITH_CURRENT_KEY</sparkle:belowVersion>
      </sparkle:informationalUpdate>
      <enclosure url="$BASE_URL/Qevigo.zip" type="application/octet-stream" $ATTRIBUTES/>
    </item>
  </channel>
</rss>
XML
echo "==> dist/appcast.xml ($VERSION, build $BUILD)"
