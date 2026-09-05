#!/usr/bin/env bash
set -euo pipefail

IDENTITY="Defi Release"
KEYCHAIN="$(
  security default-keychain -d user \
    | sed -e 's/^[[:space:]]*"//' -e 's/"[[:space:]]*$//'
)"

if security find-identity -p codesigning -v \
  | grep -F "\"$IDENTITY\"" >/dev/null
then
  echo "$IDENTITY already exists in the user keychain"
  exit 0
fi

TEMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/defi-release-certificate.XXXXXX")"
PRIVATE_KEY="$TEMP_DIR/private-key.pem"
CERTIFICATE="$TEMP_DIR/certificate.pem"
ARCHIVE="$TEMP_DIR/identity.p12"
PASSWORD="$(/usr/bin/openssl rand -hex 24)"

cleanup() {
  unlink "$PRIVATE_KEY" >/dev/null 2>&1 || true
  unlink "$CERTIFICATE" >/dev/null 2>&1 || true
  unlink "$ARCHIVE" >/dev/null 2>&1 || true
  rmdir "$TEMP_DIR" >/dev/null 2>&1 || true
}
trap cleanup EXIT
umask 077

/usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -nodes -days 3650 \
  -subj "/CN=$IDENTITY/O=Defi" \
  -addext "keyUsage=digitalSignature" \
  -addext "extendedKeyUsage=codeSigning" \
  -keyout "$PRIVATE_KEY" \
  -out "$CERTIFICATE" >/dev/null 2>&1

/usr/bin/openssl pkcs12 -export -descert \
  -name "$IDENTITY" \
  -inkey "$PRIVATE_KEY" \
  -in "$CERTIFICATE" \
  -out "$ARCHIVE" \
  -passout "pass:$PASSWORD"

security import "$ARCHIVE" \
  -k "$KEYCHAIN" \
  -f pkcs12 \
  -P "$PASSWORD" \
  -T /usr/bin/codesign >/dev/null
security add-trusted-cert \
  -r trustRoot \
  -p codeSign \
  -k "$KEYCHAIN" \
  "$CERTIFICATE"

security find-identity -p codesigning -v \
  | grep -F "\"$IDENTITY\"" >/dev/null \
  || { echo "Failed to create $IDENTITY" >&2; exit 1; }

echo "Created $IDENTITY in $KEYCHAIN"
echo "Back it up from Keychain Access and keep the exported private key offline."
