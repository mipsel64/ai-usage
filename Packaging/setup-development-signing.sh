#!/bin/bash
set -euo pipefail

identity="AI Usage Development"
root="$(cd "$(dirname "$0")/.." && pwd)"
keychain="$HOME/Library/Keychains/login.keychain-db"

if ! security find-identity -v -p codesigning | grep -q "$identity"; then
  if security find-certificate -c "$identity" "$keychain" >/dev/null 2>&1; then
    echo "$identity exists but is not a valid code-signing identity. Repair its trust settings instead of replacing it." >&2
    exit 1
  fi
  command -v openssl >/dev/null || { echo "OpenSSL is required." >&2; exit 1; }
  temp="$(mktemp -d)"
  trap 'rm -rf "$temp"' EXIT
  passphrase="$(openssl rand -hex 24)"
  cat >"$temp/openssl.cnf" <<'EOF'
[req]
prompt = no
distinguished_name = name
x509_extensions = extensions
[name]
CN = AI Usage Development
[extensions]
basicConstraints = critical, CA:TRUE, pathlen:0
keyUsage = critical, digitalSignature, keyCertSign, cRLSign
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF
  openssl req -x509 -newkey rsa:3072 -sha256 -days 3650 -nodes \
    -config "$temp/openssl.cnf" -keyout "$temp/key.pem" -out "$temp/cert.pem" \
    >/dev/null 2>&1
  openssl pkcs12 -export -legacy -out "$temp/identity.p12" \
    -inkey "$temp/key.pem" -in "$temp/cert.pem" -passout "pass:$passphrase" \
    >/dev/null 2>&1
  security import "$temp/identity.p12" -k "$keychain" -f pkcs12 -x \
    -P "$passphrase" -T /usr/bin/codesign -T /usr/bin/security >/dev/null
  security add-trusted-cert -r trustRoot -p codeSign \
    -k "$keychain" "$temp/cert.pem" >/dev/null
fi

printf 'SIGN_IDENTITY := %s\n' "$identity" >"$root/.local.mk"
echo "Configured $identity for local AI Usage builds."
