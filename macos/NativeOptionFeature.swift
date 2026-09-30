import AppKit
import Combine
import Foundation

/// The engine the native chain sends the captured selection to. Both engines
/// share the same gesture, capture, overlay and read-aloud path; there is no
/// automatic fallback between them in either direction.
enum NativeTranslationEngineChoice: String, Equatable, Sendable {
    case apple
    case volc

    var overlayEngine: NativeTranslationOverlayEngine {
        switch self {
        case .apple: return .apple
        case .volc: return .volc
        }
    }
}

/// The single production owner for native selection translation (Apple
/// on-device or Volcengine cloud). Components left by pre-native installations
/// keep the chain disabled until the user removes them (fail-closed), so one
/// double-Option press can never be translated by two paths.
@MainActor
final class NativeProductionTranslationCoordinator: ObservableObject {
    enum Phase: Equatable {
        case disabled
        case requestingAccessibility
        case legacyComponentsDetected
        case active
        case languagePackRequired
        case unsupported
        case unavailable
    }

    enum DeactivationReason: Equatable {
        case user
        case pause
        case stop
        case sleep
        case sessionResigned
        case terminate
        case authorizationRevoked
    }

    static let shared = NativeProductionTranslationCoordinator()

    @Published private(set) var phase: Phase = .disabled
    @Published private(set) var detail = "原生双 Option 尚未启用。"
    @Published private(set) var isPreparingLanguages = false
    @Published private(set) var engine: NativeTranslationEngineChoice = .apple
    /// Volcengine is selected but no credential could be read from Keychain.
    @Published private(set) var cloudCredentialRequired = false
    /// Early components were detected; the chain stays off until removal.
    @Published private(set) var legacyComponentsBlocking = false

    private static let enabledKey = "nativeAppleDoubleOptionEnabled"
    private static let translationTimeout: Duration = .seconds(12)
    static let legacyComponentsDetail = "检测到早期版本留下的组件；移除前不会启用原生双 Option。"

    private let capture = NativeSelectionCaptureCoordinator()
    private let apple = NativeAppleProductionTranslationService.shared
    private let volc = VolcTranslationEngine.shared
    private let overlay = NativeTranslationOverlayController.shared

    private var monitor: NativeOptionMonitor?
    private var enableInProgress = false
    private var pendingUserEnable = false
    /// A stop found a selection capture still running (it may be restoring
    /// the WPS clipboard). Nothing restarts until it has quiesced.
    private var awaitingCaptureStop = false
    private var resumeRequestedAfterRevocation = false
    private var appleReadinessIssue: NativeAppleProductionReadiness?
    private var pendingLanguagePreparation = false
    private var pendingAppleFailure: (
        target: NativeSelectionTarget,
        error: NativeTranslationOverlayBackendError
    )?
    private var lifecycleGeneration: UInt64 = 0
    private var isPaused = false
    private var preflight = NativeTriggerPreflight()
    private var lifecycleActivationAllowed = false
    private var pipelineGeneration: UInt64 = 0
    private var overlayGeneration: Int?
    private var translationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    private init() {}

    /// Activation needs a live session and no early components.
    private var activationAllowed: Bool {
        lifecycleActivationAllowed && !legacyComponentsBlocking
    }

    var isEnabled: Bool { phase == .active }

    var actionTitle: String {
        switch phase {
        case .active: return "停用原生双 Option"
        case .requestingAccessibility: return "正在启用…"
        default: return "启用原生双 Option"
        }
    }

    var actionIsEnabled: Bool {
        !enableInProgress
            && !isPreparingLanguages
            && !legacyComponentsBlocking
            && phase != .requestingAccessibility
    }

    func enableByUser() {
        guard !legacyComponentsBlocking else {
            showLegacyComponentsState()
            return
        }
        guard actionIsEnabled, !isPaused else { return }
        if phase != .active, monitor != nil {
            retryByUser()
            return
        }
        if phase == .active {
            pendingUserEnable = false
            disable(reason: .user)
        } else if !lifecycleActivationAllowed {
            pendingUserEnable = true
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
            phase = .disabled
            detail = "系统会话恢复后会继续启用原生双 Option。"
        } else {
            pendingUserEnable = true
            appleReadinessIssue = nil
            Task { await enable(promptForAccessibility: true) }
        }
    }

