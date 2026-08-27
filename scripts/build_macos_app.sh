#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="$ROOT/build/Juyi.app"
MODULE_CACHE="$ROOT/build/ModuleCache"
ASSET_INFO="$ROOT/build/assetcatalog-info.plist"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
CONFIGURATION="${CONFIGURATION:-Release}"
SETTING_READER="$ROOT/scripts/read_xcconfig_value.sh"
VERSION_CONFIG="$ROOT/Config/Version.xcconfig"
SHARED_CONFIG="$ROOT/Config/Shared.xcconfig"
MARKETING_VERSION="$("$SETTING_READER" "$VERSION_CONFIG" MARKETING_VERSION)"
CURRENT_PROJECT_VERSION="$("$SETTING_READER" "$VERSION_CONFIG" CURRENT_PROJECT_VERSION)"
MINIMUM_MACOS="$("$SETTING_READER" "$SHARED_CONFIG" MACOSX_DEPLOYMENT_TARGET)"

[[ "$MARKETING_VERSION" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] || { echo "invalid MARKETING_VERSION" >&2; exit 1; }
[[ "$CURRENT_PROJECT_VERSION" =~ ^[0-9]+$ ]] || { echo "invalid CURRENT_PROJECT_VERSION" >&2; exit 1; }
[[ "$MINIMUM_MACOS" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] || { echo "invalid MACOSX_DEPLOYMENT_TARGET" >&2; exit 1; }

case "$CONFIGURATION" in
    Debug) SWIFT_FLAGS=(-Onone -g -D DEBUG) ;;
    Release) SWIFT_FLAGS=(-O) ;;
    *) echo "unsupported CONFIGURATION: $CONFIGURATION (expected Debug or Release)" >&2; exit 2 ;;
esac

rm -rf "$BUILD"
mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources" "$MODULE_CACHE"

for arch in arm64 x86_64; do
    swiftc -parse-as-library "${SWIFT_FLAGS[@]}" \
        -module-cache-path "$MODULE_CACHE" \
        -sdk "$SDK" \
        -target "$arch-apple-macos$MINIMUM_MACOS" \
        -framework ApplicationServices \
        -framework AppKit \
        -framework CoreGraphics \
        -framework CryptoKit \
        -framework ServiceManagement \
        -framework SwiftUI \
        -o "$ROOT/build/Juyi-$arch" \
        "$ROOT/macos/AccessibilityController.swift" \
        "$ROOT/macos/DoubleOptionStateMachine.swift" \
        "$ROOT/macos/NativeOptionEventAdapter.swift" \
        "$ROOT/macos/NativeSelectionReader.swift" \
        "$ROOT/macos/NativeSelectionCaptureCoordinator.swift" \
        "$ROOT/macos/NativeOptionMonitor.swift" \
        "$ROOT/macos/NativeOptionFeature.swift" \
        "$ROOT/macos/OnboardingPolicy.swift" \
        "$ROOT/macos/WindowFramePolicy.swift" \
        "$ROOT/macos/JuyiMenuBar.swift"
done
lipo -create "$ROOT/build/Juyi-arm64" "$ROOT/build/Juyi-x86_64" -output "$BUILD/Contents/MacOS/Juyi"

xcrun actool "$ROOT/macos/Assets.xcassets" \
    --compile "$BUILD/Contents/Resources" \
    --platform macosx \
    --minimum-deployment-target "$MINIMUM_MACOS" \
    --app-icon AppIcon \
    --output-partial-info-plist "$ASSET_INFO" >/dev/null

cp "$ROOT/macos/Info.plist" "$BUILD/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $MARKETING_VERSION" "$BUILD/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $CURRENT_PROJECT_VERSION" "$BUILD/Contents/Info.plist"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MINIMUM_MACOS" "$BUILD/Contents/Info.plist"

SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
SIGN_ARGS=(--force --options runtime --entitlements "$ROOT/macos/Juyi.entitlements" --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then SIGN_ARGS+=(--timestamp); fi
codesign "${SIGN_ARGS[@]}" "$BUILD"

"$ROOT/scripts/verify_macos_binary.sh" "$BUILD/Contents/MacOS/Juyi" "$MINIMUM_MACOS"
plutil -lint "$BUILD/Contents/Info.plist"
"$ROOT/scripts/verify_macos_signature.sh" "$BUILD"
echo "Built $BUILD ($MARKETING_VERSION, build $CURRENT_PROJECT_VERSION, $CONFIGURATION, macOS $MINIMUM_MACOS+)"
