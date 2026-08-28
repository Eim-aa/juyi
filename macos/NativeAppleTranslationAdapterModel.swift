#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && !JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
import Combine
import Foundation

public let nativeAppleTranslationAdapterBuildSentinel =
    "juyi-native-apple-translation-adapter-v1"

enum NativeAppleTranslationAdapterFixture {
    static let sourceText = "The weather is pleasant today."
    static let sourceLanguageIdentifier = "en"
    static let targetLanguageIdentifier = "zh-Hans"
}

enum NativeAppleTranslationAdapterPhase: Equatable {
    case hidden
    case checking
    case ready
    case needsPreparation
    case unsupported
    case temporarilyUnavailable
    case preparing(extendedWait: Bool)
    case preparationWaitStopped
    case preparationFailed
    case translating(extendedWait: Bool)
    case translationTimedOut
    case translationFailed
    case success

    var isBusy: Bool {
        switch self {
        case .checking, .preparing, .translating:
            return true
        default:
            return false
        }
    }
}

struct NativeAppleTranslationAdapterSnapshot: Equatable {
    let generation: UInt64
    let phase: NativeAppleTranslationAdapterPhase
    let outcome: NativeTranslationOutcome?

    static let hidden = NativeAppleTranslationAdapterSnapshot(
        generation: 0,
        phase: .hidden,
        outcome: nil
    )

    var targetText: String? {
        guard case let .success(success)? = outcome else { return nil }
        return success.text
    }
}

enum NativeAppleTranslationAdapterAction: Equatable, Hashable {
    case translateFixture
    case recheckAvailability
    case prepareLanguages
    case retryPreparation
    case retryTranslation
    case cancelOperation
    case close
}

struct NativeAppleTranslationAdapterPresentation: Equatable {
    let title: String
    let message: String
    let primaryAction: NativeAppleTranslationAdapterAction?
    let primaryTitle: String?
    let secondaryAction: NativeAppleTranslationAdapterAction?
    let secondaryTitle: String?

