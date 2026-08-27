"""Static safety contracts for the disabled native Option-key experiment."""

from pathlib import Path


ROOT = Path(__file__).parents[1]
STATE = (ROOT / "macos" / "DoubleOptionStateMachine.swift").read_text(
    encoding="utf-8"
)
MONITOR = (ROOT / "macos" / "NativeOptionMonitor.swift").read_text(encoding="utf-8")
ACCESSIBILITY = (ROOT / "macos" / "AccessibilityController.swift").read_text(
    encoding="utf-8"
)
FEATURE = (ROOT / "macos" / "NativeOptionFeature.swift").read_text(encoding="utf-8")
APP = (ROOT / "macos" / "JuyiMenuBar.swift").read_text(encoding="utf-8")
PROJECT = (ROOT / "Juyi.xcodeproj" / "project.pbxproj").read_text(encoding="utf-8")
LEGACY_BUILD = (ROOT / "scripts" / "build_macos_app.sh").read_text(
    encoding="utf-8"
)
CI = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
DEBUG_CONFIG = (ROOT / "Config" / "Debug.xcconfig").read_text(encoding="utf-8")
RELEASE_CONFIG = (ROOT / "Config" / "Release.xcconfig").read_text(encoding="utf-8")
DOC = (ROOT / "docs" / "NATIVE_OPTION_MONITOR.md").read_text(encoding="utf-8")


def test_release_is_compile_time_disabled_and_default_debug_is_off():
    assert "#if DEBUG && JUYI_NATIVE_OPTION_MONITOR" in FEATURE
    assert "static let isEnabled = true" in FEATURE
    assert "#else\n    static let isEnabled = false" in FEATURE
    for forbidden in ("UserDefaults", "ProcessInfo", "URLSession", "NotificationCenter"):
        assert forbidden not in FEATURE
    assert "JUYI_NATIVE_OPTION_MONITOR" not in DEBUG_CONFIG
    assert "JUYI_NATIVE_OPTION_MONITOR" not in RELEASE_CONFIG

    harness = FEATURE.split("func startIfEnabled()", 1)[1].split("func stop()", 1)[0]
    assert harness.index("guard NativeOptionFeature.isEnabled") < harness.index(
        "NativeOptionMonitor"
    )
    assert "recognitionCount += 1" in harness
    for forbidden in ("translate", "selectedText", "pasteboard", "showWindow"):
        assert forbidden not in harness


def test_production_flow_has_no_native_prompt_or_behavioral_integration():
    assert "#if DEBUG" in APP
    assert "nativeOptionDevelopmentHarness.startIfEnabled()" in APP
    assert "nativeOptionDevelopmentHarness.stop()" in APP
    assert "requestAuthorization" not in APP
    assert "AccessibilityController" not in APP
    assert "NativeOptionMonitor" not in APP
    assert "NativeOptionFeature" not in APP

    assert "requestAuthorization()" in ACCESSIBILITY
    assert "AXIsProcessTrustedWithOptions" in ACCESSIBILITY
    assert "AXIsProcessTrusted()" in ACCESSIBILITY
    assert "requestAuthorization" not in MONITOR
    assert "AccessibilityController" not in MONITOR
    assert "accessibilityRequired" not in MONITOR
    assert "case tapUnavailable" in MONITOR


def test_event_tap_is_listen_only_lightweight_and_self_healing():
    assert "CGEvent.tapCreate" in MONITOR
    assert "options: .listenOnly" in MONITOR
    assert "CGEventType.flagsChanged.rawValue" in MONITOR
    assert "CGEventType.keyDown.rawValue" in MONITOR
    assert "capsLockKeyCode" in MONITOR
    assert "return .modifiersChanged(relevantModifiers(from: event.flags))" in MONITOR
    assert ".tapDisabledByTimeout" in MONITOR
    assert ".tapDisabledByUserInput" in MONITOR
    assert "CGEvent.tapEnable(tap: tap, enable: true)" in MONITOR
    assert "timer" not in MONITOR.lower()
    assert "stateMachine.reset()" in MONITOR
    assert MONITOR.count("generation += 1") >= 4
    assert "func setPaused" in MONITOR
    assert "func stop()" in MONITOR
    assert "guard let tap = eventTap else" in MONITOR
    assert "DispatchQueue.main.asyncAfter" in MONITOR
    assert MONITOR.count("Unmanaged.passUnretained(event)") >= 4
    for forbidden in ("selectedText", "pasteboard", "URLSession", "translate"):
        assert forbidden not in MONITOR


def test_state_machine_and_monitor_are_in_every_build_path():
    for source in (
        "AccessibilityController.swift",
        "DoubleOptionStateMachine.swift",
        "NativeOptionMonitor.swift",
        "NativeOptionFeature.swift",
    ):
        assert f"{source} in Sources" in PROJECT
        assert f'"$ROOT/macos/{source}"' in LEGACY_BUILD
    assert "ApplicationServices.framework in Frameworks" in PROJECT
    assert "CoreGraphics.framework in Frameworks" in PROJECT
    assert "-framework ApplicationServices" in LEGACY_BUILD
    assert "-framework CoreGraphics" in LEGACY_BUILD
    assert "tests/DoubleOptionStateMachineTests.swift" in CI


def test_docs_do_not_claim_the_native_migration_is_live():
    assert "开发中，默认未启用" in DOC
    assert "唯一生效的双 Option 触发" in DOC
    assert "仍由 `hammerspoon/argos-translator.lua` 提供" in DOC
    assert "不表示句译已经去除 Hammerspoon/Python 依赖" in DOC
    assert "不会调用翻译" in DOC
