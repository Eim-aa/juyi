#if DEBUG && JUYI_NATIVE_SELECTION_CAPTURE_LAB && (JUYI_NATIVE_OWNER_HANDOFF_LAB || JUYI_NATIVE_OPTION_MONITOR || JUYI_NATIVE_TRANSLATION_DOMAIN || JUYI_NATIVE_TRANSLATION_OVERLAY || JUYI_NATIVE_TRANSLATION_RESULT_LAB || JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER || JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER || JUYI_NATIVE_APPLE_RESULT_LAB_BINDING)
#error("JUYI_NATIVE_SELECTION_CAPTURE_LAB is an isolated capture-only build and cannot be mixed with Option or translation development flags")
#endif

#if DEBUG && JUYI_NATIVE_SELECTION_CAPTURE_LAB
import Combine
import Foundation

public let nativeSelectionCaptureLabBuildSentinel =
    "juyi-native-selection-capture-lab-v1"

enum NativeSelectionCaptureLabAuthorization: Equatable {
    case authorized
    case notAuthorized
}

enum NativeSelectionCaptureLabTargetDecision: Equatable {
    case target(NativeSelectionTarget)
    case noForegroundApplication
    case selfTarget
    case unsupportedTarget
}

enum NativeSelectionCaptureLabCaptureResult: Equatable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    case success(text: String, didTruncate: Bool)
    case accessibilityRequired
    case noFocusedElement
    case noSelection
    case unsupported
    case secureField
    case temporarilyUnavailable
    case internalFailure
    case cancelled

    var description: String {
        switch self {
        case let .success(_, didTruncate):
            return "success([REDACTED], truncated: \(didTruncate))"
        case .accessibilityRequired: return "accessibility_required"
        case .noFocusedElement: return "no_focused_element"
        case .noSelection: return "no_selection"
        case .unsupported: return "unsupported"
        case .secureField: return "secure_field"
        case .temporarilyUnavailable: return "temporarily_unavailable"
        case .internalFailure: return "internal_failure"
        case .cancelled: return "cancelled"
        }
    }

    var debugDescription: String { description }
}

enum NativeSelectionCaptureLabFailure: Equatable {
    case accessibilityRequired
    case noForegroundApplication
    case selfTarget
    case unsupportedTarget
    case noFocusedElement
    case noSelection
    case unsupported
    case secureField
    case temporarilyUnavailable
    case internalFailure
    case cancelled
}

struct NativeSelectionCaptureLabCapturedText: Equatable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    let value: String

    var description: String { "NativeSelectionCaptureLabCapturedText([REDACTED])" }
    var debugDescription: String { description }
}

enum NativeSelectionCaptureLabPhase: Equatable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    case idle(authorization: NativeSelectionCaptureLabAuthorization)
    case requestingAuthorization
    case countdown(remaining: Int)
    case reading
    case result(
        text: NativeSelectionCaptureLabCapturedText,
        didTruncate: Bool,
        expiresAt: TimeInterval
    )
    case failure(NativeSelectionCaptureLabFailure)
    case expired
    case paused

    var retainedText: NativeSelectionCaptureLabCapturedText? {
        guard case let .result(text, _, _) = self else { return nil }
        return text
    }

    var description: String {
        switch self {
        case let .idle(authorization): return "idle(\(authorization))"
        case .requestingAuthorization: return "requesting_authorization"
        case let .countdown(remaining): return "countdown(\(remaining))"
        case .reading: return "reading"
        case let .result(_, didTruncate, expiresAt):
            return "result([REDACTED], truncated: \(didTruncate), expiresAt: \(expiresAt))"
        case let .failure(failure): return "failure(\(failure))"
        case .expired: return "expired"
        case .paused: return "paused"
        }
    }

    var debugDescription: String { description }
}

enum NativeSelectionCaptureLabAction: Equatable, Hashable {
    case requestAuthorization
    case recheckAuthorization
    case beginOneShotCapture
    case cancel
    case clearNow
    case close
}

