#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER
import Foundation

@MainActor
private final class ManualScheduledTask: NativeAppleTranslationScheduledTask {
    private(set) var cancelled = false
    func cancel() { cancelled = true }
}

@MainActor
private final class ManualScheduler: NativeAppleTranslationScheduling {
    private struct Entry {
        let deadline: TimeInterval
        let sequence: Int
        let token: ManualScheduledTask
        let action: @MainActor () -> Void
    }

    private var entries: [Entry] = []
    private var sequence = 0
    private(set) var now: TimeInterval = 0

    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> any NativeAppleTranslationScheduledTask {
        sequence += 1
        let token = ManualScheduledTask()
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
                    ? lhs.sequence < rhs.sequence : lhs.deadline < rhs.deadline
            })
        {
            let entry = entries.remove(at: index)
            if !entry.token.cancelled { entry.action() }
        }
    }
}

private actor AvailabilityQueue {
    private var responses: [NativeAppleTranslationReadiness] = []
    private var continuations: [CheckedContinuation<NativeAppleTranslationReadiness, Never>] = []
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
}

@main
@MainActor
enum NativeAppleTranslationAdapterTests {
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

    private static func drain() async {
        for _ in 0..<6 { await Task.yield() }
    }

    private static func makeCoordinator(
        queue: AvailabilityQueue,
        scheduler: ManualScheduler,
        announcements: AnnouncementRecorder
    ) -> NativeAppleTranslationAdapterCoordinator {
        NativeAppleTranslationAdapterCoordinator(
            availability: NativeAppleTranslationAvailabilityClient {
                await queue.query()
            },
            scheduler: scheduler,
            announce: { message in announcements.messages.append(message) }
        )
    }

    static func main() async {
        testFixtureAndPresentationContract()
        await testOpeningAvailabilityMatrix()
        await testAvailabilityTimeoutBoundary()
        await testTranslationPreflightAndExactlyOnceClaim()
        await testHostAcquisitionTimeout()
        await testTranslationClockAndLateResult()
        await testPreparationFlowAndThirtySecondHint()
        await testPreparationFailureRechecks()
        await testCancellationAndExternalInvalidation()
        await testNewGenerationSupersedesOldAvailability()
        print("NativeAppleTranslationAdapterTests: \(passed) passed")
    }

