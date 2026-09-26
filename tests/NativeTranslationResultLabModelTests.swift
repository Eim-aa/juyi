import Foundation

@main
enum NativeTranslationResultLabModelTests {
    @MainActor
    private final class ManualClock {
        private final class Entry {
            let deadline: TimeInterval
            let action: @MainActor () -> Void
            var cancelled = false

            init(deadline: TimeInterval, action: @escaping @MainActor () -> Void) {
                self.deadline = deadline
                self.action = action
            }
        }

        private var entries: [Entry] = []
        private var now: TimeInterval = 0

        var clock: NativeTranslationResultLabOwnerClock {
            NativeTranslationResultLabOwnerClock { [weak self] delay, action in
                guard let self else { return NativeTranslationOverlayScheduledTask {} }
                let entry = Entry(deadline: now + delay, action: action)
                entries.append(entry)
                return NativeTranslationOverlayScheduledTask { entry.cancelled = true }
            }
        }

        func advance(to target: TimeInterval) {
            precondition(target >= now)
            while let next = entries
                .filter({ !$0.cancelled && $0.deadline <= target })
                .min(by: { $0.deadline < $1.deadline }) {
                next.cancelled = true
                now = next.deadline
                next.action()
            }
            now = target
        }

        var activeCount: Int { entries.filter { !$0.cancelled }.count }
    }

    @MainActor
    private final class OverlaySpy {
        let registry = NativeTranslationOverlayExternalPresentationRegistry()
        private(set) var beginCount = 0
        private(set) var resolutions: [NativeTranslationResultLabValidatedPresentation] = []
        private(set) var invalidations: [NativeTranslationOverlayDismissReason] = []
        private(set) var focusCount = 0
        var dismissDuringResolve: NativeTranslationOverlayDismissReason?
        var rejectResolve = false
        private var sessionGeneration = 0

        var client: NativeTranslationResultLabOverlayClient {
            NativeTranslationResultLabOverlayClient(
                begin: { [weak self] _, onDismiss in
                    guard let self else { return nil }
                    beginCount += 1
                    sessionGeneration += 1
                    return registry.begin(
                        sessionGeneration: sessionGeneration,
                        onDismiss: onDismiss
                    )
                },
                resolve: { [weak self] presentation, lease in
                    guard let self, !rejectResolve,
                          registry.acceptTerminal(
                              lease,
                              sessionGeneration: sessionGeneration
                          ) else { return false }
                    resolutions.append(presentation)
                    if let reason = dismissDuringResolve {
                        registry.invalidateActive(reason: reason)
                    }
                    return true
                },
                invalidate: { [weak self] lease, reason in
                    guard let self else { return }
                    invalidations.append(reason)
                    _ = registry.invalidate(lease, reason: reason)
                },
                focusCurrent: { [weak self] lease in
                    guard let self,
                          registry.matches(
                              lease,
                              sessionGeneration: sessionGeneration
                          ) else { return false }
                    focusCount += 1
                    return true
                }
            )
        }

        func dismiss(_ reason: NativeTranslationOverlayDismissReason) {
            registry.invalidateActive(reason: reason)
        }
    }

    private final class DomainRun: @unchecked Sendable {
        private let lock = NSLock()
        let fixture: NativeTranslationResultLabFixtureID
        let publisher: NativeTranslationResultLabDomainFactory.Publisher
        let generation: UInt64
        let suspendBegin: Bool
        let outcomeBeforeReturn: NativeTranslationOutcome?
        private var continuation: CheckedContinuation<Void, Never>?
        private var shouldResumeImmediately = false
        private var beginCalls = 0
        private var invalidationReasons: [NativeTranslationInvalidationReason] = []
        private var effectCalls = 0
        private var credentialLoads = 0

        init(
            fixture: NativeTranslationResultLabFixtureID,
            publisher: @escaping NativeTranslationResultLabDomainFactory.Publisher,
            generation: UInt64,
            suspendBegin: Bool,
            outcomeBeforeReturn: NativeTranslationOutcome?
        ) {
            self.fixture = fixture
            self.publisher = publisher
            self.generation = generation
            self.suspendBegin = suspendBegin
            self.outcomeBeforeReturn = outcomeBeforeReturn
        }

