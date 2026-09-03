"""Safety contracts for the native Option + selection path."""

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


def test_native_production_chain_is_explicitly_user_enabled():
    assert "final class NativeProductionTranslationCoordinator" in FEATURE
    assert "func enableByUser()" in FEATURE
    assert "NativeOptionMonitor(" in FEATURE
    assert "NativeSelectionCaptureCoordinator()" in FEATURE
    assert "recognitionHandler:" in FEATURE
    assert "setAppleEngineSelected" in FEATURE
    assert "generation == lifecycleGeneration" in FEATURE
    assert "anchorPoint: Self.overlayAnchorPoint(for: target)" in FEATURE
    assert "JUYI_NATIVE_OPTION_MONITOR" not in DEBUG_CONFIG
    assert "JUYI_NATIVE_OPTION_MONITOR" not in RELEASE_CONFIG


def test_capture_runs_on_serial_worker_and_discards_stale_text_early():
    assert 'label: "io.github.Eim-aa.Juyi.native-selection"' in COORDINATOR
    assert "qos: .userInitiated" in COORDINATOR
    assert COORDINATOR.count("isCurrent(captureGeneration)") == 3
    assert COORDINATOR.index("beginWork(captureGeneration)") < COORDINATOR.index(
        "result = reader(target)"
    )
    reader_index = COORDINATOR.index("result = reader(target)")
    assert COORDINATOR.find("completionScheduler", reader_index) > reader_index
    for forbidden in ("print(", "Logger", "os_log", "NSPasteboard", "URLSession"):
        assert forbidden not in COORDINATOR


def test_production_permission_prompt_is_reached_only_from_explicit_enable():
    assert "NativeProductionTranslationCoordinator.shared" in APP
    assert "nativeTranslation.enableByUser()" in APP
    assert "Task { await enable(promptForAccessibility: true) }" in FEATURE
    assert "if authorization != .authorized, promptForAccessibility" in FEATURE
    assert "AccessibilityController.requestAuthorization()" in FEATURE
    assert "requestAuthorization" not in APP
    assert "NativeSelectionReader" not in APP

    assert "requestAuthorization()" in ACCESSIBILITY
    assert "AXIsProcessTrustedWithOptions" in ACCESSIBILITY
    assert "AXIsProcessTrusted()" in ACCESSIBILITY
    assert "requestAuthorization" not in MONITOR
    assert "requestAuthorization" not in SELECTION


def test_production_owner_resumes_after_wake_and_session_reactivation():
    for notification in (
        "NSWorkspace.willSleepNotification",
        "NSWorkspace.didWakeNotification",
        "NSWorkspace.sessionDidResignActiveNotification",
        "NSWorkspace.sessionDidBecomeActiveNotification",
    ):
        assert notification in APP
    assert "#selector(nativeProductionDidWake(_:))" in APP
    assert "#selector(nativeProductionSessionBecameActive(_:))" in APP
    wake = APP.split(
        "private func nativeProductionDidWake", 1
    )[1].split("private func nativeProductionSessionResigned", 1)[0]
    session = APP.split(
        "private func nativeProductionSessionBecameActive", 1
    )[1].split("#if DEBUG", 1)[0]
    assert "resumeNativeProductionIfEligible()" in wake
    assert "resumeNativeProductionIfEligible()" in session
    resume = APP.split(
        "private func resumeNativeProductionIfEligible", 1
    )[1].split("#if DEBUG", 1)[0]
    assert "guard nativeProductionIsAwake" in resume
    assert "nativeProductionSessionIsActive else { return }" in resume
    assert (
        "NativeProductionTranslationCoordinator.shared.applicationBecameActive()"
        in resume
    )

    assert "private var resumeRequestedAfterRevocation = false" in FEATURE
    resume_feature = FEATURE.split("func resumeIfEnabled()", 1)[1].split(
        "func setAppleEngineSelected", 1
    )[0]
    assert "activation?.phase == .revocationRequired" in resume_feature
    assert "resumeRequestedAfterRevocation = true" in resume_feature
    deferred = FEATURE.split("private func finishDeferredRevocation()", 1)[1].split(
        "private func disable", 1
    )[0]
    assert "activation?.retryRevocation()" in deferred
    assert "let shouldResume = resumeRequestedAfterRevocation" in deferred
    assert "UserDefaults.standard.bool(forKey: Self.enabledKey)" in deferred
    assert "resumeIfEnabled()" in deferred
    disable = FEATURE.split("private func disable", 1)[1].split(
        "private func stopOwnerPolling", 1
    )[0]
    assert "resumeRequestedAfterRevocation = false" in disable


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
    assert "frontmostApplication()?.hasSameProcess(as: target) == true" in MONITOR
    assert "NativeSelectionTarget(application: application)" in MONITOR
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