    /// A diagnostic retry is an explicit request to restart, never the
    /// enable/disable toggle. An uncertain capture stop defers the restart
    /// until `finishDeferredRevocation` confirms the capture has quiesced.
    func retryByUser() {
        guard actionIsEnabled, !isPaused else { return }
        pendingUserEnable = true
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        disable(reason: .stop, preservePreference: true)
        appleReadinessIssue = nil
        resumeIfEnabled()
    }

    func resumeIfEnabled() {
        guard !isPreparingLanguages, appleReadinessIssue == nil else { return }
        guard activationAllowed else { return }
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else { return }
        guard !isPaused else { return }
        if awaitingCaptureStop {
            resumeRequestedAfterRevocation = true
            return
        }
        guard !enableInProgress,
              phase != .active,
              phase != .requestingAccessibility else { return }
        resumeRequestedAfterRevocation = false
        Task { await enable(promptForAccessibility: false) }
    }

    func setLifecycleActivationAllowed(
        _ allowed: Bool,
        reason: DeactivationReason? = nil
    ) {
        lifecycleActivationAllowed = allowed
        if !allowed, let reason {
            invalidate(reason)
        }
    }

    /// Fail-closed gate fed by AppModel's legacy detection at launch, before
    /// every explicit enable and on each refresh. Detection stops a running
    /// chain; after removal the saved or pending enable continues.
    func setLegacyComponentsDetected(_ detected: Bool) {
        guard legacyComponentsBlocking != detected else { return }
        legacyComponentsBlocking = detected
        if detected {
            disable(reason: .stop, preservePreference: true)
            showLegacyComponentsState()
            return
        }
        if phase == .legacyComponentsDetected {
            phase = .disabled
            detail = "早期组件已移除；可以启用原生双 Option。"
        }
        if pendingUserEnable, lifecycleActivationAllowed, !enableInProgress,
           !isPaused, !awaitingCaptureStop {
            Task { await enable(promptForAccessibility: false) }
        } else {
            resumeIfEnabled()
        }
    }

    private func showLegacyComponentsState() {
        guard !awaitingCaptureStop else { return }
        phase = .legacyComponentsDetected
        detail = Self.legacyComponentsDetail
    }

    static let cloudCredentialDetail = "请先配置火山密钥：在句译的“翻译方式”中打开火山云端设置并保存访问密钥。"

    /// Switching engines keeps the native chain running. The translation in
    /// flight is cancelled and the overlay's generation gate drops any late
    /// result. Apple readiness is re-checked on the next trigger; selecting
    /// Volcengine without a stored credential stops the chain with a clear
    /// "configure the key" state. Nothing falls back to the other engine.
    func setEngine(_ choice: NativeTranslationEngineChoice) {
        guard engine != choice else { return }
        engine = choice
        cancelPipeline(dismissOverlay: true)
        preflight.invalidateAppleReadiness()
        let credentialStateWasShown = cloudCredentialRequired
        cloudCredentialRequired = false
        switch choice {
        case .apple:
            volc.forgetCredentials()
            if credentialStateWasShown && phase == .unavailable {
                phase = .disabled
                detail = "原生双 Option 尚未启用。"
            }
        case .volc:
            clearAppleOnlyState()
        }
        if phase == .active {
            if choice == .volc { verifyCloudCredentialWhileRunning() }
        } else {
            resumeIfEnabled()
        }
    }

    /// The stored Volcengine credential was saved, replaced or removed.
    func cloudCredentialsDidChange() {
        volc.forgetCredentials()
        guard engine == .volc, cloudCredentialRequired else { return }
        cloudCredentialRequired = false
        if phase == .unavailable {
            phase = .disabled
            detail = "火山密钥已保存；可以启用原生双 Option。"
        }
        // Continue an enable the user already asked for, exactly like the
        // return from System Settings does; otherwise resume a saved choice.
        if pendingUserEnable, lifecycleActivationAllowed, !enableInProgress, !isPaused {
            Task { await enable(promptForAccessibility: false) }
        } else {
            resumeIfEnabled()
        }
    }

    /// Apple language preparation and readiness faults do not apply to the
    /// cloud engine and must not block it.
    private func clearAppleOnlyState() {
        if isPreparingLanguages || pendingLanguagePreparation {
            // Drops the preparation result; the system request is cancelled.
            lifecycleGeneration &+= 1
            isPreparingLanguages = false
            pendingLanguagePreparation = false
            apple.cancelCurrent()
        }
        pendingAppleFailure = nil
        guard appleReadinessIssue != nil else { return }
        appleReadinessIssue = nil
        if phase == .languagePackRequired || phase == .unsupported || phase == .unavailable {
            phase = .disabled
            detail = "已切换到火山云端；启用原生双 Option 后即可翻译。"
        }
    }

