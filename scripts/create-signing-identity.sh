#!/usr/bin/env bash
# Creates the stable self-signed certificate that local development builds are
# signed with. Run it once; `make app` picks the certificate up automatically.
#
# Why this exists: an ad-hoc signature (`codesign --sign -`) gives macOS nothing
# durable to identify the app by, so TCC — the database behind System Settings →
# Privacy & Security — records each grant against a hash of the binary. Every
# rebuild changes that hash, the grant stops matching, and the app is denied while
# its toggle still looks switched on. Signing with a real certificate makes the
# grant follow the bundle identifier and the certificate, both of which survive a
# rebuild.
#
# Self-signed is enough here: the certificate never leaves this Mac and is only
# ever used for `make app`. Release bundles stay ad-hoc, because a personal
# certificate means nothing to anyone else.
#
# Undo with: security delete-certificate -c "Local Dictation Dev"
set -euo pipefail

NAME="Local Dictation Dev"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
  echo "\"$NAME\" already exists. Nothing to do."
  exit 0
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# A self-signed root valid for code signing and nothing else.
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$work/key.pem" -out "$work/cert.pem" -subj "/CN=$NAME" \
  -addext 'basicConstraints=critical,CA:true' \
  -addext 'keyUsage=critical,digitalSignature' \
  -addext 'extendedKeyUsage=critical,codeSigning'
# Apple's keychain importer only understands the original PKCS#12 algorithms.
# OpenSSL 3 defaults to modern ones, which it rejects with "MAC verification
# failed", and it rejects an empty password outright — hence the throwaway one,
# which never leaves this script.
pass="$(openssl rand -hex 16)"
openssl pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" \
  -out "$work/identity.p12" -keypbe PBE-SHA1-3DES -certpbe PBE-SHA1-3DES \
  -macalg sha1 -passout "pass:$pass"

# -A lets codesign use the private key without a keychain prompt on every build.
security import "$work/identity.p12" -k "$KEYCHAIN" -P "$pass" -T /usr/bin/codesign -A

# macOS keeps a second access list on the private key that -A does not cover, so
# codesign can be refused with errSecInternalComponent even though the key is
# right there. Adding codesign to that list up front means `make app` never has
# to raise a keychain dialog, which matters because a build run over ssh or from
# an editor has no way to answer one.
security set-key-partition-list -S apple-tool:,apple:,codesign: -s -l "$NAME" \
  "$KEYCHAIN" >/dev/null

# codesign refuses a certificate whose chain it cannot build, so the self-signed
# root has to be trusted for code signing. This is the step that asks for your
# login password.
echo
echo "macOS will now ask for your login password to trust the certificate."
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$work/cert.pem"

echo
echo "Created \"$NAME\"."
echo "Next: run 'make app', then re-grant Input Monitoring and Accessibility once."
