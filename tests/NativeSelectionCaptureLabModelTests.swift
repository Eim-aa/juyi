#if DEBUG && JUYI_NATIVE_SELECTION_CAPTURE_LAB
import Foundation

@main
@MainActor
enum NativeSelectionCaptureLabModelTests {
    @MainActor
    private final class ManualClock {
        final class Entry {
            let deadline: TimeInterval
            let action: () -> Void
            var cancelled = false

            init(deadline: TimeInterval, action: @escaping () -> Void) {
                self.deadline = deadline
                self.action = action
            }
        }

        var now: TimeInterval = 100
        private var entries: [Entry] = []

        func schedule(
            after delay: TimeInterval,
            action: @escaping () -> Void
        ) -> NativeSelectionCaptureLabScheduledTask {
            let entry = Entry(deadline: now + delay, action: action)
            entries.append(entry)
            return NativeSelectionCaptureLabScheduledTask {
                entry.cancelled = true
            }
        }

        func advance(by interval: TimeInterval) {
            let destination = now + interval
            while let next = entries
                .filter({ !$0.cancelled && $0.deadline <= destination })
                .min(by: { $0.deadline < $1.deadline })
            {
                entries.removeAll { $0 === next }
                now = next.deadline
                next.action()
            }
            now = destination
        }
    }

    @MainActor
    private final class Harness {
        let clock = ManualClock()
        var authorization: NativeSelectionCaptureLabAuthorization = .authorized
        var requestedAuthorization: NativeSelectionCaptureLabAuthorization = .authorized
        var applicationIsActive = true
        var targetDecision: NativeSelectionCaptureLabTargetDecision = .target(
            NativeSelectionTarget(
                processIdentifier: 200,
                launchDate: Date(timeIntervalSince1970: 1_234),
                bundleIdentifier: "com.example.editor"
            )
        )
        var authorizationReads = 0
        var authorizationRequests = 0
        var targetReads = 0
        var captures: [NativeSelectionTarget] = []
        var cancelCaptureCount = 0
        var completions: [NativeSelectionCaptureLabDependencies.CaptureCompletion] = []
        lazy var coordinator = NativeSelectionCaptureLabCoordinator(
            dependencies: NativeSelectionCaptureLabDependencies(
                authorizationStatus: { [unowned self] in
                    authorizationReads += 1
                    return authorization
                },
                requestAuthorization: { [unowned self] in
                    authorizationRequests += 1
                    authorization = requestedAuthorization
                    return requestedAuthorization
                },
                targetProvider: { [unowned self] in
                    targetReads += 1
                    return targetDecision
                },
                capture: { [unowned self] target, completion in
                    captures.append(target)
                    completions.append(completion)
                },
                cancelCapture: { [unowned self] in cancelCaptureCount += 1 },
                applicationIsActive: { [unowned self] in applicationIsActive },
                now: { [unowned self] in clock.now },
                schedule: { [unowned self] delay, action in
                    clock.schedule(after: delay, action: action)
                }
            )
        )

        func reachReading() {
            coordinator.open()
            coordinator.perform(.beginOneShotCapture)
            clock.advance(by: 5)
        }
    }

