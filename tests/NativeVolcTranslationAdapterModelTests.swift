#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER
import Foundation

@MainActor
private final class NativeVolcManualScheduledTask: NativeVolcAdapterScheduledTask {
    var isCancelled = false
    func cancel() { isCancelled = true }
}

@MainActor
private final class NativeVolcManualScheduler: NativeVolcAdapterScheduling {
    private struct Entry {
        let deadline: TimeInterval
        let task: NativeVolcManualScheduledTask
        let action: @MainActor () -> Void
    }
    private var now: TimeInterval = 0
    private var entries: [Entry] = []

    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> any NativeVolcAdapterScheduledTask {
        let task = NativeVolcManualScheduledTask()
        entries.append(Entry(deadline: now + delay, task: task, action: action))
        return task
    }

    func advance(to value: TimeInterval) {
        now = value
        while let index = entries.indices
            .filter({ entries[$0].deadline <= now && !entries[$0].task.isCancelled })
            .min(by: { entries[$0].deadline < entries[$1].deadline })
        {
            let entry = entries.remove(at: index)
            if !entry.task.isCancelled { entry.action() }
        }
    }
}

private actor NativeVolcModelFakeWorkflow {
    enum Invocation: Equatable {
        case inspect
        case save(String, String)
        case validatePending
        case discardPending
        case validateActive
        case testFixture
        case recover
        case remove(Bool)
        case cancel
    }

    private var invocations: [Invocation] = []
    private var waiting: [CheckedContinuation<NativeVolcDebugWorkflowResult, Never>] = []

    var client: NativeVolcTranslationWorkflowClient {
        NativeVolcTranslationWorkflowClient(
            inspect: { await self.call(.inspect) },
            saveAndValidate: { await self.call(.save($0, $1)) },
            validatePending: { await self.call(.validatePending) },
            discardPending: { await self.call(.discardPending) },
            validateActive: { await self.call(.validateActive) },
            testFixture: { await self.call(.testFixture) },
            recoverPromotion: { await self.call(.recover) },
            remove: { await self.call(.remove($0)) },
            cancelNetwork: { await self.recordCancel() }
        )
    }

    func snapshot() -> [Invocation] { invocations }

    func respond(_ result: NativeVolcDebugWorkflowResult) {
        guard !waiting.isEmpty else { fatalError("no pending workflow call") }
        waiting.removeFirst().resume(returning: result)
    }

    private func call(_ invocation: Invocation) async -> NativeVolcDebugWorkflowResult {
        invocations.append(invocation)
        return await withCheckedContinuation { waiting.append($0) }
    }

    private func recordCancel() { invocations.append(.cancel) }
}

@main
@MainActor
enum NativeVolcTranslationAdapterModelTests {
    private static var passed = 0

    static func main() async {
        testPresentationsAndActions()
        await testOpenIsZeroIOAndCheckMapsState()
        await testSaveClearsSecretsAndPublishesOnlyTypedResult()
        await testManualClockSlowAndTimeout()
        await testRevokedResultMapsToStatusUnconfirmed()
        await testEveryNetworkStopDisclosesPossibleUsage()
        await testSleepInvalidationDropsLateSuccess()
        await testCloseAndLateGenerationAreSilent()
        await testPendingActionsAndInvalidCredential()
        print("NativeVolcTranslationAdapterModelTests: \(passed) passed")
    }

    private static func expect(
        _ condition: Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard condition else { fatalError("\(message) (\(file):\(line))") }
        passed += 1
    }

