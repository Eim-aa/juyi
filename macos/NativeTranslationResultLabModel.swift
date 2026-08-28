#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB
import Combine
import Foundation

enum NativeTranslationResultLabFixtures {
    static let appleSource = "The weather is pleasant today."
    static let volcSource = "Good tools should feel effortless."
    static let appleResult = "今天天气宜人。"
    static let volcResult = "好工具应该让使用过程毫不费力。"
    static let simulatedFingerprint = "result-lab-simulated-fingerprint-v1"

    static func source(for fixture: NativeTranslationResultLabFixtureID) -> String? {
        switch fixture {
        case .appleFixedSample: return appleSource
        case .volcFixedSample: return volcSource
        case .unrecognized: return nil
        }
    }

    static func elapsed(for fixture: NativeTranslationResultLabFixtureID) -> Int {
        fixture == .appleFixedSample ? 218 : 386
    }
}

enum NativeTranslationResultLabPhase: Equatable {
    case disclosure
    case running(engine: NativeTranslationEngine, isSlow: Bool)
    case completed(engine: NativeTranslationEngine)
    case typedNotice(engine: NativeTranslationEngine)
    case typedError(engine: NativeTranslationEngine)
    case debugSafetyFailure(engine: NativeTranslationEngine?)
    case timeout(engine: NativeTranslationEngine)
    case stopped(engine: NativeTranslationEngine?)
}

enum NativeTranslationResultLabOwnerTiming {
    static let slowDelay: TimeInterval = 2
    static let deadline: TimeInterval = 12
}

