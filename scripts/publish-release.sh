#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?Usage: bash scripts/publish-release.sh VERSION}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then exit 1; fi
REPOSITORY="$(cat updates/repository.txt)"
RELEASE_DIR="dist/releases/$VERSION"
if [ ! -f "$RELEASE_DIR/appcast.xml" ] || [ ! -f "$RELEASE_DIR/Voidamp-$VERSION.zip" ]; then
    echo "Prepare and verify this release first." >&2
    exit 1
fi
BUILD="$(python3 - "$RELEASE_DIR/Voidamp-$VERSION.zip" <<'PYBUILD'
import plistlib, sys, zipfile
with zipfile.ZipFile(sys.argv[1]) as archive:
    print(plistlib.loads(archive.read('Voidamp.app/Contents/Info.plist'))['CFBundleVersion'])
PYBUILD
)"
python3 scripts/verify-release.py "$RELEASE_DIR/appcast.xml" "$RELEASE_DIR/Voidamp-$VERSION.zip" "$BUILD"
# GitHub release creation is explicit; preparation never publishes.
gh release create "v$VERSION" \
    "$RELEASE_DIR/Voidamp-$VERSION.zip" "$RELEASE_DIR/appcast.xml" \
    --repo "$REPOSITORY" --title "Voidamp $VERSION" \
    --notes "Native macOS menu bar audio mixer. Includes signed Sparkle updates. Requires macOS 14.2 or newer and an Apple silicon Mac." \
    --latest
