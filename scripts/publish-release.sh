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
# GitHub release creation is explicit; preparation never publishes. The app and its signed feed are assets of the
# latest release, which is where SUFeedURL points.
gh release create "v$VERSION" \
    "$RELEASE_DIR/Voidamp-$VERSION.zip" "$RELEASE_DIR/appcast.xml" \
    --repo "$REPOSITORY" --title "Voidamp $VERSION" \
    --notes-file docs/RELEASE_NOTES.md \
    --latest
# Builds up to 1.1.36 read the feed of the old releases repository's latest release (and up to 1.1.14 through its
# old name). It gets a release carrying only the same signed feed, whose download points here, so those copies
# update to a build that reads the new feed. Its README says Voidamp moved.
if [ -f updates/legacy-repository.txt ]; then
    LEGACY="$(cat updates/legacy-repository.txt)"
    gh release create "v$VERSION" "$RELEASE_DIR/appcast.xml" \
        --repo "$LEGACY" --title "Voidamp $VERSION (moved to $REPOSITORY)" \
        --notes "Voidamp moved to https://github.com/$REPOSITORY. Download it there: https://github.com/$REPOSITORY/releases/latest" \
        --latest
    PAGE="$(pwd)/work/legacy-repository"
    [ -d "$PAGE/.git" ] || gh repo clone "$LEGACY" "$PAGE"
    git -C "$PAGE" pull --ff-only origin main
    cp docs/LEGACY_README.md "$PAGE/README.md"
    git -C "$PAGE" add README.md
    if ! git -C "$PAGE" diff --cached --quiet; then
        git -C "$PAGE" commit -m "Voidamp moved to $REPOSITORY"
        git -C "$PAGE" push origin HEAD:main
    fi
fi