struct NativeTranslationResultLabOverlayClient {
    let begin: @MainActor (
        NativeTranslationEngine,
        @escaping (NativeTranslationOverlayDismissReason) -> Void
    ) -> NativeTranslationOverlayExternalPresentationLease?
    let resolve: @MainActor (
        NativeTranslationResultLabValidatedPresentation,
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

struct NativeTranslationResultLabDomainHandle {
    let begin: @Sendable () async -> UInt64
    let invalidate: @Sendable (NativeTranslationInvalidationReason) async -> Void
}

struct NativeTranslationResultLabDomainFactory {
    typealias Publisher = @Sendable (UInt64, NativeTranslationOutcome) -> Void
    let make: @MainActor (
        NativeTranslationResultLabFixtureID,
        @escaping Publisher
    ) -> NativeTranslationResultLabDomainHandle

    static let fixedInMemory = NativeTranslationResultLabDomainFactory { fixture, publisher in
        let engine = fixture.expectedEngine ?? .apple
        let credentials = VolcV4Credentials(
            accessKey: "AKRESULTLABFIXTURE",
            secretKey: "SKRESULTLABFIXTURE",
            fingerprint: NativeTranslationResultLabFixtures.simulatedFingerprint
        )
        let coordinator = NativeTranslationDomainCoordinator(
            credentialLoader: { expectedFingerprint in
                guard engine == .volc,
                      expectedFingerprint == credentials.fingerprint else { return nil }
                return credentials
            },
            executor: NativeTranslationFakeExecutor { request in
                guard request.engine == engine else {
                    return .failure(.cloudCredentialSnapshotMismatch)
                }
                return .success(
                    text: engine == .apple
                        ? NativeTranslationResultLabFixtures.appleResult
                        : NativeTranslationResultLabFixtures.volcResult
                )
            },
            publisher: publisher
        )
        let context = NativeTranslationRequestContext(
            appleReadiness: .installed,
            volcPrivacy: NativeVolcPrivacyContext(
                hasExplicitConsent: true,
                removalMarker: .confirmedAbsent,
                credentialReadiness: engine == .volc
                    ? .active(
                        fingerprint: NativeTranslationResultLabFixtures.simulatedFingerprint
                    )
                    : .missing,
                verifiedFingerprint: engine == .volc
                    ? NativeTranslationResultLabFixtures.simulatedFingerprint
                    : nil
            )
        )
        return NativeTranslationResultLabDomainHandle(
            begin: {
                await coordinator.begin(
                    sourceText: NativeTranslationResultLabFixtures.source(for: fixture),
                    requestedEngine: engine,
                    context: context
                )
            },
            invalidate: { reason in await coordinator.invalidate(reason) }
        )
    }
}

struct NativeTranslationResultLabOwnerClock {
    let schedule: (
        _ delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> NativeTranslationOverlayScheduledTask

    static let main = NativeTranslationResultLabOwnerClock { delay, action in
        let item = DispatchWorkItem {
            MainActor.assumeIsolated { action() }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return NativeTranslationOverlayScheduledTask { item.cancel() }
    }
}

enum NativeTranslationResultLabDismissInvalidationPolicy {
    static func reason(
        for dismissReason: NativeTranslationOverlayDismissReason
    ) -> NativeTranslationInvalidationReason {
        switch dismissReason {
        case .close, .outside, .escape, .stop:
            return .stop
        case .pause:
            return .pause
        case .revoke:
            return .accessibilityRevoked
        case .displayRemoved, .space, .session, .sleep, .terminate:
            return .ownerChanged
        }
    }
}

enum NativeTranslationResultLabSheetEscapeAction: Equatable {
    case stop
    case close
}

enum NativeTranslationResultLabSheetInteractionPolicy {
    static func escapeAction(isBusy: Bool) -> NativeTranslationResultLabSheetEscapeAction {
        isBusy ? .stop : .close
    }
}

enum NativeTranslationResultLabMenuPolicy {
    static func focusIsEnabled(hasVisibleResult: Bool) -> Bool {
        hasVisibleResult
    }
}

@MainActor
final class NativeTranslationResultLabCoordinator: ObservableObject {
    @Published private(set) var isPresented = false
    @Published private(set) var phase: NativeTranslationResultLabPhase = .disclosure

    private final class ActiveRun {
        enum TerminalOrigin {
            case domain
            case ownerTimeout
            case safety
        }

        let runID: UInt64
        let fixture: NativeTranslationResultLabFixtureID
        let engine: NativeTranslationEngine
        let lease: NativeTranslationOverlayExternalPresentationLease
        let domain: NativeTranslationResultLabDomainHandle
        var domainGeneration: UInt64?
        var bufferedOutcome: (UInt64, NativeTranslationOutcome)?
        var beginTask: Task<Void, Never>?
        var slowTask: NativeTranslationOverlayScheduledTask?
        var timeoutTask: NativeTranslationOverlayScheduledTask?
        var acceptsOutcome = true
        var didReachTerminal = false
        var terminalOrigin: TerminalOrigin?
        var didInvalidateDomain = false

        init(
            runID: UInt64,
            fixture: NativeTranslationResultLabFixtureID,
            engine: NativeTranslationEngine,
            lease: NativeTranslationOverlayExternalPresentationLease,
            domain: NativeTranslationResultLabDomainHandle
        ) {
            self.runID = runID
            self.fixture = fixture
            self.engine = engine
            self.lease = lease
            self.domain = domain
        }

        func cancelTimers() {
            slowTask?.cancel()
            timeoutTask?.cancel()
            slowTask = nil
            timeoutTask = nil
        }
    }

    private let overlay: NativeTranslationResultLabOverlayClient
    private let domainFactory: NativeTranslationResultLabDomainFactory
    private let clock: NativeTranslationResultLabOwnerClock
    private var nextRunID: UInt64 = 0
    private var pendingLeaseRunID: UInt64?
    private var dismissedWhileMinting: Set<UInt64> = []
    private var active: ActiveRun?

    init(
        overlay: NativeTranslationResultLabOverlayClient,
        domainFactory: NativeTranslationResultLabDomainFactory,
        clock: NativeTranslationResultLabOwnerClock
    ) {
        self.overlay = overlay
        self.domainFactory = domainFactory
        self.clock = clock
    }

    var isBusy: Bool {
        if case .running = phase { return true }
        return false
    }

    var hasVisibleResult: Bool {
        guard let run = active, run.didReachTerminal else { return false }
        switch phase {
        case .completed, .typedNotice, .typedError, .debugSafetyFailure, .timeout:
            return true
        default: return false
        }
    }

    func open() {
        invalidateCurrent(reason: .ownerChanged, overlayReason: .stop)
        phase = .disclosure
        isPresented = true
    }

    func close() {
        invalidateCurrent(reason: .ownerChanged, overlayReason: .close)
        phase = .disclosure
        isPresented = false
    }

    func runAppleSimulation() { begin(.appleFixedSample) }
    func runVolcSimulation() { begin(.volcFixedSample) }

    func stopSimulation() {
        let engine = active?.engine
        invalidateCurrent(reason: .stop, overlayReason: .stop)
        phase = .stopped(engine: engine)
    }

    func focusCurrentResult() {
        guard hasVisibleResult, let run = active else { return }
        _ = overlay.focusCurrent(run.lease)
    }

    func invalidate(_ reason: NativeTranslationInvalidationReason) {
        let engine = active?.engine
        invalidateCurrent(
            reason: reason,
            overlayReason: dismissReason(for: reason)
        )
        if isPresented { phase = .stopped(engine: engine) }
    }

    private func begin(_ fixture: NativeTranslationResultLabFixtureID) {
        guard isPresented, let engine = fixture.expectedEngine else {
            phase = .debugSafetyFailure(engine: nil)
            return
        }
        invalidateCurrent(reason: .newRequest, overlayReason: .stop)
        nextRunID &+= 1
        let runID = nextRunID
        pendingLeaseRunID = runID
        dismissedWhileMinting.remove(runID)
        let lease = overlay.begin(engine) { [weak self] reason in
            self?.overlayDismissed(runID: runID, reason: reason)
        }
        pendingLeaseRunID = nil
        guard let lease, dismissedWhileMinting.remove(runID) == nil else {
            phase = .stopped(engine: engine)
            return
        }

        let domain = domainFactory.make(fixture) { [weak self] generation, outcome in
            Task { @MainActor [weak self] in
                self?.receive(
                    runID: runID,
                    domainGeneration: generation,
                    outcome: outcome
                )
            }
        }
        let run = ActiveRun(
            runID: runID,
            fixture: fixture,
            engine: engine,
            lease: lease,
            domain: domain
        )
        active = run
        phase = .running(engine: engine, isSlow: false)
        run.slowTask = clock.schedule(
            NativeTranslationResultLabOwnerTiming.slowDelay
        ) { [weak self] in
            guard let self, self.active?.runID == runID,
                  self.active?.acceptsOutcome == true else { return }
            self.phase = .running(engine: engine, isSlow: true)
        }
        run.timeoutTask = clock.schedule(
            NativeTranslationResultLabOwnerTiming.deadline
        ) { [weak self] in
            self?.timeout(runID: runID)
        }
        run.beginTask = Task { [weak self] in
            guard !Task.isCancelled else { return }
            let generation = await domain.begin()
            guard !Task.isCancelled else { return }
            self?.bindDomainGeneration(runID: runID, generation: generation)
        }
    }

    private func bindDomainGeneration(runID: UInt64, generation: UInt64) {
        guard let run = active, run.runID == runID, run.acceptsOutcome else { return }
        run.domainGeneration = generation
        guard let buffered = run.bufferedOutcome else { return }
        run.bufferedOutcome = nil
        guard buffered.0 == generation else {
            failSafety(runID: runID)
            return
        }
        handleOutcome(run: run, generation: generation, outcome: buffered.1)
    }

    private func receive(
        runID: UInt64,
        domainGeneration: UInt64,
        outcome: NativeTranslationOutcome
    ) {
        guard let run = active, run.runID == runID else { return }
        if let terminalOrigin = run.terminalOrigin {
            if terminalOrigin == .domain { failSafety(runID: runID) }
            return
        }
        guard run.acceptsOutcome else { return }
        guard let expected = run.domainGeneration else {
            guard run.bufferedOutcome == nil else {
                failSafety(runID: runID)
                return
            }
            run.bufferedOutcome = (domainGeneration, outcome)
            return
        }
        guard expected == domainGeneration else {
            failSafety(runID: runID)
            return
        }
        handleOutcome(run: run, generation: domainGeneration, outcome: outcome)
    }

    private func handleOutcome(
        run: ActiveRun,
        generation: UInt64,
        outcome: NativeTranslationOutcome
    ) {
        guard active === run, run.acceptsOutcome, !run.didReachTerminal else { return }
        let inputWasTruncated: Bool
        if case let .success(success) = outcome {
            inputWasTruncated = success.inputWasTruncated
        } else {
            inputWasTruncated = false
        }
        let envelope = NativeTranslationResultLabEnvelope(
            fixtureID: run.fixture,
            provenance: .simulated,
            requestedEngine: run.engine,
            domainGeneration: generation,
            presentationLease: run.lease,
            outcome: outcome,
            simulatedElapsedMilliseconds: NativeTranslationResultLabFixtures.elapsed(
                for: run.fixture
            ),
            inputWasTruncated: inputWasTruncated
        )
        switch NativeTranslationResultLabPresentationBridge.map(
            envelope,
            expectedDomainGeneration: generation,
            expectedLease: run.lease
        ) {
        case .drop:
            return
        case .dismiss:
            invalidateCurrent(reason: .stop, overlayReason: .stop)
            phase = .stopped(engine: run.engine)
        case let .present(presentation):
            run.cancelTimers()
            run.didReachTerminal = true
            run.terminalOrigin = .domain
            run.acceptsOutcome = false
            guard overlay.resolve(presentation, run.lease) else {
                failSafety(runID: run.runID)
                return
            }
            guard active === run else { return }
            switch presentation.category {
            case .success:
                phase = .completed(engine: run.engine)
            case .simulatedNotice:
                phase = .typedNotice(engine: run.engine)
            case .simulatedError:
                phase = .typedError(engine: run.engine)
            case .safetyFailure:
                phase = .debugSafetyFailure(engine: run.engine)
            case .timeout:
                phase = .timeout(engine: run.engine)
            case .loading:
                failSafety(runID: run.runID)
            }
        }
    }

    private func timeout(runID: UInt64) {
        guard let run = active, run.runID == runID,
              run.acceptsOutcome, !run.didReachTerminal else { return }
        run.acceptsOutcome = false
        run.cancelTimers()
        run.beginTask?.cancel()
        Task { [weak self] in
            if let beginTask = run.beginTask { await beginTask.value }
            guard let self else { return }
            await self.invalidateDomainAndWait(run, reason: .stop)
            guard self.active === run, !run.didReachTerminal else { return }
            let presentation = NativeTranslationResultLabValidatedPresentation.timeout(
                engine: run.engine
            )
            guard self.overlay.resolve(presentation, run.lease) else {
                self.failSafety(runID: runID)
                return
            }
            guard self.active === run else { return }
            run.didReachTerminal = true
            run.terminalOrigin = .ownerTimeout
            self.phase = .timeout(engine: run.engine)
        }
    }

    private func failSafety(runID: UInt64) {
        guard let run = active, run.runID == runID else { return }
        run.acceptsOutcome = false
        run.cancelTimers()
        run.beginTask?.cancel()
        if !run.didReachTerminal,
           overlay.resolve(.safetyFailure(engine: run.engine), run.lease) {
            guard active === run else { return }
            run.didReachTerminal = true
            run.terminalOrigin = .safety
            phase = .debugSafetyFailure(engine: run.engine)
            cleanupDomain(run, reason: .ownerChanged)
            return
        }
        invalidateCurrent(reason: .ownerChanged, overlayReason: .stop)
        phase = .debugSafetyFailure(engine: run.engine)
    }

    private func overlayDismissed(
        runID: UInt64,
        reason: NativeTranslationOverlayDismissReason
    ) {
        if pendingLeaseRunID == runID {
            dismissedWhileMinting.insert(runID)
            return
        }
        guard let run = active, run.runID == runID else { return }
        active = nil
        run.acceptsOutcome = false
        run.cancelTimers()
        run.beginTask?.cancel()
        cleanupDomain(
            run,
            reason: NativeTranslationResultLabDismissInvalidationPolicy.reason(
                for: reason
            )
        )
        if isPresented { phase = .stopped(engine: run.engine) }
    }

    private func invalidateCurrent(
        reason: NativeTranslationInvalidationReason,
        overlayReason: NativeTranslationOverlayDismissReason
    ) {
        guard let run = active else { return }
        active = nil
        run.acceptsOutcome = false
        run.cancelTimers()
        run.beginTask?.cancel()
        cleanupDomain(run, reason: reason)
        overlay.invalidate(run.lease, overlayReason)
    }

    private func cleanupDomain(
        _ run: ActiveRun,
        reason: NativeTranslationInvalidationReason
    ) {
        guard !run.didInvalidateDomain else { return }
        run.didInvalidateDomain = true
        let beginTask = run.beginTask
        beginTask?.cancel()
        Task {
            if let beginTask { await beginTask.value }
            await run.domain.invalidate(reason)
        }
    }

    private func invalidateDomainAndWait(
        _ run: ActiveRun,
        reason: NativeTranslationInvalidationReason
    ) async {
        guard !run.didInvalidateDomain else { return }
        run.didInvalidateDomain = true
        await run.domain.invalidate(reason)
    }

    private func dismissReason(
        for reason: NativeTranslationInvalidationReason
    ) -> NativeTranslationOverlayDismissReason {
        switch reason {
        case .pause: return .pause
        case .stop: return .stop
        case .accessibilityRevoked: return .revoke
        case .ownerChanged: return .terminate
        case .newRequest, .engineChanged, .credentialsChanged, .removalStateChanged:
            return .stop
        }
    }
}
#endif
