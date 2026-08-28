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

# Native translation slices remain compile-time-only development code. The
# standard Xcode conditions variable is accepted only for Debug; Release ignores
# every injected development condition.
FRAMEWORK_FLAGS=(
    -framework ApplicationServices
    -framework AppKit
    -framework CoreGraphics
    -framework CryptoKit
    -framework QuartzCore
    -framework ServiceManagement
    -framework SwiftUI
)
if [[ "$CONFIGURATION" == "Debug" ]]; then
    ACTIVE_CONDITIONS=" ${SWIFT_ACTIVE_COMPILATION_CONDITIONS:-} "
    HAS_NATIVE_DOMAIN=false
    HAS_NATIVE_OVERLAY=false
    if [[ "$ACTIVE_CONDITIONS" == *" JUYI_NATIVE_OWNER_HANDOFF_LAB "* ]]; then
        SWIFT_FLAGS+=(-warnings-as-errors)
        SWIFT_FLAGS+=(-D JUYI_NATIVE_OWNER_HANDOFF_LAB)
        for conflict in \
            JUYI_NATIVE_SELECTION_CAPTURE_LAB \
            JUYI_NATIVE_OPTION_MONITOR \
            JUYI_NATIVE_TRANSLATION_DOMAIN \
            JUYI_NATIVE_TRANSLATION_OVERLAY \
            JUYI_NATIVE_TRANSLATION_RESULT_LAB \
            JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER \
            JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER \
            JUYI_NATIVE_APPLE_RESULT_LAB_BINDING; do
            if [[ "$ACTIVE_CONDITIONS" == *" $conflict "* ]]; then
                SWIFT_FLAGS+=(-D "$conflict")
            fi
        done
    fi
    # The capture lab is intentionally independent. Forward it and every
    # supplied conflicting condition even when that condition would normally
    # require another slice, so the source-level #error gate rejects the unsafe
    # combination instead of silently compiling the conflict away.
    if [[ "$ACTIVE_CONDITIONS" == *" JUYI_NATIVE_SELECTION_CAPTURE_LAB "* ]]; then
        SWIFT_FLAGS+=(-warnings-as-errors)
        SWIFT_FLAGS+=(-D JUYI_NATIVE_SELECTION_CAPTURE_LAB)
        for conflict in \
            JUYI_NATIVE_OPTION_MONITOR \
            JUYI_NATIVE_OWNER_HANDOFF_LAB \
            JUYI_NATIVE_TRANSLATION_DOMAIN \
            JUYI_NATIVE_TRANSLATION_OVERLAY \
            JUYI_NATIVE_TRANSLATION_RESULT_LAB \
            JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER \
            JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER \
            JUYI_NATIVE_APPLE_RESULT_LAB_BINDING; do
            if [[ "$ACTIVE_CONDITIONS" == *" $conflict "* ]]; then
                SWIFT_FLAGS+=(-D "$conflict")
            fi
        done
    else
        # Forward the binding flag independently so its compile-time
        # prerequisite checks still fail closed when a caller omits any
        # required slice.
        if [[ "$ACTIVE_CONDITIONS" == *" JUYI_NATIVE_APPLE_RESULT_LAB_BINDING "* ]]; then
            SWIFT_FLAGS+=(-D JUYI_NATIVE_APPLE_RESULT_LAB_BINDING)
        fi
        if [[ "$ACTIVE_CONDITIONS" == *" JUYI_NATIVE_TRANSLATION_OVERLAY "* ]]; then
            HAS_NATIVE_OVERLAY=true
            SWIFT_FLAGS+=(-D JUYI_NATIVE_TRANSLATION_OVERLAY)
        fi
        if [[ "$ACTIVE_CONDITIONS" == *" JUYI_NATIVE_TRANSLATION_DOMAIN "* ]]; then
            HAS_NATIVE_DOMAIN=true
            SWIFT_FLAGS+=(-D JUYI_NATIVE_TRANSLATION_DOMAIN)
            if [[ "$ACTIVE_CONDITIONS" == *" JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER "* ]]; then
                SWIFT_FLAGS+=(-D JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER)
                FRAMEWORK_FLAGS+=(-framework Translation)
            fi
            if [[ "$ACTIVE_CONDITIONS" == *" JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER "* ]]; then
                SWIFT_FLAGS+=(-D JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER)
                FRAMEWORK_FLAGS+=(-framework LocalAuthentication -framework Security)
            fi
        fi
        if [[ "$HAS_NATIVE_DOMAIN" == true && "$HAS_NATIVE_OVERLAY" == true \
            && "$ACTIVE_CONDITIONS" == *" JUYI_NATIVE_TRANSLATION_RESULT_LAB "* ]]; then
            SWIFT_FLAGS+=(-D JUYI_NATIVE_TRANSLATION_RESULT_LAB)
        fi
    fi
