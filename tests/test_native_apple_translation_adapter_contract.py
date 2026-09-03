from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODEL = (ROOT / "macos/NativeAppleTranslationAdapterModel.swift").read_text()
HOST = (ROOT / "macos/NativeAppleTranslationAdapterHost.swift").read_text()
APP = (ROOT / "macos/JuyiMenuBar.swift").read_text()
DOMAIN = (ROOT / "macos/NativeTranslationDomain.swift").read_text()
PROJECT = (ROOT / "Juyi.xcodeproj/project.pbxproj").read_text()
LEGACY = (ROOT / "scripts/build_macos_app.sh").read_text()
CI = (ROOT / ".github/workflows/ci.yml").read_text()
DOC = (ROOT / "docs/NATIVE_APPLE_TRANSLATION_ADAPTER.md").read_text() if (
    ROOT / "docs/NATIVE_APPLE_TRANSLATION_ADAPTER.md"
).exists() else ""

GATE = "#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER"
BINDING_EXCLUSION = " && !JUYI_NATIVE_APPLE_RESULT_LAB_BINDING"
IMPLEMENTATION_GATE = GATE + BINDING_EXCLUSION
FIXTURE = "The weather is pleasant today."
MENU_TITLE = "开发：测试 Apple 离线翻译…"
SENTINEL = "juyi-native-apple-translation-adapter-v1"


def _assert_whole_file_gate(source: str) -> None:
    lines = source.strip().splitlines()
    assert lines[0] == IMPLEMENTATION_GATE
    assert lines[-1] == "#endif"
    assert source.count(IMPLEMENTATION_GATE) == 1


def _conditions_for_occurrences(source: str, token: str) -> list[tuple[str, ...]]:
    stack: list[str] = []
    conditions: list[tuple[str, ...]] = []
    for line in source.splitlines():
        stripped = line.strip()
        if stripped.startswith("#if "):
            stack.append(stripped)
        elif stripped.startswith("#elseif "):
            if stack:
                stack[-1] = "#if " + stripped.removeprefix("#elseif ")
        elif stripped == "#endif":
            if stack:
                stack.pop()
        elif token in line:
            conditions.append(tuple(stack))
    return conditions


def test_debug_adapter_stays_gated_while_production_host_is_always_available() -> None:
    _assert_whole_file_gate(MODEL)
    debug_host, production_host = HOST.split(
        "\n#endif\n\n// MARK: - Production Apple Translation host",
        1,
    )
    _assert_whole_file_gate(debug_host + "\n#endif")
    assert "final class NativeAppleProductionTranslationService" in production_host
    assert "struct NativeAppleProductionTranslationHost" in production_host
    for token in (
        "NativeAppleProductionTranslationService",
        "NativeAppleProductionTranslationHost",
    ):
        occurrences = _conditions_for_occurrences(HOST, token)
        assert occurrences
        assert all(not stack for stack in occurrences)
    for token in (
        "NativeAppleTranslationAdapterCoordinator",
        "NativeAppleTranslationAdapterSheet",
        MENU_TITLE,
        "testNativeAppleTranslationAdapter",
    ):
        occurrences = _conditions_for_occurrences(APP, token)
        assert occurrences
        assert all(IMPLEMENTATION_GATE in stack for stack in occurrences)
    assert "JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER" not in (
        (ROOT / "Config/Debug.xcconfig").read_text()
        + (ROOT / "Config/Release.xcconfig").read_text()
        + (ROOT / "Config/Shared.xcconfig").read_text()
    )


def test_only_one_fixed_fixture_and_one_main_menu_entry_exist() -> None:
    production = MODEL + HOST + APP
    assert production.count(FIXTURE) == 1
    assert APP.count(MENU_TITLE) == 1
    install_menu = APP.split("private func installMainMenu()", 1)[1].split(
        "private func item(", 1
    )[0]
    status_menu = APP.split("private func updateMenu()", 1)[1].split(
        "private func updateChrome()", 1
    )[0]
    assert MENU_TITLE in install_menu
    assert MENU_TITLE not in status_menu
    entry = APP.split("@objc private func testNativeAppleTranslationAdapter()", 1)[1].split(
        "#endif", 1
    )[0]
    assert entry.index("showWindow()") < entry.index(
        "NativeAppleTranslationAdapterCoordinator.shared.open()"
    )


def test_root_view_observes_the_presenter_and_sheet_is_not_startup_work() -> None:
    root = APP.split("private struct RootView", 1)[1].split(
        "private extension AppModel", 1
    )[0]
    assert "@ObservedObject private var nativeAppleTranslationAdapter" in root
    assert "NativeAppleTranslationAdapterCoordinator.shared" in root
    assert "get: { nativeAppleTranslationAdapter.isPresented }" in root
    launch = APP.split("func applicationDidFinishLaunching", 1)[1].split(
        "func applicationShouldHandleReopen", 1
    )[0]
    assert ".open()" not in launch
    assert "LanguageAvailability" not in launch