    private static func testFixtureAndPresentationContract() {
        expect(
            NativeAppleTranslationAdapterFixture.sourceText == "The weather is pleasant today.",
            "the one fixed fixture is exact"
        )
        expect(NativeAppleTranslationAdapterFixture.sourceLanguageIdentifier == "en", "source is en")
        expect(NativeAppleTranslationAdapterFixture.targetLanguageIdentifier == "zh-Hans", "target is zh-Hans")

        let checking = NativeAppleTranslationAdapterPresentation.make(for: .checking)
        expect(checking.title == "正在检查 Apple 离线翻译", "checking title is exact")
        expect(checking.message == "只检查英语→简体中文语言资源，不会开始下载。", "checking promise is exact")
        expect(checking.primaryAction == nil, "opening has no preparation or translation action")

        let ready = NativeAppleTranslationAdapterPresentation.make(for: .ready)
        expect(ready.title == "Apple 离线翻译已准备好", "ready title is exact")
        expect(ready.primaryAction == .translateFixture, "ready has explicit translate action")
        expect(ready.secondaryAction == .recheckAvailability, "ready can recheck")

        let needs = NativeAppleTranslationAdapterPresentation.make(for: .needsPreparation)
        expect(needs.title == "需要准备 Apple 离线语言包", "needs-preparation title is exact")
        expect(needs.primaryAction == .prepareLanguages, "only explicit CTA prepares")
        expect(needs.message.contains("只有你点击后"), "download is explicitly user initiated")

        let unsupported = NativeAppleTranslationAdapterPresentation.make(for: .unsupported)
        expect(unsupported.message == "当前测试不会改用火山云端。", "unsupported has no fallback")
        let temporary = NativeAppleTranslationAdapterPresentation.make(for: .temporarilyUnavailable)
        expect(temporary.message == "请稍后重试；当前测试不会改用云端。", "temporary failure has no fallback")

        let preparing = NativeAppleTranslationAdapterPresentation.make(for: .preparing(extendedWait: false))
        expect(preparing.title == "正在准备 Apple 离线语言包…", "preparing title is exact")
        expect(preparing.message == "请按 macOS 提示确认；下载由系统管理。", "preparing does not claim progress")
        let extended = NativeAppleTranslationAdapterPresentation.make(for: .preparing(extendedWait: true))
        expect(extended.message == "仍在等待 macOS 完成…下载由系统管理。", "30-second hint stays indeterminate")
        let stopped = NativeAppleTranslationAdapterPresentation.make(for: .preparationWaitStopped)
        expect(stopped.title == "已停止等待", "stopping only describes Juyi's wait")
        expect(
            stopped.message == "macOS 可能仍会继续下载；可稍后检查状态。",
            "stopped wait does not claim the system download was cancelled"
        )
        expect(stopped.primaryAction == .recheckAvailability, "stopped wait only offers a status check")

        let timedOut = NativeAppleTranslationAdapterPresentation.make(for: .translationTimedOut)
        expect(timedOut.title == "Apple 离线翻译暂时没有响应", "translation timeout title is exact")
        expect(timedOut.message == "请稍后重试；不会自动改用云端。", "timeout has no fallback")
        let success = NativeAppleTranslationAdapterPresentation.make(for: .success)
        expect(success.title == "Apple 离线翻译测试成功", "success title is exact")

        let readyActions = NativeAppleTranslationAdapterInteractionPolicy.orderedActions(
            phase: .ready,
            presentation: ready
        )
        expect(
            readyActions.map(\.action) == [.translateFixture, .recheckAvailability, .close],
            "keyboard order is primary, secondary, then close"
        )
        let successActions = NativeAppleTranslationAdapterInteractionPolicy.orderedActions(
            phase: .success,
            presentation: success
        )
        expect(
            successActions.map(\.action) == [.translateFixture, .close],
            "success has one completion/close action"
        )
        expect(successActions.last?.title == "完成", "success close action is titled 完成")
        let busyActions = NativeAppleTranslationAdapterInteractionPolicy.orderedActions(
            phase: .translating(extendedWait: false),
            presentation: NativeAppleTranslationAdapterPresentation.make(
                for: .translating(extendedWait: false)
            )
        )
        expect(
            busyActions.map(\.action) == [.cancelOperation, .close],
            "busy focus order offers cancellation before close"
        )

        let requestA = NativeAppleTranslationHostRequest(generation: 1, intent: .prepare)
        let requestB = NativeAppleTranslationHostRequest(generation: 2, intent: .translate)
        expect(
            NativeAppleTranslationHostConfigurationPolicy.transition(
                from: nil,
                to: requestA,
                hasConfiguration: false
            ) == .create,
            "nil to host request creates configuration"
        )
        expect(
            NativeAppleTranslationHostConfigurationPolicy.transition(
                from: requestA,
                to: requestB,
                hasConfiguration: true
            ) == .invalidate,
            "replacement request invalidates the existing configuration"
        )
        expect(
            NativeAppleTranslationHostConfigurationPolicy.transition(
                from: requestB,
                to: nil,
                hasConfiguration: true
            ) == .clear,
            "completion or close clears configuration immediately"
        )
        expect(
            NativeAppleTranslationHostConfigurationPolicy.transition(
                from: requestA,
                to: requestA,
                hasConfiguration: true
            ) == .noChange,
            "duplicate host observation does not restart the session"
        )
    }