        func begin() async -> UInt64 {
            lock.withLock {
                beginCalls += 1
                effectCalls += 1
                if fixture == .volcFixedSample { credentialLoads += 1 }
            }
            if suspendBegin {
                await withCheckedContinuation { continuation in
                    let resumeNow = lock.withLock {
                        if shouldResumeImmediately {
                            shouldResumeImmediately = false
                            return true
                        }
                        self.continuation = continuation
                        return false
                    }
                    if resumeNow {
                        continuation.resume()
                    }
                }
            }
            if let outcomeBeforeReturn { publisher(generation, outcomeBeforeReturn) }
            return generation
        }

        func invalidate(_ reason: NativeTranslationInvalidationReason) {
            lock.withLock { invalidationReasons.append(reason) }
        }

        func resumeBegin() {
            let continuationToResume: CheckedContinuation<Void, Never>? = lock.withLock {
                if let continuation {
                    self.continuation = nil
                    return continuation
                }
                shouldResumeImmediately = true
                return nil
            }
            if let continuationToResume {
                continuationToResume.resume()
            }
        }

        func publish(_ outcome: NativeTranslationOutcome, generation: UInt64? = nil) {
            publisher(generation ?? self.generation, outcome)
        }

        var counts: (begin: Int, invalidate: Int, effect: Int, credentials: Int) {
            lock.withLock {
                (beginCalls, invalidationReasons.count, effectCalls, credentialLoads)
            }
        }

        var reasons: [NativeTranslationInvalidationReason] {
            lock.withLock { invalidationReasons }
        }
    }

    @MainActor
    private final class DomainFactorySpy {
        var suspendNextBegin = false
        var nextOutcomeBeforeReturn: NativeTranslationOutcome?
        var nextGeneration: UInt64 = 101
        private(set) var runs: [DomainRun] = []

        var factory: NativeTranslationResultLabDomainFactory {
            NativeTranslationResultLabDomainFactory { [weak self] fixture, publisher in
                guard let self else {
                    return NativeTranslationResultLabDomainHandle(
                        begin: { 0 },
                        invalidate: { _ in }
                    )
                }
                let run = DomainRun(
                    fixture: fixture,
                    publisher: publisher,
                    generation: nextGeneration,
                    suspendBegin: suspendNextBegin,
                    outcomeBeforeReturn: nextOutcomeBeforeReturn
                )
                suspendNextBegin = false
                nextOutcomeBeforeReturn = nil
                nextGeneration &+= 1
                runs.append(run)
                return NativeTranslationResultLabDomainHandle(
                    begin: { await run.begin() },
                    invalidate: { run.invalidate($0) }
                )
            }
        }
    }

    @MainActor
    private static func makeSystem() -> (
        NativeTranslationResultLabCoordinator,
        OverlaySpy,
        DomainFactorySpy,
        ManualClock
    ) {
        let overlay = OverlaySpy()
        let domain = DomainFactorySpy()
        let clock = ManualClock()
        let model = NativeTranslationResultLabCoordinator(
            overlay: overlay.client,
            domainFactory: domain.factory,
            clock: clock.clock
        )
        return (model, overlay, domain, clock)
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

    @MainActor
    private static func waitUntil(
        _ message: String,
        _ condition: @escaping @MainActor () -> Bool
    ) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        expect(false, message)
    }

    @MainActor
    private static func testOpeningIsDisclosureOnly() {
        let (model, overlay, domain, clock) = makeSystem()
        model.open()
        expect(model.isPresented, "open presents the Lab sheet")
        expect(model.phase == .disclosure, "open starts at disclosure")
        expect(overlay.beginCount == 0, "open does not create a panel")
        expect(domain.runs.isEmpty, "open does not begin domain work")
        expect(clock.activeCount == 0, "open owns no timers")
    }