    private func verifyCloudCredentialWhileRunning() {
        let generation = lifecycleGeneration
        Task {
            let available = await volc.hasCredentials()
            guard !available, generation == lifecycleGeneration, engine == .volc,
                  phase == .active else { return }
            requireCloudCredential()
        }
    }

    private func requireCloudCredential() {
        pendingUserEnable = false
        disable(reason: .stop, preservePreference: true)
        cloudCredentialRequired = true
        phase = .unavailable
        detail = Self.cloudCredentialDetail
    }

    func prepareLanguages() {
        guard !isPreparingLanguages, !enableInProgress,
              !isPaused, engine == .apple,
              activationAllowed else { return }
        let shouldResume = pendingUserEnable || isEnabled
            || UserDefaults.standard.bool(forKey: Self.enabledKey)
        disable(reason: .stop, preservePreference: true)
        if shouldResume {
            pendingUserEnable = true
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
        }
        appleReadinessIssue = .needsPreparation
        phase = .languagePackRequired
        isPreparingLanguages = true
        pendingLanguagePreparation = true
        beginLanguagePreparationIfQuiescent()
    }

    private func beginLanguagePreparationIfQuiescent() {
        guard pendingLanguagePreparation, isPreparingLanguages,
              !isPaused, engine == .apple,
              lifecycleActivationAllowed else { return }
        guard !awaitingCaptureStop else {
            detail = "正在安全停止取词，随后准备中英语言包…"
            return
        }
        guard monitor == nil else {
            pendingLanguagePreparation = false
            isPreparingLanguages = false
            phase = .unavailable
            detail = "尚未完成快捷键安全停止，请重新检查后再准备语言包。"
            return
        }
        pendingLanguagePreparation = false
        let generation = lifecycleGeneration
        detail = "请在 macOS 系统窗口中确认中英语言包。"
        Task {
            guard generation == lifecycleGeneration, isPreparingLanguages,
                  !isPaused, engine == .apple,
                  lifecycleActivationAllowed else { return }
            let result = await apple.prepareLanguages()
            guard generation == lifecycleGeneration,
                  !isPaused,
                  engine == .apple,
                  lifecycleActivationAllowed else { return }
            isPreparingLanguages = false
            switch result {
            case .prepared:
                appleReadinessIssue = nil
                detail = "语言包已准备好；现在可以启用原生双 Option。"
                phase = .disabled
                resumeIfEnabled()
            case .unsupported:
                appleReadinessIssue = .unsupported
                phase = .unsupported
                detail = "这台 Mac 不支持英语到简体中文的 Apple Translation。"
            case .cancelled:
                phase = .languagePackRequired
                detail = "已停止等待语言包准备。"
            default:
                phase = .languagePackRequired
                detail = "语言包尚未准备完成，请重试。"
            }
        }
    }

    /// The pause switch is owned by AppModel (UserDefaults); quitting writes
    /// a pause, so a relaunch waits for an explicit "恢复翻译".
    func setPaused(_ paused: Bool) {
        isPaused = paused
        if paused {
            disable(reason: .pause, preservePreference: true)
        } else {
            if legacyComponentsBlocking {
                showLegacyComponentsState()
            } else if let issue = appleReadinessIssue {
                phase = issue == .unsupported ? .unsupported
                    : (issue == .needsPreparation ? .languagePackRequired : .unavailable)
                detail = "Apple 离线翻译尚未准备好，请重新检查或准备语言包。"
            }
            resumeIfEnabled()
        }
        overlay.setPaused(paused)
    }

    func applicationBecameActive() {
        guard lifecycleActivationAllowed else { return }
        guard !isPreparingLanguages, appleReadinessIssue == nil else { return }
        guard phase == .active else {
            if pendingUserEnable,
               !enableInProgress,
               AccessibilityController.status == .authorized {
                Task { await enable(promptForAccessibility: false) }
                return
            }
            resumeIfEnabled()
            return
        }
        guard AccessibilityController.status == .authorized else {
            disable(reason: .authorizationRevoked, preservePreference: true)
            phase = .unavailable
            detail = "辅助功能权限已关闭；原生双 Option 已停止。"
            return
        }
        guard monitor?.refreshAuthorizationStatus() == true else {
            // A delayed delivery may have removed the monitor while trust was
            // absent. Restart through the diagnostic retry even if trust was
            // restored before this activation; never keep a false ready state.
            retryByUser()
            return
        }
    }

