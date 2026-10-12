#!/bin/bash
# Builds the Voidamp Mic audio driver into DESTINATION/VoidampMic.driver, signed with Voidamp's local identity.
# The driver has its own version: Voidamp only asks to reinstall it when this changes.
set -euo pipefail
cd "$(dirname "$0")/.."
DESTINATION="${1:?Usage: bash scripts/build-driver.sh DESTINATION [--unsigned]}"
DRIVER_VERSION="1.1.0"
DRIVER_BUILD="2"
BUNDLE="$DESTINATION/VoidampMic.driver"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS"
sed -e "s/DRIVER_VERSION/$DRIVER_VERSION/" -e "s/DRIVER_BUILD/$DRIVER_BUILD/" Driver/Info.plist > "$BUNDLE/Contents/Info.plist"
clang -bundle -O2 -Wall -Wextra -Werror -arch arm64 -arch x86_64 -mmacosx-version-min=14.2 \
    -framework CoreAudio -framework CoreFoundation \
    -o "$BUNDLE/Contents/MacOS/VoidampMic" Driver/VoidampMic.c
if [ "${2:-}" != "--unsigned" ]; then
    SIGNING_KEYCHAIN="$(bash scripts/signing-identity.sh)"
    codesign --force --keychain "$SIGNING_KEYCHAIN" --sign "Voidamp Local Signing" "$BUNDLE"
fi
echo "Built $BUNDLE ($DRIVER_VERSION, build $DRIVER_BUILD)"
