#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUTPUT="${1:-$ROOT/bin/apple-translation-helper}"
SETTING_READER="$ROOT/scripts/read_xcconfig_value.sh"
SHARED_CONFIG="$ROOT/Config/Shared.xcconfig"
MINIMUM_MACOS="$("$SETTING_READER" "$SHARED_CONFIG" MACOSX_DEPLOYMENT_TARGET)"
SDK="$(xcrun --sdk macosx --show-sdk-path)"
BUILD_ROOT="$ROOT/build/apple-helper"
MODULE_CACHE="$BUILD_ROOT/ModuleCache"

[[ "$MINIMUM_MACOS" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] || { echo "invalid MACOSX_DEPLOYMENT_TARGET" >&2; exit 1; }
[[ "$MINIMUM_MACOS" == "15.0" ]] || { echo "Apple Translation helper requires the release baseline macOS 15.0" >&2; exit 1; }

rm -rf "$BUILD_ROOT"
mkdir -p "$BUILD_ROOT" "$MODULE_CACHE" "$(dirname "$OUTPUT")"

for arch in arm64 x86_64; do
    swiftc -parse-as-library -O \
        -module-cache-path "$MODULE_CACHE" \
        -sdk "$SDK" \
        -target "$arch-apple-macos$MINIMUM_MACOS" \
        -framework AppKit \
        -framework SwiftUI \
        -framework Translation \
        -o "$BUILD_ROOT/apple-translation-helper-$arch" \
        "$ROOT/apple/TranslationHelper.swift"
done

lipo -create \
    "$BUILD_ROOT/apple-translation-helper-arm64" \
    "$BUILD_ROOT/apple-translation-helper-x86_64" \
    -output "$OUTPUT"

SIGN_IDENTITY="${CODE_SIGN_IDENTITY:--}"
SIGN_ARGS=(--force --options runtime --sign "$SIGN_IDENTITY")
if [[ "$SIGN_IDENTITY" != "-" ]]; then SIGN_ARGS+=(--timestamp); fi
codesign "${SIGN_ARGS[@]}" "$OUTPUT"

"$ROOT/scripts/verify_macos_binary.sh" "$OUTPUT" "$MINIMUM_MACOS"
"$ROOT/scripts/verify_macos_signature.sh" "$OUTPUT"
echo "Built $OUTPUT (Universal 2, macOS $MINIMUM_MACOS+)"
