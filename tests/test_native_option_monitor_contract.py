"""Safety contracts for the disabled native NSEvent + AX foundation."""

import re
from pathlib import Path


ROOT = Path(__file__).parents[1]
STATE = (ROOT / "macos" / "DoubleOptionStateMachine.swift").read_text(
    encoding="utf-8"
)
ADAPTER = (ROOT / "macos" / "NativeOptionEventAdapter.swift").read_text(
    encoding="utf-8"
)
MONITOR = (ROOT / "macos" / "NativeOptionMonitor.swift").read_text(
    encoding="utf-8"
)
SELECTION = (ROOT / "macos" / "NativeSelectionReader.swift").read_text(
    encoding="utf-8"
)
COORDINATOR = (
    ROOT / "macos" / "NativeSelectionCaptureCoordinator.swift"
).read_text(encoding="utf-8")
ACCESSIBILITY = (ROOT / "macos" / "AccessibilityController.swift").read_text(
    encoding="utf-8"
)
FEATURE = (ROOT / "macos" / "NativeOptionFeature.swift").read_text(
    encoding="utf-8"
)
APP = (ROOT / "macos" / "JuyiMenuBar.swift").read_text(encoding="utf-8")
PROJECT = (ROOT / "Juyi.xcodeproj" / "project.pbxproj").read_text(
    encoding="utf-8"
)
LEGACY_BUILD = (ROOT / "scripts" / "build_macos_app.sh").read_text(
    encoding="utf-8"
)
CI = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
CONFIG = (ROOT / "config.py").read_text(encoding="utf-8")
DEBUG_CONFIG = (ROOT / "Config" / "Debug.xcconfig").read_text(encoding="utf-8")
RELEASE_CONFIG = (ROOT / "Config" / "Release.xcconfig").read_text(
    encoding="utf-8"
)
DOC = (ROOT / "docs" / "NATIVE_OPTION_MONITOR.md").read_text(encoding="utf-8")


def test_release_is_compile_time_disabled_and_debug_capture_is_private():
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
    assert "NativeSelectionCaptureCoordinator" in harness
    assert "recognitionInvalidationHandler" in harness
    assert "captureCoordinator?.cancelAll()" in harness
    assert "lastCaptureResult = result" in harness
    for forbidden in (
        "NativeSelectionReader",
        "readSelection",
        "pasteboard",
        "translate",
        "showWindow",
    ):
        assert forbidden not in harness


def test_capture_runs_on_serial_worker_and_discards_stale_text_early():
    assert 'label: "io.github.Eim-aa.Juyi.native-selection"' in COORDINATOR
    assert "qos: .userInitiated" in COORDINATOR
    assert COORDINATOR.count("isCurrent(captureGeneration)") == 3
    assert COORDINATOR.index("isCurrent(captureGeneration)") < COORDINATOR.index(
        "let result = reader(target)"
    )
    reader_index = COORDINATOR.index("let result = reader(target)")
    assert COORDINATOR.find("completionScheduler", reader_index) > reader_index
    for forbidden in ("print(", "Logger", "os_log", "NSPasteboard", "URLSession"):
        assert forbidden not in COORDINATOR


def test_production_flow_has_no_prompt_or_native_behavioral_takeover():
    assert "#if DEBUG" in APP
    assert "nativeOptionDevelopmentHarness.startIfEnabled()" in APP
    assert "nativeOptionDevelopmentHarness.stop()" in APP
    assert "nativeOptionDevelopmentHarness.applicationBecameActive()" in APP
    assert "nativeOptionDevelopmentHarness.setPaused(model.paused)" in APP
    assert "Task { @MainActor" not in FEATURE
    assert "MainActor.assumeIsolated" in FEATURE
    assert "isPaused = paused" in FEATURE
    assert "candidate.setPaused(isPaused)" in FEATURE
    launch = APP.split("func applicationDidFinishLaunching", 1)[1].split(
        "func applicationShouldHandleReopen", 1
    )[0]
    assert launch.index("setPaused(model.paused)") < launch.index("startIfEnabled()")
    assert "requestAuthorization" not in APP
    assert "NativeSelectionReader" not in APP

    assert "requestAuthorization()" in ACCESSIBILITY
    assert "AXIsProcessTrustedWithOptions" in ACCESSIBILITY
    assert "AXIsProcessTrusted()" in ACCESSIBILITY
    assert "requestAuthorization" not in MONITOR
    assert "requestAuthorization" not in SELECTION
    assert "requestAuthorization" not in FEATURE


