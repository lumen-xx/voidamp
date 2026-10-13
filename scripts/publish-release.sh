#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${1:?Usage: bash scripts/publish-release.sh VERSION}"
if ! [[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then exit 1; fi
REPOSITORY="$(cat updates/repository.txt)"
RELEASE_DIR="dist/releases/$VERSION"
if [ ! -f "$RELEASE_DIR/appcast.xml" ] || [ ! -f "$RELEASE_DIR/Voidamp-$VERSION.zip" ] || [ ! -f docs/RELEASE_NOTES.md ]; then
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
    --notes-file docs/RELEASE_NOTES.md \
    --latest
# The release page describes the current version, with its screenshots. The feed itself is a release asset.
PAGE="$(pwd)/work/releases-repository"
[ -d "$PAGE/.git" ] || gh repo clone "$REPOSITORY" "$PAGE"
git -C "$PAGE" pull --ff-only origin main
cp docs/RELEASE_README.md "$PAGE/README.md"
mkdir -p "$PAGE/images"
cp docs/images/*.png "$PAGE/images/"
git -C "$PAGE" add README.md images
if ! git -C "$PAGE" diff --cached --quiet; then
    git -C "$PAGE" commit -m "Describe Voidamp $VERSION"
    git -C "$PAGE" push origin HEAD:main
fi