    func invalidate(_ reason: DeactivationReason) {
        disable(reason: reason, preservePreference: reason != .user)
    }

    private func enable(promptForAccessibility: Bool) async {
        guard !enableInProgress, !isPreparingLanguages,
              appleReadinessIssue == nil, !isPaused,
              activationAllowed else { return }
        enableInProgress = true
        let generation = lifecycleGeneration
        defer { enableInProgress = false }
        guard !awaitingCaptureStop else {
            resumeRequestedAfterRevocation = true
            UserDefaults.standard.set(true, forKey: Self.enabledKey)
            detail = "正在安全停止上一次取词，随后重新启用…"
            return
        }

        var authorization = AccessibilityController.status
        if authorization != .authorized, promptForAccessibility {
            phase = .requestingAccessibility
            detail = "请在系统设置中允许句译使用辅助功能。"
            authorization = AccessibilityController.requestAuthorization()
        }
        guard authorization == .authorized else {
            phase = .unavailable
            detail = "需要辅助功能权限才能读取你主动选中的文字。"
            return
        }
        guard generation == lifecycleGeneration,
              !isPaused,
              activationAllowed else { return }
        guard await selectedEngineIsReady(generation: generation) else { return }

        guard generation == lifecycleGeneration,
              !isPaused,
              activationAllowed,
              !awaitingCaptureStop else { return }
        guard startNativeEffect() else {
            phase = .unavailable
            detail = "原生快捷键没有启动。"
            return
        }
        pendingUserEnable = false
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        phase = .active
        detail = "已启用：选中英文后连按两次 Option。"
    }

    /// The enable condition of the selected engine: Apple needs its language
    /// resources; Volcengine needs a stored credential (no request is sent).
    /// Accessibility has already been granted for both. A switch while the
    /// check runs re-checks the newly selected engine.
    private func selectedEngineIsReady(generation: UInt64) async -> Bool {
        while true {
            let checked = engine
            switch checked {
            case .apple:
                let readiness = await apple.readiness()
                guard generation == lifecycleGeneration,
                      !isPaused, activationAllowed else { return false }
                guard engine == checked else { continue }
                switch readiness {
                case .installed:
                    preflight.recordAppleReadiness(installed: true)
                    return true
                case .needsPreparation:
                    appleReadinessIssue = .needsPreparation
                    phase = .languagePackRequired
                    detail = "需要先准备 Apple 英语到简体中文语言包。"
                    return false
                case .unsupported:
                    appleReadinessIssue = .unsupported
                    phase = .unsupported
                    detail = "这台 Mac 不支持英语到简体中文的 Apple Translation。"
                    return false
                case .unavailable:
                    appleReadinessIssue = .unavailable
                    phase = .unavailable
                    detail = "暂时无法检查 Apple Translation。"
                    return false
                }
            case .volc:
                let available = await volc.hasCredentials()
                guard generation == lifecycleGeneration,
                      !isPaused, activationAllowed else { return false }
                guard engine == checked else { continue }
                guard available else {
                    cloudCredentialRequired = true
                    phase = .unavailable
                    detail = Self.cloudCredentialDetail
                    return false
                }
                cloudCredentialRequired = false
                return true
            }
        }
    }

    private func startNativeEffect() -> Bool {
        guard monitor == nil else { return true }
        let candidate = NativeOptionMonitor(
            recognitionInvalidationHandler: { [weak self] in
                self?.cancelPipeline(dismissOverlay: true)
            },
            recognitionHandler: { [weak self] target in
                self?.beginPipeline(target: target)
            }
        )
        switch candidate.start() {
        case .started, .alreadyRunning:
            monitor = candidate
            return true
        case .accessibilityRequired, .monitorUnavailable:
            candidate.stop()
            return false
        }
    }