    @MainActor
    private static func testSheetEscapeHasOneOwnerAndTwoStepBehavior() async {
        let (model, overlay, domain, _) = makeSystem()
        model.open()
        model.runAppleSimulation()
        expect(overlay.beginCount == 1, "Escape test retains its overlay client")
        guard let run = domain.runs.first else {
            expect(false, "Escape test creates one domain run")
            return
        }
        await waitUntil("Escape test run begins") { run.counts.begin == 1 }

        expect(
            NativeTranslationResultLabSheetInteractionPolicy.escapeAction(
                isBusy: model.isBusy
            ) == .stop,
            "first Escape maps to exactly one stop"
        )
        model.stopSimulation()
        expect(model.isPresented, "first Escape leaves the sheet presented")
        expect(model.phase == .stopped(engine: .apple), "first Escape shows stopped")
        await waitUntil("first Escape invalidates once") { run.counts.invalidate == 1 }

        expect(
            NativeTranslationResultLabSheetInteractionPolicy.escapeAction(
                isBusy: model.isBusy
            ) == .close,
            "second Escape maps to exactly one close"
        )
        model.close()
        expect(!model.isPresented, "second Escape closes the sheet")
        expect(run.counts.invalidate == 1, "two-step Escape does not double invalidate")
    }

    @MainActor
    private static func testImmediateOutcomeBeforeBeginReturn() async {
        let (model, overlay, domain, _) = makeSystem()
        domain.nextOutcomeBeforeReturn = .success(
            NativeTranslationSuccess(
                engine: .apple,
                text: NativeTranslationResultLabFixtures.appleResult,
                inputWasTruncated: false
            )
        )
        model.open()
        model.runAppleSimulation()
        await waitUntil("immediate result completes") {
            model.phase == .completed(engine: .apple)
        }
        expect(overlay.beginCount == 1, "lease is minted once before work")
        expect(overlay.resolutions.count == 1, "immediate publisher resolves once")
        let counts = domain.runs[0].counts
        expect(counts.begin == 1 && counts.effect == 1, "Apple has one fake effect")
        expect(counts.credentials == 0, "Apple has zero credential loads")
    }

    @MainActor
    private static func testMenuFocusEnablementTracksCurrentLease() async {
        let (model, overlay, domain, _) = makeSystem()
        expect(
            !NativeTranslationResultLabMenuPolicy.focusIsEnabled(
                hasVisibleResult: model.hasVisibleResult
            ),
            "focus menu is disabled before a result exists"
        )
        domain.nextOutcomeBeforeReturn = .success(
            NativeTranslationSuccess(
                engine: .apple,
                text: NativeTranslationResultLabFixtures.appleResult,
                inputWasTruncated: false
            )
        )
        model.open()
        model.runAppleSimulation()
        await waitUntil("focus menu result completes") {
            model.phase == .completed(engine: .apple)
        }
        expect(
            NativeTranslationResultLabMenuPolicy.focusIsEnabled(
                hasVisibleResult: model.hasVisibleResult
            ),
            "focus menu is enabled only for the current visible lease"
        )
        overlay.dismiss(.outside)
        await waitUntil("focus menu observes dismissal") {
            !model.hasVisibleResult
        }
        expect(
            !NativeTranslationResultLabMenuPolicy.focusIsEnabled(
                hasVisibleResult: model.hasVisibleResult
            ),
            "focus menu disables after invalidation"
        )
    }

    @MainActor
    private static func testVolcOneLoaderAndOneEffect() async {
        let (model, overlay, domain, _) = makeSystem()
        domain.nextOutcomeBeforeReturn = .success(
            NativeTranslationSuccess(
                engine: .volc,
                text: NativeTranslationResultLabFixtures.volcResult,
                inputWasTruncated: false
            )
        )
        model.open()
        model.runVolcSimulation()
        await waitUntil("Volc result completes") {
            model.phase == .completed(engine: .volc)
        }
        let counts = domain.runs[0].counts
        expect(counts.effect == 1, "Volc has one fake effect")
        expect(counts.credentials == 1, "Volc has one fake credential load")
        expect(overlay.resolutions.count == 1, "Volc resolves once")
    }

