#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?Usage: bash scripts/prepare-release.sh VERSION BUILD}"
BUILD="${2:?Provide an increasing numeric build number}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ && "$BUILD" =~ ^[0-9]+$ ]]; then
    echo "Use a version such as 1.1.0 and a numeric build such as 2." >&2
    exit 1
fi
VOIDAMP_VERSION="$VERSION" VOIDAMP_BUILD="$BUILD" bash scripts/build-app.sh
REPOSITORY="$(cat updates/repository.txt)"
RELEASE_DIR="$(pwd)/dist/releases/$VERSION"
mkdir -p "$RELEASE_DIR"
if gh release view "v$VERSION" --repo "$REPOSITORY" >/dev/null 2>&1; then
    echo "This version is already published. Choose a new version and build number." >&2
    exit 1
fi
rm -f "$RELEASE_DIR/appcast.xml"
# Retain previous signed feed entries without editing their signed contents.
if gh release view --repo "$REPOSITORY" >/dev/null 2>&1; then
    gh release download --repo "$REPOSITORY" --pattern appcast.xml --dir "$RELEASE_DIR" --clobber
fi
ditto -c -k --sequesterRsrc --keepParent dist/Voidamp.app "$RELEASE_DIR/Voidamp-$VERSION.zip"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
    --account app.voidamp.mac.updates \
    --maximum-deltas 0 \
    --download-url-prefix "https://github.com/$REPOSITORY/releases/download/v$VERSION/" \
    "$RELEASE_DIR"
python3 scripts/verify-release.py "$RELEASE_DIR/appcast.xml" "$RELEASE_DIR/Voidamp-$VERSION.zip" "$BUILD"
echo "Signed release prepared in $RELEASE_DIR"