fi

rm -rf "$BUILD"
mkdir -p "$BUILD/Contents/MacOS" "$BUILD/Contents/Resources" "$MODULE_CACHE"

for arch in arm64 x86_64; do
    swiftc -parse-as-library "${SWIFT_FLAGS[@]}" \
        -module-cache-path "$MODULE_CACHE" \
        -sdk "$SDK" \
        -target "$arch-apple-macos$MINIMUM_MACOS" \
        "${FRAMEWORK_FLAGS[@]}" \
        -o "$ROOT/build/Juyi-$arch" \
        "$ROOT/macos/AccessibilityController.swift" \
        "$ROOT/macos/DoubleOptionStateMachine.swift" \
        "$ROOT/macos/NativeOptionEventAdapter.swift" \
        "$ROOT/macos/NativeSelectionReader.swift" \
        "$ROOT/macos/NativeSelectionCaptureCoordinator.swift" \
        "$ROOT/macos/NativeSelectionCaptureLabModel.swift" \
        "$ROOT/macos/NativeSelectionCaptureLabHost.swift" \
        "$ROOT/macos/NativeOwnerHandoffProtocol.swift" \
        "$ROOT/macos/NativeOwnerHandoffStore.swift" \
        "$ROOT/macos/NativeOwnerHandoffWorkflow.swift" \
        "$ROOT/macos/NativeOwnerHandoffStatusReader.swift" \
        "$ROOT/macos/NativeOwnerHandoffLabModel.swift" \
        "$ROOT/macos/NativeOwnerHandoffLabHost.swift" \
        "$ROOT/macos/NativeOptionMonitor.swift" \
        "$ROOT/macos/NativeOptionFeature.swift" \
        "$ROOT/macos/NativeTranslationDomain.swift" \
        "$ROOT/macos/VolcV4RequestBuilder.swift" \
        "$ROOT/macos/VolcTranslationResponseParser.swift" \
        "$ROOT/macos/NativeAppleTranslationAdapterModel.swift" \
        "$ROOT/macos/NativeAppleTranslationAdapterHost.swift" \
        "$ROOT/macos/NativeVolcDebugCredentialStore.swift" \
        "$ROOT/macos/NativeVolcDebugInterlock.swift" \
        "$ROOT/macos/NativeVolcDebugTransport.swift" \
        "$ROOT/macos/NativeVolcDebugWorkflow.swift" \
        "$ROOT/macos/NativeVolcTranslationAdapterModel.swift" \
        "$ROOT/macos/NativeVolcTranslationAdapterHost.swift" \
        "$ROOT/macos/NativeTranslationOverlayModel.swift" \
        "$ROOT/macos/NativeTranslationOverlayAnchorPolicy.swift" \
        "$ROOT/macos/NativeTranslationOverlayInteractionPolicy.swift" \
        "$ROOT/macos/NativeTranslationOverlayController.swift" \
        "$ROOT/macos/NativeTranslationOverlayExternalPresentation.swift" \
        "$ROOT/macos/NativeTranslationResultLabPresentation.swift" \
        "$ROOT/macos/NativeTranslationResultLabModel.swift" \
        "$ROOT/macos/NativeTranslationResultLabHost.swift" \
        "$ROOT/macos/NativeTranslationAppleResultLabBindingPresentation.swift" \
        "$ROOT/macos/NativeTranslationAppleResultLabBindingModel.swift" \
        "$ROOT/macos/NativeTranslationAppleResultLabBindingHost.swift" \
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