    private static var passed = 0

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            FileHandle.standardError.write(Data(("FAIL: \(message)\n").utf8))
            exit(1)
        }
        passed += 1
    }

    private static func testOpenAndPermissionAreExplicit() {
        let harness = Harness()
        harness.authorization = .notAuthorized
        harness.requestedAuthorization = .authorized
        harness.coordinator.open()
        expect(harness.authorizationReads == 1, "open performs one read-only check")
        expect(harness.authorizationRequests == 0, "open never requests authorization")
        expect(harness.targetReads == 0 && harness.captures.isEmpty, "open captures nothing")
        expect(
            harness.coordinator.phase == .idle(authorization: .notAuthorized),
            "open publishes denied status"
        )
        expect(harness.coordinator.canPerform(.requestAuthorization), "request is explicit")

        harness.coordinator.perform(.requestAuthorization)
        expect(harness.authorizationRequests == 1, "one click makes one request")
        expect(
            harness.coordinator.phase == .idle(authorization: .authorized),
            "request only refreshes authorization"
        )
        expect(harness.targetReads == 0 && harness.captures.isEmpty, "grant never auto-captures")
    }

    private static func testManualFiveSecondCountdownReadsTargetOnce() {
        let harness = Harness()
        harness.coordinator.open()
        harness.coordinator.perform(.beginOneShotCapture)
        expect(harness.coordinator.phase == .countdown(remaining: 5), "countdown starts at five")
        expect(harness.targetReads == 0, "target is not retained at button time")

        for remaining in stride(from: 4, through: 1, by: -1) {
            harness.clock.advance(by: 1)
            expect(
                harness.coordinator.phase == .countdown(remaining: remaining),
                "visual countdown advances deterministically"
            )
            expect(harness.targetReads == 0, "countdown performs no target polling")
        }
        harness.clock.advance(by: 1)
        expect(harness.targetReads == 1, "deadline snapshots target exactly once")
        expect(harness.captures.count == 1, "deadline begins exactly one capture")
        if case let .target(expectedTarget) = harness.targetDecision {
            expect(
                harness.captures.first == expectedTarget,
                "capture receives the exact process identity snapshot"
            )
        } else {
            expect(false, "test fixture must contain one target")
        }
        expect(harness.coordinator.phase == .reading, "capture is visibly in progress")
    }

    private static func testResultTTLAndDeferredAccessibilityFeedback() {
        let harness = Harness()
        harness.applicationIsActive = false
        harness.reachReading()
        harness.completions[0](.success(text: "private selection", didTruncate: false))
        guard case let .result(text, didTruncate, expiresAt) = harness.coordinator.phase else {
            expect(false, "success retains one result")
            return
        }
        expect(text.value == "private selection", "result is exact")
        expect(!didTruncate, "truncation metadata is preserved")
        expect(expiresAt == 135, "TTL is thirty monotonic seconds after receipt")
        expect(
            harness.coordinator.consumeAccessibilityFeedbackIfApplicationIsActive() == nil,
            "no VoiceOver feedback is posted in another app"
        )
        harness.applicationIsActive = true
        expect(
            harness.coordinator.consumeAccessibilityFeedbackIfApplicationIsActive()
                == NativeSelectionCaptureLabCoordinator.accessibilityFeedback,
            "returning to Juyi yields one fixed short feedback"
        )
        expect(
            harness.coordinator.consumeAccessibilityFeedbackIfApplicationIsActive() == nil,
            "feedback is exact-once"
        )

        harness.clock.advance(by: 29.999)
        expect(harness.coordinator.phase.retainedText?.value == "private selection", "TTL is inclusive")
        harness.clock.advance(by: 0.001)
        expect(harness.coordinator.phase == .expired, "TTL clears the result")
        expect(harness.coordinator.phase.retainedText == nil, "expired state retains no text")
        expect(
            harness.coordinator.consumeAccessibilityFeedbackIfApplicationIsActive() == nil,
            "TTL cleanup never emits a duplicate status announcement"
        )

        let stalledHarness = Harness()
        stalledHarness.reachReading()
        stalledHarness.completions[0](
            .success(text: "stalled private selection", didTruncate: false)
        )
        stalledHarness.clock.now += 31
        stalledHarness.coordinator.expireIfNeeded()
        expect(
            stalledHarness.coordinator.phase == .expired,
            "deadline recheck expires text even before a delayed timer callback"
        )
        expect(
            stalledHarness.coordinator.phase.retainedText == nil,
            "deadline recheck drops the stalled text"
        )
        expect(
            stalledHarness.coordinator.consumeAccessibilityFeedbackIfApplicationIsActive() == nil,
            "stalled deadline cleanup emits no duplicate announcement"
        )
    }

    private static func testCancellationTombstonesBeforeExternalCleanup() {
        let harness = Harness()
        harness.reachReading()
        let late = harness.completions[0]
        harness.coordinator.perform(.cancel)
        expect(harness.cancelCaptureCount == 1, "reading cancel reaches injected capture once")
        expect(harness.coordinator.phase == .failure(.cancelled), "cancel is typed")
        expect(harness.coordinator.phase.retainedText == nil, "cancel clears text first")
        late(.success(text: "late sensitive text", didTruncate: false))
        expect(harness.coordinator.phase == .failure(.cancelled), "late success is dropped")
        expect(harness.coordinator.phase.retainedText == nil, "late text is never retained")
    }

    private static func testEveryLifecycleInvalidationClearsAndDropsLateText() {
        let reasons: [NativeSelectionCaptureLabInvalidationReason] = [
            .pause, .stop, .sleep, .sessionResigned, .accessibilityRevoked, .terminate,
        ]
        for reason in reasons {
            let harness = Harness()
            harness.reachReading()
            let late = harness.completions[0]
            harness.coordinator.invalidate(reason)
            expect(harness.cancelCaptureCount == 1, "\(reason) cancels active capture")
            expect(harness.coordinator.phase.retainedText == nil, "\(reason) clears text")
            late(.success(text: "late \(reason)", didTruncate: false))
            expect(harness.coordinator.phase.retainedText == nil, "\(reason) drops late text")
        }
    }

    private static func testCloseAndPauseClearResult() {
        let closeHarness = Harness()
        closeHarness.reachReading()
        closeHarness.completions[0](.success(text: "close me", didTruncate: false))
        closeHarness.coordinator.close()
        expect(!closeHarness.coordinator.isPresented, "close removes the sheet owner")
        expect(closeHarness.coordinator.phase.retainedText == nil, "close clears result")
        closeHarness.clock.advance(by: 30)
        expect(closeHarness.coordinator.phase == .expired, "old TTL cannot mutate closed state")

        let pauseHarness = Harness()
        pauseHarness.reachReading()
        pauseHarness.completions[0](.success(text: "pause me", didTruncate: false))
        pauseHarness.coordinator.setPaused(true)
        expect(pauseHarness.coordinator.phase == .paused, "pause is explicit")
        expect(pauseHarness.coordinator.phase.retainedText == nil, "pause clears result")
        expect(!pauseHarness.coordinator.canPerform(.beginOneShotCapture), "paused lab cannot run")
        pauseHarness.coordinator.setPaused(false)
        expect(
            pauseHarness.coordinator.phase == .idle(authorization: .authorized),
            "resume is idle and never auto-runs"
        )

        let reopenHarness = Harness()
        reopenHarness.authorization = .notAuthorized
        reopenHarness.coordinator.setPaused(true)
        reopenHarness.coordinator.open()
        expect(reopenHarness.coordinator.phase == .paused, "open preserves paused state")
        expect(reopenHarness.authorizationReads == 0, "paused open performs zero TCC reads")
        expect(
            !reopenHarness.coordinator.canPerform(.requestAuthorization)
                && !reopenHarness.coordinator.canPerform(.recheckAuthorization)
                && !reopenHarness.coordinator.canPerform(.beginOneShotCapture),
            "paused open exposes no TCC or capture action"
        )
        reopenHarness.coordinator.setPaused(false)
        expect(
            reopenHarness.coordinator.phase == .idle(authorization: .notAuthorized),
            "resume after paused open remains explicit and idle"
        )
    }

    private static func testPauseRemainsAHardGateAcrossLifecycleInvalidation() {
        let reasons: [NativeSelectionCaptureLabInvalidationReason] = [
            .accessibilityRevoked, .stop, .sleep, .sessionResigned, .terminate,
        ]
        for reason in reasons {
            let harness = Harness()
            harness.coordinator.setPaused(true)
            harness.coordinator.open()
            let authorizationReads = harness.authorizationReads
            harness.coordinator.invalidate(reason)
            expect(harness.coordinator.phase == .paused, "paused survives \(reason)")
            expect(
                !harness.coordinator.canPerform(.requestAuthorization)
                    && !harness.coordinator.canPerform(.recheckAuthorization)
                    && !harness.coordinator.canPerform(.beginOneShotCapture),
                "paused \(reason) exposes no TCC or capture action"
            )
            harness.coordinator.perform(.requestAuthorization)
            harness.coordinator.perform(.recheckAuthorization)
            harness.coordinator.perform(.beginOneShotCapture)
            expect(
                harness.authorizationReads == authorizationReads
                    && harness.authorizationRequests == 0
                    && harness.targetReads == 0
                    && harness.captures.isEmpty,
                "paused \(reason) performs zero I/O"
            )
            harness.coordinator.setPaused(true)
            expect(harness.coordinator.phase == .paused, "repeated pause is idempotent")
        }
    }

    private static func testTargetsAndCaptureFailuresAreTyped() {
        let targetCases: [(
            NativeSelectionCaptureLabTargetDecision,
            NativeSelectionCaptureLabFailure
        )] = [
            (.noForegroundApplication, .noForegroundApplication),
            (.selfTarget, .selfTarget),
            (.unsupportedTarget, .unsupportedTarget),
            (
                .target(
                    NativeSelectionTarget(
                        processIdentifier: 201,
                        launchDate: Date(timeIntervalSince1970: 1_235),
                        bundleIdentifier: nil
                    )
                ),
                .unsupportedTarget
            ),
            (
                .target(
                    NativeSelectionTarget(
                        processIdentifier: 202,
                        launchDate: Date(timeIntervalSince1970: 1_236),
                        bundleIdentifier: "  \n"
                    )
                ),
                .unsupportedTarget
            ),
        ]
        for (decision, expected) in targetCases {
            let harness = Harness()
            harness.targetDecision = decision
            harness.reachReading()
            expect(harness.captures.isEmpty, "invalid target performs zero AX capture")
            expect(harness.coordinator.phase == .failure(expected), "target failure is typed")
        }

        let resultCases: [(
            NativeSelectionCaptureLabCaptureResult,
            NativeSelectionCaptureLabFailure
        )] = [
            (.accessibilityRequired, .accessibilityRequired),
            (.noFocusedElement, .noFocusedElement),
            (.noSelection, .noSelection),
            (.unsupported, .unsupported),
            (.secureField, .secureField),
            (.temporarilyUnavailable, .temporarilyUnavailable),
            (.internalFailure, .internalFailure),
            (.cancelled, .cancelled),
        ]
        for (result, expected) in resultCases {
            let harness = Harness()
            harness.reachReading()
            harness.completions[0](result)
            expect(harness.coordinator.phase == .failure(expected), "capture failure is typed")
            expect(harness.coordinator.phase.retainedText == nil, "failure retains no text")
        }
    }

    private static func testOversizedInjectedTextFailsClosed() {
        let harness = Harness()
        harness.reachReading()
        harness.completions[0](
            .success(text: String(repeating: "a", count: 5_001), didTruncate: false)
        )
        expect(harness.coordinator.phase == .failure(.internalFailure), "oversized fake fails")
        expect(harness.coordinator.phase.retainedText == nil, "oversized text is not retained")
    }

    static func main() {
        testOpenAndPermissionAreExplicit()
        testManualFiveSecondCountdownReadsTargetOnce()
        testResultTTLAndDeferredAccessibilityFeedback()
        testCancellationTombstonesBeforeExternalCleanup()
        testEveryLifecycleInvalidationClearsAndDropsLateText()
        testCloseAndPauseClearResult()
        testPauseRemainsAHardGateAcrossLifecycleInvalidation()
        testTargetsAndCaptureFailuresAreTyped()
        testOversizedInjectedTextFailsClosed()
        print("NativeSelectionCaptureLabModelTests: \(passed) passed")
    }
}
#endif