    static func make(for phase: NativeAppleTranslationAdapterPhase) -> Self {
        switch phase {
        case .hidden:
            return Self(title: "", message: "", primaryAction: nil, primaryTitle: nil,
                        secondaryAction: nil, secondaryTitle: nil)
        case .checking:
            return Self(
                title: "正在检查 Apple 离线翻译",
                message: "只检查英语→简体中文语言资源，不会开始下载。",
                primaryAction: nil,
                primaryTitle: nil,
                secondaryAction: nil,
                secondaryTitle: nil
            )
        case .ready:
            return Self(
                title: "Apple 离线翻译已准备好",
                message: "可以使用源码内置的固定英文验证本机翻译链路。",
                primaryAction: .translateFixture,
                primaryTitle: "翻译固定样例",
                secondaryAction: .recheckAvailability,
                secondaryTitle: "重新检查"
            )
        case .needsPreparation:
            return Self(
                title: "需要准备 Apple 离线语言包",
                message: "只有你点击后，macOS 才会请求下载英语→简体中文语言资源。",
                primaryAction: .prepareLanguages,
                primaryTitle: "准备语言包…",
                secondaryAction: .recheckAvailability,
                secondaryTitle: "重新检查"
            )
        case .unsupported:
            return Self(
                title: "这台 Mac 不支持 Apple 离线翻译",
                message: "当前测试不会改用火山云端。",
                primaryAction: .recheckAvailability,
                primaryTitle: "重新检查",
                secondaryAction: nil,
                secondaryTitle: nil
            )
        case .temporarilyUnavailable:
            return Self(
                title: "暂时无法检查 Apple 离线翻译",
                message: "请稍后重试；当前测试不会改用云端。",
                primaryAction: .recheckAvailability,
                primaryTitle: "重新检查",
                secondaryAction: nil,
                secondaryTitle: nil
            )
        case let .preparing(extendedWait):
            return Self(
                title: "正在准备 Apple 离线语言包…",
                message: extendedWait
                    ? "仍在等待 macOS 完成…下载由系统管理。"
                    : "请按 macOS 提示确认；下载由系统管理。",
                primaryAction: nil,
                primaryTitle: nil,
                secondaryAction: .cancelOperation,
                secondaryTitle: "停止等待"
            )
        case .preparationFailed:
            return Self(
                title: "Apple 离线语言包没有准备完成",
                message: "请确认系统提示后重试。",
                primaryAction: .retryPreparation,
                primaryTitle: "重新准备…",
                secondaryAction: .recheckAvailability,
                secondaryTitle: "检查状态"
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
        case let .translating(extendedWait):
            return Self(
                title: "正在翻译固定样例…",
                message: extendedWait ? "仍在这台 Mac 上处理…" : "正文正在这台 Mac 上处理。",
                primaryAction: nil,
                primaryTitle: nil,
                secondaryAction: .cancelOperation,
                secondaryTitle: "取消测试"
            )
        case .translationTimedOut:
            return Self(
                title: "Apple 离线翻译暂时没有响应",
                message: "请稍后重试；不会自动改用云端。",
                primaryAction: .retryTranslation,
                primaryTitle: "重试",
                secondaryAction: .recheckAvailability,
                secondaryTitle: "重新检查"
            )
        case .translationFailed:
            return Self(
                title: "Apple 离线翻译未能完成测试",
                message: "请稍后重试，或重新检查语言包状态。",
                primaryAction: .retryTranslation,
                primaryTitle: "重试",
                secondaryAction: .recheckAvailability,
                secondaryTitle: "检查语言包"
            )
        case .success:
            return Self(
                title: "Apple 离线翻译测试成功",
                message: "结果只保存在当前窗口，关闭后即丢弃。",
                primaryAction: .translateFixture,
                primaryTitle: "再次翻译",
                secondaryAction: nil,
                secondaryTitle: nil
            )
        }
    }
}

struct NativeAppleTranslationAdapterActionItem: Equatable, Identifiable {
    let action: NativeAppleTranslationAdapterAction
    let title: String
    let isPrimary: Bool
    var id: NativeAppleTranslationAdapterAction { action }
}

enum NativeAppleTranslationAdapterInteractionPolicy {
    static func orderedActions(
        phase: NativeAppleTranslationAdapterPhase,
        presentation: NativeAppleTranslationAdapterPresentation
    ) -> [NativeAppleTranslationAdapterActionItem] {
        var result: [NativeAppleTranslationAdapterActionItem] = []
        if let action = presentation.primaryAction,
           let title = presentation.primaryTitle,
           action != .close
        {
            result.append(.init(action: action, title: title, isPrimary: true))
        }
        if let action = presentation.secondaryAction,
           let title = presentation.secondaryTitle,
           action != .close,
           !result.contains(where: { $0.action == action })
        {
            result.append(.init(action: action, title: title, isPrimary: false))
        }
        result.append(
            .init(
                action: .close,
                title: phase == .success ? "完成" : "关闭",
                isPrimary: false
            )
        )
        return result
    }
}

enum NativeAppleTranslationHostConfigurationTransition: Equatable {
    case noChange
    case create
    case invalidate
    case clear
}

enum NativeAppleTranslationHostConfigurationPolicy {
    static func transition(
        from currentRequest: NativeAppleTranslationHostRequest?,
        to nextRequest: NativeAppleTranslationHostRequest?,
        hasConfiguration: Bool
    ) -> NativeAppleTranslationHostConfigurationTransition {
        guard currentRequest != nextRequest else { return .noChange }
        guard nextRequest != nil else { return .clear }
        return hasConfiguration ? .invalidate : .create
    }
}

enum NativeAppleTranslationHostIntent: Equatable, Sendable {
    case prepare
    case translate
}

struct NativeAppleTranslationHostRequest: Equatable, Sendable {
    let generation: UInt64
    let intent: NativeAppleTranslationHostIntent
}

struct NativeAppleTranslationHostClaim: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    let generation: UInt64
    let intent: NativeAppleTranslationHostIntent
    let sourceText: String?

    var description: String {
        "NativeAppleTranslationHostClaim(generation: \(generation), intent: \(intent), source: [REDACTED])"
    }

    var debugDescription: String { description }
}