def test_monitor_is_main_actor_global_only_and_never_reads_key_text():
    assert "@MainActor" in MONITOR
    assert "NSEvent.addGlobalMonitorForEvents" in MONITOR
    assert "[.flagsChanged, .keyDown]" in MONITOR
    assert "NSEvent.removeMonitor" in MONITOR
    assert "addLocalMonitorForEvents" not in MONITOR
    assert "CGEvent" not in MONITOR
    assert "CoreGraphics" not in MONITOR
    assert ".characters" not in MONITOR
    assert "charactersIgnoringModifiers" not in MONITOR
    assert "event.keyCode" in MONITOR
    assert "event.isARepeat" in MONITOR

    start = MONITOR.split("func start()", 1)[1].split("func setPaused", 1)[0]
    assert start.index("accessibilityStatus()") < start.index("addGlobalMonitor")
    receive = MONITOR.split("private func receive", 1)[1].split(
        "private func deliver", 1
    )[0]
    assert "accessibilityStatus" not in receive
    assert "NativeSelectionReader" not in receive
    assert "AXUIElement" not in receive
    assert "currentProcessIdentifier" in receive
    assert "generation += 1" in receive
    assert "deliveryScheduler" in receive

    assert "func refreshAuthorizationStatus" in MONITOR
    assert "removeGlobalMonitorIfNeeded" in MONITOR
    assert "eventSource.removeMonitor(monitor)" in MONITOR
    assert "frontmostApplication()?.processIdentifier" in MONITOR
    assert MONITOR.index("recognitionInvalidationHandler()") < MONITOR.index(
        "guard let target = frontmostApplication()"
    )
    for forbidden in ("NSPasteboard", "URLSession", "translate", "showWindow"):
        assert forbidden not in MONITOR


def test_adapter_has_no_text_payload_and_handles_startup_safely():
    implementation = "\n".join(
        line for line in ADAPTER.splitlines() if not line.lstrip().startswith("//")
    )
    for forbidden in ("String", "Character", "Unicode", "characters"):
        assert forbidden not in implementation
    assert "optionInitiallyDown" in ADAPTER
    assert "awaitingAllOptionRelease" in ADAPTER
    assert "leftOptionKeyCode" in ADAPTER
    assert "rightOptionKeyCode" in ADAPTER
    assert "capsLockKeyCode" in ADAPTER
    assert "keyDown(isAutoRepeat:" in ADAPTER
    assert "NativeOptionEventAdapterTests.swift" in CI