    private static func testOpeningAvailabilityMatrix() async {
        let cases: [(NativeAppleTranslationReadiness, NativeAppleTranslationAdapterPhase, NativeTranslationFailure?)] = [
            (.installed, .ready, nil),
            (.supportedNeedsPreparation, .needsPreparation, .appleNeedsPreparation),
            (.unsupported, .unsupported, .appleUnsupported),
            (.temporarilyUnavailable, .temporarilyUnavailable, .appleTemporarilyUnavailable),
        ]
        for (readiness, expectedPhase, expectedFailure) in cases {
            let queue = AvailabilityQueue()
            let scheduler = ManualScheduler()
            let announcements = AnnouncementRecorder()
            let coordinator = makeCoordinator(queue: queue, scheduler: scheduler, announcements: announcements)
            coordinator.open()
            expect(coordinator.isPresented, "explicit open presents the sheet")
            expect(coordinator.snapshot.phase == .checking, "open starts checking only")
            expect(coordinator.hostRequest == nil, "opening never creates a Translation session request")
            await queue.respond(readiness)
            await drain()
            expect(coordinator.snapshot.phase == expectedPhase, "availability maps to the expected stable phase")
            if let expectedFailure {
                expect(coordinator.snapshot.outcome == .failure(expectedFailure), "readiness failure is typed")
            } else {
                expect(coordinator.snapshot.outcome == nil, "installed readiness is not a translation result")
            }
            expect(coordinator.hostRequest == nil, "availability check still has zero session effect")
            expect(coordinator.snapshot.targetText == nil, "availability never retains translated text")
            coordinator.close()
            expect(coordinator.fixtureSourceText == nil, "closing clears the fixture from sheet state")
            expect(coordinator.snapshot.outcome == nil, "closing clears outcomes")
        }
    }

    private static func testAvailabilityTimeoutBoundary() async {
        let queue = AvailabilityQueue()
        let scheduler = ManualScheduler()
        let coordinator = makeCoordinator(queue: queue, scheduler: scheduler, announcements: AnnouncementRecorder())
        coordinator.open()
        scheduler.advance(by: 4.999)
        expect(coordinator.snapshot.phase == .checking, "availability remains checking before five seconds")
        scheduler.advance(by: 0.001)
        expect(coordinator.snapshot.phase == .temporarilyUnavailable, "availability times out at five seconds")
        expect(
            coordinator.snapshot.outcome == .failure(.appleTemporarilyUnavailable),
            "availability timeout is typed and body-free"
        )
        await queue.respond(.installed)
        await drain()
        expect(coordinator.snapshot.phase == .temporarilyUnavailable, "late availability cannot overwrite timeout")
    }

    private static func testTranslationPreflightAndExactlyOnceClaim() async {
        let queue = AvailabilityQueue()
        let scheduler = ManualScheduler()
        let announcements = AnnouncementRecorder()
        let coordinator = makeCoordinator(queue: queue, scheduler: scheduler, announcements: announcements)
        coordinator.open()
        await queue.respond(.installed)
        await drain()
        coordinator.beginTranslation()
        expect(coordinator.hostRequest == nil, "translate click performs a second installed check first")
        await queue.respond(.installed)
        await drain()
        guard let request = coordinator.hostRequest else { fatalError("installed preflight must request the host") }
        let firstClaim = coordinator.claimHost(request)
        expect(firstClaim?.sourceText == "The weather is pleasant today.", "claim contains only the fixed fixture")
        expect(firstClaim?.intent == .translate, "claim preserves translate intent")
        expect(coordinator.claimHost(request) == nil, "host claim is atomic and exactly once")

        coordinator.completeHost(.translated("今天天气宜人。"), request: request)
        expect(coordinator.snapshot.phase == .success, "nonempty target publishes success")
        expect(coordinator.snapshot.targetText == "今天天气宜人。", "success retains exact target in sheet memory")
        if case let .success(success)? = coordinator.snapshot.outcome {
            expect(success.engine == .apple, "success engine is closed to Apple")
            expect(!success.inputWasTruncated, "fixed fixture is not truncated")
        } else {
            fatalError("success must use the typed domain outcome")
        }
        expect(announcements.messages.count == 1, "terminal success announces once")
        coordinator.completeHost(.translated("迟到译文"), request: request)
        expect(coordinator.snapshot.targetText == "今天天气宜人。", "duplicate completion cannot overwrite target")
        expect(announcements.messages.count == 1, "duplicate completion cannot reannounce")

        coordinator.close()
        expect(coordinator.fixtureSourceText == nil, "close releases the fixture")
        expect(coordinator.snapshot.targetText == nil, "close releases the target")

        let blockedQueue = AvailabilityQueue()
        let blocked = makeCoordinator(
            queue: blockedQueue,
            scheduler: ManualScheduler(),
            announcements: AnnouncementRecorder()
        )
        blocked.open()
        await blockedQueue.respond(.installed)
        await drain()
        blocked.beginTranslation()
        await blockedQueue.respond(.supportedNeedsPreparation)
        await drain()
        expect(blocked.snapshot.phase == .needsPreparation, "removed package returns to preparation")
        expect(blocked.hostRequest == nil, "non-installed second check has zero session effect")
    }

