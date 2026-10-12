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
# Sparkle only offers a higher build number, and the bundle must say the version being released.
python3 - "$RELEASE_DIR/appcast.xml" "$BUILD" "$VERSION" dist/Voidamp.app/Contents/Info.plist <<'PYCHECK'
import pathlib, plistlib, sys, xml.etree.ElementTree as ET
feed, build, version, info = sys.argv[1], int(sys.argv[2]), sys.argv[3], plistlib.loads(pathlib.Path(sys.argv[4]).read_bytes())
if pathlib.Path(feed).exists():
    namespace = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
    published = [int(item.findtext(namespace + "version")) for item in ET.parse(feed).getroot().findall("./channel/item")]
    if published and build <= max(published):
        raise SystemExit(f"Build {build} must be higher than the latest published build {max(published)}.")
if info["CFBundleShortVersionString"] != version or info["CFBundleVersion"] != str(build):
    raise SystemExit("The built app's version or build doesn't match this release.")
PYCHECK
ditto -c -k --sequesterRsrc --keepParent dist/Voidamp.app "$RELEASE_DIR/Voidamp-$VERSION.zip"
.build/artifacts/sparkle/Sparkle/bin/generate_appcast \
    --account app.voidamp.mac.updates \
    --maximum-deltas 0 \
    --download-url-prefix "https://github.com/$REPOSITORY/releases/download/v$VERSION/" \
    "$RELEASE_DIR"
python3 scripts/verify-release.py "$RELEASE_DIR/appcast.xml" "$RELEASE_DIR/Voidamp-$VERSION.zip" "$BUILD"
echo "Signed release prepared in $RELEASE_DIR"
