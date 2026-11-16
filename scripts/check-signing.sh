#!/bin/bash
# Refuses to release with signing material that existing users would reject.
#   ./scripts/check-signing.sh
#
# Sparkle installs an update only if its EdDSA signature matches SUPublicEDKey
# in the running app AND the new app is code-signed with the same certificate.
# Running setup-signing.sh on a machine without ~/.qevigo-signing silently
# creates a new certificate and key pair, and a release signed with those would
# strand every installed copy. This checks both before anything is published:
#   1. sparkle_private_key derives to Resources/Info.plist's SUPublicEDKey
#   2. the keychain's certificate is the one the latest v* release was signed with
#
# QEVIGO_NEW_IDENTITY=1 is for the one release that deliberately moves to a new
# certificate and Sparkle key because the old ones are lost. It is accepted only
# when Info.plist's SUPublicEDKey already differs from the latest release's, and
# it skips check 2. Installed copies cannot update across that release; the
# appcast tells them to reinstall by hand (see make-appcast.sh).
set -euo pipefail
cd "$(dirname "$0")/.."

DIR="${QEVIGO_SIGNING_DIR:-$HOME/.qevigo-signing}"
KEYCHAIN="$DIR/signing.keychain-db"
IDENTITY="Qevigo Self-Signed Code Signing"
REPO="mohist-club/Qevigo"
fail() { echo "error: $*" >&2; exit 1; }

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

echo "==> Sparkle key matches Info.plist"
[ -s "$DIR/sparkle_private_key" ] || fail "$DIR/sparkle_private_key missing; copy ~/.qevigo-signing from the release machine (do not regenerate it)"
cat > "$TMP/pubkey.swift" <<'EOF'
import CryptoKit
import Foundation
let text = try String(contentsOfFile: CommandLine.arguments[1], encoding: .utf8)
    .trimmingCharacters(in: .whitespacesAndNewlines)
guard let seed = Data(base64Encoded: text) else { fatalError("sparkle_private_key is not base64") }
let key = try Curve25519.Signing.PrivateKey(rawRepresentation: seed)
print(key.publicKey.rawRepresentation.base64EncodedString())
EOF
EXPECTED="$(/usr/libexec/PlistBuddy -c "Print SUPublicEDKey" Resources/Info.plist)"
ACTUAL="$(swift "$TMP/pubkey.swift" "$DIR/sparkle_private_key")"
[ "$ACTUAL" = "$EXPECTED" ] || fail "sparkle_private_key belongs to $ACTUAL, but Info.plist expects $EXPECTED; installed apps would reject this update"

echo "==> code-signing certificate matches the last release"
[ -f "$KEYCHAIN" ] || fail "$KEYCHAIN missing; run scripts/setup-signing.sh with the copied signing folder"
security find-certificate -c "$IDENTITY" -p "$KEYCHAIN" | grep -v -- '-----' | base64 -D > "$TMP/current.der" \
    || fail "\"$IDENTITY\" not found in $KEYCHAIN"
CURRENT="$(shasum -a 256 "$TMP/current.der" | cut -d' ' -f1)"

LAST_TAG="$(git tag -l 'v*' --sort=-v:refname | head -1)"
if [ -z "$LAST_TAG" ]; then
    echo "    no earlier v* tag; nothing to compare against"
    exit 0
fi
command -v gh >/dev/null || fail "gh is needed to download $LAST_TAG for the comparison"
gh release download "$LAST_TAG" --repo "$REPO" --pattern Qevigo.zip --dir "$TMP" >/dev/null
ditto -x -k "$TMP/Qevigo.zip" "$TMP/last"
LAST_KEY="$(/usr/libexec/PlistBuddy -c "Print SUPublicEDKey" "$TMP/last/Qevigo.app/Contents/Info.plist")"
if [ "${QEVIGO_NEW_IDENTITY:-0}" = 1 ]; then
    [ "$LAST_KEY" != "$EXPECTED" ] || fail "QEVIGO_NEW_IDENTITY=1, but Info.plist still has the Sparkle key $LAST_TAG shipped with; a new identity needs the new public key in Info.plist first"
    echo "    NEW IDENTITY: $LAST_TAG used Sparkle key $LAST_KEY; installed copies must reinstall this release by hand"
    exit 0
fi
[ "$LAST_KEY" = "$EXPECTED" ] || fail "Info.plist's Sparkle key changed since $LAST_TAG ($LAST_KEY -> $EXPECTED); installed copies would reject this update. If the old key is truly lost, release with QEVIGO_NEW_IDENTITY=1"
codesign -d --extract-certificates="$TMP/last-cert" "$TMP/last/Qevigo.app" 2>/dev/null
PREVIOUS="$(shasum -a 256 "$TMP/last-cert0" | cut -d' ' -f1)"
[ "$CURRENT" = "$PREVIOUS" ] || fail "signing certificate $CURRENT differs from the one $LAST_TAG was signed with ($PREVIOUS); Sparkle would refuse to install this update. If the old certificate is truly lost, release with QEVIGO_NEW_IDENTITY=1"
echo "    same certificate as $LAST_TAG"
