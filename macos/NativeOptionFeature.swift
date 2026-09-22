import AppKit
import Combine
import Foundation

/// The single production owner for native Apple selection translation.
/// It installs the Option monitor only after the existing durable owner
/// protocol proves that Hammerspoon has stopped its watcher, request and popup.
@MainActor
final class NativeProductionTranslationCoordinator: ObservableObject {
    enum Phase: Equatable {
        case disabled
        case requestingAccessibility
        case waitingForHammerspoon
        case active
        case languagePackRequired
        case unsupported
        case unavailable
    }

    static let shared = NativeProductionTranslationCoordinator()

    @Published private(set) var phase: Phase = .disabled
    @Published private(set) var detail = "原生双 Option 尚未启用。"
    @Published private(set) var isPreparingLanguages = false
    @Published private(set) var recoveryPauseHeld = false

    /// Writes the existing hs-paused switch through AppModel, which owns its
    /// user-visible state. No new owner file or protocol is introduced.
    var legacyRecoveryPauseHandler: ((Bool) -> Bool)?

    private static let enabledKey = "nativeAppleDoubleOptionEnabled"
    private static let ownerPollInterval: TimeInterval = 0.2
    private static let translationTimeout: Duration = .seconds(12)

    private let effect = NativeProductionOwnerEffect()
    private let statusReader: NativeOwnerHandoffStatusReader?
    private let activation: NativeOwnerActivationCoordinator?
    private let capture = NativeSelectionCaptureCoordinator()
    private let apple = NativeAppleProductionTranslationService.shared
    private let overlay = NativeTranslationOverlayController.shared

    private var monitor: NativeOptionMonitor?
    private var ownerTimer: Timer?
    private var ownerStartedAt: TimeInterval?
    private var enableInProgress = false
    private var pendingUserEnable = false
    private var resumeRequestedAfterRevocation = false
    private var appleReadinessIssue: NativeAppleProductionReadiness?
    private var pendingLanguagePreparation = false
    private var pendingAppleFailure: (
        target: NativeSelectionTarget,
        error: NativeTranslationOverlayBackendError
    )?
    private var lifecycleGeneration: UInt64 = 0
    private var isPaused = false
    private var appleEngineSelected = true
    private var shortcutDeploymentReady = false
    private var lifecycleActivationAllowed = false
    private var pipelineGeneration: UInt64 = 0
    private var overlayGeneration: Int?
    private var translationTask: Task<Void, Never>?
    private var timeoutTask: Task<Void, Never>?

    private init() {
        if let store = NativeOwnerHandoffStore.live(),
           let reader = NativeOwnerHandoffStatusReader.live() {
            activation = NativeOwnerActivationCoordinator(
                workflow: NativeOwnerHandoffWorkflow(store: store),
                effect: effect
            )
            statusReader = reader
        } else {
            activation = nil
            statusReader = nil
        }

        effect.startHandler = { [weak self] in self?.startNativeEffect() ?? .notStarted }
        effect.stopHandler = { [weak self] in self?.stopNativeEffect() ?? .stopped }
    }

    var isEnabled: Bool { phase == .active }

    var actionTitle: String {
        switch phase {
        case .active: return "停用原生双 Option"
        case .requestingAccessibility, .waitingForHammerspoon: return "正在启用…"
        default: return "启用原生双 Option"
        }
    }

    var actionIsEnabled: Bool {
        !enableInProgress
            && !isPreparingLanguages
            && phase != .requestingAccessibility
            && phase != .waitingForHammerspoon
    }

