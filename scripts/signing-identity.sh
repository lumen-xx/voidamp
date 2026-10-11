#!/bin/bash
# Prints the path of a private keychain holding the stable "Voidamp Local Signing" identity, creating it once.
# Ad-hoc signatures change with every build, so macOS forgets the Screen & System Audio Recording permission
# after each update. A fixed self-signed identity keeps the designated requirement, and the permission, stable.
# Keep ~/Library/Keychains/voidamp-signing.keychain-db and ~/.config/voidamp/signing-password: losing them means
# allowing audio access once more after the next update.
set -euo pipefail
NAME="Voidamp Local Signing"
KEYCHAIN="$HOME/Library/Keychains/voidamp-signing.keychain-db"
SECRET_DIR="$HOME/.config/voidamp"
PASSWORD_FILE="$SECRET_DIR/signing-password"

if [ ! -f "$KEYCHAIN" ]; then
    mkdir -p "$SECRET_DIR"
    chmod 700 "$SECRET_DIR"
    if [ ! -f "$PASSWORD_FILE" ]; then
        (umask 077; openssl rand -hex 24 > "$PASSWORD_FILE")
    fi
    PASSWORD="$(cat "$PASSWORD_FILE")"
    WORK="$(mktemp -d)"
    trap 'rm -rf "$WORK"' EXIT
    cat > "$WORK/cert.cnf" <<CNF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
CNF
    openssl req -x509 -newkey rsa:3072 -nodes -days 7300 -config "$WORK/cert.cnf" \
        -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null
    openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
        -passout "pass:$PASSWORD" -out "$WORK/identity.p12"
    security create-keychain -p "$PASSWORD" "$KEYCHAIN"
    security set-keychain-settings "$KEYCHAIN"
    security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
    security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
    security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
fi

security unlock-keychain -p "$(cat "$PASSWORD_FILE")" "$KEYCHAIN"
echo "$KEYCHAIN"