    @MainActor
    private static func testCancelBeforeBeginTaskStarts() async {
        let (model, overlay, domain, _) = makeSystem()
        model.open()
        model.runAppleSimulation()
        let run = domain.runs[0]
        model.stopSimulation()
        await waitUntil("cancel-before-start cleanup invalidates domain") {
            run.counts.invalidate == 1
        }
        expect(run.counts.begin == 0, "cancel before task start has zero begin/effect")
        expect(run.counts.effect == 0, "cancel before task start has zero effect")
        expect(overlay.resolutions.isEmpty, "cancel before start has no terminal panel")
        expect(model.phase == .stopped(engine: .apple), "stop is honest and engine-specific")
    }

    @MainActor
    private static func testCancelWhileBeginSuspendedIsOrdered() async {
        let (model, overlay, domain, _) = makeSystem()
        domain.suspendNextBegin = true
        model.open()
        model.runAppleSimulation()
        let run = domain.runs[0]
        await waitUntil("begin reaches controlled suspension") { run.counts.begin == 1 }
        model.stopSimulation()
        expect(run.counts.invalidate == 0, "invalidation waits behind begin")
        run.resumeBegin()
        await waitUntil("invalidation follows completed begin") { run.counts.invalidate == 1 }
        expect(overlay.resolutions.isEmpty, "suspended cancellation never resolves late")
        run.publish(
            .success(
                NativeTranslationSuccess(
                    engine: .apple,
                    text: NativeTranslationResultLabFixtures.appleResult,
                    inputWasTruncated: false
                )
            )
        )
        await Task.yield()
        expect(overlay.resolutions.isEmpty, "late publish after ordered invalidation is dropped")
    }

    @MainActor
    private static func testSlowAndOwnerTimeout() async {
        let (model, overlay, domain, clock) = makeSystem()
        model.open()
        model.runAppleSimulation()
        let run = domain.runs[0]
        await waitUntil("begin binds") { run.counts.begin == 1 }
        clock.advance(to: 1.999)
        expect(model.phase == .running(engine: .apple, isSlow: false), "1999ms is not slow")
        clock.advance(to: 2.0)
        expect(model.phase == .running(engine: .apple, isSlow: true), "2s becomes slow")
        clock.advance(to: 11.999)
        expect(
            model.phase == .running(engine: .apple, isSlow: true),
            "11999ms remains the slow in-memory simulation"
        )
        clock.advance(to: 12.0)
        await waitUntil("timeout invalidates before presentation") {
            model.phase == .timeout(engine: .apple)
        }
        expect(run.counts.invalidate == 1, "timeout invalidates domain first")
        expect(overlay.resolutions.count == 1, "timeout resolves current lease once")
        expect(overlay.resolutions[0].overlayState.title == "模拟执行超时", "timeout is Result Lab typed state")
        run.publish(
            .success(
                NativeTranslationSuccess(
                    engine: .apple,
                    text: NativeTranslationResultLabFixtures.appleResult,
                    inputWasTruncated: false
                )
            )
        )
        run.publish(.failure(.appleExecutionFailed))
        run.publish(.cancelled)
        await Task.yield()
        expect(model.phase == .timeout(engine: .apple), "late outcomes preserve owner timeout")
        expect(overlay.resolutions.count == 1, "late timeout outcomes cannot add a terminal")
        overlay.dismiss(.close)
        await Task.yield()
        expect(run.counts.invalidate == 1, "closing a timeout does not invalidate domain twice")
    }

