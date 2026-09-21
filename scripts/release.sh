#!/bin/bash
# Cuts a release: bump the version, test, build the signed app, package DMG/ZIP,
# write the appcast, tag, push and publish the GitHub release.
#   ./scripts/release.sh 1.0.2 release-notes.md
# Set RELEASE_TRAILER to append a trailer line to the release commit.
set -euo pipefail
cd "$(dirname "$0")/.."

VERSION="${1:?usage: release.sh <version> <notes-file>}"
NOTES="${2:?usage: release.sh <version> <notes-file>}"
PLIST=Resources/Info.plist

[ -z "$(git status --porcelain)" ] || { echo "error: working tree is not clean" >&2; exit 1; }
! git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || { echo "error: tag v$VERSION exists" >&2; exit 1; }
[ -f "$NOTES" ] || { echo "error: notes file $NOTES not found" >&2; exit 1; }

BUILD=$(( $(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$PLIST") + 1 ))
/usr/libexec/PlistBuddy -c "Set CFBundleShortVersionString $VERSION" -c "Set CFBundleVersion $BUILD" "$PLIST"

swift test
rm -rf dist
QEVIGO_REQUIRE_SIGNING=1 ./scripts/build-app.sh
./scripts/make-dmg.sh
./scripts/make-appcast.sh

git add "$PLIST"
git commit -m "Release $VERSION" ${RELEASE_TRAILER:+-m "$RELEASE_TRAILER"}
git tag -a "v$VERSION" -m "Qevigo $VERSION"
git push origin HEAD "v$VERSION"
gh release create "v$VERSION" dist/Qevigo.dmg dist/Qevigo.zip dist/appcast.xml \
    --title "Qevigo $VERSION" --notes-file "$NOTES"