enum NativeSelectionCaptureLabInvalidationReason: Equatable {
    case pause
    case stop
    case sleep
    case sessionResigned
    case accessibilityRevoked
    case terminate
}

@MainActor
final class NativeSelectionCaptureLabScheduledTask {
    private var cancelAction: (() -> Void)?

    init(cancelAction: @escaping () -> Void) {
        self.cancelAction = cancelAction
    }

    func cancel() {
        let action = cancelAction
        cancelAction = nil
        action?()
    }
}

struct NativeSelectionCaptureLabDependencies {
    typealias CaptureCompletion = (NativeSelectionCaptureLabCaptureResult) -> Void

    let authorizationStatus: () -> NativeSelectionCaptureLabAuthorization
    let requestAuthorization: () -> NativeSelectionCaptureLabAuthorization
    let targetProvider: () -> NativeSelectionCaptureLabTargetDecision
    let capture: (
        NativeSelectionTarget,
        @escaping CaptureCompletion
    ) -> Void
    let cancelCapture: () -> Void
    let applicationIsActive: () -> Bool
    let now: () -> TimeInterval
    let schedule: (
        _ delay: TimeInterval,
        _ action: @escaping () -> Void
    ) -> NativeSelectionCaptureLabScheduledTask
}

@MainActor
final class NativeSelectionCaptureLabCoordinator: ObservableObject {
    static let countdownDuration = 5
    static let resultTimeToLive: TimeInterval = 30
    static let accessibilityFeedback = "取词演练状态已更新，请返回句译查看。"
    static let maximumTextScalars = 5_000

    @Published private(set) var isPresented = false
    @Published private(set) var phase: NativeSelectionCaptureLabPhase

    private let dependencies: NativeSelectionCaptureLabDependencies
    private var authorization: NativeSelectionCaptureLabAuthorization
    private var generation: UInt64 = 0
    private var countdownTask: NativeSelectionCaptureLabScheduledTask?
    private var expiryTask: NativeSelectionCaptureLabScheduledTask?
    private var captureIsActive = false
    private var isPaused = false
    private var pendingFeedbackGeneration: UInt64?

    init(dependencies: NativeSelectionCaptureLabDependencies) {
        self.dependencies = dependencies
        authorization = .notAuthorized
        phase = .idle(authorization: .notAuthorized)
    }

    func open() {
        isPresented = true
        let expectedGeneration = tombstoneAndClear(
            finalPhase: isPaused
                ? .paused
                : .idle(authorization: authorization)
        )
        guard !isPaused else { return }
        let status = dependencies.authorizationStatus()
        guard isPresented, generation == expectedGeneration else { return }
        authorization = status
        phase = .idle(authorization: status)
    }

    func perform(_ action: NativeSelectionCaptureLabAction) {
        expireIfNeeded()
        guard canPerform(action) else { return }
        switch action {
        case .requestAuthorization:
            requestAuthorization()
        case .recheckAuthorization:
            recheckAuthorization()
        case .beginOneShotCapture:
            beginOneShotCapture()
        case .cancel:
            cancelCurrentAttempt()
        case .clearNow:
            _ = tombstoneAndClear(finalPhase: .idle(authorization: authorization))
        case .close:
            close()
        }
    }

    func canPerform(_ action: NativeSelectionCaptureLabAction) -> Bool {
        guard isPresented else { return false }
        if isPaused { return action == .close }
        switch action {
        case .requestAuthorization:
            guard !isBusy else { return false }
            return authorization == .notAuthorized
        case .recheckAuthorization:
            return !isBusy
        case .beginOneShotCapture:
            return !isBusy && authorization == .authorized
        case .cancel:
            return isBusy
        case .clearNow:
            return phase.retainedText != nil
        case .close:
            return true
        }
    }

    var isBusy: Bool {
        switch phase {
        case .requestingAuthorization, .countdown, .reading: return true
        default: return false
        }
    }