    private static func testHostAcquisitionTimeout() async {
        let queue = AvailabilityQueue()
        let scheduler = ManualScheduler()
        let coordinator = makeCoordinator(queue: queue, scheduler: scheduler, announcements: AnnouncementRecorder())
        coordinator.open()
        await queue.respond(.installed)
        await drain()
        coordinator.beginTranslation()
        await queue.respond(.installed)
        await drain()
        expect(coordinator.hostRequest != nil, "installed preflight issues host request")
        scheduler.advance(by: 4.999)
        expect(coordinator.snapshot.phase == .translating(extendedWait: true), "host waits until five seconds")
        scheduler.advance(by: 0.001)
        expect(coordinator.snapshot.phase == .temporarilyUnavailable, "unclaimed host is temporarily unavailable at five seconds")
        expect(coordinator.hostRequest == nil, "host timeout releases configuration request")
        expect(
            coordinator.snapshot.outcome == .failure(.appleTemporarilyUnavailable),
            "host timeout uses temporary typed failure"
        )
    }

    private static func testTranslationClockAndLateResult() async {
        let queue = AvailabilityQueue()
        let scheduler = ManualScheduler()
        let announcements = AnnouncementRecorder()
        let coordinator = makeCoordinator(queue: queue, scheduler: scheduler, announcements: announcements)
        coordinator.open()
        await queue.respond(.installed)
        await drain()
        coordinator.beginTranslation()
        await queue.respond(.installed)
        await drain()
        let request = coordinator.hostRequest!
        _ = coordinator.claimHost(request)
        scheduler.advance(by: 1.999)
        expect(coordinator.snapshot.phase == .translating(extendedWait: false), "extended hint is absent before two seconds")
        scheduler.advance(by: 0.001)
        expect(coordinator.snapshot.phase == .translating(extendedWait: true), "two-second hint appears in place")
        scheduler.advance(by: 9.999)
        expect(coordinator.snapshot.phase == .translating(extendedWait: true), "translation remains active before total 12 seconds")
        scheduler.advance(by: 0.001)
        expect(coordinator.snapshot.phase == .translationTimedOut, "translation times out at 12 seconds total")
        expect(announcements.messages.count == 1, "timeout announces once")
        coordinator.completeHost(.translated("不应显示"), request: request)
        expect(coordinator.snapshot.targetText == nil, "late target after timeout is discarded")
        expect(announcements.messages.count == 1, "late target cannot announce")

        coordinator.perform(.retryTranslation)
        expect(
            coordinator.snapshot.phase == .translating(extendedWait: false),
            "timeout retry starts a fresh translation generation"
        )
        expect(coordinator.hostRequest == nil, "timeout retry repeats installed preflight before host work")
        await queue.respond(.installed)
        await drain()
        expect(coordinator.hostRequest?.intent == .translate, "timeout retry reaches the host after preflight")

        let failureQueue = AvailabilityQueue()
        let failureCoordinator = makeCoordinator(
            queue: failureQueue,
            scheduler: ManualScheduler(),
            announcements: AnnouncementRecorder()
        )
        failureCoordinator.open()
        await failureQueue.respond(.installed)
        await drain()
        failureCoordinator.beginTranslation()
        await failureQueue.respond(.installed)
        await drain()
        let failedRequest = failureCoordinator.hostRequest!
        _ = failureCoordinator.claimHost(failedRequest)
        failureCoordinator.completeHost(
            .failure(.appleExecutionFailed),
            request: failedRequest
        )
        await failureQueue.respond(.installed)
        await drain()
        expect(
            failureCoordinator.snapshot.phase == .translationFailed,
            "installed package plus execution failure reaches the retryable failure state"
        )
        failureCoordinator.perform(.retryTranslation)
        expect(
            failureCoordinator.snapshot.phase == .translating(extendedWait: false),
            "failure retry starts a fresh translation generation"
        )
        expect(
            failureCoordinator.hostRequest == nil,
            "failure retry also repeats installed preflight before host work"
        )
        await failureQueue.respond(.installed)
        await drain()
        expect(
            failureCoordinator.hostRequest?.intent == .translate,
            "failure retry reaches the host only after the fresh preflight"
        )
    }

