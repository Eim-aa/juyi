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
    assert "model.enableNativeShortcut()" in APP
    explicit_enable = APP.split("func enableNativeShortcut()", 1)[1].split(
        "private func installBundledShortcut", 1
    )[0]
    assert "native.enableByUser()" in explicit_enable
    assert "Task { await enable(promptForAccessibility: true) }" in FEATURE
    assert "if authorization != .authorized, promptForAccessibility" in FEATURE
    assert "AccessibilityController.requestAuthorization()" in FEATURE
    assert "requestAuthorization" not in APP
    assert "NativeSelectionReader" not in APP
    assert "nativeOwnerBridgeReady && deploymentIsCurrent" in explicit_enable
    assert "setShortcutDeploymentReady(deploymentIsCurrent)" in explicit_enable
    assert "private var shortcutDeploymentReady = false" in FEATURE
    assert "guard shortcutDeploymentReady else" in FEATURE
    assert "private var lifecycleActivationAllowed = false" in FEATURE
    assert "guard lifecycleActivationAllowed else" in FEATURE
    assert "ownerBridgeIsFreshAfterRestart" in APP
    fresh_owner = APP.split("private func ownerBridgeIsFreshAfterRestart", 1)[1].split(
        "private func restartHammerspoonAfterInstall", 1
    )[0]
    assert "currentInstanceID != previousInstanceID" in fresh_owner
    assert "updatedAt >= ceil(restartStartedAt)" in fresh_owner
    assert "updatedAt <= previousUpdatedAt" in fresh_owner
    assert "currentSequence > candidateSequence" in fresh_owner
    assert "fallbackCandidateInstanceID = currentInstanceID" in fresh_owner
    assert "else if deployedOwnerReady" in APP

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
    assert "setLifecycleActivationAllowed(false, reason: .sleep)" in APP
    assert "setLifecycleActivationAllowed(false, reason: .sessionResigned)" in APP
    resume = APP.split(
        "private func resumeNativeProductionIfEligible", 1
    )[1].split("#if DEBUG", 1)[0]
    assert "guard nativeProductionIsAwake" in resume
    assert "nativeProductionSessionIsActive," in resume
    assert "native.setLifecycleActivationAllowed(true)" in resume
    assert "Self.currentSessionAllowsNativeActivation" in resume
    launch = APP.split("func applicationDidFinishLaunching", 1)[1].split(
        "func applicationShouldHandleReopen", 1
    )[0]
    assert "nativeProductionSessionIsActive = Self.currentSessionAllowsNativeActivation" in launch
    assert "resumeNativeProductionIfEligible()" in launch
    assert "CGSessionCopyCurrentDictionary()" in APP
    assert "kCGSessionOnConsoleKey" in APP
    assert "kCGSessionLoginDoneKey" in APP
    assert "native.applicationBecameActive()" in resume

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


def test_native_language_preparation_stops_before_system_request_and_restores_intent():
    prepare = FEATURE.split("func prepareLanguages()", 1)[1].split(
        "func setPaused", 1
    )[0]
    assert prepare.index("disable(reason: .stop, preservePreference: true)") < prepare.index(
        "await apple.prepareLanguages()"
    )
    assert "pendingUserEnable || isEnabled" in prepare
    assert "UserDefaults.standard.set(true, forKey: Self.enabledKey)" in prepare
    assert "activation?.phase != .revocationRequired" in prepare
    assert "activation?.holdsOwnerLease != true" in prepare
    assert "monitor == nil" in prepare
    assert "generation == lifecycleGeneration, isPreparingLanguages" in prepare
    assert "case .prepared:" in prepare
    assert "appleReadinessIssue = nil" in prepare
    assert "resumeIfEnabled()" in prepare
    assert "lifecycleActivationAllowed" in prepare
    assert "!isPaused, appleEngineSelected" in prepare
    assert prepare.index("holdLegacyPauseForRecovery()") < prepare.index(
        "disable(reason: .stop, preservePreference: true)"
    )


def test_language_failures_cannot_keep_active_or_resume_without_explicit_recovery():
    failure = FEATURE.split("private func suspendForAppleFailure", 1)[1].split(
        "private func receiveCapture", 1
    )[0]
    assert failure.index("disable(reason: .stop, preservePreference: true)") < failure.index(
        "overlay.beginNativeTranslation("
    )
    assert "phase = .languagePackRequired" in failure
    assert "phase = .unsupported" in failure
    assert "let generation = pipelineGeneration" in failure
    assert "activation?.phase != .revocationRequired" in failure
    assert "error: failure.error" in failure
    assert "appleReadinessIssue == nil" in FEATURE.split("func resumeIfEnabled()", 1)[1].split(
        "func setShortcutDeploymentReady", 1
    )[0]
    deferred = FEATURE.split("private func finishDeferredRevocation()", 1)[1].split(
        "private func disable", 1
    )[0]
    assert "if pendingLanguagePreparation" in deferred
    assert "beginLanguagePreparationIfQuiescent()" in deferred
    assert "if appleReadinessIssue != nil" in deferred
    assert "presentPendingAppleFailure()" in deferred
    assert "error: .serviceUnavailable" not in FEATURE
    assert "error: .appleFailed" in FEATURE
    assert "error: .appleTimedOut" in FEATURE


