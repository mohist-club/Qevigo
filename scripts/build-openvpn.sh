#!/bin/bash
# Builds a self-contained openvpn for Qevigo: one universal binary with
# OpenSSL and LZO linked in, so a user needs neither Homebrew nor the Xcode
# command line tools to connect a VPN.
#
#   ./scripts/build-openvpn.sh            builds dist/openvpn-universal
#   ARCHS="arm64" ./scripts/build-openvpn.sh   single architecture, faster
#
# openvpn is GPL-2.0 and OpenSSL is Apache-2.0: the versions, the exact source
# archives and this script are what the licenses require us to publish
# alongside the binary we distribute.
set -euo pipefail
cd "$(dirname "$0")/.."

OPENVPN_VERSION="${OPENVPN_VERSION:-2.7.8}"
OPENSSL_VERSION="${OPENSSL_VERSION:-4.1.0}"
LZO_VERSION="${LZO_VERSION:-2.10}"
ARCHS="${ARCHS:-arm64 x86_64}"
DEPLOYMENT_TARGET=14.0

WORK="${WORK:-$PWD/.build/openvpn-src}"
OUT="$PWD/dist"
mkdir -p "$WORK" "$OUT"

fetch() { # url sha256 filename
    local url=$1 expected=$2 file="$WORK/$3"
    if [ ! -f "$file" ]; then
        echo "==> download $3"
        curl -fsSL --retry 3 -o "$file.part" "$url"
        mv "$file.part" "$file"
    fi
    local actual
    actual=$(shasum -a 256 "$file" | cut -d' ' -f1)
    if [ -n "$expected" ] && [ "$actual" != "$expected" ]; then
        echo "error: $3 checksum mismatch" >&2
        echo "  expected $expected" >&2
        echo "  actual   $actual" >&2
        exit 1
    fi
    [ -n "$expected" ] || echo "    sha256 $actual"
}

# Pinned so a tampered mirror cannot change what goes into the binary.
# Set SKIP_CHECKSUMS=1 to print the checksums of new versions instead.
if [ "${SKIP_CHECKSUMS:-0}" = 1 ]; then
    OPENVPN_SHA=""; OPENSSL_SHA=""; LZO_SHA=""
else
    # Verified against the published archives on 2026-10-28.
    OPENVPN_SHA="${OPENVPN_SHA:-c070d1d2440b5a6fca6c2c68645c98cd492116ac36ef4f0946177115532c8e36}"
    OPENSSL_SHA="${OPENSSL_SHA:-50c17baf54cb008f6ce42d50deb4b28050a1aad711636cabd4b241c7e90cc2fd}"
    LZO_SHA="${LZO_SHA:-c0f892943208266f9b6543b3ae308fab6284c5c90e627931446fb49b4221a072}"
fi

fetch "https://build.openvpn.net/downloads/releases/openvpn-$OPENVPN_VERSION.tar.gz" "$OPENVPN_SHA" "openvpn-$OPENVPN_VERSION.tar.gz"
fetch "https://github.com/openssl/openssl/releases/download/openssl-$OPENSSL_VERSION/openssl-$OPENSSL_VERSION.tar.gz" "$OPENSSL_SHA" "openssl-$OPENSSL_VERSION.tar.gz"
fetch "https://www.oberhumer.com/opensource/lzo/download/lzo-$LZO_VERSION.tar.gz" "$LZO_SHA" "lzo-$LZO_VERSION.tar.gz"

