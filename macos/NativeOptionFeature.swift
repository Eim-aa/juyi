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
    private var lifecycleGeneration: UInt64 = 0
    private var isPaused = false
    private var appleEngineSelected = true
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
            && phase != .requestingAccessibility
            && phase != .waitingForHammerspoon
    }

    func enableByUser() {
        guard actionIsEnabled, !isPaused, appleEngineSelected else { return }
        if phase == .active {
            pendingUserEnable = false
            disable(reason: .user)
        } else {
            pendingUserEnable = true
            Task { await enable(promptForAccessibility: true) }
        }
    }

    func resumeIfEnabled() {
        if activation?.phase == .idle || activation?.phase == .recoveryRequired {
            activation?.recoverAndReturnToLegacy()
        }
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

    func setAppleEngineSelected(_ selected: Bool) {
        guard appleEngineSelected != selected else { return }
        appleEngineSelected = selected
        if selected {
            resumeIfEnabled()
        } else {
            pendingUserEnable = false
            disable(reason: .user)
        }
    }

    func prepareLanguages() {
        guard !isPreparingLanguages, !isPaused, appleEngineSelected else { return }
        let generation = lifecycleGeneration
        isPreparingLanguages = true
        detail = "请在 macOS 系统窗口中确认中英语言包。"
        Task {
            let result = await apple.prepareLanguages()
            isPreparingLanguages = false
            guard generation == lifecycleGeneration,
                  !isPaused,
                  appleEngineSelected else { return }
            switch result {
            case .prepared:
                detail = "语言包已准备好；现在可以启用原生双 Option。"
                phase = .disabled
            case .unsupported:
                phase = .unsupported
                detail = "这台 Mac 不支持英语到简体中文的 Apple Translation。"
            case .cancelled:
                detail = "已停止等待语言包准备。"
            default:
                phase = .languagePackRequired
                detail = "语言包尚未准备完成，请重试。"
            }
        }
    }

    func setPaused(_ paused: Bool) {
        isPaused = paused
        if paused {
            disable(reason: .pause, preservePreference: true)
        } else {
            resumeIfEnabled()
        }
        overlay.setPaused(paused)
    }

    func applicationBecameActive() {
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
        guard !enableInProgress, !isPaused, appleEngineSelected else { return }
        enableInProgress = true
        let generation = lifecycleGeneration
        defer { enableInProgress = false }
        guard let activation, statusReader != nil else {
            phase = .unavailable
            detail = "无法建立与 Hammerspoon 的安全 owner 交接。"
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
              appleEngineSelected else { return }
        pendingUserEnable = false

        switch await apple.readiness() {
        case .installed:
            break
        case .needsPreparation:
            phase = .languagePackRequired
            detail = "需要先准备 Apple 英语到简体中文语言包。"
            return
        case .unsupported:
            phase = .unsupported
            detail = "这台 Mac 不支持英语到简体中文的 Apple Translation。"
            return
        case .unavailable:
            phase = .unavailable
            detail = "暂时无法检查 Apple Translation。"
            return
        }

        guard generation == lifecycleGeneration,
              !isPaused,
              appleEngineSelected else { return }

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
        let shouldResume = resumeRequestedAfterRevocation
            && UserDefaults.standard.bool(forKey: Self.enabledKey)
            && !isPaused
            && appleEngineSelected
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
        stopOwnerPolling()
        activation?.deactivate(reason)
        if activation?.phase == .recoveryRequired {
            activation?.recoverAndReturnToLegacy()
        }
        if !preservePreference {
            UserDefaults.standard.set(false, forKey: Self.enabledKey)
            pendingUserEnable = false
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
        cancelPipeline(dismissOverlay: true)
        pipelineGeneration &+= 1
        let generation = pipelineGeneration
        translationTask = Task { [weak self] in
            guard let self else { return }
            guard await apple.readiness() == .installed,
                  generation == pipelineGeneration else {
                self.presentPreflightFailure(target: target, generation: generation)
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

    private func presentPreflightFailure(
        target: NativeSelectionTarget,
        generation: UInt64
    ) {
        guard generation == pipelineGeneration,
              let app = NSRunningApplication(processIdentifier: target.processIdentifier),
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
                error: .appleNotReady
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
                guard let self else { return }
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
                    response = .init(
                        requestedEngine: .apple,
                        actualEngine: nil,
                        result: nil,
                        elapsedMilliseconds: elapsed,
                        error: .appleNotReady,
                        captureDidTruncate: didTruncate,
                        inputTruncated: didTruncate
                    )
                case .cancelled:
                    return
                default:
                    response = .init(
                        requestedEngine: .apple,
                        actualEngine: nil,
                        result: nil,
                        elapsedMilliseconds: elapsed,
                        error: .serviceUnavailable,
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
            overlay.resolveNativeTranslation(.timeout, generation: panelGeneration)
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