enum NativeAppleTranslationHostCompletion: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    case prepared
    case translated(String)
    case failure(NativeTranslationFailure)
    case cancelled

    var description: String {
        switch self {
        case .prepared: return "prepared"
        case .translated: return "translated([REDACTED])"
        case let .failure(failure): return "failure(\(failure.description))"
        case .cancelled: return "cancelled"
        }
    }

    var debugDescription: String { description }
}

struct NativeAppleTranslationAvailabilityClient: Sendable {
    let query: @Sendable () async -> NativeAppleTranslationReadiness
}

@MainActor
protocol NativeAppleTranslationScheduledTask: AnyObject {
    func cancel()
}

@MainActor
protocol NativeAppleTranslationScheduling: AnyObject {
    var now: TimeInterval { get }
    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> any NativeAppleTranslationScheduledTask
}

@MainActor
final class NativeAppleTranslationSystemScheduledTask: NativeAppleTranslationScheduledTask {
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
final class NativeAppleTranslationSystemScheduler: NativeAppleTranslationScheduling {
    private let clock = ContinuousClock()
    private let origin: ContinuousClock.Instant

    init() {
        origin = clock.now
    }

    var now: TimeInterval {
        let components = origin.duration(to: clock.now).components
        return Double(components.seconds) + Double(components.attoseconds) / 1_000_000_000_000_000_000
    }

    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> any NativeAppleTranslationScheduledTask {
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
        return NativeAppleTranslationSystemScheduledTask(task: task)
    }
}

enum NativeAppleTranslationAdapterInvalidationReason: Equatable {
    case close
    case newRequest
    case pause
    case stop
    case engineChanged
    case terminate
}

@MainActor
final class NativeAppleTranslationAdapterCoordinator: ObservableObject {
    typealias Announcement = @MainActor (String) -> Void

    @Published private(set) var isPresented = false
    @Published private(set) var snapshot = NativeAppleTranslationAdapterSnapshot.hidden
    @Published private(set) var hostRequest: NativeAppleTranslationHostRequest?
    @Published private(set) var fixtureSourceText: String?

    private enum AvailabilityPurpose: Equatable {
        case opening
        case translationPreflight
        case preparationRecheck
        case translationFailureRecheck
    }

    private enum TimerKind: Hashable {
        case availability
        case hostAcquisition
        case translationExtended
        case translationDeadline
        case preparationExtended
    }

    private let availability: NativeAppleTranslationAvailabilityClient
    private let scheduler: any NativeAppleTranslationScheduling
    private let announce: Announcement

    private var generation: UInt64 = 0
    private var activeGeneration: UInt64?
    private var availabilityTask: Task<Void, Never>?
    private var timers: [TimerKind: any NativeAppleTranslationScheduledTask] = [:]
    private var hostClaimed = false
    private var translationDeadline: TimeInterval?
    private var announcedGeneration: UInt64?

    init(
        availability: NativeAppleTranslationAvailabilityClient,
        scheduler: any NativeAppleTranslationScheduling,
        announce: @escaping Announcement
    ) {
        self.availability = availability
        self.scheduler = scheduler
        self.announce = announce
    }

    var presentation: NativeAppleTranslationAdapterPresentation {
        NativeAppleTranslationAdapterPresentation.make(for: snapshot.phase)
    }

    func open() {
        beginGeneration(phase: .checking)
        isPresented = true
        fixtureSourceText = NativeAppleTranslationAdapterFixture.sourceText
        startAvailabilityCheck(purpose: .opening, generation: generation)
    }

    func recheckAvailability() {
        guard isPresented else { return }
        beginGeneration(phase: .checking)
        startAvailabilityCheck(purpose: .opening, generation: generation)
    }

    func beginTranslation() {
        guard isPresented else { return }
        switch snapshot.phase {
        case .ready, .success, .translationTimedOut, .translationFailed:
            break
        default:
            return
        }
        beginGeneration(phase: .translating(extendedWait: false))
        translationDeadline = scheduler.now + 12
        schedule(.translationExtended, after: 2, generation: generation) { [weak self] in
            guard let self, case .translating = self.snapshot.phase else { return }
            self.publish(.translating(extendedWait: true), outcome: nil, generation: self.generation)
        }
        schedule(.translationDeadline, after: 12, generation: generation) { [weak self] in
            self?.finishFailure(
                .appleTemporarilyUnavailable,
                phase: .translationTimedOut,
                generation: self?.generation ?? 0
            )
        }
        startAvailabilityCheck(purpose: .translationPreflight, generation: generation)
    }