build_arch() {
    local arch=$1
    local prefix="$WORK/root-$arch"
    local stamp="$prefix/.done"
    if [ -f "$stamp" ]; then
        echo "==> $arch already built"
        return
    fi
    rm -rf "$prefix"
    mkdir -p "$prefix"

    local host flags
    case "$arch" in
        arm64) host="aarch64-apple-darwin"; flags="-arch arm64" ;;
        x86_64) host="x86_64-apple-darwin"; flags="-arch x86_64" ;;
        *) echo "unknown arch $arch" >&2; exit 1 ;;
    esac
    flags="$flags -mmacosx-version-min=$DEPLOYMENT_TARGET"

    echo "==> build OpenSSL ($arch)"
    rm -rf "$WORK/openssl-$arch"
    mkdir -p "$WORK/openssl-$arch"
    tar xzf "$WORK/openssl-$OPENSSL_VERSION.tar.gz" -C "$WORK/openssl-$arch" --strip-components=1
    (
        cd "$WORK/openssl-$arch"
        local target
        [ "$arch" = arm64 ] && target=darwin64-arm64-cc || target=darwin64-x86_64-cc
        ./Configure "$target" no-shared no-tests no-docs no-legacy \
            --prefix="$prefix" --openssldir="$prefix/ssl" \
            -mmacosx-version-min=$DEPLOYMENT_TARGET >/dev/null
        make -j"$(sysctl -n hw.ncpu)" >/dev/null
        make install_sw >/dev/null
    )

    echo "==> build LZO ($arch)"
    rm -rf "$WORK/lzo-$arch"
    mkdir -p "$WORK/lzo-$arch"
    tar xzf "$WORK/lzo-$LZO_VERSION.tar.gz" -C "$WORK/lzo-$arch" --strip-components=1
    (
        cd "$WORK/lzo-$arch"
        ./configure --host="$host" --prefix="$prefix" --enable-static --disable-shared \
            CFLAGS="$flags" >/dev/null
        make -j"$(sysctl -n hw.ncpu)" >/dev/null
        make install >/dev/null
    )

    echo "==> build openvpn ($arch)"
    rm -rf "$WORK/openvpn-$arch"
    mkdir -p "$WORK/openvpn-$arch"
    tar xzf "$WORK/openvpn-$OPENVPN_VERSION.tar.gz" -C "$WORK/openvpn-$arch" --strip-components=1
    (
        cd "$WORK/openvpn-$arch"
        # Everything optional is off: a plugin, pkcs11 or lz4 found on the build
        # machine would be linked dynamically and the binary would stop being
        # self-contained. Compression stays available through the LZO built above.
        PKG_CONFIG_PATH="" PKG_CONFIG_LIBDIR="$prefix/lib/pkgconfig" \
        ./configure --host="$host" --disable-plugins --disable-pkcs11 --disable-selinux \
            --disable-systemd --disable-dependency-tracking --disable-lz4 \
            CFLAGS="$flags -I$prefix/include" \
            LDFLAGS="$flags -L$prefix/lib" \
            OPENSSL_CFLAGS="-I$prefix/include" \
            OPENSSL_LIBS="$prefix/lib/libssl.a $prefix/lib/libcrypto.a" \
            LZO_CFLAGS="-I$prefix/include" \
            LZO_LIBS="$prefix/lib/liblzo2.a" >/dev/null
        make -j"$(sysctl -n hw.ncpu)" >/dev/null
    )
    cp "$WORK/openvpn-$arch/src/openvpn/openvpn" "$prefix/openvpn"
    touch "$stamp"
}

for arch in $ARCHS; do build_arch "$arch"; done

echo "==> combine"
BINARIES=()
for arch in $ARCHS; do BINARIES+=("$WORK/root-$arch/openvpn"); done
if [ ${#BINARIES[@]} -eq 0 ]; then
    echo "nothing built (ARCHS is empty)"
    exit 0
elif [ ${#BINARIES[@]} -gt 1 ]; then
    lipo -create "${BINARIES[@]}" -output "$OUT/openvpn-universal"
else
    cp "${BINARIES[0]}" "$OUT/openvpn-universal"
fi
strip -S "$OUT/openvpn-universal"

SIGNING_DIR="${QEVIGO_SIGNING_DIR:-$HOME/.qevigo-signing}"
if [ -f "$SIGNING_DIR/signing.keychain-db" ]; then
    echo "==> sign"
    security unlock-keychain -p "$(cat "$SIGNING_DIR/keychain-password")" "$SIGNING_DIR/signing.keychain-db"
    codesign --force --timestamp=none --keychain "$SIGNING_DIR/signing.keychain-db" \
        --sign "Qevigo Self-Signed Code Signing" "$OUT/openvpn-universal"
fi

echo "==> verify"
file "$OUT/openvpn-universal" | sed 's/^/    /'
otool -L "$OUT/openvpn-universal" | tail -n +2 | sed 's/^/    links: /'
# The whole point is that it runs on a Mac with nothing installed, so a link to
# anything outside the system libraries is a failure, not a warning.
if otool -L "$OUT/openvpn-universal" | tail -n +2 | grep -vqE '^[[:space:]]+(/usr/lib/|/System/)'; then
    echo "error: links to a library outside the system; the binary is not self-contained" >&2
    exit 1
fi
"$OUT/openvpn-universal" --version | head -2 | sed 's/^/    /'
echo "    size   $(du -h "$OUT/openvpn-universal" | cut -f1)"
echo "    sha256 $(shasum -a 256 "$OUT/openvpn-universal" | cut -d' ' -f1)"
