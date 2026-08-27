"""Release-baseline contracts for the native Xcode project."""

import os
import plistlib
import re
from pathlib import Path


ROOT = Path(__file__).parents[1]
PROJECT = (ROOT / "Juyi.xcodeproj" / "project.pbxproj").read_text(encoding="utf-8")
SCHEME = (
    ROOT / "Juyi.xcodeproj" / "xcshareddata" / "xcschemes" / "Juyi.xcscheme"
).read_text(encoding="utf-8")
CI = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
SHARED = (ROOT / "Config" / "Shared.xcconfig").read_text(encoding="utf-8")
VERSION = (ROOT / "Config" / "Version.xcconfig").read_text(encoding="utf-8")
HELPER_BUILD = (ROOT / "scripts" / "build_apple_helper.sh").read_text(
    encoding="utf-8"
)
APP_BUILD = (ROOT / "scripts" / "build_macos_app.sh").read_text(encoding="utf-8")
VERIFY = (ROOT / "scripts" / "verify_macos_binary.sh").read_text(encoding="utf-8")
SIGNATURE_VERIFY = (ROOT / "scripts" / "verify_macos_signature.sh").read_text(
    encoding="utf-8"
)


def setting(text: str, key: str) -> str:
    match = re.search(rf"^\s*{re.escape(key)}\s*=\s*(.*?)\s*$", text, re.MULTILINE)
    assert match, f"missing {key}"
    return match.group(1)


def test_project_is_explicit_shared_and_does_not_absorb_local_scripts():
    assert "PBXFileSystemSynchronized" not in PROJECT
    assert "isa = PBXGroup;" in PROJECT
    assert "JuyiMenuBar.swift in Sources" in PROJECT
    assert "TranslationHelper.swift in Sources" in PROJECT
    assert "Assets.xcassets in Resources" in PROJECT
    assert "start_service.command" not in PROJECT
    assert "start_service.command" not in SCHEME
    assert "start_service.command" not in CI
    assert "<Scheme" in SCHEME
    assert 'BuildableName = "Juyi.app"' in SCHEME


def test_public_baseline_is_macos_15_universal_and_hardened():
    assert setting(SHARED, "MACOSX_DEPLOYMENT_TARGET") == "15.0"
    assert setting(SHARED, "ARCHS") == "arm64 x86_64"
    assert setting(SHARED, "ONLY_ACTIVE_ARCH") == "NO"
    assert setting(SHARED, "ENABLE_HARDENED_RUNTIME") == "YES"
    assert setting(SHARED, "ENABLE_APP_SANDBOX") == "NO"
    assert setting(SHARED, "ENABLE_USER_SCRIPT_SANDBOXING") == "YES"
    assert PROJECT.count("baseConfigurationReference") == 4
    assert PROJECT.count("SKIP_INSTALL = NO") == 2
    assert PROJECT.count("SKIP_INSTALL = YES") == 2


def test_version_and_minimum_system_are_expanded_from_config():
    assert re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", setting(VERSION, "MARKETING_VERSION"))
    assert re.fullmatch(r"[1-9][0-9]*", setting(VERSION, "CURRENT_PROJECT_VERSION"))
    with (ROOT / "macos" / "Info.plist").open("rb") as handle:
        info = plistlib.load(handle)
    assert info["CFBundleShortVersionString"] == "$(MARKETING_VERSION)"
    assert info["CFBundleVersion"] == "$(CURRENT_PROJECT_VERSION)"
    assert info["LSMinimumSystemVersion"] == "$(MACOSX_DEPLOYMENT_TARGET)"
    assert "MARKETING_VERSION =" not in SHARED
    assert "CURRENT_PROJECT_VERSION =" not in SHARED


def test_empty_entitlements_are_the_non_sandboxed_release_baseline():
    with (ROOT / "macos" / "Juyi.entitlements").open("rb") as handle:
        entitlements = plistlib.load(handle)
    assert entitlements == {}
    assert "com.apple.security.app-sandbox" not in PROJECT
    assert "com.apple.security.get-task-allow" not in PROJECT


def test_apple_helper_legacy_build_matches_xcode_release_contract():
    helper_source = (ROOT / "apple" / "TranslationHelper.swift").read_text(
        encoding="utf-8"
    )
    assert "@main" in helper_source
    assert "for arch in arm64 x86_64" in HELPER_BUILD
    assert '-target "$arch-apple-macos$MINIMUM_MACOS"' in HELPER_BUILD
    assert "-parse-as-library" in HELPER_BUILD
    assert '"$ROOT/scripts/verify_macos_binary.sh"' in HELPER_BUILD
    assert '"$ROOT/scripts/verify_macos_binary.sh"' in APP_BUILD
    assert '"$ROOT/scripts/verify_macos_signature.sh"' in HELPER_BUILD
    assert '"$ROOT/scripts/verify_macos_signature.sh"' in APP_BUILD
    assert 'lipo "$BINARY_PATH" -verify_arch arm64 x86_64' in VERIFY
    assert 'xcrun vtool -arch "$arch" -show-build' in VERIFY
    assert 'codesign --verify "${VERIFY_ARGS[@]}"' in SIGNATURE_VERIFY
    assert 'flags=.*runtime' in SIGNATURE_VERIFY
    for relative in (
        "scripts/build_apple_helper.sh",
        "scripts/read_xcconfig_value.sh",
        "scripts/verify_macos_binary.sh",
        "scripts/verify_macos_signature.sh",
    ):
        assert os.access(ROOT / relative, os.X_OK)


def test_asset_catalog_has_every_required_macos_icon_slot():
    iconset = ROOT / "macos" / "Assets.xcassets" / "AppIcon.appiconset"
    manifest = (iconset / "Contents.json").read_text(encoding="utf-8")
    for size in (16, 32, 128, 256, 512):
        for suffix in ("", "@2x"):
            filename = f"icon_{size}x{size}{suffix}.png"
            assert filename in manifest
            assert (iconset / filename).is_file()
