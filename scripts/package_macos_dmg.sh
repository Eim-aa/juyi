#!/usr/bin/env bash
# Package an already-built app; signing/notarization are separate release steps.
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
    echo "usage: $0 <app bundle> <new output.dmg>" >&2
    exit 2
fi
ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_PATH="$1"
OUTPUT_PATH="$2"
[[ -d "$APP_PATH/Contents" ]] || { echo "missing app bundle" >&2; exit 1; }
[[ "$OUTPUT_PATH" == *.dmg && ! -e "$OUTPUT_PATH" ]] || {
    echo "output must be a new .dmg path; existing files are never replaced" >&2
    exit 1
}
PLIST="$APP_PATH/Contents/Info.plist"
[[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$PLIST")" == io.github.Eim-aa.Juyi ]] || {
    echo "unexpected app identity" >&2; exit 1;
}
for pair in 'MARKETING_VERSION CFBundleShortVersionString' 'CURRENT_PROJECT_VERSION CFBundleVersion'; do
    read -r setting key <<< "$pair"
    expected="$(bash "$ROOT_DIR/scripts/read_xcconfig_value.sh" "$ROOT_DIR/Config/Version.xcconfig" "$setting")"
    actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$PLIST")"
    [[ "$actual" == "$expected" ]] || { echo "app version differs from source: $key" >&2; exit 1; }
done
bash "$ROOT_DIR/scripts/verify_macos_binary.sh" "$APP_PATH/Contents/MacOS/Juyi" 15.0
bash "$ROOT_DIR/scripts/verify_macos_signature.sh" "$APP_PATH"
STAGING_DIR="$(mktemp -d /private/tmp/juyi-dmg.XXXXXX)"
ditto "$APP_PATH" "$STAGING_DIR/句译.app"
ln -s /Applications "$STAGING_DIR/Applications"
cp "$ROOT_DIR/docs/INSTALL.html" "$STAGING_DIR/安装与第一次翻译.html"
hdiutil create -volname '句译安装' -srcfolder "$STAGING_DIR" -format UDZO "$OUTPUT_PATH"
hdiutil verify "$OUTPUT_PATH"
echo "Created $OUTPUT_PATH. Staging retained at $STAGING_DIR."
echo "Packaging is not notarization. Do not publish until release acceptance is complete."
