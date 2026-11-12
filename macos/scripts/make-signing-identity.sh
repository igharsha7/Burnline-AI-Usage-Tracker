#!/bin/bash
#
# make-signing-identity.sh
# Burnline
#
# Copyright (C) 2026 Challapalli Harshavardhan Reddy
# Licensed under the GNU Affero General Public License v3. See LICENSE and NOTICE.
#
# Makes the self-signed certificate releases are signed with, and imports it
# into a keychain. Run it once: every release must be signed by the same
# certificate, or macOS treats an update as a different app and asks again
# for what the last one was allowed, such as Keychain access to Claude Code's
# login. See docs/releasing.md.
#
#   macos/scripts/make-signing-identity.sh [keychain]
#
# The keychain defaults to the login keychain. The private key is made in a
# private temporary directory, imported, and deleted; nothing secret is
# printed. Refuses to run if an identity of the same name already exists,
# since a second one would sign with a different key.

set -euo pipefail

name="${BURNLINE_SIGNING_IDENTITY:-Burnline Release}"
keychain="${1:-$(security default-keychain -d user | tr -d ' "')}"
# macOS's own OpenSSL: a newer one writes a bundle `security` cannot read.
openssl=/usr/bin/openssl
# Twenty years: an expired certificate would end updates for everyone.
valid_days=7300

if security find-certificate -c "$name" "$keychain" > /dev/null 2>&1; then
    echo "A certificate named \"$name\" is already in $keychain. Releases must keep using it." >&2
    exit 1
fi

work=$(mktemp -d)
chmod 700 "$work"
trap 'rm -rf "$work"' EXIT

cat > "$work/cert.conf" <<EOF
[req]
distinguished_name = subject
prompt = no
x509_extensions = codesign
[subject]
CN = $name
[codesign]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
EOF

"$openssl" req -x509 -newkey rsa:3072 -nodes -days "$valid_days" -config "$work/cert.conf" \
    -keyout "$work/key.pem" -out "$work/cert.pem" 2> /dev/null
# The bundle's password only carries the key into the keychain; it is random
# and discarded with the bundle.
password=$("$openssl" rand -hex 24)
"$openssl" pkcs12 -export -inkey "$work/key.pem" -in "$work/cert.pem" -name "$name" \
    -out "$work/identity.p12" -passout "pass:$password"
security import "$work/identity.p12" -k "$keychain" -P "$password" -T /usr/bin/codesign > /dev/null

echo "Made \"$name\" in $keychain."
security find-identity -p codesigning "$keychain" | grep "\"$name\"" || true
