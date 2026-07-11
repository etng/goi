#!/bin/bash
# Creates a stable self-signed code-signing identity in a dedicated keychain,
# so locally-built dev apps keep a constant designated requirement across
# rebuilds — which means macOS keeps their Accessibility grant (needed for
# 划词取词) instead of dropping it every time the binary's cdhash changes.
#
# Idempotent: re-running finds the existing identity and does nothing.
# The keychain and its (local, low-sensitivity) password are dev-only and
# never leave this machine.
set -euo pipefail

CERT_NAME="Goi Local Signing"
KEYCHAIN="$HOME/Library/Keychains/goi-signing.keychain-db"
KEYCHAIN_PASSWORD="goi-local-signing"

# note: -v (valid only) would hide our self-signed cert (it's untrusted but
# still usable for signing), so check the full listing
if security find-identity -p codesigning 2>/dev/null | grep -q "$CERT_NAME"; then
  echo "signing identity '$CERT_NAME' already present — nothing to do"
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# X.509 config: a leaf code-signing cert (codeSigning EKU is what makes
# `security find-identity -p codesigning` list it).
cat > "$WORK/cert.cnf" <<'CNF'
[ req ]
distinguished_name = dn
x509_extensions    = ext
prompt             = no
[ dn ]
CN = Goi Local Signing
[ ext ]
basicConstraints       = critical, CA:false
keyUsage               = critical, digitalSignature
extendedKeyUsage       = critical, codeSigning
CNF

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -config "$WORK/cert.cnf" 2>/dev/null

# -legacy: OpenSSL 3 defaults to a PKCS12 MAC that macOS's Security
# framework can't verify; the legacy (SHA1/3DES) format imports cleanly.
LEGACY=""
if openssl pkcs12 -help 2>&1 | grep -q -- "-legacy"; then LEGACY="-legacy"; fi
openssl pkcs12 -export $LEGACY -out "$WORK/cert.p12" \
  -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$CERT_NAME" -passout pass:goi 2>/dev/null

# dedicated keychain so we can authorize codesign non-interactively
if [[ ! -f "$KEYCHAIN" ]]; then
  security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
fi
security set-keychain-settings "$KEYCHAIN"                       # no auto-lock timeout
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$WORK/cert.p12" -k "$KEYCHAIN" -P goi \
  -T /usr/bin/codesign -T /usr/bin/security
# pre-authorize codesign to use the key without a GUI prompt
security set-key-partition-list -S apple-tool:,apple:,codesign: \
  -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null 2>&1

# add to the user's keychain search list (keep the existing ones)
EXISTING="$(security list-keychains -d user | sed 's/[":]//g' | xargs)"
if ! echo "$EXISTING" | tr ' ' '\n' | grep -qF "$KEYCHAIN"; then
  security list-keychains -d user -s "$KEYCHAIN" $EXISTING
fi

echo "created signing identity '$CERT_NAME' in $KEYCHAIN"
security find-identity -p codesigning | grep "$CERT_NAME" || true
