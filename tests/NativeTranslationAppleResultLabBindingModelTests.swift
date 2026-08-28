#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
import Foundation

@MainActor
private final class BindingManualScheduledTask:
    NativeTranslationAppleResultLabScheduledTask
{
    private(set) var cancelled = false
    func cancel() { cancelled = true }
}

@MainActor
private final class BindingManualScheduler:
    NativeTranslationAppleResultLabScheduling
{
    private struct Entry {
        let deadline: TimeInterval
        let sequence: Int
        let token: BindingManualScheduledTask
        let action: @MainActor () -> Void
    }

    private var entries: [Entry] = []
    private var sequence = 0
    private(set) var now: TimeInterval = 0

    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> any NativeTranslationAppleResultLabScheduledTask {
        sequence += 1
        let token = BindingManualScheduledTask()
        entries.append(
            Entry(
                deadline: now + max(0, delay),
                sequence: sequence,
                token: token,
                action: action
            )
        )
        return token
    }

    func advance(by interval: TimeInterval) {
        now += interval
        while let index = entries.indices
            .filter({ entries[$0].deadline <= now })
            .min(by: {
                let lhs = entries[$0]
                let rhs = entries[$1]
                return lhs.deadline == rhs.deadline
                    ? lhs.sequence < rhs.sequence
                    : lhs.deadline < rhs.deadline
            })
        {
            let entry = entries.remove(at: index)
            if !entry.token.cancelled { entry.action() }
        }
    }
}

private actor BindingAvailabilityQueue {
    private var responses: [NativeAppleTranslationReadiness] = []
    private var continuations: [
        CheckedContinuation<NativeAppleTranslationReadiness, Never>
    ] = []
    private(set) var queryCount = 0

    func query() async -> NativeAppleTranslationReadiness {
        queryCount += 1
        if !responses.isEmpty { return responses.removeFirst() }
        return await withCheckedContinuation { continuation in
            continuations.append(continuation)
        }
    }

    func respond(_ readiness: NativeAppleTranslationReadiness) {
        if continuations.isEmpty {
            responses.append(readiness)
        } else {
            continuations.removeFirst().resume(returning: readiness)
        }
    }

    func count() -> Int { queryCount }
}

private final class BindingEventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []
    func append(_ value: String) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }
    func snapshot() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }
}

@MainActor
private final class BindingOverlaySpy {
    private let registry = NativeTranslationOverlayExternalPresentationRegistry()
    private var sessionGeneration = 0

    var reserveSucceeds = true
    var activateSucceeds = true
    var updateSucceeds = true
    var resolveSucceeds = true
    var reserveCount = 0
    var activations: [NativeTranslationAppleResultLabValidatedPresentation] = []
    var updates: [NativeTranslationAppleResultLabValidatedPresentation] = []
    var terminals: [NativeTranslationAppleResultLabValidatedPresentation] = []
    var invalidations: [NativeTranslationOverlayDismissReason] = []
    var focusCount = 0
    var onInvalidate: (() -> Void)?

    var client: NativeTranslationAppleResultLabOverlayClient {
        NativeTranslationAppleResultLabOverlayClient(
            reserve: { [weak self] onDismiss in
                guard let self else { return nil }
                self.reserveCount += 1
                guard self.reserveSucceeds else { return nil }
                self.sessionGeneration += 1
                return self.registry.begin(
                    sessionGeneration: self.sessionGeneration,
                    onDismiss: onDismiss
                )
            },
            activate: { [weak self] presentation, lease in
                guard let self, self.activateSucceeds,
                      self.registry.matches(
                          lease,
                          sessionGeneration: self.sessionGeneration
                      ) else { return false }
                self.activations.append(presentation)
                return true
            },
            updateLoading: { [weak self] presentation, lease in
                guard let self, self.updateSucceeds,
                      self.registry.matches(
                          lease,
                          sessionGeneration: self.sessionGeneration
                      ) else { return false }
                self.updates.append(presentation)
                return true
            },
            resolve: { [weak self] presentation, lease in
                guard let self, self.resolveSucceeds,
                      self.registry.acceptTerminal(
                          lease,
                          sessionGeneration: self.sessionGeneration
                      ) else { return false }
                self.terminals.append(presentation)
                return true
            },
            invalidate: { [weak self] lease, reason in
                guard let self else { return }
                self.invalidations.append(reason)
                self.onInvalidate?()
                _ = self.registry.invalidate(lease, reason: reason)
            },
            focusCurrent: { [weak self] lease in
                guard let self,
                      self.registry.matches(
                          lease,
                          sessionGeneration: self.sessionGeneration
                      ) else { return false }
                self.focusCount += 1
                return true
            }
        )
    }
}