    /// Returns whether the selection capture has quiesced. Otherwise the
    /// capture's completion calls `finishDeferredRevocation`.
    private func stopNativeEffect() -> Bool {
        monitor?.stop()
        monitor = nil
        cancelPipeline(dismissOverlay: true)
        let captureIsQuiescent = capture.cancelAll { [weak self] in
            Task { @MainActor in self?.finishDeferredRevocation() }
        }
        apple.cancelCurrent()
        volc.cancelCurrent()
        return captureIsQuiescent
    }

    private func finishDeferredRevocation() {
        guard awaitingCaptureStop else { return }
        awaitingCaptureStop = false
        if pendingLanguagePreparation {
            beginLanguagePreparationIfQuiescent()
            return
        }
        if appleReadinessIssue != nil {
            presentPendingAppleFailure()
            return
        }
        if legacyComponentsBlocking {
            showLegacyComponentsState()
            return
        }
        if cloudCredentialRequired {
            phase = .unavailable
            detail = Self.cloudCredentialDetail
            return
        }
        let shouldResume = resumeRequestedAfterRevocation
            && UserDefaults.standard.bool(forKey: Self.enabledKey)
            && !isPaused
            && activationAllowed
        resumeRequestedAfterRevocation = false
        phase = .disabled
        if shouldResume {
            detail = "原生双 Option 已安全停止，正在重新启用…"
            resumeIfEnabled()
            return
        }
        if isPaused {
            detail = "原生双 Option 已暂停。"
        } else if UserDefaults.standard.bool(forKey: Self.enabledKey) {
            detail = "原生双 Option 已安全停止；系统恢复后会重新启用。"
        } else {
            detail = "原生双 Option 已停用。"
        }
    }

    private func disable(
        reason: DeactivationReason,
        preservePreference: Bool = false
    ) {
        lifecycleGeneration &+= 1
        resumeRequestedAfterRevocation = false
        pendingAppleFailure = nil
        pendingLanguagePreparation = false
        if isPreparingLanguages {
            isPreparingLanguages = false
            apple.cancelCurrent()
        }
        if !stopNativeEffect() { awaitingCaptureStop = true }
        // Pause, sleep, session changes, permission loss, language
        // preparation, early components and failures all pass through here.
        preflight.reset()
        if !preservePreference {
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            pendingUserEnable = false
            appleReadinessIssue = nil
            cloudCredentialRequired = false
        }
        if awaitingCaptureStop {
            phase = .unavailable
            detail = "原生快捷键已停止，正在等待上一次取词结束。请保持句译运行。"
        } else if legacyComponentsBlocking {
            showLegacyComponentsState()
        } else if phase != .unavailable {
            phase = .disabled
            detail = preservePreference
                ? "原生双 Option 已暂停；恢复后会重新启用。"
                : "原生双 Option 已停用。"
        }
    }

    private func beginPipeline(target: NativeSelectionTarget) {
        guard phase == .active, !legacyComponentsBlocking, !isPreparingLanguages,
              appleReadinessIssue == nil else { return }
        cancelPipeline(dismissOverlay: true)
        pipelineGeneration &+= 1
        let generation = pipelineGeneration
        let requestedEngine = engine
        // After a successful check, go straight to capture: no system API is
        // awaited between recognition and `capture.capture`. The cloud engine
        // has no Apple readiness precondition.
        let needsReadinessCheck = requestedEngine == .apple
            && preflight.decision == .checkAppleReadiness
        translationTask = Task { [weak self] in
            guard let self else { return }
            if needsReadinessCheck {
                let readiness = await apple.readiness()
                guard generation == pipelineGeneration else { return }
                guard readiness == .installed else {
                    self.suspendForAppleFailure(target: target, readiness: readiness)
                    return
                }
                preflight.recordAppleReadiness(installed: true)
            }
            guard generation == pipelineGeneration else { return }
            guard let app = NSRunningApplication(processIdentifier: target.processIdentifier),
                  NativeSelectionTarget(application: app)?.hasSameProcess(as: target) == true,
                  let panelGeneration = overlay.beginNativeTranslation(
                    sourceApplication: app,
                    anchorPoint: Self.overlayAnchorPoint(for: target),
                    startsWithSelectionCapture: true,
                    onDismiss: { [weak self] _ in self?.overlayWasDismissed(generation) }
                  ) else { return }
            overlayGeneration = panelGeneration
            capture.capture(target: target) { [weak self] result in
                self?.receiveCapture(
                    result,
                    target: target,
                    engine: requestedEngine,
                    generation: generation
                )
            }
        }
    }