def test_ax_reader_is_pid_bound_secure_fail_closed_and_ax_only():
    for result in (
        "success(text: String, didTruncate: Bool)",
        "accessibilityRequired",
        "noFocusedElement",
        "noSelection",
        "unsupported",
        "secureField",
        "temporarilyUnavailable",
        "internalFailure",
        "cancelled",
    ):
        assert f"case {result}" in SELECTION

    assert "AXUIElementCreateApplication(target.processIdentifier)" in SELECTION
    assert "kAXFocusedUIElementAttribute" in SELECTION
    assert "AXUIElementGetPid" in SELECTION
    assert "kAXSubroleAttribute" in SELECTION
    assert "kAXSecureTextFieldSubrole" in SELECTION
    assert "kAXSelectedTextAttribute" in SELECTION
    assert SELECTION.index("AXUIElementGetPid") < SELECTION.index(
        "kAXSelectedTextAttribute"
    )
    assert SELECTION.index("kAXSecureTextFieldSubrole") < SELECTION.index(
        "kAXSelectedTextAttribute"
    )
    assert SELECTION.count("AXUIElementSetMessagingTimeout") == 2
    assert "messagingTimeout: Float = 0.10" in SELECTION
    assert SELECTION.count(
        "client.frontmostApplication?.processIdentifier == targetPID"
    ) == 2
    reader_call = SELECTION.index("let selection = client.copySelectedText(from: target)")
    assert SELECTION.find(
        "client.frontmostApplication?.processIdentifier == targetPID",
        reader_call,
    ) > reader_call
    assert "targetPID != client.currentProcessIdentifier" in SELECTION

    for forbidden in (
        "NSPasteboard",
        "pasteboard",
        "URLSession",
        "translator",
        "server",
        "print(",
        "Logger",
        "os_log",
        "kAXDescriptionAttribute",
        "kAXTitleAttribute",
        "kAXValueAttribute",
    ):
        assert forbidden not in SELECTION


def test_selection_normalization_matches_existing_backend_limit():
    match = re.search(r"^MAX_INPUT_CHARS\s*=\s*(\d+)$", CONFIG, re.MULTILINE)
    assert match
    assert int(match.group(1)) == 5_000
    assert "maximumInputCharacters: Int { 5_000 }" in SELECTION
    assert 'replacingOccurrences(of: "\\r\\n", with: "\\n")' in SELECTION
    assert 'replacingOccurrences(of: "\\r", with: "\\n")' in SELECTION
    assert "trimmingCharacters(in: .whitespacesAndNewlines)" in SELECTION
    assert "normalized.unicodeScalars" in SELECTION
    assert "scalars.prefix(maximumInputCharacters)" in SELECTION


def test_sources_tests_and_frameworks_are_in_every_build_path():
    for source in (
        "AccessibilityController.swift",
        "DoubleOptionStateMachine.swift",
        "NativeOptionEventAdapter.swift",
        "NativeSelectionReader.swift",
        "NativeSelectionCaptureCoordinator.swift",
        "NativeOptionMonitor.swift",
        "NativeOptionFeature.swift",
    ):
        assert f"{source} in Sources" in PROJECT
        assert f'"$ROOT/macos/{source}"' in LEGACY_BUILD
    assert "ApplicationServices.framework in Frameworks" in PROJECT
    # WindowFramePolicy still imports CoreGraphics; only the event-tap usage is gone.
    assert "CoreGraphics.framework in Frameworks" in PROJECT
    assert "-framework ApplicationServices" in LEGACY_BUILD
    assert "-framework CoreGraphics" in LEGACY_BUILD
    for test in (
        "DoubleOptionStateMachineTests.swift",
        "NativeOptionEventAdapterTests.swift",
        "NativeSelectionReaderTests.swift",
        "NativeSelectionCaptureCoordinatorTests.swift",
        "NativeOptionMonitorTests.swift",
    ):
        assert f"tests/{test}" in CI


def test_docs_record_official_boundary_without_claiming_migration_is_live():
    assert "开发中，默认未启用" in DOC
    assert "唯一生效的双 Option 触发" in DOC
    assert "仍由 `hammerspoon/argos-translator.lua` 提供" in DOC
    assert "不表示句译已经去除 Hammerspoon/Python 依赖" in DOC
    assert "不会调用翻译" in DOC
    assert "addglobalmonitorforevents" in DOC.lower()
    assert "MonitoringEvents.html" in DOC
    assert "kaxselectedtextattribute" in DOC.lower()
    assert "常态 global-only" in DOC
    assert "CGEventTap" in DOC and "已退役" in DOC
    assert "干净 TCC 环境" in DOC
