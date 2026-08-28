#if DEBUG && JUYI_NATIVE_TRANSLATION_RESULT_LAB && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && !JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
#error("Result Lab and the Apple adapter require JUYI_NATIVE_APPLE_RESULT_LAB_BINDING when compiled together")
#endif

#if DEBUG && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING && !(JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER)
#error("JUYI_NATIVE_APPLE_RESULT_LAB_BINDING requires the domain, overlay, Result Lab and Apple adapter gates")
#endif

#if DEBUG && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING && JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER
#error("The real Apple Result Lab binding cannot be compiled with the live Volc adapter")
#endif

#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
import Combine
import Foundation

public let nativeTranslationAppleResultLabBindingBuildSentinel =
    "juyi-native-apple-result-lab-binding-v1"

enum NativeTranslationAppleResultLabFixture {
    static let sourceText = "The weather is pleasant today."
    static let sourceLanguageIdentifier = "en"
    static let targetLanguageIdentifier = "zh-Hans"
}

enum NativeTranslationAppleResultLabPhase: Equatable {
    case checkingAvailability
    case ready
    case needsPreparation
    case unsupported
    case temporarilyUnavailable
    case hostUnavailable
    case preparing(extendedWait: Bool)
    case preparationWaitStopped
    case preparationFailed
    case translationPreflight(extendedWait: Bool)
    case acquiringHost(extendedWait: Bool)
    case running(extendedWait: Bool)
    case success
    case typedFailure(NativeTranslationFailure)
    case safetyFailure
    case timeout
    case stopped

    var isBusy: Bool {
        switch self {
        case .checkingAvailability, .preparing, .translationPreflight,
             .acquiringHost, .running:
            return true
        default:
            return false
        }
    }
}

enum NativeTranslationAppleResultLabSheetAnnouncementPolicy {
    static func sheetOwnsStatusAnnouncement(
        for phase: NativeTranslationAppleResultLabPhase,
        hasVisibleResult: Bool
    ) -> Bool {
        switch phase {
        case .success, .typedFailure, .timeout, .running:
            return false
        case .safetyFailure:
            return !hasVisibleResult
        case .checkingAvailability, .ready, .needsPreparation, .unsupported,
             .temporarilyUnavailable, .hostUnavailable, .preparing,
             .preparationWaitStopped, .preparationFailed,
             .translationPreflight, .acquiringHost, .stopped:
            return true
        }
    }
}

enum NativeTranslationAppleResultLabAction: Equatable, Hashable {
    case recheckAvailability
    case prepareLanguages
    case translateFixture
    case stopWaiting
    case close
}

struct NativeTranslationAppleResultLabPresentation: Equatable {
    let title: String
    let message: String
    let primaryAction: NativeTranslationAppleResultLabAction?
    let primaryTitle: String?
    let secondaryAction: NativeTranslationAppleResultLabAction?
    let secondaryTitle: String?

    static func make(for phase: NativeTranslationAppleResultLabPhase) -> Self {
        switch phase {
        case .checkingAvailability:
            return Self(
                title: "正在检查 Apple Translation",
                message: "只检查英语→简体中文语言资源；不会开始下载或翻译。",
                primaryAction: nil,
                primaryTitle: nil,
                secondaryAction: nil,
                secondaryTitle: nil
            )
        case .ready:
            return Self(
                title: "Apple Translation 已准备好",
                message: "点击后才会把固定原文交给 Apple Translation。",
                primaryAction: .translateFixture,
                primaryTitle: "翻译固定样例",
                secondaryAction: .recheckAvailability,
                secondaryTitle: "重新检查"
            )
        case .needsPreparation:
            return Self(
                title: "需要准备 Apple 语言包",
                message: "只有你点击后，macOS 才会请求准备英语→简体中文语言资源。",
                primaryAction: .prepareLanguages,
                primaryTitle: "准备语言包…",
                secondaryAction: .recheckAvailability,
                secondaryTitle: "重新检查"
            )
        case .unsupported:
            return Self(
                title: "这台 Mac 不支持 Apple Translation",
                message: "当前实验不会改用火山云端。",
                primaryAction: .recheckAvailability,
                primaryTitle: "重新检查",
                secondaryAction: nil,
                secondaryTitle: nil
            )
        case .temporarilyUnavailable:
            return Self(
                title: "暂时无法检查 Apple Translation",
                message: "请稍后重试；当前实验不会改用火山云端。",
                primaryAction: .recheckAvailability,
                primaryTitle: "重新检查",
                secondaryAction: nil,
                secondaryTitle: nil
            )
        case .hostUnavailable:
            return Self(
                title: "暂时无法启动 Apple Translation",
                message: "Translation host 未取得会话；固定原文尚未交给 Apple，也不会改用火山云端。",
                primaryAction: .recheckAvailability,
                primaryTitle: "重新检查",
                secondaryAction: nil,
                secondaryTitle: nil
            )
        case let .preparing(extendedWait):
            return Self(
                title: extendedWait ? "仍在等待 macOS 完成…" : "正在准备 Apple 语言包…",
                message: "请按 macOS 提示确认；下载由系统管理。停止等待或关闭此页面只会停止句译等待，不会取消系统下载；macOS 可能继续下载，之后请重新检查状态。",
                primaryAction: .stopWaiting,
                primaryTitle: "停止等待",
                secondaryAction: nil,
                secondaryTitle: nil
            )
        case .preparationWaitStopped:
            return Self(
                title: "已停止等待",
                message: "macOS 可能仍会继续下载；可稍后检查状态。",
                primaryAction: .recheckAvailability,
                primaryTitle: "检查状态",
                secondaryAction: nil,
                secondaryTitle: nil
            )
        case .preparationFailed:
            return Self(
                title: "Apple 语言包没有准备完成",
                message: "请确认系统提示后重试；不会自动开始翻译。",
                primaryAction: .recheckAvailability,
                primaryTitle: "重新检查",
                secondaryAction: nil,
                secondaryTitle: nil
            )
        case let .translationPreflight(extendedWait):
            return Self(
                title: extendedWait
                    ? "仍在检查 Apple Translation 语言资源…"
                    : "正在重新检查 Apple Translation",
                message: "正在确认英语→简体中文语言资源；尚未开始翻译。",
                primaryAction: .stopWaiting,
                primaryTitle: "停止等待",
                secondaryAction: nil,
                secondaryTitle: nil
            )
        case let .acquiringHost(extendedWait):
            return Self(
                title: extendedWait
                    ? "仍在等待 Apple Translation host…"
                    : "正在取得 Apple Translation host",
                message: "固定原文尚未交给 Apple Translation；不会改用火山云端。",
                primaryAction: .stopWaiting,
                primaryTitle: "停止等待",
                secondaryAction: nil,
                secondaryTitle: nil
            )
        case let .running(extendedWait):
            return Self(
                title: extendedWait ? "仍在等待 Apple Translation…" : "正在运行真实 Apple Translation…",
                message: "固定原文正在本机处理；不会改用火山云端。",
                primaryAction: .stopWaiting,
                primaryTitle: "停止等待",
                secondaryAction: nil,
                secondaryTitle: nil
            )
        case .success:
            return terminal(
                title: "Apple Translation 真实译文已显示",
                message: "未复制时，结果只保留在当前 Debug 浮窗；复制后其他 App 或剪贴板管理器可能继续保留。",
                primaryAction: .translateFixture,
                primaryTitle: "再次翻译固定样例",
                secondaryAction: .recheckAvailability,
                secondaryTitle: "重新检查"
            )
        case let .typedFailure(failure):
            return terminal(
                title: failureTitle(failure),
                message: "没有改用火山云端；请重新检查语言包状态后重试。",
                primaryAction: .recheckAvailability,
                primaryTitle: "重新检查"
            )
        case .safetyFailure:
            return terminal(
                title: "真实 Apple 结果未通过 Debug 安全检查",
                message: "结果未显示或保留；这不表示 Apple Translation 没有被调用。",
                primaryAction: .recheckAvailability,
                primaryTitle: "重新检查"
            )
        case .timeout:
            return terminal(
                title: "Apple Translation 暂时没有响应",
                message: "已停止等待；迟到结果不会显示或复制，也不会改用火山云端。",
                primaryAction: .translateFixture,
                primaryTitle: "重试固定样例",
                secondaryAction: .recheckAvailability,
                secondaryTitle: "重新检查"
            )
        case .stopped:
            return terminal(
                title: "已停止真实 Apple Translation",
                message: "迟到结果不会显示或复制；不会改用火山云端。",
                primaryAction: .recheckAvailability,
                primaryTitle: "重新检查"
            )
        }
    }