    @MainActor
    private static func testStaleDuplicateAndMismatchBoundaries() async {
        do {
            let (model, overlay, domain, _) = makeSystem()
            model.open()
            model.runAppleSimulation()
            let run = domain.runs[0]
            await waitUntil("generation binds") { run.counts.begin == 1 }
            await Task.yield()
            run.publish(
                .success(
                    NativeTranslationSuccess(
                        engine: .apple,
                        text: NativeTranslationResultLabFixtures.appleResult,
                        inputWasTruncated: false
                    )
                ),
                generation: run.generation + 99
            )
            await waitUntil("generation mismatch fails safely") {
                model.phase == .debugSafetyFailure(engine: .apple)
            }
            expect(overlay.resolutions.count == 1, "mismatch produces one safe state")
            expect(overlay.resolutions[0].overlayState.copyText == nil, "mismatch has no copy")
            await waitUntil("safety cleanup completes") { run.counts.invalidate == 1 }
            overlay.dismiss(.close)
            await Task.yield()
            expect(run.counts.invalidate == 1, "closing safety state keeps cleanup exact once")
        }
        do {
            let (model, overlay, domain, _) = makeSystem()
            model.open()
            model.runAppleSimulation()
            let run = domain.runs[0]
            await waitUntil("generation binds for duplicate") { run.counts.begin == 1 }
            await Task.yield()
            let success = NativeTranslationOutcome.success(
                NativeTranslationSuccess(
                    engine: .apple,
                    text: NativeTranslationResultLabFixtures.appleResult,
                    inputWasTruncated: false
                )
            )
            run.publish(success)
            await waitUntil("first terminal presents") {
                model.phase == .completed(engine: .apple)
            }
            run.publish(success)
            await waitUntil("duplicate revokes old copy") {
                model.phase == .debugSafetyFailure(engine: .apple)
            }
            expect(overlay.invalidations == [.stop], "duplicate hides the old copyable result")
            expect(overlay.resolutions.count == 1, "duplicate cannot overwrite or reopen")
            expect(!model.hasVisibleResult, "duplicate safety state is not a visible panel")
            model.focusCurrentResult()
            expect(overlay.focusCount == 0, "duplicate safety state cannot focus another panel")
        }
    }

    @MainActor
    private static func testRejectedPresentationCannotExposeFocus() async {
        let (model, overlay, domain, _) = makeSystem()
        overlay.rejectResolve = true
        domain.nextOutcomeBeforeReturn = .success(
            NativeTranslationSuccess(
                engine: .apple,
                text: NativeTranslationResultLabFixtures.appleResult,
                inputWasTruncated: false
            )
        )
        model.open()
        model.runAppleSimulation()
        await waitUntil("rejected presentation fails safely") {
            model.phase == .debugSafetyFailure(engine: .apple)
        }
        expect(!model.hasVisibleResult, "rejected presentation has no visible result")
        model.focusCurrentResult()
        expect(overlay.focusCount == 0, "rejected presentation cannot focus globally")
    }

    @MainActor
    private static func testDismissAndLifecycleDropLateOutcome() async {
        let (model, overlay, domain, clock) = makeSystem()
        model.open()
        model.runVolcSimulation()
        let run = domain.runs[0]
        await waitUntil("Volc begin binds") { run.counts.begin == 1 }
        await Task.yield()
        overlay.dismiss(.outside)
        await waitUntil("panel dismissal invalidates domain") { run.counts.invalidate == 1 }
        expect(model.phase == .stopped(engine: .volc), "outside dismissal stops owner")
        expect(clock.activeCount == 0, "dismissal cancels all owner timers")
        run.publish(
            .success(
                NativeTranslationSuccess(
                    engine: .volc,
                    text: NativeTranslationResultLabFixtures.volcResult,
                    inputWasTruncated: false
                )
            )
        )
        await Task.yield()
        expect(overlay.resolutions.isEmpty, "dismissed result never reopens")

        model.runVolcSimulation()
        let second = domain.runs[1]
        await waitUntil("second run begins") { second.counts.begin == 1 }
        model.invalidate(.pause)
        await waitUntil("pause invalidates second domain") { second.counts.invalidate == 1 }
        second.publish(
            .success(
                NativeTranslationSuccess(
                    engine: .volc,
                    text: NativeTranslationResultLabFixtures.volcResult,
                    inputWasTruncated: false
                )
            )
        )
        await Task.yield()
        expect(overlay.resolutions.isEmpty, "lifecycle late result is dropped")
    }