    func enableByUser() {
        guard shortcutDeploymentReady else {
            phase = .unavailable
            detail = "请先部署并重新载入当前快捷键模块。"
            return
        }
        guard actionIsEnabled, !isPaused, appleEngineSelected else { return }
        if phase != .active, activation?.phase == .nativeActive {
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
    /// enable/disable toggle. An uncertain capture stop retains the owner
    /// lease until `finishDeferredRevocation` can safely resume this request.
    func retryByUser() {
        guard actionIsEnabled, !isPaused, appleEngineSelected else { return }
        guard shortcutDeploymentReady else {
            phase = .unavailable
            detail = "请先部署并重新载入当前快捷键模块。"
            return
        }
        guard holdLegacyPauseForRecovery() else { return }
        pendingUserEnable = true
        UserDefaults.standard.set(true, forKey: Self.enabledKey)
        disable(reason: .stop, preservePreference: true)
        appleReadinessIssue = nil
        resumeIfEnabled()
    }

    /// Transfer an existing user pause to Apple recovery without opening a
    /// 1→0→1 legacy-watcher window. AppModel keeps hs-paused at 1 until the
    /// normal fresh owner acknowledgement has activated native translation.
    func resumeAppleRecoveryByUser() -> Bool {
        guard isPaused, appleEngineSelected,
              appleReadinessIssue != nil, actionIsEnabled else { return false }
        recoveryPauseHeld = true
        isPaused = false
        overlay.setPaused(false)
        retryByUser()
        return true
    }

    func resumeIfEnabled() {
        guard !isPreparingLanguages, appleReadinessIssue == nil else { return }
        if activation?.phase == .idle || activation?.phase == .recoveryRequired {
            activation?.recoverAndReturnToLegacy()
        }
        guard shortcutDeploymentReady else {
            if phase != .disabled {
                phase = .disabled
                detail = "快捷键模块需要更新后才能恢复原生双 Option。"
            }
            return
        }
        guard lifecycleActivationAllowed else { return }
        guard UserDefaults.standard.bool(forKey: Self.enabledKey) else {
            if activation?.phase == .returnedToLegacy {
                phase = .disabled
                detail = "原生双 Option 已停用；Hammerspoon 可恢复响应。"
            }
            return
        }
        guard !isPaused, appleEngineSelected else { return }
        if activation?.phase == .revocationRequired {
            resumeRequestedAfterRevocation = true
            return
        }
        guard !enableInProgress,
              phase != .active,
              phase != .requestingAccessibility,
              phase != .waitingForHammerspoon else { return }
        resumeRequestedAfterRevocation = false
        Task { await enable(promptForAccessibility: false) }
    }

    func setShortcutDeploymentReady(_ ready: Bool) {
        guard shortcutDeploymentReady != ready else { return }
        shortcutDeploymentReady = ready
        if !ready {
            pendingUserEnable = false
            disable(reason: .stop, preservePreference: true)
        }
    }

    func setLifecycleActivationAllowed(
        _ allowed: Bool,
        reason: NativeOwnerActivationCoordinator.DeactivationReason? = nil
    ) {
        lifecycleActivationAllowed = allowed
        if !allowed, let reason {
            invalidate(reason)
        }
    }

    func setAppleEngineSelected(_ selected: Bool) {
        guard appleEngineSelected != selected else { return }
        appleEngineSelected = selected
        if selected {
            resumeIfEnabled()
        } else {
            if recoveryPauseHeld {
                recoveryPauseHeld = false
                isPaused = true
                overlay.setPaused(true)
            }
            pendingUserEnable = false
            disable(reason: .user)
        }
    }

    func prepareLanguages() {
        guard !isPreparingLanguages, !enableInProgress,
              !isPaused, appleEngineSelected,
              lifecycleActivationAllowed else { return }
        let shouldResume = pendingUserEnable || isEnabled
            || UserDefaults.standard.bool(forKey: Self.enabledKey)
        guard holdLegacyPauseForRecovery() else { return }
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
              !isPaused, appleEngineSelected,
              lifecycleActivationAllowed else { return }
        guard activation?.phase != .revocationRequired else {
            detail = "正在安全停止取词，随后准备中英语言包…"
            return
        }
        guard activation?.phase != .recoveryRequired,
              activation?.holdsOwnerLease != true,
              monitor == nil else {
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
                  !isPaused, appleEngineSelected,
                  lifecycleActivationAllowed else { return }
            let result = await apple.prepareLanguages()
            guard generation == lifecycleGeneration,
                  !isPaused,
                  appleEngineSelected,
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

    func setPaused(_ paused: Bool, byUser: Bool = false) {
        if byUser {
            // A user's pause (including Quit) takes ownership of the existing
            // pause file. This operation must never later clear it.
            recoveryPauseHeld = false
        } else if recoveryPauseHeld && paused {
            return
        } else if recoveryPauseHeld {
            // An external change to the pause switch cancels this operation.
            recoveryPauseHeld = false
            disable(reason: .user)
        }
        isPaused = paused
        if paused {
            disable(reason: .pause, preservePreference: true)
        } else {
            if let issue = appleReadinessIssue {
                guard holdLegacyPauseForRecovery() else { return }
                phase = issue == .unsupported ? .unsupported
                    : (issue == .needsPreparation ? .languagePackRequired : .unavailable)
                detail = "Apple 离线翻译尚未准备好，请重新检查或准备语言包。"
            }
            resumeIfEnabled()
        }
        overlay.setPaused(paused)
    }

    private func holdLegacyPauseForRecovery() -> Bool {
        if recoveryPauseHeld { return true }
        guard !isPaused else { return false }
        recoveryPauseHeld = true
        guard legacyRecoveryPauseHandler?(true) == true else {
            recoveryPauseHeld = false
            // Without a durable pause, do not return the owner request: the
            // old watcher could otherwise restart. Keep the conservative
            // activation lease while stopping this process's effect.
            _ = stopNativeEffect()
            phase = .unavailable
            detail = "无法安全暂停旧快捷键。原生取词已停止，请检查配置目录后重试。"
            return false
        }
        return true
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
        guard AccessibilityController.status == .authorized,
              monitor?.refreshAuthorizationStatus() == true else {
            disable(reason: .authorizationRevoked, preservePreference: true)
            phase = .unavailable
            detail = "辅助功能权限已关闭；原生双 Option 已停止。"
            return
        }
    }

    func invalidate(_ reason: NativeOwnerActivationCoordinator.DeactivationReason) {
        disable(reason: reason, preservePreference: reason != .user)
    }

    private func enable(promptForAccessibility: Bool) async {
        guard !enableInProgress, !isPreparingLanguages,
              appleReadinessIssue == nil, !isPaused, appleEngineSelected,
              shortcutDeploymentReady,
              lifecycleActivationAllowed else { return }
        enableInProgress = true
        let generation = lifecycleGeneration
        defer { enableInProgress = false }
        guard let activation, statusReader != nil else {
            phase = .unavailable
            detail = "无法建立与 Hammerspoon 的安全 owner 交接。"
            return
        }
        guard activation.phase != .revocationRequired else {
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
              appleEngineSelected,
              shortcutDeploymentReady,
              lifecycleActivationAllowed else { return }
        let readiness = await apple.readiness()
        guard generation == lifecycleGeneration,
              !isPaused, appleEngineSelected,
              shortcutDeploymentReady, lifecycleActivationAllowed else { return }
        switch readiness {
        case .installed:
            break
        case .needsPreparation:
            guard holdLegacyPauseForRecovery() else { return }
            appleReadinessIssue = .needsPreparation
            phase = .languagePackRequired
            detail = "需要先准备 Apple 英语到简体中文语言包。"
            return
        case .unsupported:
            guard holdLegacyPauseForRecovery() else { return }
            appleReadinessIssue = .unsupported
            phase = .unsupported
            detail = "这台 Mac 不支持英语到简体中文的 Apple Translation。"
            return
        case .unavailable:
            guard holdLegacyPauseForRecovery() else { return }
            appleReadinessIssue = .unavailable
            phase = .unavailable
            detail = "暂时无法检查 Apple Translation。"
            return
        }

        guard generation == lifecycleGeneration,
              !isPaused,
              appleEngineSelected,
              shortcutDeploymentReady,
              lifecycleActivationAllowed else { return }

        if activation.phase == .recoveryRequired {
            activation.recoverAndReturnToLegacy()
        }
        activation.beginHandoff()
        if activation.phase == .recoveryRequired {
            activation.recoverAndReturnToLegacy()
            if activation.phase == .returnedToLegacy {
                activation.beginHandoff()
            }
        }
        guard activation.phase == .waitingForLegacy else {
            syncOwnerFailure()
            return
        }
        phase = .waitingForHammerspoon
        detail = "正在让 Hammerspoon 停止旧快捷键、请求和浮窗…"
        ownerStartedAt = ProcessInfo.processInfo.systemUptime
        pollOwner()
    }

    private func pollOwner() {
        guard let activation, let statusReader,
              activation.phase == .waitingForLegacy,
              let ownerStartedAt else { return }
        if ProcessInfo.processInfo.systemUptime - ownerStartedAt
            >= NativeOwnerHandoffWorkflow.acknowledgementDeadline {
            activation.handoffTimedOut()
            stopOwnerPolling()
            syncOwnerFailure()
            return
        }
        switch statusReader.read() {
        case .absent:
            activation.ingestLegacyStatus(nil, now: Date().timeIntervalSince1970)
        case let .present(data):
            activation.ingestLegacyStatus(data, now: Date().timeIntervalSince1970)
        case .unavailable:
            activation.statusBecameUnavailable()
        }
        if activation.phase == .readyToActivate {
            activation.activate()
            stopOwnerPolling()
            if activation.phase == .nativeActive {
                if recoveryPauseHeld {
                    guard legacyRecoveryPauseHandler?(false) == true else {
                        _ = stopNativeEffect()
                        phase = .unavailable
                        detail = "翻译已准备好，但无法恢复快捷键状态，请重新检查。"
                        return
                    }
                    recoveryPauseHeld = false
                }
                pendingUserEnable = false
                UserDefaults.standard.set(true, forKey: Self.enabledKey)
                phase = .active
                detail = "已启用：选中英文后连按两次 Option。"
            } else {
                syncOwnerFailure()
            }
            return
        }
        guard activation.phase == .waitingForLegacy else {
            stopOwnerPolling()
            syncOwnerFailure()
            return
        }
        ownerTimer?.invalidate()
        ownerTimer = Timer.scheduledTimer(
            withTimeInterval: Self.ownerPollInterval,
            repeats: false
        ) { [weak self] _ in
            Task { @MainActor in self?.pollOwner() }
        }
    }

    private func syncOwnerFailure() {
        phase = .unavailable
        switch activation?.phase {
        case .busy:
            detail = "另一个句译进程正在使用原生快捷键。"
        case .recoveryRequired:
            detail = "发现未完成的 owner 交接；原生快捷键保持关闭。"
        default:
            detail = "Hammerspoon 未能安全让出；原生快捷键没有启动。"
        }
    }

    private func startNativeEffect() -> NativeOwnerActivationCoordinator.StartResult {
        guard monitor == nil else { return .started }
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
            return .started
        case .accessibilityRequired, .monitorUnavailable:
            candidate.stop()
            return .notStarted
        }
    }

    private func stopNativeEffect() -> NativeOwnerActivationCoordinator.StopResult {
        monitor?.stop()
        monitor = nil
        cancelPipeline(dismissOverlay: true)
        let captureIsQuiescent = capture.cancelAll { [weak self] in
            Task { @MainActor in self?.finishDeferredRevocation() }
        }
        apple.cancelCurrent()
        return captureIsQuiescent ? .stopped : .uncertain
    }

    private func finishDeferredRevocation() {
        activation?.retryRevocation()
        guard activation?.phase == .returnedToLegacy else { return }
        if pendingLanguagePreparation {
            beginLanguagePreparationIfQuiescent()
            return
        }
        if appleReadinessIssue != nil {
            presentPendingAppleFailure()
            return
        }
        let shouldResume = resumeRequestedAfterRevocation
            && UserDefaults.standard.bool(forKey: Self.enabledKey)
            && !isPaused
            && appleEngineSelected
            && shortcutDeploymentReady
            && lifecycleActivationAllowed
        resumeRequestedAfterRevocation = false
        phase = .disabled
        if shouldResume {
            detail = "原生双 Option 已安全停止，正在重新启用…"
            resumeIfEnabled()
            return
        }
        if isPaused {
            detail = "原生双 Option 已暂停；恢复后会重新安全交接。"
        } else if UserDefaults.standard.bool(forKey: Self.enabledKey),
                  appleEngineSelected {
            detail = "原生双 Option 已安全停止；系统恢复后会重新启用。"
        } else {
            detail = "原生双 Option 已停用；Hammerspoon 可恢复响应。"
        }
    }

    private func disable(
        reason: NativeOwnerActivationCoordinator.DeactivationReason,
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
        stopOwnerPolling()
        activation?.deactivate(reason)
        // A terminal error panel may outlive an already-stopped owner. Close
        // it before a new preparation/retry so its dismissal cannot cancel
        // the replacement Apple request.
        cancelPipeline(dismissOverlay: true)
        if activation?.phase == .recoveryRequired {
            activation?.recoverAndReturnToLegacy()
        }
        if !preservePreference {
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            pendingUserEnable = false
            appleReadinessIssue = nil
        }
        if activation?.phase == .recoveryRequired ||
            activation?.phase == .revocationRequired {
            phase = .unavailable
            detail = "原生快捷键已停止，但暂时无法确认 Hammerspoon 已恢复。请保持句译运行并重试。"
        } else if phase != .unavailable {
            phase = .disabled
            detail = preservePreference
                ? "原生双 Option 已暂停；恢复后会重新安全交接。"
                : "原生双 Option 已停用；Hammerspoon 可恢复响应。"
        }
    }

    private func stopOwnerPolling() {
        ownerTimer?.invalidate()
        ownerTimer = nil
        ownerStartedAt = nil
    }

    private func beginPipeline(target: NativeSelectionTarget) {
        guard phase == .active, !isPreparingLanguages,
              appleReadinessIssue == nil else { return }
        cancelPipeline(dismissOverlay: true)
        pipelineGeneration &+= 1
        let generation = pipelineGeneration
        translationTask = Task { [weak self] in
            guard let self else { return }
            let readiness = await apple.readiness()
            guard generation == pipelineGeneration else { return }
            guard readiness == .installed else {
                self.suspendForAppleFailure(target: target, readiness: readiness)
                return
            }
            capture.capture(target: target) { [weak self] result in
                self?.receiveCapture(
                    result,
                    target: target,
                    generation: generation
                )
            }
        }
    }

    private func suspendForAppleFailure(
        target: NativeSelectionTarget,
        readiness: NativeAppleProductionReadiness
    ) {
        guard holdLegacyPauseForRecovery() else { return }
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
        guard activation?.phase != .revocationRequired,
              activation?.phase != .recoveryRequired,
              let failure = pendingAppleFailure,
              !isPaused, appleEngineSelected, lifecycleActivationAllowed else { return }
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
        generation: UInt64
    ) {
        guard generation == pipelineGeneration,
              let app = NSRunningApplication(
                processIdentifier: target.processIdentifier
              ), NativeSelectionTarget(application: app)?.hasSameProcess(as: target) == true,
              let panelGeneration = overlay.beginNativeTranslation(
                sourceApplication: app,
                anchorPoint: Self.overlayAnchorPoint(for: target),
                onDismiss: { [weak self] _ in self?.overlayWasDismissed(generation) }
              ) else { return }
        overlayGeneration = panelGeneration
        switch result {
        case let .success(text, didTruncate):
            startTimeout(generation: generation, panelGeneration: panelGeneration)
            let started = ProcessInfo.processInfo.systemUptime
            translationTask = Task { [weak self] in
                guard !Task.isCancelled, let self,
                      generation == pipelineGeneration,
                      overlayGeneration == panelGeneration else { return }
                let result = await apple.translate(text)
                guard generation == pipelineGeneration,
                      overlayGeneration == panelGeneration else { return }
                let elapsed = max(
                    0,
                    (ProcessInfo.processInfo.systemUptime - started) * 1_000
                ).rounded()
                let response: NativeTranslationOverlayResponse
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

    private func startTimeout(generation: UInt64, panelGeneration: Int) {
        timeoutTask?.cancel()
        timeoutTask = Task { [weak self] in
            try? await Task.sleep(for: Self.translationTimeout)
            guard !Task.isCancelled, let self,
                  generation == pipelineGeneration,
                  overlayGeneration == panelGeneration else { return }
            capture.cancelAll()
            apple.cancelCurrent()
            translationTask?.cancel()
            overlay.resolveNativeTranslation(
                .response(.init(
                    requestedEngine: .apple,
                    actualEngine: nil,
                    result: nil,
                    elapsedMilliseconds: nil,
                    error: .appleTimedOut
                )),
                generation: panelGeneration
            )
        }
    }

    private func overlayWasDismissed(_ generation: UInt64) {
        guard generation == pipelineGeneration else { return }
        overlayGeneration = nil
        capture.cancelAll()
        apple.cancelCurrent()
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

@MainActor
private final class NativeProductionOwnerEffect: NativeOwnerActivatingEffect {
    var startHandler: (() -> NativeOwnerActivationCoordinator.StartResult)?
    var stopHandler: (() -> NativeOwnerActivationCoordinator.StopResult)?

    func start() -> NativeOwnerActivationCoordinator.StartResult {
        startHandler?() ?? .notStarted
    }

    func stop() -> NativeOwnerActivationCoordinator.StopResult {
        stopHandler?() ?? .stopped
    }
}