    private func suspendForAppleFailure(
        target: NativeSelectionTarget,
        readiness: NativeAppleProductionReadiness
    ) {
        disable(reason: .stop, preservePreference: true)
        appleReadinessIssue = readiness
        let error: NativeTranslationOverlayBackendError
        switch readiness {
        case .needsPreparation:
            phase = .languagePackRequired
            detail = "需要准备 Apple 中英语言包；原生双 Option 已安全停止。"
            error = .appleNotReady
        case .unsupported:
            phase = .unsupported
            detail = "这台 Mac 不支持英语到简体中文的 Apple Translation。"
            error = .appleUnsupported
        case .installed, .unavailable:
            phase = .unavailable
            detail = "暂时无法使用 Apple 离线翻译，请在诊断中重新检查。"
            error = .appleFailed
        }
        pendingAppleFailure = (target, error)
        presentPendingAppleFailure()
    }

    private func presentPendingAppleFailure() {
        guard !awaitingCaptureStop,
              let failure = pendingAppleFailure,
              !isPaused, engine == .apple, lifecycleActivationAllowed else { return }
        pendingAppleFailure = nil
        // Stopping invalidates the old pipeline and closes its panel. Create
        // the actionable error only after that barrier, with a fresh callback.
        let generation = pipelineGeneration
        let target = failure.target
        guard let app = NSRunningApplication(processIdentifier: target.processIdentifier),
              NativeSelectionTarget(application: app)?.hasSameProcess(as: target) == true,
              let panelGeneration = overlay.beginNativeTranslation(
                sourceApplication: app,
                anchorPoint: Self.overlayAnchorPoint(for: target),
                onDismiss: { [weak self] _ in self?.overlayWasDismissed(generation) }
              ) else { return }
        overlayGeneration = panelGeneration
        overlay.resolveNativeTranslation(
            .response(.init(
                requestedEngine: .apple,
                actualEngine: nil,
                result: nil,
                elapsedMilliseconds: nil,
                error: failure.error
            )),
            generation: panelGeneration
        )
    }

    private func receiveCapture(
        _ result: NativeSelectionResult,
        target: NativeSelectionTarget,
        engine requestedEngine: NativeTranslationEngineChoice,
        generation: UInt64
    ) {
        guard generation == pipelineGeneration,
              let panelGeneration = overlayGeneration else { return }
        guard let app = NSRunningApplication(
                processIdentifier: target.processIdentifier
              ), NativeSelectionTarget(application: app)?.hasSameProcess(as: target) == true else {
            cancelPipeline(dismissOverlay: true)
            return
        }
        switch result {
        case let .success(text, didTruncate):
            overlay.nativeSelectionCaptured(generation: panelGeneration, sourceText: text)
            startTimeout(
                generation: generation,
                panelGeneration: panelGeneration,
                engine: requestedEngine
            )
            let started = ProcessInfo.processInfo.systemUptime
            translationTask = Task { [weak self] in
                guard !Task.isCancelled, let self,
                      generation == pipelineGeneration,
                      overlayGeneration == panelGeneration else { return }
                let response: NativeTranslationOverlayResponse
                switch requestedEngine {
                case .apple:
                    let result = await apple.translate(text)
                    guard generation == pipelineGeneration,
                          overlayGeneration == panelGeneration else { return }
                    let elapsed = Self.elapsedMilliseconds(since: started)
                    switch result {
                    case let .translated(value):
                        response = .init(
                            requestedEngine: .apple,
                            actualEngine: .apple,
                            result: value,
                            elapsedMilliseconds: elapsed,
                            captureDidTruncate: didTruncate,
                            inputTruncated: didTruncate
                        )
                    case .needsPreparation, .unsupported:
                        suspendForAppleFailure(
                            target: target,
                            readiness: result == .needsPreparation ? .needsPreparation : .unsupported
                        )
                        return
                    case .cancelled:
                        return
                    default:
                        preflight.invalidateAppleReadiness()
                        response = .init(
                            requestedEngine: .apple,
                            actualEngine: nil,
                            result: nil,
                            elapsedMilliseconds: elapsed,
                            error: .appleFailed,
                            captureDidTruncate: didTruncate,
                            inputTruncated: didTruncate
                        )
                    }
                case .volc:
                    let outcome = await volc.translate(text)
                    guard generation == pipelineGeneration,
                          overlayGeneration == panelGeneration else { return }
                    let elapsed = Self.elapsedMilliseconds(since: started)
                    switch outcome {
                    case let .translated(value):
                        response = .init(
                            requestedEngine: .volc,
                            actualEngine: .volc,
                            result: value,
                            elapsedMilliseconds: elapsed,
                            captureDidTruncate: didTruncate,
                            inputTruncated: didTruncate
                        )
                    case let .failed(error):
                        // No fallback: a cloud failure is shown as such and
                        // the selection is never sent to another engine.
                        response = .init(
                            requestedEngine: .volc,
                            actualEngine: nil,
                            result: nil,
                            elapsedMilliseconds: elapsed,
                            error: error.overlayError,
                            captureDidTruncate: didTruncate,
                            inputTruncated: didTruncate
                        )
                    case .cancelled:
                        return
                    }
                }
                timeoutTask?.cancel()
                timeoutTask = nil
                overlay.resolveNativeTranslation(
                    .response(response),
                    generation: panelGeneration
                )
            }
        default:
            timeoutTask?.cancel()
            timeoutTask = nil
            overlay.resolveNativeTranslation(
                .capture(Self.captureStatus(result)),
                generation: panelGeneration
            )
        }
    }