def test_native_diagnostic_retry_retains_owner_stop_barrier():
    retry = FEATURE.split("func retryByUser()", 1)[1].split("func resumeIfEnabled()", 1)[0]
    assert "guard shortcutDeploymentReady else" in retry
    assert "!isPaused, appleEngineSelected" in retry
    assert "UserDefaults.standard.set(true, forKey: Self.enabledKey)" in retry
    assert retry.index("disable(reason: .stop, preservePreference: true)") < retry.index(
        "resumeIfEnabled()"
    )
    translation = FEATURE.split("let started = ProcessInfo.processInfo.systemUptime", 1)[1].split(
        "let result = await apple.translate(text)", 1
    )[0]
    assert "guard !Task.isCancelled" in translation
    assert "generation == pipelineGeneration" in translation
    assert "overlayGeneration == panelGeneration" in translation


def test_recovery_uses_existing_pause_and_releases_only_after_native_owner_activation():
    failure = FEATURE.split("private func suspendForAppleFailure", 1)[1].split(
        "private func presentPendingAppleFailure", 1
    )[0]
    assert failure.index("holdLegacyPauseForRecovery()") < failure.index(
        "disable(reason: .stop, preservePreference: true)"
    )
    owner_ready = FEATURE.split("if activation.phase == .nativeActive", 1)[1].split(
        "guard activation.phase == .waitingForLegacy", 1
    )[0]
    assert "legacyRecoveryPauseHandler?(false)" in owner_ready
    assert owner_ready.index("legacyRecoveryPauseHandler?(false)") < owner_ready.index(
        "phase = .active"
    )
    pause = FEATURE.split("func setPaused(_ paused: Bool", 1)[1].split(
        "private func holdLegacyPauseForRecovery", 1
    )[0]
    assert "if byUser" in pause
    assert "recoveryPauseHeld = false" in pause
    assert "else if recoveryPauseHeld && paused" in pause
    assert "disable(reason: .pause, preservePreference: true)" in pause
    assert "native.setPaused(paused, byUser: true)" in APP
    assert "setPaused(true, byUser: true)" in APP
    assert "var userPaused: Bool" in APP
    assert "paused && !NativeProductionTranslationCoordinator.shared.recoveryPauseHeld" in APP
    assert "NativeTranslationOverlayController.shared.setPaused(model.userPaused)" in APP
    assert "try (pause ? \"1\\n\" : \"0\\n\").write(to: pauseFile" in APP
    assert "legacyRecoveryPauseHandler =" in APP


def test_resuming_known_apple_fault_never_briefly_unpauses_legacy():
    resume = FEATURE.split("func resumeAppleRecoveryByUser()", 1)[1].split(
        "func resumeIfEnabled()", 1
    )[0]
    assert "guard isPaused, appleEngineSelected" in resume
    assert "appleReadinessIssue != nil" in resume
    assert resume.index("recoveryPauseHeld = true") < resume.index("retryByUser()")
    assert "legacyRecoveryPauseHandler?(false)" not in resume
    toggle = APP.split("func togglePause()", 1)[1].split(
        "func setLegacyPauseForNativeRecovery", 1
    )[0]
    assert toggle.index("native.resumeAppleRecoveryByUser()") < toggle.index(
        "write(to: pauseFile"
    )


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
    assert "let firstDeadline = ProcessInfo.processInfo.systemUptime" in SELECTION
    assert "let confirmationDeadline = ProcessInfo.processInfo.systemUptime" in SELECTION
    assert "confirmedText == firstText" in SELECTION
    assert "confirmedSnapshot.hasSamePayload(as: firstCandidateSnapshot)" in SELECTION
    first_candidate_cleanup = SELECTION.split("switch firstAttempt", 1)[1].split(
        "// A pasteboard change has no source identity", 1
    )[0]
    assert "defer {" in first_candidate_cleanup
    assert "restorePasteboardSnapshot(" in first_candidate_cleanup
    assert (
        "onlyIfChangeCount: firstCandidateSnapshot.changeCount"
        in first_candidate_cleanup
    )
    assert "let restoredContextIsCurrent = isCurrentWPSPDFContext(" in SELECTION
    assert "guard restoredContextIsCurrent," in SELECTION
    assert "postCopyKeystroke(to: target.processIdentifier)" in SELECTION
    assert SELECTION.count(".postToPid(processIdentifier)") == 2
    assert "let postedCopyDrainDeadline = max(" in SELECTION
    assert "var drainOnly = false" in SELECTION
    assert "guard !drainOnly else { continue }" in SELECTION
    settlement = SELECTION.split("let postedCopyDrainDeadline = max(", 1)[1].split(
        "let finalChangeCount = pasteboard.changeCount", 1
    )[0]
    assert "while ProcessInfo.processInfo.systemUptime < postedCopyDrainDeadline" in settlement
    assert "drainOnly = true" in settlement
    assert "pasteboard.string(forType:" not in settlement
    assert "PasteboardSnapshot(pasteboard:" not in settlement
    assert "return .candidate" not in settlement
    assert "performCriticalEffect:" in COORDINATOR
    assert "performIfCurrent(captureGeneration, action)" in COORDINATOR
    assert "performCleanupEffect:" in COORDINATOR
    assert "performIfActive(captureGeneration, action)" in COORDINATOR
    assert "cancelAll(onQuiesced:" in COORDINATOR
    assert "capture.cancelAll {" in FEATURE
    assert "retryRevocation()" in FEATURE
    assert "cancellationCheck()" in SELECTION

    # Prose comments may describe the downstream translator; only executable
    # source should be checked for unwanted transport/logging dependencies.
    selection_code = "\n".join(
        line for line in SELECTION.splitlines()
        if not line.lstrip().startswith("//")
    )
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
        assert forbidden not in selection_code


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
