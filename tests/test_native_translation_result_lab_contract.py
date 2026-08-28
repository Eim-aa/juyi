"""Static P0 contracts for the default-off 4D0 Result Lab slice."""

from __future__ import annotations

import json
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
APP = (ROOT / "macos/JuyiMenuBar.swift").read_text(encoding="utf-8")
CONTROLLER = (ROOT / "macos/NativeTranslationOverlayController.swift").read_text(
    encoding="utf-8"
)
OVERLAY_MODEL = (ROOT / "macos/NativeTranslationOverlayModel.swift").read_text(
    encoding="utf-8"
)
INTERACTION = (
    ROOT / "macos/NativeTranslationOverlayInteractionPolicy.swift"
).read_text(encoding="utf-8")
EXTERNAL = (
    ROOT / "macos/NativeTranslationOverlayExternalPresentation.swift"
).read_text(encoding="utf-8")
PRESENTATION = (
    ROOT / "macos/NativeTranslationResultLabPresentation.swift"
).read_text(encoding="utf-8")
MODEL = (ROOT / "macos/NativeTranslationResultLabModel.swift").read_text(
    encoding="utf-8"
)
HOST = (ROOT / "macos/NativeTranslationResultLabHost.swift").read_text(
    encoding="utf-8"
)
PROJECT = (ROOT / "Juyi.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
LEGACY = (ROOT / "scripts/build_macos_app.sh").read_text(encoding="utf-8")
CI = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
DOC = (ROOT / "docs/NATIVE_TRANSLATION_RESULT_LAB.md").read_text(encoding="utf-8")
PARITY = (ROOT / "tests/check_native_translation_parity.py").read_text(
    encoding="utf-8"
)
PARITY_RUNNER = (ROOT / "tests/NativeTranslationParityRunner.swift").read_text(
    encoding="utf-8"
)
CORPUS = json.loads(
    (ROOT / "tests/fixtures/native_translation_parity_v1.json").read_text(
        encoding="utf-8"
    )
)

GATE = (
    "#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && "
    "JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB"
)
MIXED_GATE = (
    "#if DEBUG && JUYI_NATIVE_TRANSLATION_RESULT_LAB && "
    "(JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER || "
    "JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER)"
)


def _conditions_for_occurrences(source: str, token: str) -> list[tuple[str, ...]]:
    stack: list[str] = []
    conditions: list[tuple[str, ...]] = []
    for line in source.splitlines():
        stripped = line.strip()
        if stripped.startswith("#if "):
            stack.append(stripped)
        elif stripped.startswith("#elseif "):
            if stack:
                stack[-1] = stripped
        elif stripped == "#endif":
            if stack:
                stack.pop()
        elif token in line:
            conditions.append(tuple(stack))
    return conditions


def _assert_whole_file_gate(source: str) -> None:
    lines = source.strip().splitlines()
    assert lines[0] == GATE
    assert lines[-1] == "#endif"
    assert source.count(GATE) == 1


def test_exact_four_gate_and_live_adapter_conflict_are_compile_time_only() -> None:
    for source in (EXTERNAL, MODEL, HOST):
        _assert_whole_file_gate(source)
    assert PRESENTATION.count(GATE) == 1
    assert PRESENTATION.startswith(MIXED_GATE)
    assert '#error("Result Lab cannot be compiled with a live native translation adapter")' in PRESENTATION
    for token in (
        "NativeTranslationResultLabLive",
        "NativeTranslationResultLabSheet",
        "开发：结果界面实验室…",
        "openNativeTranslationResultLab",
        "focusNativeTranslationResultLab",
    ):
        occurrences = _conditions_for_occurrences(APP, token)
        assert occurrences
        assert all(GATE in conditions for conditions in occurrences)
    configs = "".join(
        (ROOT / path).read_text(encoding="utf-8")
        for path in ("Config/Debug.xcconfig", "Config/Release.xcconfig", "Config/Shared.xcconfig")
    )
    assert "JUYI_NATIVE_TRANSLATION_RESULT_LAB" not in configs


def test_result_lab_sources_have_no_live_io_or_production_owner() -> None:
    joined = "\n".join((EXTERNAL, PRESENTATION, MODEL, HOST))
    for forbidden in (
        "URLSession",
        "URLRequest",
        "TranslationSession",
        "LanguageAvailability",
        "SecItem",
        "Security.framework",
        "LocalAuthentication",
        "NativeVolcDebug",
        "NativeSelectionReader",
        "NativeSelectionResult",
        "NativeOptionMonitor",
        "NativeOptionDevelopmentHarness",
        "AXUIElement",
        "NSPasteboard",
        "FileManager",
        "Process(",
        "UserDefaults",
        "127.0.0.1",
        "localhost",
    ):
        assert forbidden not in joined
    assert "fallbackReason" not in joined
    assert "usedAppleFallback" not in joined
    assert "warning:" not in joined
    assert "hammerspoon/argos-translator.lua" not in joined


def test_open_is_disclosure_only_and_fixtures_use_real_4a_pure_policy() -> None:
    assert MODEL.count('"The weather is pleasant today."') == 1
    assert MODEL.count('"Good tools should feel effortless."') == 1
    assert "NativeTranslationDomainCoordinator(" in MODEL
    assert "NativeTranslationInputPolicy" not in MODEL or "coordinator.begin(" in MODEL
    assert "NativeTranslationFakeExecutor" in MODEL
    assert "credentialLoader:" in MODEL
    assert "sourceText: NativeTranslationResultLabFixtures.source" in MODEL
    open_body = MODEL.split("func open()", 1)[1].split("func close()", 1)[0]
    assert "phase = .disclosure" in open_body
    assert "domainFactory.make" not in open_body
    assert "overlay.begin" not in open_body
    assert "executor" not in open_body
    assert "runAppleSimulation" in HOST and "runVolcSimulation" in HOST


def test_opaque_lease_double_generation_and_reentrancy_are_mandatory() -> None:
    assert "fileprivate init(nonce:" in EXTERNAL
    assert "private var active: Active?" in EXTERNAL
    assert "active = Active(lease: lease, onDismiss: onDismiss)" in EXTERNAL
    assert EXTERNAL.index("active = Active(lease: lease, onDismiss: onDismiss)") < EXTERNAL.index(
        "dismissed?.onDismiss(replacingReason)"
    )
    assert "acceptTerminal" in EXTERNAL
    assert "currentLease" in EXTERNAL
    begin = CONTROLLER.split("func beginExternal(", 1)[1].split("func resolve(", 1)[0]
    assert "revokeExternalPresentationForReplacement" not in begin
    assert begin.index("session.beginResultLabPresentation") < begin.index(
        "externalPresentationRegistry.begin"
    )
    assert "session.generation == generation" in begin
    fixture = CONTROLLER.split("func showFixturePreview()", 1)[1].split(
        "func beginExternal(", 1
    )[0]
    assert "externalPresentationRegistry.currentLease" in fixture
    assert "externalPresentationRegistry.invalidate(" in fixture
    assert "invalidateActive" not in fixture
    assert "domainGeneration: UInt64?" in MODEL
    assert "expectedDomainGeneration" in PRESENTATION
    assert "expectedLease" in PRESENTATION
    assert "didInvalidateDomain" in MODEL


def test_bridge_is_same_engine_body_first_and_fixed_result_only() -> None:
    assert "requestedEngine == success.engine" in PRESENTATION
    assert "fixture.expectedEngine == envelope.requestedEngine" in PRESENTATION
    assert "expectedResult(for:" in PRESENTATION
    assert "success.text == expectedResult" in PRESENTATION
    assert "inputWasTruncated == false" in PRESENTATION
    assert "resultContainsForbiddenScalar" in PRESENTATION
    assert "maximumResultScalarCount" in PRESENTATION
    assert "case .cancelled:" in PRESENTATION and "return .dismiss" in PRESENTATION
    assert "case .emptyInput, .sourceLanguageMismatch" in PRESENTATION
    assert "结果未通过 Debug 安全检查" in PRESENTATION
    assert "copyText: nil" in PRESENTATION
    assert "simulatedElapsedMilliseconds >= 0" in PRESENTATION


def test_owner_timing_lifecycle_focus_and_escape_are_single_owner() -> None:
    assert "NativeTranslationResultLabOwnerTiming.slowDelay" in MODEL
    assert "NativeTranslationResultLabOwnerTiming.deadline" in MODEL
    assert "static let slowDelay: TimeInterval = 2" in MODEL
    assert "static let deadline: TimeInterval = 12" in MODEL
    assert "terminalOrigin == .domain" in MODEL
    assert "case ownerTimeout" in MODEL
    assert "NativeTranslationResultLabDismissInvalidationPolicy" in MODEL
    assert "guard let run = active, run.didReachTerminal" in MODEL
    assert "overlay.focusCurrent(run.lease)" in MODEL
    assert "NativeTranslationResultLabMenuPolicy.focusIsEnabled" in APP
    assert "hasVisibleResult: NativeTranslationResultLabLive.shared.hasVisibleResult" in APP
    assert "focusCurrentOverlay(\n        lease:" in CONTROLLER
    assert "NativeTranslationResultLabOwnerSurfacePolicy" in INTERACTION
    assert "source == .local" in INTERACTION
    assert "if eventIsKeyDown { return !panelIsKey }" in INTERACTION
    assert "NativeTranslationResultLabSheetInteractionPolicy.escapeAction" in HOST
    assert ".keyboardShortcut(.cancelAction)" not in HOST


def test_sheet_disclosure_sticky_actions_and_voiceover_contract_are_visible() -> None:
    for text in (
        "Debug 固定样例 · 模拟执行",
        "未调用 Apple Translation",
        "未读密钥、未联网、不计费",
        "不会读取真实选区、剪贴板现有内容或文本输入",
        "检查按键的键码与修饰键",
        "不会读取字符正文或记录按键",
        "复制固定译文",
        "替换系统剪贴板",
        "剪贴板管理器可能读取并长期保留",
    ):
        assert text in HOST + PRESENTATION
    assert HOST.index("ScrollView {") < HOST.index("Divider()") < HOST.index("actionRow")
    assert "ViewThatFits(in: .horizontal)" in HOST
    assert HOST.index('Button("运行 Apple 模拟")') < HOST.index('Button("运行火山模拟")')
    assert HOST.index('Button("运行火山模拟")') < HOST.index('Button("聚焦当前结果")')
    assert HOST.index('Button("聚焦当前结果")') < HOST.index('Button("关闭")')
    assert "@AccessibilityFocusState" in HOST
    assert ".accessibilityFocused($accessibilityFocus, equals: .title)" in HOST
    assert ".onChange(of: coordinator.phase)" not in HOST
    assert "terminalAnnouncement" in PRESENTATION
    assert "Debug 固定样例" in CONTROLLER
    assert "已复制 Debug 固定样例" in CONTROLLER


def test_versioned_parity_is_pure_and_all_differences_are_classified() -> None:
    assert CORPUS["schema"] == "juyi.native_translation.input_parity"
    assert CORPUS["version"] == 1
    assert len(CORPUS["inputCases"]) >= 8
    assert {case["id"] for case in CORPUS["inputCases"]} >= {
        "line_endings_and_scalar_whitespace",
        "unicode_scalars_4999",
        "unicode_scalars_5000",
        "unicode_scalars_5001",
        "cjk_ratio_exactly_half",
        "cjk_ratio_above_half",
        "one_alphabetic_scalar",
    }
    assert len(CORPUS["intentionalDeltas"]) == 8
    assert "import translator" not in PARITY
    assert "spec_from_file_location" in PARITY
    assert "volc_proxy.translate_text = forbidden_volc_effect" in PARITY
    assert 'volc_calls["count"] == 0' in PARITY
    assert "build_signed_request" in PARITY
    assert "urlopen(" not in PARITY
    assert "NativeTranslationInputPolicy.prepare" in PARITY_RUNNER
    assert "VolcV4RequestBuilder.build" in PARITY_RUNNER
    assert "NativeTranslationResultLabOwnerTiming.deadline" in PARITY_RUNNER
    assert "unclassified parity record" in PARITY


def test_xcode_legacy_ci_and_artifact_gates_are_wired() -> None:
    for source in (
        "NativeTranslationOverlayExternalPresentation.swift",
        "NativeTranslationResultLabPresentation.swift",
        "NativeTranslationResultLabModel.swift",
        "NativeTranslationResultLabHost.swift",
    ):
        assert source in PROJECT
        assert source in LEGACY
        assert source in CI
    assert "HAS_NATIVE_DOMAIN" in LEGACY and "HAS_NATIVE_OVERLAY" in LEGACY
    assert 'SWIFT_FLAGS+=(-D JUYI_NATIVE_TRANSLATION_RESULT_LAB)' in LEGACY
    assert "JuyiTranslationResultLab" in CI
    assert "JuyiResultLabOnly" in CI
    assert "JuyiResultLabMissingFlag" in CI
    assert "JuyiResultLabMixedApple" in CI and "JuyiResultLabMixedVolc" in CI
    assert "native-translation-result-lab-lease-tests" in CI
    assert "native-translation-result-lab-bridge-tests" in CI
    assert "native-translation-result-lab-owner-tests" in CI
    assert "check_native_translation_parity.py" in CI
    assert "juyi-native-translation-result-lab-v1" in CI
    assert "'/Translation.framework/'" in CI
    assert "'/Security.framework/'" in CI
    release_all = CI.split(
        "Build Release with every native development flag injected", 1
    )[1].split("Verify overlay compile-time gate", 1)[0]
    assert "JUYI_NATIVE_TRANSLATION_RESULT_LAB" in release_all


def test_documentation_is_explicitly_default_off_and_user_script_is_excluded() -> None:
    for required in (
        "开发中未启用",
        "Hammerspoon",
        "不会加载或调用 Apple Translation",
        "不签名、不读 Keychain、不联网",
        "12 秒 deadline",
        "input-only corpus",
        "未分类差异直接失败",
        "arm64 与 Intel",
        "正式启用前",
    ):
        assert required in DOC
    for source in (PROJECT, LEGACY, CI):
        assert "scripts/start_service.command" not in source
        assert "start_service.command" not in source
