#!/bin/bash
# Creates a self-signed code-signing identity "TypeMouse Dev" in the login keychain.
# A stable identity keeps the Accessibility grant across rebuilds.
# Ad-hoc signatures change on every build, so macOS treats each build as a new app.
set -euo pipefail

NAME="${TYPEMOUSE_SIGN_IDENTITY:-TypeMouse Dev}"

if security find-certificate -c "$NAME" >/dev/null 2>&1; then
  echo "Certificate \"$NAME\" already exists."
  exit 0
fi

mkdir -p "$HOME/scratch/typemouse"
WORK="$(mktemp -d "$HOME/scratch/typemouse/cert.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
PASS="$(openssl rand -hex 16)"

/usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" \
  -addext "basicConstraints=critical,CA:false" 2>/dev/null

/usr/bin/openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
  -name "$NAME" -out "$WORK/id.p12" -passout "pass:$PASS"

security import "$WORK/id.p12" -k "$HOME/Library/Keychains/login.keychain-db" \
  -P "$PASS" -T /usr/bin/codesign >/dev/null

echo "Created code-signing identity \"$NAME\"."