def test_ax_reader_is_process_and_focus_bound_secure_fail_closed_and_ax_only():
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

    assert "struct NativeSelectionProcessIdentity: Equatable, Sendable" in SELECTION
    assert "struct NativeSelectionTarget: Equatable, Sendable" in SELECTION
    assert "let launchDate: Date" in SELECTION
    assert "let launchDate = application.launchDate" in SELECTION
    assert "processIdentity == other.processIdentity" in SELECTION
    assert "NativeSelectionTarget(application: application)" in SELECTION
    assert "AXUIElementCreateApplication(target.processIdentifier)" in SELECTION
    assert SELECTION.count("kAXFocusedUIElementAttribute as CFString") == 2
    assert "CFEqual(focusedElement, revalidatedFocusedElement)" in SELECTION
    assert "AXUIElementGetPid" in SELECTION
    assert "NSRunningApplication(processIdentifier: elementPID)" in SELECTION
    assert "targetProcessIdentity: target.processIdentity" in SELECTION
    assert "kAXRoleAttribute" in SELECTION
    assert "kAXSubroleAttribute" in SELECTION
    assert "kAXSecureTextFieldSubrole" in SELECTION
    assert "kAXUnknownRole" in SELECTION
    assert "kAXUnknownSubrole" in SELECTION
    assert "kAXTextFieldRole" in SELECTION
    assert "kAXSearchFieldSubrole" in SELECTION
    assert "kAXSelectedTextAttribute" in SELECTION
    selected_index = SELECTION.index("kAXSelectedTextAttribute as CFString")
    validation_calls = [
        match.start()
        for match in re.finditer("validateIdentityRoleAndSubrole\\(", SELECTION)
    ]
    assert len(validation_calls) == 3
    assert validation_calls[0] < selected_index < validation_calls[1]
    assert "roleAndSubroleValueDecision" in SELECTION
    assert SELECTION.count("AXUIElementSetMessagingTimeout") >= 3
    assert "messagingTimeout: Float = 0.50" in SELECTION
    assert SELECTION.count(
        "client.frontmostApplication?.hasSameProcess(as: target) == true"
    ) == 2
    reader_call = SELECTION.index("let selection = client.copySelectedText(from: target)")
    assert SELECTION.find(
        "client.frontmostApplication?.hasSameProcess(as: target) == true",
        reader_call,
    ) > reader_call
    assert "targetPID != client.currentProcessIdentifier" in SELECTION

    validator = SELECTION.split(
        "private func validateIdentityRoleAndSubrole", 1
    )[1]
    assert validator.index("kAXRoleAttribute") < validator.index("kAXSubroleAttribute")
    assert "role == (kAXTextFieldRole as String)" in SELECTION
    assert "subrole == (kAXSearchFieldSubrole as String)" in SELECTION

    assert 'wpsBundleIdentifier = "com.kingsoft.wpsoffice.mac"' in SELECTION
    assert "copyWPSPDFSelectionIfEligible" in SELECTION
    assert "onlyIfChangeCount" in SELECTION
    assert "candidate == markerValue" in SELECTION
    assert "candidate == snapshot.originalString" in SELECTION
    assert SELECTION.count("captureStableWPSClipboardCandidate(") == 3
    assert "confirmedText == firstText" in SELECTION
    assert "confirmedSnapshot.hasSamePayload(as: firstCandidateSnapshot)" in SELECTION
    assert "performCriticalEffect:" in COORDINATOR
    assert "performIfCurrent(captureGeneration, action)" in COORDINATOR
    assert "performCleanupEffect:" in COORDINATOR
    assert "performIfActive(captureGeneration, action)" in COORDINATOR
    assert "cancelAll(onQuiesced:" in COORDINATOR
    assert "capture.cancelAll {" in FEATURE
    assert "retryRevocation()" in FEATURE
    assert "cancellationCheck()" in SELECTION

    for forbidden in (
        "URLSession",
        "translator",
        "server",
        "print(",
        "Logger",
        "os_log",
        "kAXDescriptionAttribute",
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


def test_docs_record_the_live_native_mvp_and_remaining_boundaries():
    assert "Apple 离线翻译 MVP 已接入普通 Debug 与 Release 构建" in DOC
    assert "真实 AX 选区" in DOC
    assert "现有 owner 协议" in DOC
    assert "macOS 15 Translation framework" in DOC
    assert "WPS PDF" in DOC
    assert "除 WPS PDF 外不使用剪贴板回退" in DOC
    assert "需要 OCR，不属于本 MVP" in DOC
    assert "addglobalmonitorforevents" in DOC.lower()
    assert "MonitoringEvents.html" in DOC
    assert "kaxselectedtextattribute" in DOC.lower()
    assert "PID + NSRunningApplication.launchDate" in DOC
    assert "bundle ID 只作元数据" in DOC
    assert "CFEqual" in DOC
    assert "干净 TCC 状态" in DOC