@MainActor
private final class BindingHostControlSpy {
    var commands: [NativeTranslationAppleResultLabHostConfigurationCommand] = []
    var onCommand: ((NativeTranslationAppleResultLabHostConfigurationCommand) -> Void)?

    var installs: [NativeTranslationAppleResultLabHostRequest] {
        commands.compactMap { command in
            guard case let .install(request) = command else { return nil }
            return request
        }
    }

    var clearGenerations: [UInt64] {
        commands.compactMap { command in
            guard case let .invalidateAndClear(generation) = command else {
                return nil
            }
            return generation
        }
    }

    func record(_ command: NativeTranslationAppleResultLabHostConfigurationCommand) {
        commands.append(command)
        onCommand?(command)
    }
}

private final class BindingDomainSpy: @unchecked Sendable {
    private struct SessionState {
        var generation: UInt64 = 0
        var activeGeneration: UInt64?
        var retainedInput = false
    }

    private let lock = NSLock()
    private let eventLog: BindingEventLog?
    private var nextSessionID = 0
    private var sessions: [Int: SessionState] = [:]
    private var _makeCount = 0
    private var _beginCount = 0
    private var _invalidations: [NativeTranslationInvalidationReason] = []

    init(eventLog: BindingEventLog? = nil) {
        self.eventLog = eventLog
    }

    var makeCount: Int { locked { _makeCount } }
    var beginCount: Int { locked { _beginCount } }
    var invalidations: [NativeTranslationInvalidationReason] {
        locked { _invalidations }
    }

    @MainActor
    var factory: NativeTranslationAppleResultLabDomainFactory {
        NativeTranslationAppleResultLabDomainFactory { [weak self] executor, publisher in
            guard let self else {
                return NativeTranslationAppleResultLabDomainHandle(
                    begin: { 0 },
                    invalidate: { _ in },
                    hasRetainedInput: { false }
                )
            }
            let sessionID = self.createSession()
            return NativeTranslationAppleResultLabDomainHandle(
                begin: { [weak self] in
                    guard let self else { return 0 }
                    let generation = self.begin(sessionID: sessionID)
                    let input = NativeTranslationInput(
                        text: NativeTranslationAppleResultLabFixture.sourceText,
                        wasTruncated: false,
                        scalarCount: NativeTranslationAppleResultLabFixture
                            .sourceText.unicodeScalars.count
                    )
                    let result = await executor.execute(
                        NativeTranslationEffectRequest(
                            engine: .apple,
                            input: input,
                            volcCredentials: nil
                        )
                    )
                    guard !Task.isCancelled,
                          self.isCurrent(
                              sessionID: sessionID,
                              generation: generation
                          ) else { return generation }
                    let outcome: NativeTranslationOutcome
                    switch result {
                    case let .success(text):
                        outcome = .success(
                            NativeTranslationSuccess(
                                engine: .apple,
                                text: text,
                                inputWasTruncated: false
                            )
                        )
                    case let .failure(failure):
                        outcome = .failure(failure)
                    case .cancelled:
                        outcome = .cancelled
                    }
                    publisher(generation, outcome)
                    return generation
                },
                invalidate: { [weak self] reason in
                    self?.invalidate(sessionID: sessionID, reason: reason)
                    self?.eventLog?.append("domain-invalidate")
                },
                hasRetainedInput: { [weak self] in
                    self?.retainedInput(sessionID: sessionID) ?? false
                }
            )
        }
    }

    private func createSession() -> Int {
        lock.lock()
        defer { lock.unlock() }
        nextSessionID += 1
        _makeCount += 1
        sessions[nextSessionID] = SessionState()
        return nextSessionID
    }

    private func begin(sessionID: Int) -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        _beginCount += 1
        var state = sessions[sessionID] ?? SessionState()
        state.generation &+= 1
        state.activeGeneration = state.generation
        state.retainedInput = true
        sessions[sessionID] = state
        return state.generation
    }

    private func invalidate(
        sessionID: Int,
        reason: NativeTranslationInvalidationReason
    ) {
        lock.lock()
        defer { lock.unlock() }
        _invalidations.append(reason)
        var state = sessions[sessionID] ?? SessionState()
        state.activeGeneration = nil
        state.retainedInput = false
        sessions[sessionID] = state
    }

    private func isCurrent(sessionID: Int, generation: UInt64) -> Bool {
        locked { sessions[sessionID]?.activeGeneration == generation }
    }

    private func retainedInput(sessionID: Int) -> Bool {
        locked { sessions[sessionID]?.retainedInput == true }
    }

    private func locked<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }
}