    func close() {
        guard isPresented else { return }
        isPresented = false
        _ = tombstoneAndClear(finalPhase: .expired)
    }

    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        if paused {
            _ = tombstoneAndClear(finalPhase: .paused)
        } else if phase == .paused {
            _ = tombstoneAndClear(finalPhase: .idle(authorization: authorization))
        }
    }

    func invalidate(_ reason: NativeSelectionCaptureLabInvalidationReason) {
        if isPaused {
            if reason == .accessibilityRevoked {
                authorization = .notAuthorized
            }
            _ = tombstoneAndClear(finalPhase: .paused)
            return
        }
        switch reason {
        case .accessibilityRevoked:
            authorization = .notAuthorized
            _ = tombstoneAndClear(
                finalPhase: isPresented
                    ? .idle(authorization: .notAuthorized)
                    : .expired
            )
        case .pause:
            isPaused = true
            _ = tombstoneAndClear(finalPhase: .paused)
        case .stop, .sleep, .sessionResigned, .terminate:
            _ = tombstoneAndClear(finalPhase: .expired)
        }
    }

    /// Returns one fixed, non-textual announcement only while Juyi is active.
    /// Completion while another app is active remains pending until this is
    /// called again after the user manually returns.
    func consumeAccessibilityFeedbackIfApplicationIsActive() -> String? {
        expireIfNeeded()
        guard isPresented,
              dependencies.applicationIsActive(),
              pendingFeedbackGeneration == generation else { return nil }
        pendingFeedbackGeneration = nil
        return Self.accessibilityFeedback
    }

    func expireIfNeeded() {
        guard isPresented,
              case let .result(_, _, expiresAt) = phase,
              dependencies.now() >= expiresAt else { return }
        _ = tombstoneAndClear(finalPhase: .expired)
    }

    private func requestAuthorization() {
        let expectedGeneration = tombstoneAndClear(
            finalPhase: .requestingAuthorization
        )
        let status = dependencies.requestAuthorization()
        guard isPresented, generation == expectedGeneration else { return }
        authorization = status
        phase = .idle(authorization: status)
    }

    private func recheckAuthorization() {
        let expectedGeneration = tombstoneAndClear(
            finalPhase: .idle(authorization: authorization)
        )
        let status = dependencies.authorizationStatus()
        guard isPresented, generation == expectedGeneration else { return }
        authorization = status
        phase = .idle(authorization: status)
    }

    private func beginOneShotCapture() {
        let attemptGeneration = tombstoneAndClear(
            finalPhase: .idle(authorization: authorization)
        )
        let freshStatus = dependencies.authorizationStatus()
        guard isPresented, generation == attemptGeneration else { return }
        authorization = freshStatus
        guard freshStatus == .authorized else {
            phase = .failure(.accessibilityRequired)
            pendingFeedbackGeneration = attemptGeneration
            return
        }

        phase = .countdown(remaining: Self.countdownDuration)
        scheduleCountdown(
            remaining: Self.countdownDuration,
            generation: attemptGeneration
        )
    }

    private func scheduleCountdown(remaining: Int, generation expected: UInt64) {
        countdownTask = dependencies.schedule(1) { [weak self] in
            guard let self,
                  self.isPresented,
                  !self.isPaused,
                  self.generation == expected,
                  case .countdown = self.phase else { return }
            self.countdownTask = nil
            if remaining > 1 {
                self.phase = .countdown(remaining: remaining - 1)
                self.scheduleCountdown(
                    remaining: remaining - 1,
                    generation: expected
                )
            } else {
                self.beginReading(generation: expected)
            }
        }
    }

    private func beginReading(generation expected: UInt64) {
        guard isPresented, !isPaused, generation == expected else { return }
        let status = dependencies.authorizationStatus()
        guard isPresented,
              !isPaused,
              generation == expected,
              case .countdown = phase else { return }
        authorization = status
        guard status == .authorized else {
            finishFailure(.accessibilityRequired, generation: expected)
            return
        }

        let decision = dependencies.targetProvider()
        guard isPresented,
              !isPaused,
              generation == expected,
              case .countdown = phase else { return }
        let target: NativeSelectionTarget
        switch decision {
        case let .target(candidate):
            guard candidate.processIdentifier > 0,
                  let bundleIdentifier = candidate.bundleIdentifier,
                  !bundleIdentifier.trimmingCharacters(
                      in: .whitespacesAndNewlines
                  ).isEmpty else {
                finishFailure(.unsupportedTarget, generation: expected)
                return
            }
            target = candidate
        case .noForegroundApplication:
            finishFailure(.noForegroundApplication, generation: expected)
            return
        case .selfTarget:
            finishFailure(.selfTarget, generation: expected)
            return
        case .unsupportedTarget:
            finishFailure(.unsupportedTarget, generation: expected)
            return
        }

        phase = .reading
        captureIsActive = true
        dependencies.capture(target) { [weak self] result in
            self?.receiveCapture(result, generation: expected)
        }
    }

    private func receiveCapture(
        _ result: NativeSelectionCaptureLabCaptureResult,
        generation expected: UInt64
    ) {
        guard isPresented,
              !isPaused,
              generation == expected,
              captureIsActive,
              phase == .reading else { return }
        captureIsActive = false

        switch result {
        case let .success(rawText, didTruncate):
            let scalarCount = rawText.unicodeScalars.count
            guard scalarCount > 0, scalarCount <= Self.maximumTextScalars else {
                finishFailure(.internalFailure, generation: expected)
                return
            }
            let expiresAt = dependencies.now() + Self.resultTimeToLive
            phase = .result(
                text: NativeSelectionCaptureLabCapturedText(value: rawText),
                didTruncate: didTruncate,
                expiresAt: expiresAt
            )
            pendingFeedbackGeneration = expected
            expiryTask = dependencies.schedule(Self.resultTimeToLive) { [weak self] in
                guard let self,
                      self.isPresented,
                      self.generation == expected,
                      self.phase.retainedText != nil else { return }
                _ = self.tombstoneAndClear(finalPhase: .expired)
            }
        case .accessibilityRequired:
            authorization = .notAuthorized
            finishFailure(.accessibilityRequired, generation: expected)
        case .noFocusedElement:
            finishFailure(.noFocusedElement, generation: expected)
        case .noSelection:
            finishFailure(.noSelection, generation: expected)
        case .unsupported:
            finishFailure(.unsupported, generation: expected)
        case .secureField:
            finishFailure(.secureField, generation: expected)
        case .temporarilyUnavailable:
            finishFailure(.temporarilyUnavailable, generation: expected)
        case .internalFailure:
            finishFailure(.internalFailure, generation: expected)
        case .cancelled:
            finishFailure(.cancelled, generation: expected)
        }
    }

    private func finishFailure(
        _ failure: NativeSelectionCaptureLabFailure,
        generation expected: UInt64
    ) {
        guard isPresented, generation == expected else { return }
        captureIsActive = false
        phase = .failure(failure)
        pendingFeedbackGeneration = expected
    }

    private func cancelCurrentAttempt() {
        let cancelledGeneration = tombstoneAndClear(
            finalPhase: .failure(.cancelled)
        )
        pendingFeedbackGeneration = cancelledGeneration
    }

    /// Advances the public owner generation and drops the only retained text
    /// before invoking injected cancellation callbacks, making synchronous
    /// cancellation and reentrancy unable to revive the old attempt.
    @discardableResult
    private func tombstoneAndClear(
        finalPhase: NativeSelectionCaptureLabPhase
    ) -> UInt64 {
        generation &+= 1
        let oldCountdownTask = countdownTask
        let oldExpiryTask = expiryTask
        let shouldCancelCapture = captureIsActive
        countdownTask = nil
        expiryTask = nil
        captureIsActive = false
        pendingFeedbackGeneration = nil
        phase = finalPhase

        oldCountdownTask?.cancel()
        oldExpiryTask?.cancel()
        if shouldCancelCapture { dependencies.cancelCapture() }
        return generation
    }
}
#endif
