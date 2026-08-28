"""Static P0 contracts for the default-off 4D-B selection Capture Lab."""

from __future__ import annotations

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
MODEL = (ROOT / "macos/NativeSelectionCaptureLabModel.swift").read_text(
    encoding="utf-8"
)
HOST = (ROOT / "macos/NativeSelectionCaptureLabHost.swift").read_text(
    encoding="utf-8"
)
READER = (ROOT / "macos/NativeSelectionReader.swift").read_text(encoding="utf-8")
APP = (ROOT / "macos/JuyiMenuBar.swift").read_text(encoding="utf-8")
PROJECT = (ROOT / "Juyi.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
LEGACY = (ROOT / "scripts/build_macos_app.sh").read_text(encoding="utf-8")
CI = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
DOC = (ROOT / "docs/NATIVE_SELECTION_CAPTURE_LAB.md").read_text(encoding="utf-8")
SWIFT_TESTS = (ROOT / "tests/NativeSelectionCaptureLabModelTests.swift").read_text(
    encoding="utf-8"
)
CONFIG = "\n".join(
    (ROOT / f"Config/{name}.xcconfig").read_text(encoding="utf-8")
    for name in ("Debug", "Release", "Shared")
)

FLAG = "JUYI_NATIVE_SELECTION_CAPTURE_LAB"
GATE = f"#if DEBUG && {FLAG}"
CONFLICT_FLAGS = (
    "JUYI_NATIVE_OPTION_MONITOR",
    "JUYI_NATIVE_TRANSLATION_DOMAIN",
    "JUYI_NATIVE_TRANSLATION_OVERLAY",
    "JUYI_NATIVE_TRANSLATION_RESULT_LAB",
    "JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER",
    "JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER",
    "JUYI_NATIVE_APPLE_RESULT_LAB_BINDING",
)
CONFLICT_GATE = (
    f"#if DEBUG && {FLAG} && (" + " || ".join(CONFLICT_FLAGS) + ")"
)
SENTINEL = "juyi-native-selection-capture-lab-v1"
MENU = "开发：原生取词实验室…"


def _conditions_for_occurrences(source: str, token: str) -> list[tuple[str, ...]]:
    stack: list[str] = []
    occurrences: list[tuple[str, ...]] = []
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
            occurrences.append(tuple(stack))
    return occurrences


def _assert_exact_isolated_source(source: str) -> None:
    lines = source.strip().splitlines()
    assert lines[0] == CONFLICT_GATE
    assert lines[1].startswith('#error("JUYI_NATIVE_SELECTION_CAPTURE_LAB')
    assert lines[2] == "#endif"
    assert lines[4] == GATE
    assert lines[-1] == "#endif"
    assert source.count(CONFLICT_GATE) == 1
    assert lines.count(GATE) == 1
    assert source.count("#if ") == 2
    assert source.count("#endif") == 2
    assert "#if DEBUG ||" not in source


def test_exact_two_flag_gate_and_all_seven_conflicts_are_compile_time_only() -> None:
    for source in (MODEL, HOST):
        _assert_exact_isolated_source(source)
        for conflict in CONFLICT_FLAGS:
            assert conflict in source.splitlines()[0]
    for token in (
        "NativeSelectionCaptureLabLive",
        "NativeSelectionCaptureLabHost",
        MENU,
        "openNativeSelectionCaptureLab",
    ):
        occurrences = _conditions_for_occurrences(APP, token)
        assert occurrences, token
        assert all(GATE in conditions for conditions in occurrences), token
    assert FLAG not in CONFIG


def test_open_and_permission_are_zero_effect_until_an_explicit_action() -> None:
    open_body = MODEL.split("func open()", 1)[1].split("func perform(", 1)[0]
    assert "dependencies.authorizationStatus()" in open_body
    for forbidden in (
        "requestAuthorization",
        "targetProvider",
        "capture(",
        "schedule(",
    ):
        assert forbidden not in open_body
    assert "case requestAuthorization" in MODEL
    assert "case recheckAuthorization" in MODEL
    assert "AccessibilityController.requestAuthorization()" in HOST
    assert 'Button("请求辅助功能权限…")' in HOST
    assert 'Button("重新检查权限")' in HOST
    assert "只有点击“请求辅助功能权限…”才会触发 macOS 权限请求" in HOST
    assert "该权限不替代、移交或接管 Hammerspoon 的生产 owner" in HOST
    active_handler = HOST.split(
        "for: NSApplication.didBecomeActiveNotification", 1
    )[1].split(".onReceive(", 1)[0]
    assert "if coordinator.phase != .paused," in active_handler
    assert active_handler.index("coordinator.phase != .paused") < active_handler.index(
        "dependencies.authorizationStatus()"
    )


def test_app_wires_every_capture_lab_owner_lifecycle_under_the_exact_gate() -> None:
    assert "NativeSelectionCaptureLabHost()" in APP
    pause_bridges = {
        "NativeSelectionCaptureLabLive.shared.setPaused(paused)": 1,
        "NativeSelectionCaptureLabLive.shared.setPaused(model.paused)": 2,
    }
    for bridge, minimum_count in pause_bridges.items():
        assert APP.count(bridge) >= minimum_count, bridge
        occurrences = _conditions_for_occurrences(APP, bridge)
        assert all(GATE in conditions for conditions in occurrences), bridge
    for lifecycle in (
        "NativeSelectionCaptureLabLive.shared.invalidate(.stop)",
        "NativeSelectionCaptureLabLive.shared.invalidate(.terminate)",
        "NativeSelectionCaptureLabLive.shared.close()",
    ):
        occurrences = _conditions_for_occurrences(APP, lifecycle)
        assert occurrences, lifecycle
        assert all(GATE in conditions for conditions in occurrences), lifecycle
    open_body = APP.split("@objc private func openNativeSelectionCaptureLab()", 1)[1]
    open_body = open_body.split("#endif", 1)[0]
    assert open_body.index("showWindow()") < open_body.index(
        "NativeSelectionCaptureLabLive.shared.setPaused(model.paused)"
    )
    assert open_body.index("NativeSelectionCaptureLabLive.shared.setPaused(model.paused)") < open_body.index(
        "NativeSelectionCaptureLabLive.shared.open()"
    )


def test_manual_countdown_snapshots_and_passes_one_full_process_identity() -> None:
    assert "static let countdownDuration = 5" in MODEL
    assert MODEL.count("dependencies.targetProvider()") == 1
    assert MODEL.count("dependencies.capture(target)") == 1
    assert "case target(NativeSelectionTarget)" in MODEL
    assert "let target: NativeSelectionTarget" in MODEL
    assert "struct NativeSelectionCaptureLabTarget:" not in MODEL
    assert HOST.count("NSWorkspace.shared.frontmostApplication") == 1
    assert "NativeSelectionTarget(application: application)" in HOST
    assert "let bundleIdentifier = target.bundleIdentifier" in HOST
    assert "return .target(target)" in HOST
    assert "captureCoordinator.capture(target: target)" in HOST
    assert "NSApp.activate" not in HOST
    assert "activateApplication" not in HOST
    assert "makeKeyAndOrderFront" not in HOST
    for identity_contract in (
        "struct NativeSelectionProcessIdentity: Equatable, Sendable",
        "let launchDate: Date",
        "processIdentity == other.processIdentity",
        "targetProcessIdentity: target.processIdentity",
    ):
        assert identity_contract in READER


def test_capture_lab_has_no_hotkey_translation_clipboard_network_or_storage() -> None:
    joined = MODEL + "\n" + HOST
    for forbidden in (
        "NativeOptionMonitor",
        "NativeOptionDevelopmentHarness",
        "NativeTranslationDomainCoordinator",
        "NativeTranslationOverlayController",
        "TranslationSession",
        "LanguageAvailability",
        "NativeAppleTranslationAdapterCoordinator",
        "NativeVolcTranslationAdapterCoordinator",
        "URLSession",
        "URLRequest",
        "NSPasteboard",
        "SecItem",
        "UserDefaults",
        "FileManager",
        "Process(",
        "print(",
        "NSLog",
        "os_log",
    ):
        assert forbidden not in joined, forbidden
    assert 'Button("复制' not in HOST
    for disclosure in (
        "不会监听双 Option",
        "Apple Translation、Volc、localhost、本机翻译 Domain、overlay 或 Keychain",
        "不会读取或写入剪贴板、记录或持久化文字",
        "Hammerspoon 仍是生产双 Option 的唯一 owner",
        "当前只验证已审核的搜索文本框",
    ):
        assert disclosure in HOST


def test_text_ttl_tombstone_lifecycle_late_drop_and_voiceover_are_bounded() -> None:
    assert "static let resultTimeToLive: TimeInterval = 30" in MODEL
    assert "static let maximumTextScalars = 5_000" in MODEL
    assert "rawText.unicodeScalars.count" in MODEL
    assert "phase = finalPhase" in MODEL
    assert MODEL.index("phase = finalPhase") < MODEL.index(
        "dependencies.cancelCapture()"
    )
    for reason in (
        "case pause",
        "case stop",
        "case sleep",
        "case sessionResigned",
        "case accessibilityRevoked",
        "case terminate",
    ):
        assert reason in MODEL
    assert "generation == expected" in MODEL
    assert "pendingFeedbackGeneration == generation" in MODEL
    assert "func expireIfNeeded()" in MODEL
    assert "dependencies.now() >= expiresAt" in MODEL
    feedback_contract = (
        'static let accessibilityFeedback = "'
        '取词演练状态已更新，请返回句译查看。"'
    )
    assert feedback_contract in MODEL
    assert "dependencies.applicationIsActive()" in MODEL
    assert "NSApplication.didBecomeActiveNotification" in HOST
    assert ".textSelection(.disabled)" in HOST
    for disclosure in (
        "结果可被 macOS 辅助功能读取",
        "30 秒后自动清除",
        "立即使旧代次失效并清除窗口可达的文字",
        "正在收尾的系统读取可能在运行时内存中短暂存在",
        "迟到结果不会显示或保存",
        "Swift 与 macOS 不保证对已释放内存进行物理覆写",
        "5,000 个 Unicode scalar 上限",
    ):
        assert disclosure in HOST
    for test_contract in (
        "testManualFiveSecondCountdownReadsTargetOnce",
        "testResultTTLAndDeferredAccessibilityFeedback",
        "deadline recheck expires text even before a delayed timer callback",
        "testCancellationTombstonesBeforeExternalCleanup",
        "testEveryLifecycleInvalidationClearsAndDropsLateText",
        "testCloseAndPauseClearResult",
        "testPauseRemainsAHardGateAcrossLifecycleInvalidation",
        "paused open performs zero TCC reads",
    ):
        assert test_contract in SWIFT_TESTS


def test_xcode_legacy_and_ci_wire_the_exact_matrix_and_raw_artifact_scan() -> None:
    for source in (
        "NativeSelectionCaptureLabModel.swift",
        "NativeSelectionCaptureLabHost.swift",
    ):
        assert PROJECT.count(source) == 6
        assert f'"$ROOT/macos/{source}"' in LEGACY
        assert source in CI
    assert f"SWIFT_FLAGS+=(-D {FLAG})" in LEGACY
    legacy_capture_forwarding = LEGACY.split(
        'if [[ "$ACTIVE_CONDITIONS" == *" JUYI_NATIVE_SELECTION_CAPTURE_LAB "* ]]',
        1,
    )[1].split("\n    else", 1)[0]
    assert 'SWIFT_FLAGS+=(-D "$conflict")' in legacy_capture_forwarding
    assert "SWIFT_FLAGS+=(-warnings-as-errors)" in legacy_capture_forwarding
    assert "Build exact Debug native selection Capture Lab" in CI
    assert "Reject Debug native selection Capture Lab conflicts one by one" in CI
    assert "Verify native selection Capture Lab compile-time gate" in CI
    assert "Build exact legacy Debug native selection Capture Lab" in CI
    assert "Reject legacy Debug native selection Capture Lab conflicts one by one" in CI
    assert "Run native selection Capture Lab pure model tests" in CI
    xcode_positive = CI.split(
        "- name: Build exact Debug native selection Capture Lab", 1
    )[1].split(
        "- name: Reject Debug native selection Capture Lab conflicts one by one", 1
    )[0]
    xcode_rejections = CI.split(
        "- name: Reject Debug native selection Capture Lab conflicts one by one", 1
    )[1].split("- name: Build explicit Debug native overlay preview", 1)[0]
    legacy_positive = CI.split(
        "- name: Build exact legacy Debug native selection Capture Lab", 1
    )[1].split(
        "- name: Reject legacy Debug native selection Capture Lab conflicts one by one",
        1,
    )[0]
    legacy_rejections = CI.split(
        "- name: Reject legacy Debug native selection Capture Lab conflicts one by one",
        1,
    )[1].split("- name: Build explicit legacy Debug Apple Translation adapter", 1)[0]
    exact_conditions = "DEBUG JUYI_NATIVE_SELECTION_CAPTURE_LAB"
    assert f"SWIFT_ACTIVE_COMPILATION_CONDITIONS='{exact_conditions}'" in xcode_positive
    assert f"SWIFT_ACTIVE_COMPILATION_CONDITIONS='{exact_conditions}'" in legacy_positive
    assert "SWIFT_TREAT_WARNINGS_AS_ERRORS=YES" in xcode_positive
    assert "ARCHS='arm64 x86_64'" in xcode_positive
    for conflict in CONFLICT_FLAGS:
        assert conflict in legacy_capture_forwarding
        assert conflict in xcode_rejections
        assert conflict in legacy_rejections
    capture_gate = CI.split(
        "- name: Verify native selection Capture Lab compile-time gate", 1
    )[1].split("- name: Verify overlay compile-time gate", 1)[0]
    assert 'scripts/verify_macos_binary.sh "$opt_in_dir/Juyi" 15.0' in capture_gate
    for token in (
        SENTINEL,
        "NativeSelectionCaptureLabCoordinator",
        "一次性取词实验室",
        MENU,
        "LC_ALL=C grep -aFq",
        '"$opt_in_dir"/*',
        '"$directory"/*',
    ):
        assert token in capture_gate
    # A legal 4A domain may carry its pure Volc host. Those tokens are not a
    # valid absence canary for this independent capture-only slice.
    for invalid_canary in (
        "translate.volcengineapi.com",
        "VolcV4RequestBuilder",
        "VolcTranslationResponseParser",
    ):
        assert invalid_canary not in capture_gate
    release_all = CI.split(
        "Build Release with every native development flag injected", 1
    )[1].split("Verify native selection Capture Lab compile-time gate", 1)[0]
    legacy_release_all = CI.split(
        "Build legacy Release with every development flag injected", 1
    )[1].split("Build legacy universal Apple Translation helper", 1)[0]
    assert FLAG in release_all
    assert FLAG in legacy_release_all
    assert SENTINEL in legacy_release_all


def test_documentation_freezes_go_no_go_and_user_script_is_not_a_build_input() -> None:
    for required in (
        "4D-B，开发中未启用",
        "DEBUG && JUYI_NATIVE_SELECTION_CAPTURE_LAB",
        "5 秒",
        "不会自动激活",
        "`PID + NSRunningApplication.launchDate`",
        "30 秒",
        "Swift/macOS 不保证物理覆写",
        "Hammerspoon",
        "自动化 GO",
        "真机 P0",
        "P1",
        "生产 Activation NO-GO",
        "双 Option NO-GO",
    ):
        assert required in DOC, required
    user_script = "start_service" + ".command"
    for source in (PROJECT, LEGACY, CI, DOC, MODEL, HOST):
        assert user_script not in source