    private static func terminal(
        title: String,
        message: String,
        primaryAction: NativeTranslationAppleResultLabAction? = nil,
        primaryTitle: String? = nil,
        secondaryAction: NativeTranslationAppleResultLabAction? = nil,
        secondaryTitle: String? = nil
    ) -> Self {
        Self(
            title: title,
            message: message,
            primaryAction: primaryAction,
            primaryTitle: primaryTitle,
            secondaryAction: secondaryAction,
            secondaryTitle: secondaryTitle
        )
    }

    private static func failureTitle(_ failure: NativeTranslationFailure) -> String {
        switch failure {
        case .appleNeedsPreparation:
            return "Apple 语言包需要重新准备"
        case .appleUnsupported:
            return "Apple Translation 当前不受支持"
        case .appleTemporarilyUnavailable:
            return "Apple Translation 暂时不可用"
        case .appleExecutionFailed:
            return "Apple Translation 未能完成"
        default:
            return "真实 Apple 结果未通过 Debug 安全检查"
        }
    }
}

enum NativeTranslationAppleResultLabHostIntent: Equatable {
    case prepare
    case translate
}

struct NativeTranslationAppleResultLabHostRequest: Equatable, CustomStringConvertible {
    let ownerGeneration: UInt64
    let requestGeneration: UInt64
    let intent: NativeTranslationAppleResultLabHostIntent

    var description: String {
        "NativeTranslationAppleResultLabHostRequest(owner: \(ownerGeneration), request: \(requestGeneration), intent: \(intent))"
    }
}

struct NativeTranslationAppleResultLabHostClaim: Equatable, CustomStringConvertible {
    let request: NativeTranslationAppleResultLabHostRequest
    let sourceText: String?
    let receipt: NativeTranslationAppleResultLabHostReceipt?

    var description: String {
        "NativeTranslationAppleResultLabHostClaim(request: \(request.description), source: [REDACTED], receipt: [REDACTED])"
    }
}

enum NativeTranslationAppleResultLabHostCompletion: Equatable {
    case prepared
    case translated(String)
    case failure(NativeTranslationFailure)
    case cancelled
}

enum NativeTranslationAppleResultLabHostConfigurationCommand: Equatable {
    case install(NativeTranslationAppleResultLabHostRequest)
    case invalidateAndClear(ownerGeneration: UInt64)
}

struct NativeTranslationAppleResultLabOverlayClient {
    let reserve: @MainActor (
        @escaping (NativeTranslationOverlayDismissReason) -> Void
    ) -> NativeTranslationOverlayExternalPresentationLease?
    let activate: @MainActor (
        NativeTranslationAppleResultLabValidatedPresentation,
        NativeTranslationOverlayExternalPresentationLease
    ) -> Bool
    let updateLoading: @MainActor (
        NativeTranslationAppleResultLabValidatedPresentation,
        NativeTranslationOverlayExternalPresentationLease
    ) -> Bool
    let resolve: @MainActor (
        NativeTranslationAppleResultLabValidatedPresentation,
        NativeTranslationOverlayExternalPresentationLease
    ) -> Bool
    let invalidate: @MainActor (
        NativeTranslationOverlayExternalPresentationLease,
        NativeTranslationOverlayDismissReason
    ) -> Void
    let focusCurrent: @MainActor (
        NativeTranslationOverlayExternalPresentationLease
    ) -> Bool
}