    private static func testPresentationsAndActions() {
        let disclosure = NativeVolcTranslationAdapterPresentation.make(for: .disclosure)
        expect(disclosure.title == "火山云端翻译开发测试", "disclosure is explicit Debug UI")
        expect(disclosure.actions.map(\.action) == [.checkConfiguration], "opening has one check CTA")
        let pending = NativeVolcTranslationAdapterPresentation.make(for: .pendingReady)
        expect(pending.actions.map(\.action) == [.validatePending, .discardPending],
               "pending supports explicit paid retry or candidate-only discard")
        expect(pending.message.contains("可能产生少量用量或费用"), "pending retry discloses cost")
        let busy: [NativeVolcTranslationAdapterPhase] = [
            .checkingInterlock, .checkingKeychain, .savingPending, .validatingPending,
            .promoting, .connecting, .slow, .removing,
        ]
        for phase in busy {
            expect(NativeVolcTranslationAdapterPresentation.make(for: phase).actions.map(\.action)
                == [.stopWaiting], "every busy phase exposes only Stop Waiting")
        }
        let stopped = NativeVolcTranslationAdapterPresentation.make(
            for: .stopped(pendingRetained: false)
        )
        expect(stopped.message == "已停止等待。验证请求可能已经发送，并可能产生少量用量或费用；不会保存或启用这次更改。",
               "confirmed cleanup uses exact stopped disclosure")
        let retained = NativeVolcTranslationAdapterPresentation.make(
            for: .stopped(pendingRetained: true)
        )
        expect(retained.message.contains("仍保存在 Debug 钥匙串"),
               "uncertain cleanup never claims unsaved")
    }

    private static func testOpenIsZeroIOAndCheckMapsState() async {
        let fake = NativeVolcModelFakeWorkflow()
        let scheduler = NativeVolcManualScheduler()
        var announcements: [String] = []
        let coordinator = NativeVolcTranslationAdapterCoordinator(
            workflow: await fake.client,
            scheduler: scheduler,
            announce: { announcements.append($0) }
        )
        coordinator.open()
        expect(coordinator.isPresented && coordinator.snapshot.phase == .disclosure,
               "open presents disclosure only")
        expect(await fake.snapshot().isEmpty, "open performs zero Keychain/file/network workflow")
        expect(announcements.isEmpty, "disclosure does not announce a terminal result")

        coordinator.perform(.checkConfiguration)
        await waitFor(fake, .inspect)
        expect(coordinator.snapshot.phase == .checkingInterlock, "check begins at interlock")
        scheduler.advance(to: 0.12)
        expect(coordinator.snapshot.phase == .checkingKeychain, "manual clock advances to Keychain")
        await fake.respond(.configuration(.ready))
        await settle()
        expect(coordinator.snapshot.phase == .ready, "typed ready maps to ready UI")
        expect(announcements.count == 1 && !announcements[0].contains("Good tools"),
               "terminal announcement occurs once without fixture text")
    }

    private static func testSaveClearsSecretsAndPublishesOnlyTypedResult() async {
        let fake = NativeVolcModelFakeWorkflow()
        let coordinator = NativeVolcTranslationAdapterCoordinator(workflow: await fake.client)
        coordinator.open()
        coordinator.perform(.checkConfiguration)
        await waitFor(fake, .inspect)
        await fake.respond(.configuration(.missing))
        await settle()
        coordinator.accessKey = "AKTEST"
        coordinator.secretKey = "SKTEST"
        coordinator.perform(.saveAndValidate)
        await waitFor(fake, .save("AKTEST", "SKTEST"))
        expect(coordinator.accessKey.isEmpty && coordinator.secretKey.isEmpty,
               "new generation immediately clears AK/SK form memory")
        await fake.respond(.translated("固定译文", savedCandidate: true))
        await settle()
        expect(coordinator.snapshot == NativeVolcTranslationAdapterSnapshot(
            generation: coordinator.snapshot.generation,
            phase: .success(savedCandidate: true),
            targetText: "固定译文"
        ), "only typed success retains target in current sheet generation")
        coordinator.close()
        expect(coordinator.snapshot == .hidden && coordinator.accessKey.isEmpty
            && coordinator.secretKey.isEmpty, "close clears all sheet-only content")
    }

