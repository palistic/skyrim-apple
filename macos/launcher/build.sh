#!/bin/sh
set -eu
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
OUTPUT_DIR="$PROJECT_DIR/macos/build/launcher"
mkdir -p "$OUTPUT_DIR"
STAGE_DIR=$(mktemp -d "$OUTPUT_DIR/package-XXXXXX")
APP_DIR="$STAGE_DIR/Skyrim Launcher.app"
mkdir -p "$APP_DIR/Contents/MacOS" "$APP_DIR/Contents/Resources"
SDK_PATH=$(xcrun --sdk macosx --show-sdk-path)
xcrun --sdk macosx metal -std=metal3.1 -target air64-apple-macos14.0 \
    -c "$PROJECT_DIR/macos/launcher/SmokeBackground.metal" -o "$STAGE_DIR/SmokeBackground.air"
xcrun --sdk macosx metallib "$STAGE_DIR/SmokeBackground.air" \
    -o "$APP_DIR/Contents/Resources/default.metallib"
xcrun swiftc -O -parse-as-library -target arm64-apple-macos14.0 -sdk "$SDK_PATH" \
    "$PROJECT_DIR/macos/launcher/LauncherApp.swift" \
    "$PROJECT_DIR/macos/launcher/LauncherModel.swift" \
    -framework SwiftUI -framework AppKit -o "$APP_DIR/Contents/MacOS/SkyrimLauncher"
printf '%s\n' "$PROJECT_DIR" > "$APP_DIR/Contents/Resources/checkout-path.txt"
cat > "$APP_DIR/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>dev.zschwendi.skyrim.launcher</string>
<key>CFBundleName</key><string>Skyrim Launcher</string>
<key>CFBundleDisplayName</key><string>Skyrim</string>
<key>CFBundleExecutable</key><string>SkyrimLauncher</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleShortVersionString</key><string>0.1</string>
<key>CFBundleVersion</key><string>1</string>
<key>LSMinimumSystemVersion</key><string>14.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSPrincipalClass</key><string>NSApplication</string>
</dict></plist>
PLIST
codesign --force --sign - --options runtime "$APP_DIR"
if [ -e "$OUTPUT_DIR/Skyrim Launcher.app" ]; then
    PREVIOUS_DIR=$(mktemp -d "$OUTPUT_DIR/previous-XXXXXX")
    mv "$OUTPUT_DIR/Skyrim Launcher.app" "$PREVIOUS_DIR/"
fi
mv "$APP_DIR" "$OUTPUT_DIR/Skyrim Launcher.app"
printf 'Launcher: %s\n' "$OUTPUT_DIR/Skyrim Launcher.app"
