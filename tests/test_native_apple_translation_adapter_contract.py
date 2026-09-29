"""Static contracts for the production Apple Translation service.

The Debug-only adapter lab was removed in 2026-09; only the always-compiled
production host remains, in NativeAppleTranslationService.swift.
"""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
HOST = (ROOT / "macos/NativeAppleTranslationService.swift").read_text()
APP = (ROOT / "macos/JuyiMenuBar.swift").read_text()
PROJECT = (ROOT / "Juyi.xcodeproj/project.pbxproj").read_text()
LEGACY = (ROOT / "scripts/build_macos_app.sh").read_text()
CI = (ROOT / ".github/workflows/ci.yml").read_text()


def test_production_host_is_unconditionally_compiled() -> None:
    assert "#if" not in HOST
    assert "final class NativeAppleProductionTranslationService" in HOST
    assert "struct NativeAppleProductionTranslationHost" in HOST
    assert "enum NativeAppleProductionReadiness" in HOST
    assert "NativeAppleProductionTranslationHost(" in APP
    assert "service: NativeAppleProductionTranslationService.shared" in APP
    for removed in (
        "NativeAppleTranslationAdapterModel.swift",
        "NativeAppleTranslationAdapterHost.swift",
        "NativeAppleTranslationAdapterCoordinator",
        "开发：测试 Apple 离线翻译…",
        "juyi-native-apple-translation-adapter-v1",
    ):
        assert removed not in HOST + APP + PROJECT + LEGACY + CI


def test_host_uses_only_the_macos_15_translation_surface() -> None:
    assert "import Translation" in HOST
    assert "LanguageAvailability().status(" in HOST
    assert ".translationTask(configuration)" in HOST
    assert "TranslationSession.Configuration(" in HOST
    assert "configuration.invalidate()" in HOST
    assert "try await session.prepareTranslation()" in HOST
    assert "try await session.translate(sourceText)" in HOST
    for forbidden in (
        "canRequestDownloads",
        ".isReady",
        "session.cancel()",
        "installedSource",
        "preferredStrategy",
        "attributedSourceText",
        "attributedTargetText",
    ):
        assert forbidden not in HOST


def test_session_is_local_to_translation_task_and_requests_are_generation_claimed() -> None:
    assert "var session" not in HOST
    assert "let session" not in HOST
    assert "Task.detached" not in HOST
    assert "@unchecked Sendable" not in HOST
    assert "private var generation: UInt64" in HOST
    assert "guard request == candidate, !claimed else { return nil }" in HOST
    assert "guard let claim = service.claim(request) else { return }" in HOST
    assert "service.hostDisappeared(request)" in HOST
    assert 'payload: [REDACTED]' in HOST


def test_translation_result_is_validated_before_use() -> None:
    assert "response.sourceText == sourceText" in HOST
    assert 'response.sourceLanguage.languageCode?.identifier == "en"' in HOST
    assert 'response.targetLanguage.languageCode?.identifier == "zh"' in HOST
    assert 'Locale.Language(identifier: "zh-Hans")' in HOST


def test_host_has_no_live_input_network_storage_helper_or_logging_api() -> None:
    for forbidden in (
        "URLSession",
        "URLRequest",
        "NSPasteboard",
        "NativeOption",
        "NativeSelection",
        "AccessibilityController",
        "127.0.0.1",
        "localhost",
        "Keychain",
        "SecItem",
        "FileManager",
        "UserDefaults",
        "Process(",
        "apple-translation-helper",
        "print(",
        "NSLog",
        "os_log",
        "localizedDescription",
        ".volc",
    ):
        assert forbidden not in HOST


def test_lifecycle_invalidations_remain_wired() -> None:
    for reason in (".stop", ".terminate"):
        assert f"NativeProductionTranslationCoordinator.shared.invalidate({reason})" in APP


def test_xcode_legacy_and_ci_are_connected_without_user_script() -> None:
    assert "NativeAppleTranslationService.swift" in PROJECT
    assert "NativeAppleTranslationService.swift" in LEGACY
    assert "-framework Translation" in LEGACY
    assert "scripts/start_service.command" not in PROJECT + LEGACY + CI + HOST
    assert "grep -aFq" in CI
    assert "otool -L" in CI
    assert "/Translation.framework/" in CI
    assert "/_Translation_SwiftUI.framework/" in CI