struct NativeTranslationAppleResultLabDomainHandle {
    let begin: @Sendable () async -> UInt64
    let invalidate: @Sendable (NativeTranslationInvalidationReason) async -> Void
    let hasRetainedInput: @Sendable () async -> Bool
}

struct NativeTranslationAppleResultLabDomainFactory {
    typealias Publisher = @Sendable (UInt64, NativeTranslationOutcome) -> Void
    let make: @MainActor (
        NativeTranslationExecutor,
        @escaping Publisher
    ) -> NativeTranslationAppleResultLabDomainHandle

    static let liveApple = NativeTranslationAppleResultLabDomainFactory { executor, publisher in
        let coordinator = NativeTranslationDomainCoordinator(
            credentialLoader: { _ in nil },
            executor: executor,
            publisher: publisher
        )
        let context = NativeTranslationRequestContext(
            appleReadiness: .installed,
            volcPrivacy: NativeVolcPrivacyContext(
                hasExplicitConsent: false,
                removalMarker: .unavailable,
                credentialReadiness: .missing,
                verifiedFingerprint: nil
            )
        )
        return NativeTranslationAppleResultLabDomainHandle(
            begin: {
                await coordinator.begin(
                    sourceText: NativeTranslationAppleResultLabFixture.sourceText,
                    requestedEngine: .apple,
                    context: context
                )
            },
            invalidate: { reason in await coordinator.invalidate(reason) },
            hasRetainedInput: { await coordinator.hasRetainedInput() }
        )
    }
}

struct NativeTranslationAppleResultLabAvailabilityClient: Sendable {
    let query: @Sendable () async -> NativeAppleTranslationReadiness
}

@MainActor
protocol NativeTranslationAppleResultLabScheduledTask: AnyObject {
    func cancel()
}

@MainActor
protocol NativeTranslationAppleResultLabScheduling: AnyObject {
    var now: TimeInterval { get }
    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> any NativeTranslationAppleResultLabScheduledTask
}

@MainActor
final class NativeTranslationAppleResultLabSystemScheduledTask:
    NativeTranslationAppleResultLabScheduledTask
{
    private var task: Task<Void, Never>?

    init(task: Task<Void, Never>) {
        self.task = task
    }

    func cancel() {
        task?.cancel()
        task = nil
    }
}