    @MainActor
    private static func testSynchronousDismissInsideResolveWins() async {
        do {
            let (model, overlay, domain, _) = makeSystem()
            overlay.dismissDuringResolve = .displayRemoved
            domain.nextOutcomeBeforeReturn = .success(
                NativeTranslationSuccess(
                    engine: .apple,
                    text: NativeTranslationResultLabFixtures.appleResult,
                    inputWasTruncated: false
                )
            )
            model.open()
            model.runAppleSimulation()
            await waitUntil("success render dismissal wins") {
                model.phase == .stopped(engine: .apple)
            }
            expect(!model.hasVisibleResult, "dismissed success cannot claim a visible result")
            await waitUntil("dismissed success cleans domain once") {
                domain.runs[0].counts.invalidate == 1
            }
            expect(domain.runs[0].counts.invalidate == 1, "success dismissal cleanup is exact")
        }
        do {
            let (model, overlay, domain, clock) = makeSystem()
            overlay.dismissDuringResolve = .displayRemoved
            model.open()
            model.runVolcSimulation()
            let run = domain.runs[0]
            await waitUntil("timeout run begins") { run.counts.begin == 1 }
            clock.advance(to: 12)
            await waitUntil("timeout render dismissal wins") {
                model.phase == .stopped(engine: .volc)
            }
            expect(!model.hasVisibleResult, "dismissed timeout cannot claim a visible result")
            expect(run.counts.invalidate == 1, "timeout render dismissal cleanup is exact")
        }
        do {
            let (model, overlay, domain, _) = makeSystem()
            overlay.dismissDuringResolve = .displayRemoved
            model.open()
            model.runAppleSimulation()
            let run = domain.runs[0]
            await waitUntil("safety run begins") { run.counts.begin == 1 }
            run.publish(.failure(.cloudConsentRequired))
            await waitUntil("safety render dismissal wins") {
                model.phase == .stopped(engine: .apple)
            }
            expect(!model.hasVisibleResult, "dismissed safety state cannot claim a visible result")
            await waitUntil("dismissed safety cleans domain once") {
                run.counts.invalidate == 1
            }
            expect(run.counts.invalidate == 1, "safety render dismissal cleanup is exact")
        }
    }

    @MainActor
    private static func testDismissReasonsMapToDomainInvalidation() async {
        let cases: [(
            NativeTranslationOverlayDismissReason,
            NativeTranslationInvalidationReason
        )] = [
            (.close, .stop), (.outside, .stop), (.escape, .stop), (.stop, .stop),
            (.pause, .pause), (.revoke, .accessibilityRevoked),
            (.displayRemoved, .ownerChanged), (.space, .ownerChanged),
            (.session, .ownerChanged), (.sleep, .ownerChanged),
            (.terminate, .ownerChanged),
        ]
        for (dismissReason, expectedReason) in cases {
            let (model, overlay, domain, _) = makeSystem()
            model.open()
            model.runAppleSimulation()
            let run = domain.runs[0]
            await waitUntil("dismiss reason run begins") { run.counts.begin == 1 }
            overlay.dismiss(dismissReason)
            await waitUntil("dismiss reason reaches domain") {
                run.counts.invalidate == 1
            }
            expect(
                run.reasons == [expectedReason],
                "\(dismissReason) maps to \(expectedReason)"
            )
        }
    }

    @MainActor
    static func main() async {
        testOpeningIsDisclosureOnly()
        await testSheetEscapeHasOneOwnerAndTwoStepBehavior()
        await testImmediateOutcomeBeforeBeginReturn()
        await testMenuFocusEnablementTracksCurrentLease()
        await testVolcOneLoaderAndOneEffect()
        await testCancelBeforeBeginTaskStarts()
        await testCancelWhileBeginSuspendedIsOrdered()
        await testSlowAndOwnerTimeout()
        await testStaleDuplicateAndMismatchBoundaries()
        await testRejectedPresentationCannotExposeFocus()
        await testDismissAndLifecycleDropLateOutcome()
        await testSynchronousDismissInsideResolveWins()
        await testDismissReasonsMapToDomainInvalidation()
        print("NativeTranslationResultLabModelTests: \(passed) passed")
    }
}