    func beginPreparation() {
        guard isPresented,
              snapshot.phase == .needsPreparation || snapshot.phase == .preparationFailed
        else { return }
        beginGeneration(phase: .preparing(extendedWait: false))
        schedule(.preparationExtended, after: 30, generation: generation) { [weak self] in
            guard let self, case .preparing = self.snapshot.phase else { return }
            self.publish(.preparing(extendedWait: true), outcome: nil, generation: self.generation)
        }
        issueHostRequest(.prepare, generation: generation)
    }

    func perform(_ action: NativeAppleTranslationAdapterAction) {
        switch action {
        case .translateFixture, .retryTranslation:
            beginTranslation()
        case .recheckAvailability:
            recheckAvailability()
        case .prepareLanguages, .retryPreparation:
            beginPreparation()
        case .cancelOperation:
            cancelCurrentOperation()
        case .close:
            close()
        }
    }

    func handleEscape() {
        if snapshot.phase.isBusy {
            cancelCurrentOperation()
        } else {
            close()
        }
    }

    func close() {
        invalidate(.close)
    }

    func invalidate(_ reason: NativeAppleTranslationAdapterInvalidationReason) {
        generation &+= 1
        cancelWork()
        activeGeneration = nil
        translationDeadline = nil
        fixtureSourceText = nil
        hostRequest = nil
        hostClaimed = false
        isPresented = false
        snapshot = NativeAppleTranslationAdapterSnapshot(
            generation: generation,
            phase: .hidden,
            outcome: nil
        )
        _ = reason
    }

    func claimHost(_ request: NativeAppleTranslationHostRequest) -> NativeAppleTranslationHostClaim? {
        guard isCurrent(request.generation), hostRequest == request, !hostClaimed else { return nil }
        let sourceText: String?
        switch request.intent {
        case .prepare:
            sourceText = nil
        case .translate:
            guard case let .ready(input) = NativeTranslationInputPolicy.prepare(fixtureSourceText),
                  input.text == NativeAppleTranslationAdapterFixture.sourceText
            else {
                finishFailure(
                    .appleExecutionFailed,
                    phase: .translationFailed,
                    generation: request.generation
                )
                return nil
            }
            sourceText = input.text
        }
        hostClaimed = true
        cancelTimer(.hostAcquisition)
        return NativeAppleTranslationHostClaim(
            generation: request.generation,
            intent: request.intent,
            sourceText: sourceText
        )
    }

    func completeHost(
        _ completion: NativeAppleTranslationHostCompletion,
        request: NativeAppleTranslationHostRequest
    ) {
        guard isCurrent(request.generation), hostRequest == request, hostClaimed else { return }
        hostRequest = nil
        hostClaimed = false

        switch (request.intent, completion) {
        case (.prepare, .prepared), (.prepare, .failure):
            cancelTimer(.preparationExtended)
            startAvailabilityCheck(purpose: .preparationRecheck, generation: request.generation)
        case (.prepare, .cancelled):
            cancelCurrentOperation()
        case (.prepare, .translated):
            finishFailure(.appleExecutionFailed, phase: .preparationFailed, generation: request.generation)

        case let (.translate, .translated(targetText)):
            guard validTarget(targetText) else {
                finishFailure(.appleExecutionFailed, phase: .translationFailed, generation: request.generation)
                return
            }
            let success = NativeTranslationSuccess(
                engine: .apple,
                text: targetText,
                inputWasTruncated: false
            )
            finish(
                phase: .success,
                outcome: .success(success),
                generation: request.generation,
                announcement: "句译，Apple 离线翻译测试成功"
            )
        case (.translate, .failure):
            startAvailabilityCheck(purpose: .translationFailureRecheck, generation: request.generation)
        case (.translate, .cancelled):
            cancelCurrentOperation()
        case (.translate, .prepared):
            finishFailure(.appleExecutionFailed, phase: .translationFailed, generation: request.generation)
        }
    }

