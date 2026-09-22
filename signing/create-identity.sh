#!/usr/bin/env bash
# Stable self-signed code-signing identity for Deck. Ad-hoc signatures change with every
# rebuild, and macOS pins Accessibility / Microphone grants to that hash, so the dictation
# chord dies silently after each build. A fixed certificate keeps the designated requirement
# (identifier + certificate) constant, and the grants survive.
set -euo pipefail
NAME="Deck Local Signing"
if security find-certificate -c "$NAME" >/dev/null 2>&1; then echo "identity already present: $NAME"; exit 0; fi
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
cat > "$T/ext.cnf" <<'CNF'
[v3]
basicConstraints=critical,CA:false
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -keyout "$T/key.pem" -out "$T/cert.pem" -days 3650 -nodes \
  -subj "/CN=$NAME/O=Yahya Elghobashy" -extensions v3 -config <(cat /etc/ssl/openssl.cnf "$T/ext.cnf") 2>/dev/null
openssl pkcs12 -export -inkey "$T/key.pem" -in "$T/cert.pem" -out "$T/id.p12" -passout pass:deck -name "$NAME" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1
security import "$T/id.p12" -k ~/Library/Keychains/login.keychain-db -P deck -T /usr/bin/codesign -A
cp "$T/cert.pem" "$(dirname "$0")/deck-signing.pem"
echo "created: $NAME"