    private static func testPreparationFlowAndThirtySecondHint() async {
        let queue = AvailabilityQueue()
        let scheduler = ManualScheduler()
        let coordinator = makeCoordinator(queue: queue, scheduler: scheduler, announcements: AnnouncementRecorder())
        coordinator.open()
        await queue.respond(.supportedNeedsPreparation)
        await drain()
        expect(coordinator.hostRequest == nil, "supported status alone never prepares")
        coordinator.recheckAvailability()
        await queue.respond(.supportedNeedsPreparation)
        await drain()
        coordinator.beginPreparation()
        guard let request = coordinator.hostRequest else { fatalError("explicit CTA must issue prepare host request") }
        let claim = coordinator.claimHost(request)
        expect(claim?.intent == .prepare, "prepare host intent is exact")
        expect(claim?.sourceText == nil, "prepare claim carries no source text")
        scheduler.advance(by: 29.999)
        expect(coordinator.snapshot.phase == .preparing(extendedWait: false), "prepare has no progress claim before 30 seconds")
        scheduler.advance(by: 0.001)
        expect(coordinator.snapshot.phase == .preparing(extendedWait: true), "30 seconds only extends the waiting hint")
        scheduler.advance(by: 300)
        expect(coordinator.snapshot.phase == .preparing(extendedWait: true), "prepare has no fabricated hard timeout")
        coordinator.completeHost(.prepared, request: request)
        expect(coordinator.hostRequest == nil, "prepare completion releases host configuration")
        await queue.respond(.installed)
        await drain()
        expect(coordinator.snapshot.phase == .ready, "installed recheck returns to ready")
        expect(coordinator.snapshot.outcome == nil, "preparation never auto-translates")

        coordinator.recheckAvailability()
        await queue.respond(.supportedNeedsPreparation)
        await drain()
        coordinator.beginPreparation()
        let cancelledRequest = coordinator.hostRequest!
        _ = coordinator.claimHost(cancelledRequest)
        coordinator.perform(.cancelOperation)
        expect(
            coordinator.snapshot.phase == .preparationWaitStopped,
            "stopping a wait uses the honest system-download-may-continue state"
        )
        coordinator.completeHost(.prepared, request: cancelledRequest)
        expect(
            coordinator.snapshot.phase == .preparationWaitStopped,
            "late prepare completion cannot overwrite the stopped-wait generation"
        )
    }

