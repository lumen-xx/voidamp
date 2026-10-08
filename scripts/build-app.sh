#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
VERSION="${VOIDAMP_VERSION:-1.1.6}"
BUILD="${VOIDAMP_BUILD:-8}"
APP="$(pwd)/dist/Voidamp.app"
swift build -c release
BIN_PATH="$(swift build -c release --show-bin-path)"
FRAMEWORK=".build/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
if [ -d "$APP/Contents/Resources" ]; then
    rm -rf "$APP/Contents/Resources"
fi
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Frameworks" "$APP/Contents/Resources"
ditto Sources/Voidamp/Resources "$APP/Contents/Resources"
cp "$BIN_PATH/Voidamp" "$APP/Contents/MacOS/Voidamp"
if [ -d "$APP/Contents/Frameworks/Sparkle.framework" ]; then
    rm -rf "$APP/Contents/Frameworks/Sparkle.framework"
fi
ditto "$FRAMEWORK" "$APP/Contents/Frameworks/Sparkle.framework"
cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>Voidamp</string>
<key>CFBundleIdentifier</key><string>app.voidamp.mac</string>
<key>CFBundleName</key><string>Voidamp</string>
<key>CFBundleDisplayName</key><string>Voidamp</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleIconFile</key><string>AppIcon</string>
<key>LSMinimumSystemVersion</key><string>14.2</string>
<key>LSUIElement</key><true/>
<key>NSAudioCaptureUsageDescription</key><string>Voidamp mixes application audio so you can control and boost each app’s volume. Audio stays on your Mac.</string>
<key>NSHighResolutionCapable</key><true/>
<key>SUEnableAutomaticChecks</key><true/>
<key>SUAutomaticallyUpdate</key><false/>
<key>SUEnableInstallerLauncherService</key><true/>
<key>SUVerifyUpdateBeforeExtraction</key><true/>
<key>SURequireSignedFeed</key><true/>
</dict></plist>
PLIST
PUBLIC_KEY="$(cat updates/public-key.txt)"
UPDATE_REPOSITORY="$(cat updates/repository.txt)"
/usr/libexec/PlistBuddy -c "Add :CFBundleShortVersionString string $VERSION" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :CFBundleVersion string $BUILD" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SUPublicEDKey string $PUBLIC_KEY" "$APP/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Add :SUFeedURL string https://github.com/$UPDATE_REPOSITORY/releases/latest/download/appcast.xml" "$APP/Contents/Info.plist"
# Preserve Sparkle's upstream signatures, including its nested helpers.
codesign --force --sign - "$APP"
codesign --verify --deep --strict "$APP"
echo "Built $APP ($VERSION, build $BUILD)"