def test_host_uses_only_the_macos_15_translation_surface() -> None:
    assert "import Translation" in HOST
    assert "LanguageAvailability().status(from: source, to: target)" in HOST
    assert ".translationTask(configuration)" in HOST
    assert "TranslationSession.Configuration(" in HOST
    assert "current.invalidate()" in HOST
    assert "try await session.prepareTranslation()" in HOST
    assert "try await session.translate(sourceText)" in HOST
    for forbidden in (
        "canRequestDownloads",
        ".isReady",
        "session.cancel()",
        "installedSource",
        "preferredStrategy",
        "TranslationError.notInstalled",
        "TranslationError.alreadyCancelled",
        "attributedSourceText",
        "attributedTargetText",
    ):
        assert forbidden not in HOST + MODEL


def test_session_is_local_to_translation_task_and_configuration_is_host_state() -> None:
    assert "@State private var configuration: TranslationSession.Configuration?" in HOST
    assert "@State private var configuredRequest" in HOST
    assert "configuration = nil" in HOST
    assert "NativeAppleTranslationHostConfigurationPolicy.transition" in HOST
    assert "TranslationSession" not in MODEL
    assert "Task.detached" not in HOST + MODEL
    assert "@unchecked Sendable" not in HOST + MODEL
    assert "var session" not in HOST
    assert "let session" not in HOST
    assert "with session" not in HOST


def test_pure_coordinator_has_one_generation_manual_clock_and_claim_gate() -> None:
    assert "@MainActor\nfinal class NativeAppleTranslationAdapterCoordinator" in MODEL
    assert MODEL.count("private var generation: UInt64") == 1
    assert "ContinuousClock" in MODEL
    assert "ProcessInfo" not in MODEL
    assert "NativeAppleTranslationScheduling" in MODEL
    assert "guard isCurrent(request.generation), hostRequest == request, !hostClaimed" in MODEL
    assert "translationDeadline = scheduler.now + 12" in MODEL
    assert "after: 2" in MODEL
    assert "after: 30" in MODEL
    assert "after: timeout" in MODEL
    assert "NativeTranslationInputPolicy.prepare(fixtureSourceText)" in MODEL


def test_status_copy_privacy_and_no_fallback_are_stable() -> None:
    for text in (
        "正在检查 Apple 离线翻译",
        "只检查英语→简体中文语言资源，不会开始下载。",
        "Apple 离线翻译已准备好",
        "需要准备 Apple 离线语言包",
        "只有你点击后，macOS 才会请求下载英语→简体中文语言资源。",
        "这台 Mac 不支持 Apple 离线翻译",
        "当前测试不会改用火山云端。",
        "暂时无法检查 Apple 离线翻译",
        "正在准备 Apple 离线语言包…",
        "已停止等待",
        "macOS 可能仍会继续下载；可稍后检查状态。",
        "Apple 离线语言包没有准备完成",
        "正在翻译固定样例…",
        "Apple 离线翻译暂时没有响应",
        "Apple 离线翻译未能完成测试",
        "Apple 离线翻译测试成功",
    ):
        assert text in MODEL
    assert "Apple 可能收集 App 标识" in HOST
    assert "不读取选区、剪贴板、键盘输入或云端配置" in HOST
    assert ".volc" not in HOST + MODEL
    assert "fallback" not in (HOST + MODEL).lower()


def test_adapter_has_no_live_input_network_storage_helper_or_logging_api() -> None:
    source = HOST + MODEL
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
        "NativeTranslationOverlay",
        "print(",
        "NSLog",
        "os_log",
        "localizedDescription",
    ):
        assert forbidden not in source


def test_typed_domain_lifecycle_and_keyboard_order_are_wired() -> None:
    assert "case temporarilyUnavailable" in DOMAIN
    assert "case appleTemporarilyUnavailable" in DOMAIN
    for reason in (".pause", ".stop", ".engineChanged", ".terminate"):
        assert f"invalidate({reason})" in APP
    assert "NativeAppleTranslationAdapterInteractionPolicy.orderedActions" in HOST
    assert "accessibilitySortPriority(60)" in HOST
    assert "accessibilitySortPriority(20)" in HOST
    assert 'keyboardShortcut("w", modifiers: .command)' not in HOST  # policy-driven shortcut
    assert 'KeyboardShortcut("w", modifiers: .command)' in HOST
    assert ".onExitCommand" in HOST


def test_xcode_legacy_ci_and_docs_are_connected_without_user_script() -> None:
    for filename in (
        "NativeAppleTranslationAdapterModel.swift",
        "NativeAppleTranslationAdapterHost.swift",
    ):
        assert filename in PROJECT
        assert filename in LEGACY
    assert "scripts/start_service.command" not in PROJECT + LEGACY + CI + DOC + HOST + MODEL
    assert SENTINEL in MODEL
    assert "JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER" in CI
    assert SENTINEL in CI
    assert MENU_TITLE in CI
    assert FIXTURE in CI
    assert "grep -aFq" in CI
    assert "otool -L" in CI
    assert "/Translation.framework/" in CI
    assert "/_Translation_SwiftUI.framework/" in CI
    assert "仅供开发" in DOC
    assert "macOS 15" in DOC
    assert "真机" in DOC