    private static func testPreparationFailureRechecks() async {
        let queue = AvailabilityQueue()
        let coordinator = makeCoordinator(
            queue: queue,
            scheduler: ManualScheduler(),
            announcements: AnnouncementRecorder()
        )
        coordinator.open()
        await queue.respond(.supportedNeedsPreparation)
        await drain()
        coordinator.beginPreparation()
        let request = coordinator.hostRequest!
        _ = coordinator.claimHost(request)
        coordinator.completeHost(.failure(.appleExecutionFailed), request: request)
        await queue.respond(.supportedNeedsPreparation)
        await drain()
        expect(coordinator.snapshot.phase == .preparationFailed, "failed prepare rechecks and stays actionable")
        expect(
            coordinator.snapshot.outcome == .failure(.appleNeedsPreparation),
            "post-prepare supported state is typed without raw errors"
        )
        expect(!String(reflecting: coordinator.snapshot.outcome).contains("localized"), "failure carries no raw error")
    }

    private static func testCancellationAndExternalInvalidation() async {
        let invalidations: [NativeAppleTranslationAdapterInvalidationReason] = [
            .pause, .stop, .engineChanged, .terminate,
        ]
        for reason in invalidations {
            let queue = AvailabilityQueue()
            let scheduler = ManualScheduler()
            let coordinator = makeCoordinator(
                queue: queue,
                scheduler: scheduler,
                announcements: AnnouncementRecorder()
            )
            coordinator.open()
            await queue.respond(.installed)
            await drain()
            coordinator.beginTranslation()
            await queue.respond(.installed)
            await drain()
            let request = coordinator.hostRequest!
            _ = coordinator.claimHost(request)
            coordinator.invalidate(reason)
            expect(!coordinator.isPresented, "external invalidation closes the development sheet")
            expect(coordinator.snapshot.phase == .hidden, "external invalidation hides state")
            expect(coordinator.fixtureSourceText == nil, "external invalidation clears fixture")
            expect(coordinator.hostRequest == nil, "external invalidation clears configuration claim")
            coordinator.completeHost(.translated("secret-target"), request: request)
            expect(coordinator.snapshot.targetText == nil, "late target after invalidation is discarded")
        }

        let queue = AvailabilityQueue()
        let coordinator = makeCoordinator(
            queue: queue,
            scheduler: ManualScheduler(),
            announcements: AnnouncementRecorder()
        )
        coordinator.open()
        await queue.respond(.installed)
        await drain()
        coordinator.beginTranslation()
        await queue.respond(.installed)
        await drain()
        coordinator.handleEscape()
        expect(coordinator.isPresented, "Escape while busy cancels without closing the sheet")
        expect(coordinator.snapshot.phase == .ready, "busy cancellation is silent and returns to ready")
        expect(coordinator.snapshot.outcome == nil, "cancelled operation has no body or error outcome")
        coordinator.handleEscape()
        expect(!coordinator.isPresented, "Escape while idle closes the sheet")
    }

    private static func testNewGenerationSupersedesOldAvailability() async {
        let queue = AvailabilityQueue()
        let coordinator = makeCoordinator(
            queue: queue,
            scheduler: ManualScheduler(),
            announcements: AnnouncementRecorder()
        )
        coordinator.open()
        let firstGeneration = coordinator.snapshot.generation
        coordinator.open()
        let secondGeneration = coordinator.snapshot.generation
        expect(secondGeneration > firstGeneration, "new open advances the one authoritative generation")
        await queue.respond(.unsupported)
        await drain()
        expect(coordinator.snapshot.generation == secondGeneration, "cancelled old query cannot change generation")
        expect(coordinator.snapshot.phase == .checking, "old availability result cannot publish")
        await queue.respond(.installed)
        await drain()
        expect(coordinator.snapshot.phase == .ready, "current generation publishes normally")
    }
}

@MainActor
private final class AnnouncementRecorder {
    var messages: [String] = []
}
#endif