    private func beginGeneration(phase: NativeAppleTranslationAdapterPhase) {
        generation &+= 1
        cancelWork()
        activeGeneration = generation
        translationDeadline = nil
        hostRequest = nil
        hostClaimed = false
        fixtureSourceText = NativeAppleTranslationAdapterFixture.sourceText
        publish(phase, outcome: nil, generation: generation)
    }

    private func cancelCurrentOperation() {
        guard isPresented else { return }
        let restoredPhase: NativeAppleTranslationAdapterPhase
        switch snapshot.phase {
        case .preparing:
            restoredPhase = .preparationWaitStopped
        case .translating:
            restoredPhase = .ready
        default:
            invalidate(.close)
            return
        }
        generation &+= 1
        cancelWork()
        activeGeneration = nil
        translationDeadline = nil
        hostRequest = nil
        hostClaimed = false
        publish(restoredPhase, outcome: nil, generation: generation)
    }

    private func startAvailabilityCheck(
        purpose: AvailabilityPurpose,
        generation requestGeneration: UInt64
    ) {
        guard isCurrent(requestGeneration) else { return }
        cancelTimer(.availability)
        let timeout = min(5, remainingTranslationTime() ?? 5)
        guard timeout > 0 else {
            finishFailure(
                .appleTemporarilyUnavailable,
                phase: .translationTimedOut,
                generation: requestGeneration
            )
            return
        }
        schedule(.availability, after: timeout, generation: requestGeneration) { [weak self] in
            guard let self else { return }
            let phase: NativeAppleTranslationAdapterPhase = purpose == .translationPreflight
                && self.remainingTranslationTime() == 0
                ? .translationTimedOut : .temporarilyUnavailable
            self.finishFailure(
                .appleTemporarilyUnavailable,
                phase: phase,
                generation: requestGeneration
            )
        }
        availabilityTask?.cancel()
        availabilityTask = Task { [weak self, availability] in
            let readiness = await availability.query()
            guard !Task.isCancelled else { return }
            self?.receiveAvailability(
                readiness,
                purpose: purpose,
                generation: requestGeneration
            )
        }
    }

    private func receiveAvailability(
        _ readiness: NativeAppleTranslationReadiness,
        purpose: AvailabilityPurpose,
        generation requestGeneration: UInt64
    ) {
        guard isCurrent(requestGeneration) else { return }
        cancelTimer(.availability)
        availabilityTask = nil
        switch purpose {
        case .opening:
            finishReadiness(readiness, generation: requestGeneration)

        case .translationPreflight:
            switch readiness {
            case .installed:
                issueHostRequest(.translate, generation: requestGeneration)
            case .supportedNeedsPreparation:
                finishFailure(.appleNeedsPreparation, phase: .needsPreparation, generation: requestGeneration)
            case .unsupported:
                finishFailure(.appleUnsupported, phase: .unsupported, generation: requestGeneration)
            case .temporarilyUnavailable:
                finishFailure(
                    .appleTemporarilyUnavailable,
                    phase: .temporarilyUnavailable,
                    generation: requestGeneration
                )
            }

        case .preparationRecheck:
            switch readiness {
            case .installed:
                finish(phase: .ready, outcome: nil, generation: requestGeneration, announcement: nil)
            case .supportedNeedsPreparation:
                finishFailure(.appleNeedsPreparation, phase: .preparationFailed, generation: requestGeneration)
            case .unsupported:
                finishFailure(.appleUnsupported, phase: .unsupported, generation: requestGeneration)
            case .temporarilyUnavailable:
                finishFailure(
                    .appleTemporarilyUnavailable,
                    phase: .temporarilyUnavailable,
                    generation: requestGeneration
                )
            }

        case .translationFailureRecheck:
            switch readiness {
            case .installed:
                finishFailure(.appleExecutionFailed, phase: .translationFailed, generation: requestGeneration)
            case .supportedNeedsPreparation:
                finishFailure(.appleNeedsPreparation, phase: .needsPreparation, generation: requestGeneration)
            case .unsupported:
                finishFailure(.appleUnsupported, phase: .unsupported, generation: requestGeneration)
            case .temporarilyUnavailable:
                finishFailure(
                    .appleTemporarilyUnavailable,
                    phase: .temporarilyUnavailable,
                    generation: requestGeneration
                )
            }
        }
    }

