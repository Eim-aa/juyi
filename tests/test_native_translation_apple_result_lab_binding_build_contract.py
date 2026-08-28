"""Build wiring contracts for the Debug-only Apple Result Lab binding."""

from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
PROJECT = (ROOT / "Juyi.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
LEGACY = (ROOT / "scripts/build_macos_app.sh").read_text(encoding="utf-8")
CI = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")
DOC = (
    ROOT / "docs/NATIVE_TRANSLATION_APPLE_RESULT_LAB_BINDING.md"
).read_text(encoding="utf-8")

BINDING_FLAG = "JUYI_NATIVE_APPLE_RESULT_LAB_BINDING"
BINDING_SOURCES = (
    "NativeTranslationAppleResultLabBindingPresentation.swift",
    "NativeTranslationAppleResultLabBindingModel.swift",
    "NativeTranslationAppleResultLabBindingHost.swift",
)


def test_binding_sources_are_explicit_xcode_and_legacy_inputs() -> None:
    for source in BINDING_SOURCES:
        assert f"path = {source};" in PROJECT
        assert f"/* {source} */," in PROJECT
        assert f"/* {source} in Sources */," in PROJECT
        assert f'"$ROOT/macos/{source}" \\' in LEGACY
        assert (ROOT / "macos" / source).is_file()


def test_legacy_binding_flag_is_forwarded_independently_in_debug_only() -> None:
    debug = LEGACY.split('if [[ "$CONFIGURATION" == "Debug" ]]; then', 1)[1].split(
        "\nfi\n\nrm -rf", 1
    )[0]
    binding_check = debug.split(f'*" {BINDING_FLAG} "*', 1)[0].rsplit("if [[", 1)[1]

    assert f"SWIFT_FLAGS+=(-D {BINDING_FLAG})" in debug
    assert "HAS_NATIVE_DOMAIN" not in binding_check
    assert "HAS_NATIVE_OVERLAY" not in binding_check
    assert LEGACY.count(f"SWIFT_FLAGS+=(-D {BINDING_FLAG})") == 1
    assert BINDING_FLAG not in LEGACY.split(
        'if [[ "$CONFIGURATION" == "Debug" ]]; then', 1
    )[0]


def test_user_start_script_is_not_absorbed_by_build_inputs() -> None:
    assert "start_service.command" not in PROJECT
    assert "start_service.command" not in LEGACY


def test_ci_builds_and_rejects_the_exact_xcode_and_legacy_matrix() -> None:
    exact = (
        "DEBUG JUYI_NATIVE_TRANSLATION_DOMAIN JUYI_NATIVE_TRANSLATION_OVERLAY "
        "JUYI_NATIVE_TRANSLATION_RESULT_LAB JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER "
        "JUYI_NATIVE_APPLE_RESULT_LAB_BINDING"
    )
    assert "Build exact Debug real Apple Result Lab binding" in CI
    assert "Build exact legacy Debug real Apple Result Lab binding" in CI
    assert CI.count(exact) == 2
    assert "Reject incomplete or mixed real Apple Result Lab binding" in CI
    assert "Reject incomplete or mixed legacy real Apple Result Lab binding" in CI
    assert CI.count("JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER " + BINDING_FLAG) >= 2
    assert "Build Release with every native development flag injected" in CI
    assert "Build legacy Release with every development flag injected" in CI


def test_ci_binding_artifacts_require_real_surface_and_exclude_old_slices() -> None:
    xcode = CI.split(
        "- name: Verify real Apple Result Lab binding compile-time gate", 1
    )[1].split("- name: Verify native Apple Translation adapter", 1)[0]
    legacy = CI.split(
        "- name: Build exact legacy Debug real Apple Result Lab binding", 1
    )[1].split("- name: Reject legacy Debug Result Lab", 1)[0]
    for gate in (xcode, legacy):
        for token in (
            "juyi-native-apple-result-lab-binding-v1",
            "NativeTranslationAppleResultLabCoordinator",
            "开发：真实 Apple 结果实验室…",
            "正在运行真实 Apple Translation…",
            "Apple Translation 真实译文",
            "The weather is pleasant today.",
            "/Translation.framework/",
            "/_Translation_SwiftUI.framework/",
            "juyi-native-translation-result-lab-v1",
            "NativeTranslationResultLabCoordinator",
            "juyi-native-overlay-fixed-fixture-v1",
            "开发：预览下一状态：",
            "这是固定的火山云端成功预览译文。",
            "juyi-native-apple-translation-adapter-v1",
            "NativeAppleTranslationAdapterCoordinator",
            "juyi-native-volc-translation-adapter-v1",
            "NativeVolcDebugWorkflow",
            "NativeVolcTranslationAdapterSheet",
            "/Security.framework/",
            "/LocalAuthentication.framework/",
        ):
            assert token in gate, token
        # The 4A domain deliberately retains its pure Volc builder endpoint;
        # endpoint absence is not evidence that the live 4C slice is absent.
        assert "translate.volcengineapi.com" not in gate


def test_ci_runs_both_binding_swift_suites_with_the_six_gate() -> None:
    for source, binary in (
        (
            "tests/NativeTranslationAppleResultLabBindingPresentationTests.swift",
            "native-apple-result-lab-binding-presentation-tests",
        ),
        (
            "tests/NativeTranslationAppleResultLabBindingModelTests.swift",
            "native-apple-result-lab-binding-owner-tests",
        ),
    ):
        assert source in CI
        assert CI.count(binary) >= 2
    assert CI.count(f"-D {BINDING_FLAG}") >= 2


def test_binding_documentation_keeps_activation_and_privacy_limits_explicit() -> None:
    for text in (
        "4D-A，开发中未启用",
        "exact-once",
        "The weather is pleasant today.",
        "冷启动已未授权仍允许显式运行",
        "不会请求或弹出辅助功能授权提示",
        "不是 Activation GO",
        "macOS 15.0",
        "arm64 与 Intel",
    ):
        assert text in DOC