@MainActor
private struct BindingHarness {
    let availability: BindingAvailabilityQueue
    let scheduler: BindingManualScheduler
    let overlay: BindingOverlaySpy
    let domain: BindingDomainSpy
    let host: BindingHostControlSpy
    let coordinator: NativeTranslationAppleResultLabCoordinator

    init(eventLog: BindingEventLog? = nil) {
        let availabilityQueue = BindingAvailabilityQueue()
        availability = availabilityQueue
        scheduler = BindingManualScheduler()
        overlay = BindingOverlaySpy()
        domain = BindingDomainSpy(eventLog: eventLog)
        host = BindingHostControlSpy()
        coordinator = NativeTranslationAppleResultLabCoordinator(
            availability: NativeTranslationAppleResultLabAvailabilityClient {
                await availabilityQueue.query()
            },
            scheduler: scheduler,
            overlay: overlay.client,
            domainFactory: domain.factory
        )
        coordinator.attachHostConfigurationControl { [host] command in
            host.record(command)
        }
    }
}

@main
@MainActor
enum NativeTranslationAppleResultLabBindingModelTests {
    private static var passed = 0

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard condition() else { fatalError("\(message) (\(file):\(line))") }
        passed += 1
    }

    private static func drain(_ turns: Int = 16) async {
        for _ in 0..<turns { await Task.yield() }
    }

    private static func open(
        _ harness: BindingHarness,
        readiness: NativeAppleTranslationReadiness
    ) async {
        harness.coordinator.open()
        await drain()
        await harness.availability.respond(readiness)
        await drain()
    }

    private static func beginInstalledTranslation(
        _ harness: BindingHarness
    ) async -> NativeTranslationAppleResultLabHostRequest? {
        harness.coordinator.perform(.translateFixture)
        await drain()
        await harness.availability.respond(.installed)
        await drain()
        return harness.host.installs.last
    }

    static func main() async {
        testFixturePresentationAndActionContract()
        await testOpenIsAvailabilityOnly()
        await testDormantLeaseFailsClosedBeforeActivation()
        await testInstalledRunsDomainHostAndVariableSuccess()
        await testTotalDeadlineIncludesAvailability()
        await testAvailabilityAndHostAcquisitionBoundaries()
        await testPreparationIsExplicitIndeterminateAndRechecked()
        await testSynchronousClearCompletionOrdering()
        await testRetiringHostBlocksReplacementClaim()
        await testStaleUnclaimedSlotCannotClaimReplacement()
        await testLifecycleInvalidatesPreparationBeforeLateCompletion()
        await testCurrentPhysicalCancellationStopsWithoutTerminal()
        await testStopCloseAndLateCompletionAreSilent()
        await testHostFailureUsesFreshAvailabilityMatrix()
        await testPlacementFailuresStayEffectFree()
        await testActionGates()
        print(
            "NativeTranslationAppleResultLabBindingModelTests: \(passed) passed"
        )
    }

    private static func testFixturePresentationAndActionContract() {
        expect(
            NativeTranslationAppleResultLabFixture.sourceText
                == "The weather is pleasant today.",
            "binding uses the one exact fixture"
        )
        expect(
            NativeTranslationAppleResultLabSheetAnnouncementPolicy
                .sheetOwnsStatusAnnouncement(
                    for: .safetyFailure,
                    hasVisibleResult: false
                ),
            "sheet owns nonvisible safety feedback"
        )
        expect(
            !NativeTranslationAppleResultLabSheetAnnouncementPolicy
                .sheetOwnsStatusAnnouncement(
                    for: .safetyFailure,
                    hasVisibleResult: true
                ),
            "visible safety feedback remains overlay-owned"
        )
        let checking = NativeTranslationAppleResultLabPresentation.make(
            for: .checkingAvailability
        )
        expect(checking.primaryAction == nil, "open exposes no effect action")
        let ready = NativeTranslationAppleResultLabPresentation.make(for: .ready)
        expect(ready.primaryAction == .translateFixture, "ready explicitly translates")
        let needs = NativeTranslationAppleResultLabPresentation.make(
            for: .needsPreparation
        )
        expect(needs.primaryAction == .prepareLanguages, "preparation is explicit")
        let stopped = NativeTranslationAppleResultLabPresentation.make(
            for: .preparationWaitStopped
        )
        expect(
            stopped.message.contains("macOS 可能仍会继续下载"),
            "stopping only stops Juyi waiting"
        )
        expect(
            !stopped.message.contains("已取消" + "系统下载"),
            "UI never claims system download cancellation"
        )
        let preparing = NativeTranslationAppleResultLabPresentation.make(
            for: .preparing(extendedWait: false)
        )
        expect(
            preparing.message.contains("停止等待或关闭此页面")
                && preparing.message.contains("macOS 可能继续下载"),
            "stop and close disclose that system download may continue"
        )
        let typedFailure = NativeTranslationAppleResultLabPresentation.make(
            for: .typedFailure(.appleExecutionFailed)
        )
        expect(
            typedFailure.primaryAction == .recheckAvailability,
            "typed failure has an explicit recheck action"
        )
        let timeout = NativeTranslationAppleResultLabPresentation.make(for: .timeout)
        expect(
            timeout.primaryAction == .translateFixture
                && timeout.secondaryAction == .recheckAvailability,
            "timeout exposes retry and recheck actions"
        )
        let terminalStopped = NativeTranslationAppleResultLabPresentation.make(
            for: .stopped
        )
        expect(
            terminalStopped.primaryAction == .recheckAvailability,
            "stopped state has an explicit recheck action"
        )
    }

    private static func testOpenIsAvailabilityOnly() async {
        let harness = BindingHarness()
        harness.coordinator.open()
        await drain()
        let queryCount = await harness.availability.count()
        expect(queryCount == 1, "open queries exactly once")
        expect(harness.overlay.reserveCount == 0, "open reserves no lease")
        expect(harness.overlay.activations.isEmpty, "open activates no panel")
        expect(harness.domain.makeCount == 0, "open makes no domain")
        expect(harness.domain.beginCount == 0, "open begins no domain")
        expect(harness.host.installs.isEmpty, "open installs no Translation host")
        expect(
            harness.coordinator.phase == .checkingAvailability,
            "open remains availability-only while query is pending"
        )
        await harness.availability.respond(.installed)
        await drain()
        expect(harness.coordinator.phase == .ready, "installed opening becomes ready")
    }

    private static func testDormantLeaseFailsClosedBeforeActivation() async {
        let harness = BindingHarness()
        await open(harness, readiness: .installed)
        harness.coordinator.perform(.translateFixture)
        await drain()
        expect(harness.overlay.reserveCount == 1, "translate first reserves dormant lease")
        expect(harness.overlay.activations.isEmpty, "preflight does not show a panel")
        harness.scheduler.advance(by: 0.5)
        await harness.availability.respond(.supportedNeedsPreparation)
        await drain()
        expect(harness.coordinator.phase == .needsPreparation, "fresh pack state wins")
        expect(harness.overlay.activations.isEmpty, "failed preflight never activates")
        expect(harness.overlay.terminals.isEmpty, "failed dormant lease has no panel terminal")
        expect(harness.domain.makeCount == 0, "failed preflight makes no domain")
        expect(harness.domain.beginCount == 0, "failed preflight begins no domain")
        expect(harness.host.installs.isEmpty, "failed preflight creates no host")
        expect(harness.overlay.invalidations == [.stop], "dormant lease is revoked")
    }

    private static func testInstalledRunsDomainHostAndVariableSuccess() async {
        let harness = BindingHarness()
        await open(harness, readiness: .installed)
        guard let request = await beginInstalledTranslation(harness) else {
            expect(false, "installed preflight issues host request")
            return
        }
        expect(harness.overlay.activations.isEmpty, "lease stays dormant until host claim")
        expect(harness.domain.makeCount == 1, "installed makes one domain")
        expect(harness.domain.beginCount == 1, "installed begins one domain")
        expect(request.intent == .translate, "host request is translation")
        guard let claim = harness.coordinator.claimHost(request) else {
            expect(false, "current request claims host once")
            return
        }
        expect(harness.overlay.activations.count == 1, "host claim activates loading")
        expect(
            claim.sourceText == NativeTranslationAppleResultLabFixture.sourceText,
            "host receives only fixed source"
        )
        expect(claim.receipt != nil, "real host claim receives opaque receipt")
        expect(
            harness.coordinator.claimHost(request) == nil,
            "duplicate host claim is rejected"
        )
        let variableTarget = "今日天气宜人，适合散步。"
        harness.coordinator.completeHost(.translated(variableTarget), claim: claim)
        await drain(32)
        expect(harness.coordinator.phase == .success, "variable target succeeds")
        expect(harness.overlay.terminals.count == 1, "success resolves once")
        expect(
            harness.overlay.terminals.first?.overlayState.copyText == variableTarget,
            "full variable target is copyable"
        )
        expect(harness.host.clearGenerations.count >= 1, "completion clears host config")
    }

    private static func testTotalDeadlineIncludesAvailability() async {
        let harness = BindingHarness()
        await open(harness, readiness: .installed)
        harness.coordinator.perform(.translateFixture)
        await drain()
        harness.scheduler.advance(by: 4.9)
        await harness.availability.respond(.installed)
        await drain()
        guard let request = harness.host.installs.last,
              let claim = harness.coordinator.claimHost(request) else {
            expect(false, "host is claimable after slow installed preflight")
            return
        }
        harness.scheduler.advance(by: 7.09)
        await drain()
        expect(harness.coordinator.phase != .timeout, "deadline has not fired early")
        harness.scheduler.advance(by: 0.01)
        await drain(32)
        expect(harness.coordinator.phase == .timeout, "12 seconds starts at lease reserve")
        expect(harness.overlay.terminals.last?.category == .timeout, "timeout resolves once")
        harness.coordinator.completeHost(.translated("迟到结果"), claim: claim)
        await drain()
        expect(harness.overlay.terminals.count == 1, "late physical completion is silent")
    }

    private static func testAvailabilityAndHostAcquisitionBoundaries() async {
        do {
            let harness = BindingHarness()
            await open(harness, readiness: .installed)
            harness.coordinator.perform(.translateFixture)
            await drain()
            harness.scheduler.advance(by: 4.999)
            await drain()
            expect(
                harness.coordinator.phase != .temporarilyUnavailable,
                "availability is allowed until five seconds"
            )
            harness.scheduler.advance(by: 0.001)
            await drain()
            expect(
                harness.coordinator.phase == .temporarilyUnavailable,
                "availability fails closed at five seconds"
            )
            expect(harness.overlay.activations.isEmpty, "availability timeout stays dormant")
        }
        do {
            let harness = BindingHarness()
            await open(harness, readiness: .installed)
            guard await beginInstalledTranslation(harness) != nil else {
                expect(false, "host request exists for acquisition timeout")
                return
            }
            harness.scheduler.advance(by: 4.999)
            await drain()
            expect(harness.overlay.terminals.isEmpty, "host may claim before five seconds")
            harness.scheduler.advance(by: 0.001)
            await drain(32)
            expect(
                harness.coordinator.phase == .hostUnavailable,
                "host acquisition fails in the sheet at five seconds"
            )
            expect(harness.overlay.activations.isEmpty, "host timeout never activates")
            expect(harness.overlay.terminals.isEmpty, "host timeout has no overlay terminal")
            expect(harness.overlay.invalidations == [.stop], "dormant lease is revoked")
        }
    }

    private static func testPreparationIsExplicitIndeterminateAndRechecked() async {
        do {
            let harness = BindingHarness()
            await open(harness, readiness: .supportedNeedsPreparation)
            expect(harness.host.installs.isEmpty, "readiness alone never prepares")
            harness.coordinator.perform(.prepareLanguages)
            guard let request = harness.host.installs.last,
                  let claim = harness.coordinator.claimHost(request) else {
                expect(false, "explicit preparation claims host")
                return
            }
            harness.scheduler.advance(by: 30)
            expect(
                harness.coordinator.phase == .preparing(extendedWait: true),
                "thirty seconds only enables extended hint"
            )
            expect(harness.overlay.terminals.isEmpty, "preparation has no hard timeout")
            harness.coordinator.perform(.stopWaiting)
            expect(
                harness.coordinator.phase == .preparationWaitStopped,
                "stop only ends Juyi waiting"
            )
            harness.coordinator.completeHost(.prepared, claim: claim)
            await drain()
            expect(harness.overlay.terminals.isEmpty, "late preparation is not a result")
        }
        do {
            let harness = BindingHarness()
            await open(harness, readiness: .supportedNeedsPreparation)
            harness.coordinator.perform(.prepareLanguages)
            guard let request = harness.host.installs.last,
                  let claim = harness.coordinator.claimHost(request) else {
                expect(false, "preparation claim exists")
                return
            }
            harness.coordinator.completeHost(.prepared, claim: claim)
            await drain()
            let queryCount = await harness.availability.count()
            expect(queryCount == 2, "completion rechecks once")
            expect(
                harness.coordinator.phase == .checkingAvailability,
                "completion waits for fresh pack state"
            )
            await harness.availability.respond(.installed)
            await drain()
            expect(harness.coordinator.phase == .ready, "fresh installed becomes ready")
            expect(harness.domain.beginCount == 0, "preparation never auto-translates")
            expect(harness.overlay.reserveCount == 0, "preparation never reserves result panel")
        }
        do {
            let harness = BindingHarness()
            await open(harness, readiness: .supportedNeedsPreparation)
            harness.coordinator.perform(.prepareLanguages)
            guard let request = harness.host.installs.last,
                  let claim = harness.coordinator.claimHost(request) else {
                expect(false, "failed preparation claim exists")
                return
            }
            harness.coordinator.completeHost(
                .failure(.appleExecutionFailed),
                claim: claim
            )
            await drain()
            await harness.availability.respond(.supportedNeedsPreparation)
            await drain()
            expect(
                harness.coordinator.phase == .preparationFailed,
                "failure rechecks and retains fresh needs-preparation state"
            )
            expect(harness.domain.beginCount == 0, "failure never auto-translates")
        }
    }

    private static func testSynchronousClearCompletionOrdering() async {
        let log = BindingEventLog()
        let harness = BindingHarness(eventLog: log)
        harness.overlay.onInvalidate = {
            log.append("overlay-invalidate")
        }
        await open(harness, readiness: .installed)
        guard let request = await beginInstalledTranslation(harness),
              let claim = harness.coordinator.claimHost(request) else {
            expect(false, "reentrant clear test claims host")
            return
        }
        harness.host.onCommand = { command in
            guard case .invalidateAndClear = command else { return }
            log.append("clear")
            harness.coordinator.completeHost(.translated("同步迟到"), claim: claim)
            log.append("clear-return")
        }
        harness.coordinator.perform(.stopWaiting)
        await drain(40)
        let events = log.snapshot()
        guard let clearIndex = events.firstIndex(of: "clear"),
              let clearReturnIndex = events.firstIndex(of: "clear-return"),
              let overlayIndex = events.firstIndex(of: "overlay-invalidate"),
              let domainIndex = events.firstIndex(of: "domain-invalidate") else {
            expect(false, "clear, overlay and domain events are recorded")
            return
        }
        expect(clearIndex < clearReturnIndex, "physical completion is synchronous in clear")
        expect(clearReturnIndex < overlayIndex, "tombstone clears before lease invalidation")
        expect(clearIndex < overlayIndex, "host clear precedes lease invalidation")
        expect(clearIndex < domainIndex, "host clear precedes domain invalidation")
        expect(harness.overlay.terminals.isEmpty, "reentrant completion cannot resolve")
        expect(harness.coordinator.phase == .stopped, "stop remains authoritative")
    }

    private static func testRetiringHostBlocksReplacementClaim() async {
        let harness = BindingHarness()
        await open(harness, readiness: .installed)
        guard let requestA = await beginInstalledTranslation(harness),
              let claimA = harness.coordinator.claimHost(requestA) else {
            expect(false, "A claims physical host")
            return
        }
        harness.coordinator.perform(.stopWaiting)
        await drain()
        harness.coordinator.perform(.recheckAvailability)
        await drain()
        await harness.availability.respond(.installed)
        await drain()
        harness.coordinator.perform(.translateFixture)
        await drain()
        await harness.availability.respond(.installed)
        await drain(24)
        guard let requestB = harness.coordinator.hostRequest else {
            expect(false, "B waits with logical host request")
            return
        }
        expect(
            harness.coordinator.claimHost(requestB) == nil,
            "A retiring physical task blocks B claim"
        )
        let installsBefore = harness.host.installs.count
        harness.coordinator.completeHost(.cancelled, claim: claimA)
        expect(
            harness.host.installs.count == installsBefore + 1,
            "A physical completion installs waiting B"
        )
        expect(
            harness.coordinator.claimHost(requestB) != nil,
            "B claims only after A physical completion"
        )
        harness.coordinator.perform(.stopWaiting)
        await drain()
    }

    private static func testStaleUnclaimedSlotCannotClaimReplacement() async {
        let harness = BindingHarness()
        await open(harness, readiness: .installed)
        guard let requestA = await beginInstalledTranslation(harness) else {
            expect(false, "A installs an immutable host slot")
            return
        }
        harness.coordinator.perform(.stopWaiting)
        await drain(32)
        harness.coordinator.perform(.recheckAvailability)
        await drain()
        await harness.availability.respond(.installed)
        await drain()
        guard let requestB = await beginInstalledTranslation(harness) else {
            expect(false, "B installs a replacement host slot")
            return
        }
        expect(requestA != requestB, "A and B have distinct immutable slot tickets")
        harness.coordinator.hostSlotWillDisappear(requestA)
        expect(
            harness.coordinator.claimHost(requestA) == nil,
            "a delayed A translationTask can only submit A and cannot claim B"
        )
        expect(
            harness.overlay.activations.isEmpty,
            "stale A performs no live overlay activation"
        )
        expect(
            harness.coordinator.claimHost(requestB) != nil,
            "only the keyed B slot claims the replacement request"
        )
        expect(
            harness.overlay.activations.count == 1,
            "B activates the live panel exactly once"
        )
    }

    private static func testLifecycleInvalidatesPreparationBeforeLateCompletion() async {
        for reason in [
            NativeTranslationInvalidationReason.ownerChanged,
            .accessibilityRevoked,
        ] {
            let harness = BindingHarness()
            await open(harness, readiness: .supportedNeedsPreparation)
            harness.coordinator.perform(.prepareLanguages)
            guard let request = harness.host.installs.last,
                  let claim = harness.coordinator.claimHost(request) else {
                expect(false, "preparation claims a keyed host before lifecycle change")
                continue
            }
            let queriesBeforeLifecycle = await harness.availability.count()
            harness.coordinator.invalidate(reason)
            harness.coordinator.completeHost(.prepared, claim: claim)
            await drain(32)
            expect(
                harness.coordinator.phase == .stopped,
                "lifecycle tombstone keeps late preparation completion stopped"
            )
            let queriesAfterLifecycle = await harness.availability.count()
            expect(
                queriesAfterLifecycle == queriesBeforeLifecycle,
                "late preparation completion starts no readiness recheck"
            )
            expect(
                harness.domain.beginCount == 0,
                "prepare lifecycle race never starts translation"
            )
            expect(
                harness.overlay.activations.isEmpty && harness.overlay.terminals.isEmpty,
                "prepare lifecycle race has zero panel and terminal output"
            )
        }
    }

    private static func testCurrentPhysicalCancellationStopsWithoutTerminal() async {
        let harness = BindingHarness()
        await open(harness, readiness: .installed)
        guard let request = await beginInstalledTranslation(harness),
              let claim = harness.coordinator.claimHost(request) else {
            expect(false, "current cancellation test claims the physical host")
            return
        }
        harness.coordinator.completeHost(.cancelled, claim: claim)
        await drain(48)
        expect(
            harness.coordinator.phase == .stopped,
            "a spontaneous current host cancellation stops instead of hanging"
        )
        expect(
            harness.overlay.terminals.isEmpty,
            "current cancellation produces zero terminal panel or VO event"
        )
        expect(
            harness.overlay.invalidations.count == 1,
            "current cancellation invalidates the exact lease once"
        )
        expect(
            !harness.coordinator.hasVisibleResult,
            "current cancellation leaves no focusable or copyable result"
        )
        expect(
            harness.domain.invalidations == [.stop],
            "current cancellation cleans the 4A domain exactly once"
        )
    }

    private static func testStopCloseAndLateCompletionAreSilent() async {
        for shouldClose in [false, true] {
            let harness = BindingHarness()
            await open(harness, readiness: .installed)
            guard let request = await beginInstalledTranslation(harness),
                  let claim = harness.coordinator.claimHost(request) else {
                expect(false, "lifecycle test claims host")
                continue
            }
            if shouldClose {
                harness.coordinator.close()
            } else {
                harness.coordinator.perform(.stopWaiting)
            }
            harness.coordinator.completeHost(.translated("迟到目标"), claim: claim)
            await drain(32)
            expect(harness.overlay.terminals.isEmpty, "late completion never resolves")
            expect(harness.overlay.invalidations.count == 1, "current lease invalidates once")
            expect(harness.coordinator.phase == .stopped, "lifecycle stop is terminal")
            if shouldClose {
                expect(!harness.coordinator.isPresented, "close hides sheet")
            }
        }
    }

    private static func testHostFailureUsesFreshAvailabilityMatrix() async {
        let cases: [(NativeAppleTranslationReadiness, NativeTranslationFailure)] = [
            (.installed, .appleExecutionFailed),
            (.supportedNeedsPreparation, .appleNeedsPreparation),
            (.unsupported, .appleUnsupported),
            (.temporarilyUnavailable, .appleTemporarilyUnavailable),
        ]
        for (readiness, expectedFailure) in cases {
            let harness = BindingHarness()
            await open(harness, readiness: .installed)
            guard let request = await beginInstalledTranslation(harness),
                  let claim = harness.coordinator.claimHost(request) else {
                expect(false, "failure recheck test claims host")
                continue
            }
            harness.coordinator.completeHost(
                .failure(.appleExecutionFailed),
                claim: claim
            )
            await drain()
            let queryCount = await harness.availability.count()
            expect(queryCount == 3, "host failure performs one fresh availability query")
            await harness.availability.respond(readiness)
            await drain(32)
            expect(
                harness.coordinator.phase == .typedFailure(expectedFailure),
                "fresh pack state determines typed failure"
            )
            expect(harness.overlay.terminals.count == 1, "typed failure resolves once")
            expect(
                harness.overlay.terminals[0].overlayState.copyText == nil,
                "typed failure has zero copy"
            )
        }
    }

    private static func testPlacementFailuresStayEffectFree() async {
        do {
            let harness = BindingHarness()
            await open(harness, readiness: .installed)
            harness.overlay.reserveSucceeds = false
            harness.coordinator.perform(.translateFixture)
            await drain()
            expect(harness.coordinator.phase == .stopped, "reserve failure stops safely")
            expect(harness.domain.makeCount == 0, "reserve failure makes no domain")
            expect(harness.host.installs.isEmpty, "reserve failure requests no host")
            expect(harness.overlay.activations.isEmpty, "reserve failure shows no panel")
        }
        do {
            let harness = BindingHarness()
            await open(harness, readiness: .installed)
            guard let request = await beginInstalledTranslation(harness) else {
                expect(false, "activation failure reaches a logical host request")
                return
            }
            harness.overlay.activateSucceeds = false
            expect(
                harness.coordinator.claimHost(request) == nil,
                "activation failure returns no physical claim"
            )
            await drain(32)
            expect(harness.coordinator.phase == .stopped, "activation failure stops safely")
            expect(harness.overlay.terminals.isEmpty, "activation failure has no terminal")
            expect(harness.overlay.activations.isEmpty, "activation failure shows no panel")
            expect(
                harness.domain.invalidations == [.ownerChanged],
                "activation failure invalidates 4A domain; got \(harness.domain.invalidations)"
            )
        }
        do {
            let harness = BindingHarness()
            await open(harness, readiness: .installed)
            guard let request = await beginInstalledTranslation(harness),
                  let claim = harness.coordinator.claimHost(request) else {
                expect(false, "terminal rejection reaches the current host claim")
                return
            }
            harness.overlay.resolveSucceeds = false
            harness.coordinator.completeHost(.translated("今日天气宜人。"), claim: claim)
            await drain(32)
            expect(
                harness.coordinator.phase == .safetyFailure,
                "terminal rejection becomes a sheet-visible safety failure"
            )
            expect(
                !harness.coordinator.hasVisibleResult,
                "terminal rejection exposes no focusable result"
            )
            expect(
                NativeTranslationAppleResultLabSheetAnnouncementPolicy
                    .sheetOwnsStatusAnnouncement(
                        for: harness.coordinator.phase,
                        hasVisibleResult: harness.coordinator.hasVisibleResult
                    ),
                "sheet announces rejected nonvisible safety state"
            )
            expect(harness.overlay.terminals.isEmpty, "rejected terminal is never shown")
        }
    }

    private static func testActionGates() async {
        do {
            let harness = BindingHarness()
            harness.coordinator.open()
            await drain()
            harness.coordinator.perform(.translateFixture)
            harness.coordinator.perform(.prepareLanguages)
            harness.coordinator.perform(.recheckAvailability)
            expect(harness.overlay.reserveCount == 0, "checking rejects translate")
            expect(harness.host.installs.isEmpty, "checking rejects prepare")
            let queryCount = await harness.availability.count()
            expect(queryCount == 1, "checking rejects extra recheck")
            harness.coordinator.perform(.close)
            expect(!harness.coordinator.isPresented, "close is always allowed")
        }
        do {
            let harness = BindingHarness()
            await open(harness, readiness: .installed)
            harness.coordinator.perform(.prepareLanguages)
            expect(harness.host.installs.isEmpty, "ready rejects prepare")
        }
        do {
            let harness = BindingHarness()
            await open(harness, readiness: .supportedNeedsPreparation)
            harness.coordinator.perform(.translateFixture)
            expect(harness.overlay.reserveCount == 0, "needs-preparation rejects translate")
        }
    }
}
#endif