    private func finishReadiness(
        _ readiness: NativeAppleTranslationReadiness,
        generation requestGeneration: UInt64
    ) {
        switch readiness {
        case .installed:
            finish(phase: .ready, outcome: nil, generation: requestGeneration, announcement: nil)
        case .supportedNeedsPreparation:
            finishFailure(.appleNeedsPreparation, phase: .needsPreparation, generation: requestGeneration)
        case .unsupported:
            finishFailure(.appleUnsupported, phase: .unsupported, generation: requestGeneration)
        case .temporarilyUnavailable:
            finishFailure(
                .appleTemporarilyUnavailable,
                phase: .temporarilyUnavailable,
                generation: requestGeneration
            )
        }
    }

    private func issueHostRequest(
        _ intent: NativeAppleTranslationHostIntent,
        generation requestGeneration: UInt64
    ) {
        guard isCurrent(requestGeneration) else { return }
        hostRequest = NativeAppleTranslationHostRequest(
            generation: requestGeneration,
            intent: intent
        )
        hostClaimed = false
        let timeout = min(5, remainingTranslationTime() ?? 5)
        guard timeout > 0 else {
            finishFailure(
                .appleTemporarilyUnavailable,
                phase: intent == .translate ? .translationTimedOut : .temporarilyUnavailable,
                generation: requestGeneration
            )
            return
        }
        schedule(.hostAcquisition, after: timeout, generation: requestGeneration) { [weak self] in
            self?.finishFailure(
                .appleTemporarilyUnavailable,
                phase: .temporarilyUnavailable,
                generation: requestGeneration
            )
        }
    }

    private func finishFailure(
        _ failure: NativeTranslationFailure,
        phase: NativeAppleTranslationAdapterPhase,
        generation requestGeneration: UInt64
    ) {
        finish(
            phase: phase,
            outcome: .failure(failure),
            generation: requestGeneration,
            announcement: "句译，\(NativeAppleTranslationAdapterPresentation.make(for: phase).title)"
        )
    }

    private func finish(
        phase: NativeAppleTranslationAdapterPhase,
        outcome: NativeTranslationOutcome?,
        generation requestGeneration: UInt64,
        announcement: String?
    ) {
        guard isCurrent(requestGeneration) else { return }
        cancelWork()
        activeGeneration = nil
        translationDeadline = nil
        hostRequest = nil
        hostClaimed = false
        publish(phase, outcome: outcome, generation: requestGeneration)
        if let announcement, announcedGeneration != requestGeneration {
            announcedGeneration = requestGeneration
            announce(announcement)
        }
    }

    private func publish(
        _ phase: NativeAppleTranslationAdapterPhase,
        outcome: NativeTranslationOutcome?,
        generation requestGeneration: UInt64
    ) {
        guard requestGeneration == generation else { return }
        snapshot = NativeAppleTranslationAdapterSnapshot(
            generation: requestGeneration,
            phase: phase,
            outcome: outcome
        )
    }

    private func schedule(
        _ kind: TimerKind,
        after delay: TimeInterval,
        generation requestGeneration: UInt64,
        _ action: @escaping @MainActor () -> Void
    ) {
        cancelTimer(kind)
        timers[kind] = scheduler.schedule(after: delay) { [weak self] in
            guard let self, self.isCurrent(requestGeneration) else { return }
            self.timers[kind] = nil
            action()
        }
    }

    private func cancelTimer(_ kind: TimerKind) {
        timers.removeValue(forKey: kind)?.cancel()
    }

    private func cancelWork() {
        availabilityTask?.cancel()
        availabilityTask = nil
        for timer in timers.values { timer.cancel() }
        timers.removeAll()
    }

    private func remainingTranslationTime() -> TimeInterval? {
        guard let translationDeadline else { return nil }
        return max(0, translationDeadline - scheduler.now)
    }

    private func isCurrent(_ requestGeneration: UInt64) -> Bool {
        isPresented && generation == requestGeneration && activeGeneration == requestGeneration
    }

    private func validTarget(_ text: String) -> Bool {
        !text.isEmpty && !text.unicodeScalars.allSatisfy { $0.properties.isWhitespace }
    }
}
#endif
