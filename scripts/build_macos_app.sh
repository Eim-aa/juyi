#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/Juyi.app"
ICONSET="$ROOT/build/AppIcon.iconset"
MODULE_CACHE="$ROOT/build/ModuleCache"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
rm -rf "$BUILD" "$ICONSET"
mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources" "$ICONSET" "$MODULE_CACHE"

swiftc -parse-as-library -O -module-cache-path "$MODULE_CACHE" -sdk "$SDK" -target arm64-apple-macos13.0 -framework AppKit -framework ServiceManagement -framework SwiftUI -o "$ROOT/build/Juyi-arm64" "$ROOT/macos/OnboardingPolicy.swift" "$ROOT/macos/WindowFramePolicy.swift" "$ROOT/macos/JuyiMenuBar.swift"
swiftc -parse-as-library -O -module-cache-path "$MODULE_CACHE" -sdk "$SDK" -target x86_64-apple-macos13.0 -framework AppKit -framework ServiceManagement -framework SwiftUI -o "$ROOT/build/Juyi-x86_64" "$ROOT/macos/OnboardingPolicy.swift" "$ROOT/macos/WindowFramePolicy.swift" "$ROOT/macos/JuyiMenuBar.swift"
lipo -create "$ROOT/build/Juyi-arm64" "$ROOT/build/Juyi-x86_64" -output "$BUILD/Contents/MacOS/Juyi"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ROOT/macos/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$ROOT/macos/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$BUILD/Contents/Resources/AppIcon.icns"

cp "$ROOT/macos/Info.plist" "$BUILD/Contents/Info.plist"
codesign --force --sign - "$BUILD"
plutil -lint "$BUILD/Contents/Info.plist"
echo "Built $BUILD"