    private static func testManualClockSlowAndTimeout() async {
        let fake = NativeVolcModelFakeWorkflow()
        let scheduler = NativeVolcManualScheduler()
        let coordinator = NativeVolcTranslationAdapterCoordinator(
            workflow: await fake.client, scheduler: scheduler
        )
        coordinator.open()
        coordinator.perform(.testFixture)
        await settle()
        expect(await fake.snapshot().isEmpty,
               "disclosure rejects direct billable test action")
        coordinator.perform(.checkConfiguration)
        await waitFor(fake, .inspect)
        await fake.respond(.configuration(.ready))
        await settle()
        coordinator.perform(.testFixture)
        await waitFor(fake, .testFixture)
        scheduler.advance(to: 1.999)
        expect(coordinator.snapshot.phase == .connecting, "slow hint not before 2 seconds")
        scheduler.advance(to: 2)
        expect(coordinator.snapshot.phase == .slow, "slow hint starts at 2 seconds")
        scheduler.advance(to: 11.999)
        expect(coordinator.snapshot.phase == .slow, "timeout not before 12 seconds")
        scheduler.advance(to: 12)
        await waitFor(fake, .cancel)
        await fake.respond(.failure(.cancelled))
        await settle()
        expect(coordinator.snapshot.phase == .timeout, "12 second generation timeout is typed")
        let timeoutCopy = coordinator.presentation.message
        expect(timeoutCopy.contains("请求可能已经发送")
            && timeoutCopy.contains("少量用量或费用")
            && timeoutCopy.contains("迟到译文不会显示或保存"),
               "timeout always discloses possible send, cost, and discarded late text")
    }

    private static func testRevokedResultMapsToStatusUnconfirmed() async {
        let fake = NativeVolcModelFakeWorkflow()
        let coordinator = NativeVolcTranslationAdapterCoordinator(workflow: await fake.client)
        coordinator.open()
        coordinator.perform(.checkConfiguration)
        await waitFor(fake, .inspect)
        await fake.respond(.configuration(.ready))
        await settle()
        coordinator.perform(.testFixture)
        await waitFor(fake, .testFixture)
        await fake.respond(.failure(.revoked))
        await settle()
        expect(coordinator.snapshot.phase == .networkStatusUnconfirmed,
               "a completed cross-process revocation never masquerades as active removal")
        expect(coordinator.snapshot.targetText == nil,
               "a revoked epoch publishes no stale translation")
        expect(coordinator.presentation.message.contains("请求可能已经发送")
            && coordinator.presentation.message.contains("少量用量或费用")
            && coordinator.presentation.message.contains("迟到译文不会显示或保存")
            && coordinator.presentation.message.contains("配置状态尚未确认"),
               "revoked state keeps the complete network uncertainty disclosure")
        expect(await fake.snapshot().filter({ $0 == .testFixture }).count == 1,
               "revoked results never retry the paid request automatically")
        expect(coordinator.presentation.actions.map(\.action) == [.checkConfiguration],
               "revoked state requires an explicit fresh configuration check")
    }

    private static func testEveryNetworkStopDisclosesPossibleUsage() async {
        let cases: [(NativeVolcDebugConfigurationState,
                     NativeVolcTranslationAdapterAction,
                     NativeVolcModelFakeWorkflow.Invocation)] = [
            (.missing, .saveAndValidate, .save("AKTEST", "SKTEST")),
            (.pendingReady, .validatePending, .validatePending),
            (.activeNeedsVerification, .validateActive, .validateActive),
            (.ready, .testFixture, .testFixture),
        ]
        for (state, action, invocation) in cases {
            for result in [
                NativeVolcDebugWorkflowResult.failure(.cancelled),
                .translated("不应显示的迟到译文", savedCandidate: true),
            ] {
            let fake = NativeVolcModelFakeWorkflow()
            let coordinator = NativeVolcTranslationAdapterCoordinator(workflow: await fake.client)
            coordinator.open()
            coordinator.perform(.checkConfiguration)
            await waitFor(fake, .inspect)
            await fake.respond(.configuration(state))
            await settle()
            if action == .saveAndValidate {
                coordinator.accessKey = "AKTEST"
                coordinator.secretKey = "SKTEST"
            }
            coordinator.perform(action)
            await waitFor(fake, invocation)
            coordinator.perform(.stopWaiting)
            await waitFor(fake, .cancel)
            await fake.respond(result)
            await settle()
            expect(coordinator.snapshot.phase == .networkStatusUnconfirmed,
                   "every network operation maps cancellation to network uncertainty")
            let message = coordinator.presentation.message
            expect(message.contains("请求可能已经发送")
                && message.contains("少量用量或费用")
                && message.contains("迟到译文不会显示或保存")
                && message.contains("配置状态尚未确认"),
                   "every network stop has the complete cost/privacy disclosure")
            expect(coordinator.snapshot.targetText == nil,
                   "network stop drops every late target regardless of workflow race result")
            }
        }
    }

