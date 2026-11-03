#!/bin/sh
set -eu
PROJECT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
BUILD_JOBS=${SKYRIM_BUILD_JOBS:-2}
case "$BUILD_JOBS" in 1|2) ;; *) echo 'Use one or two build jobs.' >&2; exit 2 ;; esac
mkdir -p "$PROJECT_DIR/vision/build"
swift "$PROJECT_DIR/vision/prepare_assets.swift"
xcodegen generate --spec "$PROJECT_DIR/vision/project.yml" --project "$PROJECT_DIR/vision"
xcodebuild -project "$PROJECT_DIR/vision/SkyrimLauncher.xcodeproj" \
    -scheme SkyrimLauncher -configuration Release -sdk xros \
    -destination 'generic/platform=visionOS' \
    -derivedDataPath "$PROJECT_DIR/vision/build/DerivedData" \
    -jobs "$BUILD_JOBS" -allowProvisioningUpdates build \
    > "$PROJECT_DIR/vision/build/build.log" 2>&1 || {
        tail -80 "$PROJECT_DIR/vision/build/build.log"
        exit 1
    }
printf 'Built: %s\n' "$PROJECT_DIR/vision/build/DerivedData/Build/Products/Release-xros/SkyrimLauncher.app"
