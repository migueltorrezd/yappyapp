#!/usr/bin/env bash
set -euo pipefail

# Creates a stable self-signed code signing identity for YappYapp.
#
# Why: ad-hoc signatures (codesign --sign -) change on every build, which makes
# macOS revoke the Accessibility permission after each rebuild. Signing with a
# stable identity keeps the TCC grant across rebuilds, so auto-paste keeps
# working. macOS will show one password prompt while trusting the certificate.

IDENTITY_NAME="YappYapp Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY_NAME"; then
  echo "Signing identity '$IDENTITY_NAME' already exists. Nothing to do."
  exit 0
fi

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

echo "Generating self-signed code signing certificate '$IDENTITY_NAME'..."
openssl req -x509 -newkey rsa:2048 -nodes \
  -keyout "$TMP_DIR/key.pem" -out "$TMP_DIR/cert.pem" -days 3650 \
  -subj "/CN=$IDENTITY_NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" 2>/dev/null

# OpenSSL 3 defaults to AES encryption that Keychain's importer rejects;
# -legacy falls back to the PKCS12 encryption macOS understands.
PKCS12_FLAGS=()
if openssl pkcs12 -help 2>&1 | grep -q -- "-legacy"; then
  PKCS12_FLAGS+=("-legacy")
fi

openssl pkcs12 -export "${PKCS12_FLAGS[@]+"${PKCS12_FLAGS[@]}"}" \
  -inkey "$TMP_DIR/key.pem" -in "$TMP_DIR/cert.pem" \
  -out "$TMP_DIR/identity.p12" -passout pass:yappyapp -name "$IDENTITY_NAME"

echo "Importing into the login keychain..."
security import "$TMP_DIR/identity.p12" -k "$KEYCHAIN" -P yappyapp -T /usr/bin/codesign

echo "Trusting the certificate for code signing (macOS will ask for your password once)..."
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$TMP_DIR/cert.pem"

echo "Done. 'scripts/package_app.sh' will now sign with '$IDENTITY_NAME'."
echo "Grant Accessibility to the next build once; after that it survives rebuilds."