    private static func testSleepInvalidationDropsLateSuccess() async {
        let fake = NativeVolcModelFakeWorkflow()
        let coordinator = NativeVolcTranslationAdapterCoordinator(workflow: await fake.client)
        coordinator.open()
        coordinator.perform(.checkConfiguration)
        await waitFor(fake, .inspect)
        await fake.respond(.configuration(.ready))
        await settle()
        coordinator.perform(.testFixture)
        await waitFor(fake, .testFixture)
        coordinator.invalidate(.sleep)
        await waitFor(fake, .cancel)
        await fake.respond(.translated("休眠后的迟到译文", savedCandidate: false))
        await settle()
        expect(coordinator.snapshot.phase == .networkStatusUnconfirmed,
               "sleep invalidation never republishes a late success")
        expect(coordinator.snapshot.targetText == nil,
               "sleep invalidation clears late translation text")
    }

    private static func testCloseAndLateGenerationAreSilent() async {
        let fake = NativeVolcModelFakeWorkflow()
        var announcements: [String] = []
        let coordinator = NativeVolcTranslationAdapterCoordinator(
            workflow: await fake.client,
            announce: { announcements.append($0) }
        )
        coordinator.open()
        coordinator.perform(.checkConfiguration)
        await waitFor(fake, .inspect)
        coordinator.close()
        await fake.respond(.configuration(.ready))
        await settle()
        expect(!coordinator.isPresented && coordinator.snapshot == .hidden,
               "late result cannot reopen a closed sheet")
        expect(announcements.isEmpty, "late closed generation has zero announcement")
    }

    private static func testPendingActionsAndInvalidCredential() async {
        let fake = NativeVolcModelFakeWorkflow()
        let coordinator = NativeVolcTranslationAdapterCoordinator(workflow: await fake.client)
        coordinator.open()
        coordinator.perform(.saveAndValidate)
        expect(await fake.snapshot().isEmpty,
               "disclosure rejects save before explicit configuration check")
        coordinator.perform(.checkConfiguration)
        await waitFor(fake, .inspect)
        await fake.respond(.configuration(.missing))
        await settle()
        coordinator.accessKey = "bad key"
        coordinator.secretKey = "bad\nsecret"
        coordinator.perform(.saveAndValidate)
        expect(coordinator.snapshot.phase == .credentialError, "invalid form fails locally")
        expect(await fake.snapshot() == [.inspect], "invalid form performs zero additional IO")

        coordinator.perform(.validatePending)
        await settle()
        expect(await fake.snapshot() == [.inspect],
               "credential-error state rejects stale pending action")
        coordinator.open()
        coordinator.perform(.checkConfiguration)
        await waitFor(fake, .inspect, count: 2)
        await fake.respond(.configuration(.pendingReady))
        await settle()
        coordinator.perform(.validatePending)
        await waitFor(fake, .validatePending)
        await fake.respond(.stopped(pendingRetained: true))
        await settle()
        expect(coordinator.snapshot.phase == .stopped(pendingRetained: true),
               "retained pending survives typed result mapping")

        coordinator.perform(.checkConfiguration)
        await waitFor(fake, .inspect, count: 3)
        await fake.respond(.configuration(.pendingReady))
        await settle()
        coordinator.perform(.discardPending)
        await waitFor(fake, .discardPending)
        await fake.respond(.configuration(.ready))
        await settle()
        expect(coordinator.snapshot.phase == .ready, "candidate-only discard returns prior ready")
    }

    private static func waitFor(
        _ fake: NativeVolcModelFakeWorkflow,
        _ invocation: NativeVolcModelFakeWorkflow.Invocation,
        count: Int = 1
    ) async {
        while await fake.snapshot().filter({ $0 == invocation }).count < count {
            await Task.yield()
        }
    }

    private static func settle() async {
        for _ in 0..<20 { await Task.yield() }
    }
}
#endif