    /// One 12 s deadline for both engines. On expiry the in-flight Apple
    /// request or URLSession task is cancelled and the engine's own timeout
    /// copy is shown; nothing is retried with the other engine.
    private func startTimeout(
        generation: UInt64,
        panelGeneration: Int,
        engine requestedEngine: NativeTranslationEngineChoice
    ) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.translationTimeout)
            guard !Task.isCancelled, let self,
                  generation == pipelineGeneration,
                  overlayGeneration == panelGeneration else { return }
            capture.cancelAll()
            translationTask?.cancel()
            let error: NativeTranslationOverlayBackendError
            switch requestedEngine {
            case .apple:
                apple.cancelCurrent()
                preflight.invalidateAppleReadiness()
                error = .appleTimedOut
            case .volc:
                volc.cancelCurrent()
                error = .volcTimeout
            }
            overlay.resolveNativeTranslation(
                .response(.init(
                    requestedEngine: requestedEngine.overlayEngine,
                    actualEngine: nil,
                    result: nil,
                    elapsedMilliseconds: nil,
                    error: error
                )),
                generation: panelGeneration
            )
        }
    }

    private static func elapsedMilliseconds(since started: TimeInterval) -> Double {
        max(0, (ProcessInfo.processInfo.systemUptime - started) * 1_000).rounded()
    }

    private func overlayWasDismissed(_ generation: UInt64) {
        guard generation == pipelineGeneration else { return }
        overlayGeneration = nil
        capture.cancelAll()
        apple.cancelCurrent()
        volc.cancelCurrent()
        translationTask?.cancel()
        timeoutTask?.cancel()
        translationTask = nil
        timeoutTask = nil
        pipelineGeneration &+= 1
    }

    private func cancelPipeline(dismissOverlay: Bool) {
        pipelineGeneration &+= 1
        capture.cancelAll()
        apple.cancelCurrent()
        volc.cancelCurrent()
        translationTask?.cancel()
        timeoutTask?.cancel()
        translationTask = nil
        timeoutTask = nil
        let panelGeneration = overlayGeneration
        overlayGeneration = nil
        if dismissOverlay, let panelGeneration {
            overlay.cancelNativeTranslation(
                generation: panelGeneration,
                reason: .stop
            )
        }
    }

    private static func captureStatus(
        _ result: NativeSelectionResult
    ) -> NativeTranslationOverlayCaptureStatus {
        switch result {
        case .accessibilityRequired: return .accessibilityRequired
        case .noFocusedElement: return .noFocusedElement
        case .noSelection: return .noSelection
        case .unsupported: return .unsupported
        case .secureField: return .secureField
        case .temporarilyUnavailable, .internalFailure: return .temporarilyUnavailable
        case .cancelled: return .cancelled
        case .success: return .temporarilyUnavailable
        }
    }

    private static func overlayAnchorPoint(
        for target: NativeSelectionTarget
    ) -> CGPoint? {
        guard let point = target.selectionPoint,
              let primaryScreen = NSScreen.screens.first else { return nil }
        return CGPoint(
            x: point.x,
            y: primaryScreen.frame.maxY - point.y
        )
    }
}
