#!/usr/bin/env bash
# Creates a stable, local code-signing identity for development builds of Tagen.
#
# Why: ad-hoc signatures (codesign -s -) change with every build, and macOS ties privacy permissions
# (Accessibility, Screen Recording, Microphone, Speech) to the signature, so each rebuild silently
# loses them. Signing every build with the same self-signed certificate keeps the designated
# requirement stable, so permissions granted once survive rebuilds.
#
# What it touches: only a separate keychain file in $TAGEN_SIGNING_DIR (default
# ~/Library/Application Support/Tagen-dev-signing). It does not add the certificate to the login
# keychain, change any trust settings, or modify TCC. The user keychain search list is restored
# after the keychain file is created. Idempotent: does nothing if the identity already exists.
set -euo pipefail
DIR="${TAGEN_SIGNING_DIR:-$HOME/Library/Application Support/Tagen-dev-signing}"
KC="$DIR/tagen-dev.keychain-db"
PWFILE="$DIR/keychain-password"
NAME="Tagen Local Development"

if [[ -f "$KC" && -f "$PWFILE" ]]; then
  security unlock-keychain -p "$(cat "$PWFILE")" "$KC"
  if security find-certificate -c "$NAME" "$KC" >/dev/null 2>&1; then
    echo "signing identity already set up: $KC"; exit 0
  fi
fi

mkdir -p "$DIR"; chmod 700 "$DIR"
WORK="$(mktemp -d)"; trap 'rm -rf "$WORK"' EXIT
umask 077
openssl rand -hex 24 > "$PWFILE"
P12PW="$(openssl rand -hex 16)"

cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical,CA:false
keyUsage = critical,digitalSignature
extendedKeyUsage = critical,codeSigning
CNF
openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/id.p12" -passout "pass:$P12PW" 2>/dev/null

ORIG_LIST=()
while IFS= read -r line; do
  line="${line#"${line%%[![:space:]]*}"}"; line="${line%\"}"; line="${line#\"}"
  [[ -n "$line" ]] && ORIG_LIST+=("$line")
done < <(security list-keychains -d user)

rm -f "$KC"
security create-keychain -p "$(cat "$PWFILE")" "$KC"
security list-keychains -d user -s "${ORIG_LIST[@]}"   # keep the user's search list unchanged
security set-keychain-settings "$KC"                   # no auto-lock
security unlock-keychain -p "$(cat "$PWFILE")" "$KC"
security import "$WORK/id.p12" -k "$KC" -P "$P12PW" -T /usr/bin/codesign >/dev/null
security set-key-partition-list -S apple-tool:,apple: -s -k "$(cat "$PWFILE")" "$KC" >/dev/null
echo "created signing identity \"$NAME\" in $KC"
