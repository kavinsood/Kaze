#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
SOURCE_DIR="$PROJECT_DIR/Kaze"
BUILD_DIR="$PROJECT_DIR/build/local"
STAGING_DIR="$BUILD_DIR/staging"
APP_BUNDLE="$BUILD_DIR/Kaze Cloud.app"
CONTENTS_DIR="$STAGING_DIR/Kaze Cloud.app/Contents"

rm -rf "$STAGING_DIR"
mkdir -p "$CONTENTS_DIR/MacOS" "$CONTENTS_DIR/Resources"

SOURCES=()
while IFS= read -r source_file; do
    SOURCES+=("$source_file")
done < <(find "$SOURCE_DIR" -name '*.swift' -type f -print | sort)

swiftc \
    -O \
    -swift-version 5 \
    -warnings-as-errors \
    -default-isolation MainActor \
    -target arm64-apple-macos26.0 \
    "${SOURCES[@]}" \
    -o "$CONTENTS_DIR/MacOS/KazeCloud"

cp "$SCRIPT_DIR/LocalBuildInfo.plist" "$CONTENTS_DIR/Info.plist"
cp "$SOURCE_DIR/kaze-icon.png" "$CONTENTS_DIR/Resources/kaze-icon.png"
cp "$SOURCE_DIR/Assets.xcassets/openai-icon.imageset/openai-icon.svg" "$CONTENTS_DIR/Resources/openai-icon.svg"
cp "$SOURCE_DIR/Assets.xcassets/nvidia-icon.imageset/nvidia-icon.svg" "$CONTENTS_DIR/Resources/nvidia-icon.svg"

ICONSET_DIR="$STAGING_DIR/KazeCloud.iconset"
mkdir -p "$ICONSET_DIR"
for size in 16 32 128 256; do
    sips -z "$size" "$size" "$SOURCE_DIR/kaze-icon.png" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
    doubled=$((size * 2))
    sips -z "$doubled" "$doubled" "$SOURCE_DIR/kaze-icon.png" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done
sips -z 512 512 "$SOURCE_DIR/kaze-icon.png" --out "$ICONSET_DIR/icon_512x512.png" >/dev/null
sips -z 1024 1024 "$SOURCE_DIR/kaze-icon.png" --out "$ICONSET_DIR/icon_512x512@2x.png" >/dev/null
iconutil -c icns "$ICONSET_DIR" -o "$CONTENTS_DIR/Resources/KazeCloud.icns"

codesign \
    --force \
    --deep \
    --sign - \
    --requirements '=designated => identifier "com.kavin.KazeCloud"' \
    --entitlements "$SOURCE_DIR/Kaze.entitlements" \
    "$STAGING_DIR/Kaze Cloud.app"

rm -rf "$APP_BUNDLE"
mv "$STAGING_DIR/Kaze Cloud.app" "$APP_BUNDLE"
rm -rf "$STAGING_DIR"

codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
echo "$APP_BUNDLE"