@MainActor
final class NativeTranslationAppleResultLabSystemScheduler:
    NativeTranslationAppleResultLabScheduling
{
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    init() {
        origin = clock.now
    }

    var now: TimeInterval {
        let components = origin.duration(to: clock.now).components
        return Double(components.seconds)
            + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> any NativeTranslationAppleResultLabScheduledTask {
        let nanoseconds = Int64(max(0, delay) * 1_000_000_000)
        let clock = self.clock
        let task = Task { @MainActor in
            do {
                try await clock.sleep(for: .nanoseconds(nanoseconds))
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            action()
        }
        return NativeTranslationAppleResultLabSystemScheduledTask(task: task)
    }
}

@MainActor
final class NativeTranslationAppleResultLabCoordinator: ObservableObject {
    typealias HostConfigurationControl = @MainActor (
        NativeTranslationAppleResultLabHostConfigurationCommand
    ) -> Void

    private enum AvailabilityPurpose: Equatable {
        case opening
        case explicitRecheck
        case translationPreflight
        case translationFailureRecheck
        case preparationRecheck
    }

    private enum TimerKind: Hashable {
        case availability
        case preparationExtended
        case translationExtended
        case translationDeadline
        case hostAcquisition
    }

    private final class ActiveRun {
        enum TerminalOrigin {
            case domain
            case ownerTimeout
            case safety
        }

        let ownerGeneration: UInt64
        let lease: NativeTranslationOverlayExternalPresentationLease
        let startedAt: TimeInterval
        var domain: NativeTranslationAppleResultLabDomainHandle?
        var domainGeneration: UInt64?
        var bufferedOutcome: (UInt64, NativeTranslationOutcome)?
        var beginTask: Task<Void, Never>?
        var acceptsOutcome = true
        var overlayActivated = false
        var terminalOrigin: TerminalOrigin?
        var didInvalidateDomain = false
        var expectedReceipt: NativeTranslationAppleResultLabHostReceipt?
        var effectContinuation: CheckedContinuation<NativeTranslationEffectResult, Never>?

        init(
            ownerGeneration: UInt64,
            lease: NativeTranslationOverlayExternalPresentationLease,
            startedAt: TimeInterval
        ) {
            self.ownerGeneration = ownerGeneration
            self.lease = lease
            self.startedAt = startedAt
        }
    }

    @Published private(set) var isPresented = false
    @Published private(set) var phase: NativeTranslationAppleResultLabPhase = .checkingAvailability
    @Published private(set) var hostRequest: NativeTranslationAppleResultLabHostRequest?

    private let availability: NativeTranslationAppleResultLabAvailabilityClient
    private let scheduler: any NativeTranslationAppleResultLabScheduling
    private let overlay: NativeTranslationAppleResultLabOverlayClient
    private let domainFactory: NativeTranslationAppleResultLabDomainFactory

    private var ownerGeneration: UInt64 = 0
    private var requestGeneration: UInt64 = 0
    private var claimGeneration: UInt64 = 0
    private var availabilityTask: Task<Void, Never>?
    private var timers: [TimerKind: any NativeTranslationAppleResultLabScheduledTask] = [:]
    private var active: ActiveRun?
    private var pendingLeaseGeneration: UInt64?
    private var dismissedWhileMinting: Set<UInt64> = []
    private var hostConfigurationControl: HostConfigurationControl?
    private let hostReceiptRegistry = NativeTranslationAppleResultLabHostReceiptRegistry()
    private var hostClaim: NativeTranslationAppleResultLabHostClaim?
    private var retiringHostClaim: NativeTranslationAppleResultLabHostClaim?
    private var pendingPreparation = false

    init(
        availability: NativeTranslationAppleResultLabAvailabilityClient,
        scheduler: any NativeTranslationAppleResultLabScheduling,
        overlay: NativeTranslationAppleResultLabOverlayClient,
        domainFactory: NativeTranslationAppleResultLabDomainFactory
    ) {
        self.availability = availability
        self.scheduler = scheduler
        self.overlay = overlay
        self.domainFactory = domainFactory
    }

    var presentation: NativeTranslationAppleResultLabPresentation {
        NativeTranslationAppleResultLabPresentation.make(for: phase)
    }

    var isBusy: Bool { phase.isBusy }

    var hasVisibleResult: Bool {
        guard let active, active.terminalOrigin != nil else { return false }
        switch phase {
        case .success, .typedFailure, .safetyFailure, .timeout:
            return true
        default:
            return false
        }
    }

    func open() {
        invalidateCurrent(reason: .ownerChanged, overlayReason: .stop)
        cancelAvailabilityAndTimers()
        revokeHost(ownerGeneration: ownerGeneration)
        beginOwnerGeneration()
        isPresented = true
        phase = .checkingAvailability
        startAvailability(.opening, generation: ownerGeneration, maximumDelay: 5)
    }

    func close() {
        invalidateCurrent(reason: .ownerChanged, overlayReason: .close)
        ownerGeneration &+= 1
        cancelAvailabilityAndTimers()
        revokeHost(ownerGeneration: ownerGeneration)
        isPresented = false
        phase = .stopped
    }

    func perform(_ action: NativeTranslationAppleResultLabAction) {
        guard actionIsAllowed(action, in: phase) else { return }
        switch action {
        case .recheckAvailability:
            recheckAvailability()
        case .prepareLanguages:
            beginPreparation()
        case .translateFixture:
            beginTranslation()
        case .stopWaiting:
            stopWaiting()
        case .close:
            close()
        }
    }

    func handleEscape() {
        if isBusy { stopWaiting() } else { close() }
    }

    func focusCurrentResult() {
        guard hasVisibleResult, let active else { return }
        _ = overlay.focusCurrent(active.lease)
    }

    func invalidate(_ reason: NativeTranslationInvalidationReason) {
        let hadPresentation = isPresented
        invalidateCurrent(reason: reason, overlayReason: dismissReason(for: reason))
        ownerGeneration &+= 1
        cancelAvailabilityAndTimers()
        revokeHost(ownerGeneration: ownerGeneration)
        if hadPresentation { phase = .stopped }
    }

    func attachHostConfigurationControl(
        _ control: @escaping HostConfigurationControl
    ) {
        hostConfigurationControl = control
        if let hostRequest { control(.install(hostRequest)) }
    }

    func detachHostConfigurationControl() {
        hostConfigurationControl = nil
        invalidate(.ownerChanged)
    }

    func hostSlotWillDisappear(
        _ request: NativeTranslationAppleResultLabHostRequest
    ) {
        guard hostRequest == request || hostClaim?.request == request else { return }
        revokeHost(ownerGeneration: request.ownerGeneration)
    }

    func claimHost(
        _ request: NativeTranslationAppleResultLabHostRequest
    ) -> NativeTranslationAppleResultLabHostClaim? {
        guard request == hostRequest,
              request.ownerGeneration == ownerGeneration,
              hostClaim == nil,
              retiringHostClaim == nil
        else { return nil }

        let claim: NativeTranslationAppleResultLabHostClaim
        switch request.intent {
        case .prepare:
            guard pendingPreparation, case .preparing = phase else { return nil }
            claim = NativeTranslationAppleResultLabHostClaim(
                request: request,
                sourceText: nil,
                receipt: nil
            )
        case .translate:
            guard let active,
                  active.ownerGeneration == request.ownerGeneration,
                  active.effectContinuation != nil,
                  active.acceptsOutcome else { return nil }
            claimGeneration &+= 1
            guard let receipt = hostReceiptRegistry.claim(
                runID: active.ownerGeneration,
                claimGeneration: claimGeneration
            ) else { return nil }
            active.expectedReceipt = receipt
            let isExtended = scheduler.now - active.startedAt >= 2
            guard overlay.activate(.loading(isExtended: isExtended), active.lease),
                  self.active === active else {
                active.acceptsOutcome = false
                resumeEffectIfCurrent(
                    ownerGeneration: active.ownerGeneration,
                    result: .cancelled
                )
                self.active = nil
                hostRequest = nil
                clearHostConfiguration(ownerGeneration: active.ownerGeneration)
                cleanupDomain(active, reason: .ownerChanged)
                overlay.invalidate(active.lease, .stop)
                phase = .stopped
                return nil
            }
            active.overlayActivated = true
            phase = .running(extendedWait: isExtended)
            claim = NativeTranslationAppleResultLabHostClaim(
                request: request,
                sourceText: NativeTranslationAppleResultLabFixture.sourceText,
                receipt: receipt
            )
        }
        hostClaim = claim
        cancelTimer(.hostAcquisition)
        return claim
    }

    func completeHost(
        _ completion: NativeTranslationAppleResultLabHostCompletion,
        claim: NativeTranslationAppleResultLabHostClaim
    ) {
        if retiringHostClaim == claim {
            retiringHostClaim = nil
            issueWaitingHostRequestIfPossible()
            return
        }
        guard hostClaim == claim else { return }
        hostClaim = nil
        hostRequest = nil
        clearHostConfiguration(ownerGeneration: claim.request.ownerGeneration)

        switch claim.request.intent {
        case .prepare:
            pendingPreparation = false
            cancelTimer(.preparationExtended)
            switch completion {
            case .prepared, .failure:
                phase = .checkingAvailability
                startAvailability(
                    .preparationRecheck,
                    generation: claim.request.ownerGeneration,
                    maximumDelay: 5
                )
            case .cancelled:
                phase = .preparationWaitStopped
            case .translated:
                phase = .preparationFailed
            }
        case .translate:
            switch completion {
            case let .translated(text):
                resumeEffectIfCurrent(
                    ownerGeneration: claim.request.ownerGeneration,
                    result: .success(text: text)
                )
            case .failure:
                guard let run = active,
                      run.ownerGeneration == claim.request.ownerGeneration,
                      run.acceptsOutcome else { return }
                startAvailability(
                    .translationFailureRecheck,
                    generation: claim.request.ownerGeneration,
                    maximumDelay: min(5, remainingTime(for: run))
                )
            case .cancelled:
                resumeEffectIfCurrent(
                    ownerGeneration: claim.request.ownerGeneration,
                    result: .cancelled
                )
            case .prepared:
                resumeEffectIfCurrent(
                    ownerGeneration: claim.request.ownerGeneration,
                    result: .failure(.appleExecutionFailed)
                )
            }
        }
    }

    private func recheckAvailability() {
        guard isPresented else { return }
        invalidateCurrent(reason: .newRequest, overlayReason: .stop)
        beginOwnerGeneration()
        phase = .checkingAvailability
        startAvailability(.explicitRecheck, generation: ownerGeneration, maximumDelay: 5)
    }

    private func beginPreparation() {
        guard isPresented else { return }
        invalidateCurrent(reason: .newRequest, overlayReason: .stop)
        beginOwnerGeneration()
        phase = .preparing(extendedWait: false)
        pendingPreparation = true
        schedule(.preparationExtended, after: 30, generation: ownerGeneration) { [weak self] in
            guard let self, case .preparing = self.phase else { return }
            self.phase = .preparing(extendedWait: true)
        }
        issueHostRequest(.prepare, generation: ownerGeneration, acquisitionLimit: 5)
    }

    private func beginTranslation() {
        guard isPresented else { return }
        invalidateCurrent(reason: .newRequest, overlayReason: .stop)
        beginOwnerGeneration()
        let generation = ownerGeneration
        pendingLeaseGeneration = generation
        dismissedWhileMinting.remove(generation)
        let lease = overlay.reserve { [weak self] reason in
            self?.overlayDismissed(generation: generation, reason: reason)
        }
        pendingLeaseGeneration = nil
        guard let lease, dismissedWhileMinting.remove(generation) == nil else {
            phase = .stopped
            return
        }
        let run = ActiveRun(
            ownerGeneration: generation,
            lease: lease,
            startedAt: scheduler.now
        )
        active = run
        phase = .translationPreflight(extendedWait: false)
        schedule(.translationExtended, after: 2, generation: generation) { [weak self] in
            guard let self, self.active === run, run.acceptsOutcome else { return }
            if run.overlayActivated {
                self.phase = .running(extendedWait: true)
                guard self.overlay.updateLoading(.loading(isExtended: true), run.lease) else {
                    self.invalidateCurrent(reason: .ownerChanged, overlayReason: .stop)
                    self.phase = .stopped
                    return
                }
            } else {
                switch self.phase {
                case .acquiringHost:
                    self.phase = .acquiringHost(extendedWait: true)
                default:
                    self.phase = .translationPreflight(extendedWait: true)
                }
            }
        }
        schedule(.translationDeadline, after: 12, generation: generation) { [weak self] in
            self?.translationTimedOut(generation: generation)
        }
        startAvailability(
            .translationPreflight,
            generation: generation,
            maximumDelay: min(5, remainingTime(for: run))
        )
    }

    private func startDomain(for run: ActiveRun) {
        guard active === run, run.acceptsOutcome else { return }
        phase = .acquiringHost(extendedWait: scheduler.now - run.startedAt >= 2)
        let generation = run.ownerGeneration
        let executor = NativeTranslationExecutor { [weak self] request in
            guard let self else { return .cancelled }
            return await self.executeLiveAppleEffect(request, generation: generation)
        }
        let domain = domainFactory.make(executor) { [weak self] domainGeneration, outcome in
            Task { @MainActor [weak self] in
                self?.receiveDomain(
                    ownerGeneration: generation,
                    domainGeneration: domainGeneration,
                    outcome: outcome
                )
            }
        }
        run.domain = domain
        run.beginTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let domainGeneration = await domain.begin()
            guard !Task.isCancelled else {
                return
            }
            self?.bindDomainGeneration(
                ownerGeneration: generation,
                domainGeneration: domainGeneration
            )
        }
    }

    private func executeLiveAppleEffect(
        _ request: NativeTranslationEffectRequest,
        generation: UInt64
    ) async -> NativeTranslationEffectResult {
        guard request.engine == .apple,
              request.volcCredentials == nil,
              request.input.text == NativeTranslationAppleResultLabFixture.sourceText,
              request.input.wasTruncated == false else {
            return .failure(.appleExecutionFailed)
        }
        if Task.isCancelled { return .cancelled }
        return await withTaskCancellationHandler(operation: {
            await withCheckedContinuation { continuation in
                guard let run = active,
                      run.ownerGeneration == generation,
                      run.acceptsOutcome,
                      run.effectContinuation == nil,
                      !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                run.effectContinuation = continuation
                issueHostRequest(
                    .translate,
                    generation: generation,
                    acquisitionLimit: min(5, remainingTime(for: run))
                )
                if Task.isCancelled {
                    cancelEffect(generation: generation)
                }
            }
        }, onCancel: { [weak self] in
            Task { @MainActor in self?.cancelEffect(generation: generation) }
        })
    }

    private func cancelEffect(generation: UInt64) {
        guard let run = active, run.ownerGeneration == generation else { return }
        revokeHost(ownerGeneration: generation)
        resumeEffectIfCurrent(ownerGeneration: generation, result: .cancelled)
    }

    private func issueHostRequest(
        _ intent: NativeTranslationAppleResultLabHostIntent,
        generation: UInt64,
        acquisitionLimit: TimeInterval
    ) {
        guard generation == ownerGeneration,
              acquisitionLimit > 0 else {
            if intent == .translate {
                resumeEffectIfCurrent(
                    ownerGeneration: generation,
                    result: .failure(.appleTemporarilyUnavailable)
                )
            } else {
                pendingPreparation = false
                phase = .temporarilyUnavailable
            }
            return
        }
        requestGeneration &+= 1
        hostRequest = NativeTranslationAppleResultLabHostRequest(
            ownerGeneration: generation,
            requestGeneration: requestGeneration,
            intent: intent
        )
        schedule(.hostAcquisition, after: acquisitionLimit, generation: generation) { [weak self] in
            self?.hostAcquisitionTimedOut(intent: intent, generation: generation)
        }
        issueWaitingHostRequestIfPossible()
    }

    private func issueWaitingHostRequestIfPossible() {
        guard retiringHostClaim == nil, hostClaim == nil, let hostRequest else { return }
        hostConfigurationControl?(.install(hostRequest))
    }

    private func hostAcquisitionTimedOut(
        intent: NativeTranslationAppleResultLabHostIntent,
        generation: UInt64
    ) {
        guard generation == ownerGeneration,
              hostRequest?.ownerGeneration == generation,
              hostClaim == nil else { return }
        hostRequest = nil
        clearHostConfiguration(ownerGeneration: generation)
        switch intent {
        case .prepare:
            pendingPreparation = false
            phase = .temporarilyUnavailable
        case .translate:
            guard let run = active, run.ownerGeneration == generation else { return }
            run.acceptsOutcome = false
            resumeEffectIfCurrent(ownerGeneration: generation, result: .cancelled)
            active = nil
            cleanupDomain(run, reason: .ownerChanged)
            overlay.invalidate(run.lease, .stop)
            phase = .hostUnavailable
        }
    }

    private func resumeEffectIfCurrent(
        ownerGeneration generation: UInt64,
        result: NativeTranslationEffectResult
    ) {
        guard let run = active,
              run.ownerGeneration == generation,
              let continuation = run.effectContinuation else { return }
        run.effectContinuation = nil
        cancelTimer(.hostAcquisition)
        continuation.resume(returning: result)
    }

    private func startAvailability(
        _ purpose: AvailabilityPurpose,
        generation: UInt64,
        maximumDelay: TimeInterval
    ) {
        guard isPresented, generation == ownerGeneration, maximumDelay > 0 else {
            receiveAvailabilityTimeout(purpose, generation: generation)
            return
        }
        availabilityTask?.cancel()
        cancelTimer(.availability)
        schedule(.availability, after: maximumDelay, generation: generation) { [weak self] in
            self?.receiveAvailabilityTimeout(purpose, generation: generation)
        }
        availabilityTask = Task { [weak self, availability] in
            let readiness = await availability.query()
            guard !Task.isCancelled else { return }
            self?.receiveAvailability(readiness, purpose: purpose, generation: generation)
        }
    }

    private func receiveAvailability(
        _ readiness: NativeAppleTranslationReadiness,
        purpose: AvailabilityPurpose,
        generation: UInt64
    ) {
        guard isPresented, generation == ownerGeneration else { return }
        cancelTimer(.availability)
        availabilityTask = nil
        switch purpose {
        case .opening, .explicitRecheck, .preparationRecheck:
            publishReadiness(readiness, preparationRecheck: purpose == .preparationRecheck)
        case .translationPreflight:
            guard let run = active, run.ownerGeneration == generation,
                  run.acceptsOutcome else { return }
            switch readiness {
            case .installed:
                startDomain(for: run)
            case .supportedNeedsPreparation:
                resolvePreflightFailure(.appleNeedsPreparation, run: run)
            case .unsupported:
                resolvePreflightFailure(.appleUnsupported, run: run)
            case .temporarilyUnavailable:
                resolvePreflightFailure(.appleTemporarilyUnavailable, run: run)
            }
        case .translationFailureRecheck:
            let failure: NativeTranslationFailure
            switch readiness {
            case .installed: failure = .appleExecutionFailed
            case .supportedNeedsPreparation: failure = .appleNeedsPreparation
            case .unsupported: failure = .appleUnsupported
            case .temporarilyUnavailable: failure = .appleTemporarilyUnavailable
            }
            resumeEffectIfCurrent(
                ownerGeneration: generation,
                result: .failure(failure)
            )
        }
    }

    private func receiveAvailabilityTimeout(
        _ purpose: AvailabilityPurpose,
        generation: UInt64
    ) {
        guard isPresented, generation == ownerGeneration else { return }
        availabilityTask?.cancel()
        availabilityTask = nil
        cancelTimer(.availability)
        if purpose == .translationPreflight,
           let run = active, run.ownerGeneration == generation {
            resolvePreflightFailure(.appleTemporarilyUnavailable, run: run)
        } else if purpose == .translationFailureRecheck {
            resumeEffectIfCurrent(
                ownerGeneration: generation,
                result: .failure(.appleTemporarilyUnavailable)
            )
        } else {
            phase = .temporarilyUnavailable
        }
    }

    private func publishReadiness(
        _ readiness: NativeAppleTranslationReadiness,
        preparationRecheck: Bool
    ) {
        switch readiness {
        case .installed:
            phase = .ready
        case .supportedNeedsPreparation:
            phase = preparationRecheck ? .preparationFailed : .needsPreparation
        case .unsupported:
            phase = .unsupported
        case .temporarilyUnavailable:
            phase = .temporarilyUnavailable
        }
    }

    private func resolvePreflightFailure(
        _ failure: NativeTranslationFailure,
        run: ActiveRun
    ) {
        guard active === run, run.acceptsOutcome else { return }
        run.acceptsOutcome = false
        cancelTranslationTimers()
        revokeHost(ownerGeneration: run.ownerGeneration)
        active = nil
        cleanupDomain(run, reason: .ownerChanged)
        overlay.invalidate(run.lease, .stop)
        switch failure {
        case .appleNeedsPreparation:
            phase = .needsPreparation
        case .appleUnsupported:
            phase = .unsupported
        case .appleTemporarilyUnavailable:
            phase = .temporarilyUnavailable
        default:
            phase = .safetyFailure
        }
    }

    private func bindDomainGeneration(
        ownerGeneration generation: UInt64,
        domainGeneration: UInt64
    ) {
        guard let run = active, run.ownerGeneration == generation,
              run.acceptsOutcome else { return }
        run.domainGeneration = domainGeneration
        if let buffered = run.bufferedOutcome {
            run.bufferedOutcome = nil
            guard buffered.0 == domainGeneration else {
                failSafety(run)
                return
            }
            handleDomainOutcome(run, domainGeneration: domainGeneration, outcome: buffered.1)
        }
    }

    private func receiveDomain(
        ownerGeneration generation: UInt64,
        domainGeneration: UInt64,
        outcome: NativeTranslationOutcome
    ) {
        guard let run = active, run.ownerGeneration == generation else { return }
        if let origin = run.terminalOrigin {
            if origin == .domain { failSafety(run) }
            return
        }
        guard run.acceptsOutcome else { return }
        guard let expected = run.domainGeneration else {
            guard run.bufferedOutcome == nil else {
                failSafety(run)
                return
            }
            run.bufferedOutcome = (domainGeneration, outcome)
            return
        }
        guard expected == domainGeneration else {
            failSafety(run)
            return
        }
        handleDomainOutcome(run, domainGeneration: domainGeneration, outcome: outcome)
    }

    private func handleDomainOutcome(
        _ run: ActiveRun,
        domainGeneration: UInt64,
        outcome: NativeTranslationOutcome
    ) {
        guard active === run, run.acceptsOutcome, run.terminalOrigin == nil else { return }
        if case .cancelled = outcome {
            run.acceptsOutcome = false
            cancelTranslationTimers()
            revokeHost(ownerGeneration: run.ownerGeneration)
            active = nil
            cleanupDomain(run, reason: .stop)
            overlay.invalidate(run.lease, .stop)
            phase = .stopped
            return
        }
        guard let receipt = run.expectedReceipt else {
            failSafety(run)
            return
        }
        let elapsed = max(0, Int((scheduler.now - run.startedAt) * 1_000))
        let inputWasTruncated: Bool
        if case let .success(success) = outcome {
            inputWasTruncated = success.inputWasTruncated
        } else {
            inputWasTruncated = false
        }
        let envelope = NativeTranslationAppleResultLabEnvelope(
            fixtureID: .appleFixedSample,
            provenance: .realAppleTranslation,
            requestedEngine: .apple,
            domainGeneration: domainGeneration,
            presentationLease: run.lease,
            hostReceipt: receipt,
            outcome: outcome,
            elapsedMilliseconds: elapsed,
            inputWasTruncated: inputWasTruncated
        )
        switch NativeTranslationAppleResultLabPresentationBridge.map(
            envelope,
            expectedDomainGeneration: domainGeneration,
            expectedLease: run.lease,
            expectedHostReceipt: receipt
        ) {
        case .drop:
            return
        case let .present(presentation):
            run.acceptsOutcome = false
            run.terminalOrigin = .domain
            cancelTranslationTimers()
            let didPresent = overlay.resolve(presentation, run.lease)
            guard active === run else { return }
            guard didPresent else {
                rejectPresentation(run)
                return
            }
            switch presentation.category {
            case .success:
                phase = .success
            case .appleNotice, .appleError:
                if case let .failure(failure) = outcome {
                    phase = .typedFailure(failure)
                } else {
                    failSafety(run)
                }
            case .safetyFailure:
                phase = .safetyFailure
            case .timeout:
                phase = .timeout
            case .loading:
                failSafety(run)
            }
        }
    }

    private func translationTimedOut(generation: UInt64) {
        guard let run = active, run.ownerGeneration == generation,
              run.acceptsOutcome, run.terminalOrigin == nil else { return }
        run.acceptsOutcome = false
        run.terminalOrigin = .ownerTimeout
        cancelTranslationTimers()
        revokeHost(ownerGeneration: generation)
        cleanupDomain(run, reason: .stop) { [weak self] in
            guard let self, self.active === run else { return }
            let didPresent = self.overlay.resolve(.timeout(), run.lease)
            guard self.active === run else { return }
            guard didPresent else {
                self.rejectPresentation(run)
                return
            }
            self.phase = .timeout
        }
    }

    private func failSafety(_ run: ActiveRun) {
        guard active === run else { return }
        run.acceptsOutcome = false
        run.terminalOrigin = .safety
        cancelTranslationTimers()
        revokeHost(ownerGeneration: run.ownerGeneration)
        cleanupDomain(run, reason: .ownerChanged) { [weak self] in
            guard let self, self.active === run else { return }
            let didPresent = self.overlay.resolve(.safetyFailure(), run.lease)
            guard self.active === run else { return }
            guard didPresent else {
                self.rejectPresentation(run)
                return
            }
            self.phase = .safetyFailure
        }
    }

    private func rejectPresentation(_ run: ActiveRun) {
        guard active === run else { return }
        run.acceptsOutcome = false
        revokeHost(ownerGeneration: run.ownerGeneration)
        active = nil
        cleanupDomain(run, reason: .ownerChanged)
        overlay.invalidate(run.lease, .stop)
        phase = .safetyFailure
    }

    private func stopWaiting() {
        switch phase {
        case .preparing:
            ownerGeneration &+= 1
            cancelAvailabilityAndTimers()
            pendingPreparation = false
            revokeHost(ownerGeneration: ownerGeneration)
            phase = .preparationWaitStopped
        case .translationPreflight, .acquiringHost, .running:
            invalidateCurrent(reason: .stop, overlayReason: .stop)
            ownerGeneration &+= 1
            cancelAvailabilityAndTimers()
            revokeHost(ownerGeneration: ownerGeneration)
            phase = .stopped
        case .checkingAvailability:
            ownerGeneration &+= 1
            cancelAvailabilityAndTimers()
            phase = .stopped
        default:
            break
        }
    }

    private func overlayDismissed(
        generation: UInt64,
        reason: NativeTranslationOverlayDismissReason
    ) {
        if pendingLeaseGeneration == generation {
            dismissedWhileMinting.insert(generation)
            return
        }
        guard let run = active, run.ownerGeneration == generation else { return }
        run.acceptsOutcome = false
        cancelTranslationTimers()
        revokeHost(ownerGeneration: generation)
        active = nil
        cleanupDomain(run, reason: invalidationReason(for: reason))
        if isPresented { phase = .stopped }
    }

    private func invalidateCurrent(
        reason: NativeTranslationInvalidationReason,
        overlayReason: NativeTranslationOverlayDismissReason
    ) {
        guard let run = active else { return }
        run.acceptsOutcome = false
        cancelTranslationTimers()
        revokeHost(ownerGeneration: run.ownerGeneration)
        active = nil
        cleanupDomain(run, reason: reason)
        overlay.invalidate(run.lease, overlayReason)
    }

    private func cleanupDomain(
        _ run: ActiveRun,
        reason: NativeTranslationInvalidationReason,
        completion: (@MainActor () -> Void)? = nil
    ) {
        guard !run.didInvalidateDomain else {
            completion?()
            return
        }
        run.didInvalidateDomain = true
        let beginTask = run.beginTask
        beginTask?.cancel()
        Task { [weak self] in
            if let beginTask { await beginTask.value }
            if let domain = run.domain { await domain.invalidate(reason) }
            guard self != nil else { return }
            completion?()
        }
    }

    private func revokeHost(ownerGeneration generation: UInt64) {
        cancelTimer(.hostAcquisition)
        hostRequest = nil
        if let claim = hostClaim {
            hostClaim = nil
            retiringHostClaim = claim
        }
        let continuation: CheckedContinuation<NativeTranslationEffectResult, Never>?
        if let run = active, run.ownerGeneration == generation,
           let pendingContinuation = run.effectContinuation {
            run.effectContinuation = nil
            continuation = pendingContinuation
        } else {
            continuation = nil
        }
        clearHostConfiguration(ownerGeneration: generation)
        continuation?.resume(returning: .cancelled)
    }

    private func clearHostConfiguration(ownerGeneration generation: UInt64) {
        hostConfigurationControl?(.invalidateAndClear(ownerGeneration: generation))
    }

    private func beginOwnerGeneration() {
        ownerGeneration &+= 1
        cancelAvailabilityAndTimers()
        pendingPreparation = false
        hostRequest = nil
    }

    private func schedule(
        _ kind: TimerKind,
        after delay: TimeInterval,
        generation: UInt64,
        _ action: @escaping @MainActor () -> Void
    ) {
        cancelTimer(kind)
        timers[kind] = scheduler.schedule(after: max(0, delay)) { [weak self] in
            guard let self, self.ownerGeneration == generation else { return }
            self.timers[kind] = nil
            action()
        }
    }

    private func cancelTimer(_ kind: TimerKind) {
        timers.removeValue(forKey: kind)?.cancel()
    }

    private func cancelTranslationTimers() {
        cancelTimer(.translationExtended)
        cancelTimer(.translationDeadline)
        cancelTimer(.hostAcquisition)
        cancelTimer(.availability)
    }

    private func cancelAvailabilityAndTimers() {
        availabilityTask?.cancel()
        availabilityTask = nil
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
    }

    private func remainingTime(for run: ActiveRun) -> TimeInterval {
        max(0, 12 - (scheduler.now - run.startedAt))
    }

    private func actionIsAllowed(
        _ action: NativeTranslationAppleResultLabAction,
        in phase: NativeTranslationAppleResultLabPhase
    ) -> Bool {
        switch (phase, action) {
        case (.checkingAvailability, .stopWaiting),
             (.ready, .translateFixture), (.ready, .recheckAvailability),
             (.needsPreparation, .prepareLanguages), (.needsPreparation, .recheckAvailability),
             (.unsupported, .recheckAvailability),
             (.temporarilyUnavailable, .recheckAvailability),
             (.hostUnavailable, .recheckAvailability),
             (.preparing, .stopWaiting),
             (.preparationWaitStopped, .recheckAvailability),
             (.preparationFailed, .recheckAvailability),
             (.translationPreflight, .stopWaiting),
             (.acquiringHost, .stopWaiting),
             (.running, .stopWaiting),
             (.success, .translateFixture), (.success, .recheckAvailability),
             (.typedFailure, .recheckAvailability),
             (.safetyFailure, .recheckAvailability),
             (.timeout, .translateFixture), (.timeout, .recheckAvailability),
             (.stopped, .recheckAvailability),
             (_, .close):
            return true
        default:
            return false
        }
    }

    private func invalidationReason(
        for reason: NativeTranslationOverlayDismissReason
    ) -> NativeTranslationInvalidationReason {
        switch reason {
        case .pause: return .pause
        case .revoke: return .accessibilityRevoked
        case .close, .outside, .escape, .stop: return .stop
        case .displayRemoved, .space, .session, .sleep, .terminate: return .ownerChanged
        }
    }

    private func dismissReason(
        for reason: NativeTranslationInvalidationReason
    ) -> NativeTranslationOverlayDismissReason {
        switch reason {
        case .pause: return .pause
        case .accessibilityRevoked: return .revoke
        case .stop: return .stop
        case .newRequest, .engineChanged, .credentialsChanged,
             .removalStateChanged, .ownerChanged:
            return .stop
        }
    }
}
#endif
