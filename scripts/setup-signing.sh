#!/bin/bash
# One-time setup of the release signing material. Safe to re-run: existing
# files are kept. Everything lives in ~/.qevigo-signing (outside the repo).
#
#   signing.keychain-db    dedicated keychain holding the code-signing identity
#   keychain-password      password of that keychain (random)
#   signing.p12            backup of the certificate + private key (same password)
#   sparkle_private_key    Sparkle EdDSA private key (base64 seed)
#   sparkle_public_key     goes into Info.plist as SUPublicEDKey
#
# Back this folder up. Losing it means users cannot auto-update to builds signed
# with a new identity/key and will have to reinstall and re-grant Accessibility.
set -euo pipefail

DIR="${QEVIGO_SIGNING_DIR:-$HOME/.qevigo-signing}"
IDENTITY="Qevigo Self-Signed Code Signing"
mkdir -p "$DIR"
chmod 700 "$DIR"
cd "$DIR"

if [ ! -f keychain-password ]; then
    (umask 077; openssl rand -base64 24 > keychain-password)
fi
PASSWORD="$(cat keychain-password)"

if [ ! -f signing.p12 ]; then
    echo "==> create self-signed code-signing certificate"
    cat > cert.cnf <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $IDENTITY
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
    (umask 077; openssl req -x509 -newkey rsa:2048 -nodes -days 7300 -config cert.cnf -keyout key.pem -out cert.pem 2>/dev/null)
    # macOS `security import` only reads PKCS#12 files using the older 3DES/SHA-1 encoding.
    (umask 077; openssl pkcs12 -export -inkey key.pem -in cert.pem -name "$IDENTITY" \
        -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES -macalg sha1 \
        -out signing.p12 -passout pass:"$PASSWORD")
    rm -f key.pem cert.cnf
fi

KEYCHAIN="$DIR/signing.keychain-db"
if [ ! -f "$KEYCHAIN" ]; then
    echo "==> create dedicated keychain"
    SEARCH_LIST="$(security list-keychains -d user | tr -d '"')"
    security create-keychain -p "$PASSWORD" "$KEYCHAIN"
    # Keep the user's keychain search list exactly as it was.
    # shellcheck disable=SC2086
    security list-keychains -d user -s $SEARCH_LIST
    security set-keychain-settings "$KEYCHAIN"
    security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
    security import signing.p12 -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
    # Lets codesign use the key without a GUI permission prompt.
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
fi

if [ ! -f sparkle_private_key ]; then
    echo "==> create Sparkle EdDSA key pair"
    GEN="$(mktemp -d)/keygen.swift"
    cat > "$GEN" <<'EOF'
import CryptoKit
import Foundation
let key = Curve25519.Signing.PrivateKey()
let dir = URL(fileURLWithPath: CommandLine.arguments[1])
try (key.rawRepresentation.base64EncodedString() + "\n").write(to: dir.appendingPathComponent("sparkle_private_key"), atomically: true, encoding: .utf8)
try (key.publicKey.rawRepresentation.base64EncodedString() + "\n").write(to: dir.appendingPathComponent("sparkle_public_key"), atomically: true, encoding: .utf8)
EOF
    (umask 077; swift "$GEN" "$DIR")
    rm -rf "$(dirname "$GEN")"
    chmod 600 sparkle_private_key
fi

echo "==> signing identity:"
security find-identity -p codesigning "$KEYCHAIN" | grep "$IDENTITY" || { echo "identity missing"; exit 1; }
echo "==> Sparkle public key: $(cat sparkle_public_key)"
echo "Done. Back up $DIR."
