#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER
import Darwin
import Foundation

private final class NativeVolcWorkflowFakeSecItems: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private(set) var calls: [String] = []
    private var failNextWriteAccount: String?
    private var failDeleteAccount: String?
    private var unavailableReadAccount: String?

    var client: NativeVolcSecItemClient {
        NativeVolcSecItemClient(
            read: { [weak self] service, account in self?.read(service, account) ?? .unavailable },
            write: { [weak self] service, account, data in
                self?.write(service, account, data) ?? false
            },
            delete: { [weak self] service, account in self?.delete(service, account) ?? false }
        )
    }

    func resetCalls() { lock.withLock { calls.removeAll() } }
    var callCount: Int { lock.withLock { calls.count } }
    var callSnapshot: [String] { lock.withLock { calls } }
    func failNextWrite(to account: String) {
        lock.withLock { failNextWriteAccount = account }
    }
    func failDeletes(of account: String?) {
        lock.withLock { failDeleteAccount = account }
    }
    func failReads(of account: String?) {
        lock.withLock { unavailableReadAccount = account }
    }

    private func read(_ service: String, _ account: String) -> NativeVolcRawItemRead {
        lock.withLock {
            calls.append("read:\(service):\(account)")
            if unavailableReadAccount == account { return .unavailable }
            guard let data = items[key(service, account)] else { return .notFound }
            return .found(data)
        }
    }

    private func write(_ service: String, _ account: String, _ data: Data) -> Bool {
        lock.withLock {
            calls.append("write:\(service):\(account)")
            if failNextWriteAccount == account {
                failNextWriteAccount = nil
                return false
            }
            items[key(service, account)] = data
            return true
        }
    }

    private func delete(_ service: String, _ account: String) -> Bool {
        lock.withLock {
            calls.append("delete:\(service):\(account)")
            if failDeleteAccount == account { return false }
            items.removeValue(forKey: key(service, account))
            return true
        }
    }

    private func key(_ service: String, _ account: String) -> String {
        "\(service)\u{0}\(account)"
    }
}

private final class NativeVolcWorkflowFakeTransport: @unchecked Sendable {
    enum Mode { case success, status(Int), holdUntilCancelled }
    private let lock = NSLock()
    private var mode: Mode = .success
    private var requests: [VolcV4SignedRequest] = []

    var client: NativeVolcDebugTransportClient {
        NativeVolcDebugTransportClient { [weak self] request, lease in
            guard let self else {
                lease.releaseGate()
                lease.releaseTransport()
                return .failure(.cancelled)
            }
            let mode = self.record(request)
            lease.releaseGate()
            switch mode {
            case .holdUntilCancelled:
                while !Task.isCancelled { await Task.yield() }
                lease.releaseTransport()
                return .failure(.cancelled)
            case let .status(status):
                lease.releaseTransport()
                return .response(statusCode: status, data: Data("{}".utf8))
            case .success:
                lease.releaseTransport()
                let body = Data(
                    #"{"TranslationList":[{"Translation":"好工具应该让人感觉毫不费力。"}]}"#.utf8
                )
                return .response(statusCode: 200, data: body)
            }
        }
    }

    func setMode(_ mode: Mode) { lock.withLock { self.mode = mode } }
    var callCount: Int { lock.withLock { requests.count } }
    var lastRequest: VolcV4SignedRequest? { lock.withLock { requests.last } }

    private func record(_ request: VolcV4SignedRequest) -> Mode {
        lock.withLock {
            requests.append(request)
            return mode
        }
    }
}

private actor NativeVolcWorkflowHookGate {
    private var entered = false
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        entered = true
        await withCheckedContinuation { continuation = $0 }
    }

    func waitUntilEntered() async {
        while !entered { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

private struct NativeVolcWorkflowFixture {
    let base: String
    let interlock: NativeVolcDebugInterlock
    let keychain: NativeVolcWorkflowFakeSecItems
    let store: NativeVolcDebugCredentialStore
    let transport: NativeVolcWorkflowFakeTransport
    let workflow: NativeVolcDebugWorkflow

    init(hooks: NativeVolcDebugWorkflowHooks = .none) {
        var template = Array("/private/tmp/juyi-volc-workflow.XXXXXX".utf8CString)
        base = template.withUnsafeMutableBufferPointer { buffer in
            guard let path = mkdtemp(buffer.baseAddress) else { fatalError("mkdtemp failed") }
            return String(cString: path)
        }
        interlock = NativeVolcDebugInterlock(rootPath: base + "/NativeVolcDebug")
        keychain = NativeVolcWorkflowFakeSecItems()
        store = NativeVolcDebugCredentialStore(client: keychain.client)
        transport = NativeVolcWorkflowFakeTransport()
        workflow = NativeVolcDebugWorkflow(
            interlock: interlock,
            store: store,
            transport: transport.client,
            wallClock: NativeVolcDebugWallClock {
                Date(timeIntervalSince1970: 1_767_323_045)
            },
            hooks: hooks
        )
    }

    func cleanup() { try? FileManager.default.removeItem(atPath: base) }
}

@main
@MainActor
enum NativeVolcDebugWorkflowTests {
    private static var passed = 0

    static func main() async {
        await testSavePromoteAndNoCache()
        await testBlockedInterlockDoesZeroKeychainAndNetwork()
        await testInspectionLeaseBlocksWriterAndZeroReadsAfterIntent()
        await testRemovalRevokesVerifiedResultBeforePublish()
        await testVerifiedPostflightFailureTyping()
        await testFailureAndCancellationCleanPending()
        await testPendingReadyContinueAndDiscard()
        await testSingleFlightAndRollbackTruthfulness()
        await testRemovalAndCrashResume()
        await testJournalRollForwardWithoutNetwork()
        await testDurableRollbackCrashPhases()
        await testCancellationBeforeTransportStarts()
        await testRemovalRevokesStaleSave()
        testRedaction()
        print("NativeVolcDebugWorkflowTests: \(passed) passed")
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

    private static func testSavePromoteAndNoCache() async {
        let fixture = NativeVolcWorkflowFixture()
        defer { fixture.cleanup() }
        expect(await fixture.workflow.inspect() == .configuration(.missing),
               "explicit inspection reports missing")
        expect(fixture.transport.callCount == 0, "inspection never sends the fixture")

        let result = await fixture.workflow.saveAndValidate(
            accessKey: "AKTEST", secretKey: "SKTEST"
        )
        expect(
            result == .translated("好工具应该让人感觉毫不费力。", savedCandidate: true),
            "one successful fixture atomically saves the candidate"
        )
        expect(fixture.transport.callCount == 1, "candidate validation sends exactly once")
        expect(await fixture.workflow.inspect() == .configuration(.ready),
               "active fingerprint/profile are ready")
        expect(await fixture.store.readCredentials(.pending) == .notFound,
               "promotion removes pending")
        expect(await fixture.store.readJournal() == .notFound, "promotion removes journal")

        let testA = await fixture.workflow.testActive()
        let testB = await fixture.workflow.testActive()
        expect(testA == .translated("好工具应该让人感觉毫不费力。", savedCandidate: false),
               "ready active test succeeds")
        expect(testB == testA, "same input has same typed result")
        expect(fixture.transport.callCount == 3, "same input executes every time; no cache")
        let expectedBody = try! VolcV4RequestBuilder.deterministicBody(
            text: NativeVolcDebugFixture.sourceText,
            sourceLanguage: "en",
            targetLanguage: "zh"
        )
        expect(fixture.transport.lastRequest?.body == expectedBody,
               "workflow signs only the fixed sample")
    }

    private static func testBlockedInterlockDoesZeroKeychainAndNetwork() async {
        let fixture = NativeVolcWorkflowFixture()
        defer { fixture.cleanup() }
        _ = await fixture.interlock.inspectWithoutCredentials()
        guard case let .acquired(writer) = await fixture.interlock.beginWriterPhaseA() else {
            fatalError("writer setup")
        }
        writer.release()
        fixture.keychain.resetCalls()
        expect(await fixture.workflow.inspect() == .configuration(.removalBlocked),
               "durable removal state is visible")
        expect(fixture.keychain.callCount == 0, "blocked inspect performs zero Keychain calls")
        expect(await fixture.workflow.testActive() == .failure(.removalBlocked),
               "blocked request fails before credential load")
        expect(fixture.keychain.callCount == 0 && fixture.transport.callCount == 0,
               "intent or marker guarantees zero Keychain and zero network")
    }

    private static func testInspectionLeaseBlocksWriterAndZeroReadsAfterIntent() async {
        let gate = NativeVolcWorkflowHookGate()
        let fixture = NativeVolcWorkflowFixture(
            hooks: NativeVolcDebugWorkflowHooks(
                beforeInspectionKeychain: { await gate.wait() }
            )
        )
        defer { fixture.cleanup() }
        let active = NativeVolcDebugCredentials(
            accessKey: "ACTIVE", secretKey: "ACTIVESECRET"
        )!
        expect(await fixture.store.writeCredentials(active, to: .active),
               "inspection race fixture stores active credentials")
        expect(await fixture.store.writeVerified(
            NativeVolcDebugVerifiedRecord(fingerprint: active.fingerprint)!
        ), "inspection race fixture stores verification")
        fixture.keychain.resetCalls()

        let inspection = Task { await fixture.workflow.inspect() }
        await gate.waitUntilEntered()
        let remover = NativeVolcDebugWorkflow(
            interlock: fixture.interlock,
            store: fixture.store,
            transport: fixture.transport.client,
            wallClock: NativeVolcDebugWallClock {
                Date(timeIntervalSince1970: 1_767_323_045)
            }
        )
        let removal = Task { await remover.remove() }
        while await fixture.interlock.inspectWithoutCredentials() != .present {
            await Task.yield()
        }
        expect(fixture.keychain.callCount == 0,
               "writer intent commits before inspection performs any Keychain read")
        await gate.release()
        expect(await inspection.value == .configuration(.removalBlocked),
               "inspection revalidation maps the committed writer intent to blocked")
        expect(await removal.value == .removed,
               "writer waits for the inspection lease, then completes removal")
        expect(fixture.keychain.callSnapshot.first?.contains(":verified") == true,
               "only the authorized remover touches Keychain, verified slot first")
        expect(fixture.transport.callCount == 0,
               "inspection/removal race never sends the fixed fixture")
    }

    private static func testRemovalRevokesVerifiedResultBeforePublish() async {
        let gate = NativeVolcWorkflowHookGate()
        let fixture = NativeVolcWorkflowFixture(
            hooks: NativeVolcDebugWorkflowHooks(
                afterVerifiedTransport: { await gate.wait() }
            )
        )
        defer { fixture.cleanup() }
        let active = NativeVolcDebugCredentials(
            accessKey: "ACTIVE", secretKey: "ACTIVESECRET"
        )!
        expect(await fixture.store.writeCredentials(active, to: .active),
               "post-transport race fixture stores active credentials")
        expect(await fixture.store.writeVerified(
            NativeVolcDebugVerifiedRecord(fingerprint: active.fingerprint)!
        ), "post-transport race fixture stores verification")

        let request = Task { await fixture.workflow.testActive() }
        await gate.waitUntilEntered()
        let remover = NativeVolcDebugWorkflow(
            interlock: fixture.interlock,
            store: fixture.store,
            transport: fixture.transport.client,
            wallClock: NativeVolcDebugWallClock {
                Date(timeIntervalSince1970: 1_767_323_045)
            }
        )
        expect(await remover.remove() == .removed,
               "cross-process-equivalent removal completes before result publication")
        fixture.keychain.resetCalls()
        await gate.release()
        expect(await request.value == .failure(.revoked),
               "a response from the revoked epoch is never published as success")
        expect(fixture.keychain.callCount == 0,
               "epoch revocation blocks the stale response before any Keychain reread")
        expect(fixture.transport.callCount == 1,
               "the completed fixed request is not retried after revocation")
        expect(await fixture.store.readCredentials(.active) == .notFound,
               "post-transport revalidation cannot revive removed credentials")
    }

    private static func testVerifiedPostflightFailureTyping() async {
        let mismatchGate = NativeVolcWorkflowHookGate()
        let mismatch = NativeVolcWorkflowFixture(
            hooks: NativeVolcDebugWorkflowHooks(
                afterVerifiedTransport: { await mismatchGate.wait() }
            )
        )
        defer { mismatch.cleanup() }
        let active = NativeVolcDebugCredentials(
            accessKey: "ACTIVE", secretKey: "ACTIVESECRET"
        )!
        expect(await mismatch.store.writeCredentials(active, to: .active),
               "postflight typing fixture stores active credentials")
        expect(await mismatch.store.writeVerified(
            NativeVolcDebugVerifiedRecord(fingerprint: active.fingerprint)!
        ), "postflight typing fixture stores verification")
        let mismatchedRequest = Task { await mismatch.workflow.testActive() }
        await mismatchGate.waitUntilEntered()
        expect(await mismatch.store.delete(.active),
               "postflight typing fixture removes active without a removal transaction")
        await mismatchGate.release()
        expect(await mismatchedRequest.value == .failure(.credential),
               "credential drift is not mislabeled as an active removal")

        let journalGate = NativeVolcWorkflowHookGate()
        let journalFixture = NativeVolcWorkflowFixture(
            hooks: NativeVolcDebugWorkflowHooks(
                afterVerifiedTransport: { await journalGate.wait() }
            )
        )
        defer { journalFixture.cleanup() }
        expect(await journalFixture.store.writeCredentials(active, to: .active),
               "journal typing fixture stores active credentials")
        expect(await journalFixture.store.writeVerified(
            NativeVolcDebugVerifiedRecord(fingerprint: active.fingerprint)!
        ), "journal typing fixture stores verification")
        let journalRequest = Task { await journalFixture.workflow.testActive() }
        await journalGate.waitUntilEntered()
        let journal = NativeVolcPromotionJournal(
            identifier: UUID().uuidString,
            phase: .validated,
            candidateFingerprint: active.fingerprint,
            oldActive: nil,
            oldVerified: nil
        )!
        expect(await journalFixture.store.writeJournal(journal),
               "postflight typing fixture introduces a valid recovery journal")
        await journalGate.release()
        expect(await journalRequest.value == .failure(.pendingRecovery),
               "journal drift is typed as recovery, not removal")

        let unavailableGate = NativeVolcWorkflowHookGate()
        let unavailable = NativeVolcWorkflowFixture(
            hooks: NativeVolcDebugWorkflowHooks(
                afterVerifiedTransport: { await unavailableGate.wait() }
            )
        )
        defer { unavailable.cleanup() }
        expect(await unavailable.store.writeCredentials(active, to: .active),
               "unavailable typing fixture stores active credentials")
        expect(await unavailable.store.writeVerified(
            NativeVolcDebugVerifiedRecord(fingerprint: active.fingerprint)!
        ), "unavailable typing fixture stores verification")
        let unavailableRequest = Task { await unavailable.workflow.testActive() }
        await unavailableGate.waitUntilEntered()
        unavailable.keychain.failReads(of: "verified")
        await unavailableGate.release()
        expect(await unavailableRequest.value == .failure(.keychainUnavailable),
               "postflight Keychain unavailability keeps its precise type")
    }

    private static func testFailureAndCancellationCleanPending() async {
        let failureFixture = NativeVolcWorkflowFixture()
        defer { failureFixture.cleanup() }
        failureFixture.transport.setMode(.status(403))
        expect(
            await failureFixture.workflow.saveAndValidate(
                accessKey: "AKTEST", secretKey: "SKTEST"
            ) == .failure(.credential),
            "403 is a redacted credential failure"
        )
        expect(await failureFixture.store.readCredentials(.pending) == .notFound,
               "failed validation confirms pending cleanup")

        let cancelFixture = NativeVolcWorkflowFixture()
        defer { cancelFixture.cleanup() }
        cancelFixture.transport.setMode(.holdUntilCancelled)
        let operation = Task {
            await cancelFixture.workflow.saveAndValidate(
                accessKey: "AKTEST", secretKey: "SKTEST"
            )
        }
        while cancelFixture.transport.callCount == 0 { await Task.yield() }
        await cancelFixture.workflow.cancelNetwork()
        expect(await operation.value == .stopped(pendingRetained: false),
               "cancel waits for transport completion and confirms cleanup")
        expect(await cancelFixture.store.readCredentials(.pending) == .notFound,
               "cancelled candidate is not silently retained")
    }

    private static func testRemovalAndCrashResume() async {
        let fixture = NativeVolcWorkflowFixture()
        defer { fixture.cleanup() }
        _ = await fixture.workflow.saveAndValidate(accessKey: "AKTEST", secretKey: "SKTEST")
        expect(await fixture.workflow.remove() == .removed, "removal clears all Debug state")
        let deletionAccounts = fixture.keychain.callSnapshot.compactMap { call -> String? in
            guard call.hasPrefix("delete:") else { return nil }
            return call.split(separator: ":").last.map(String.init)
        }
        expect(deletionAccounts.suffix(4) == ["verified", "active", "pending", "promotion"],
               "removal revokes proof before active, pending, then transaction")
        for slot in NativeVolcDebugKeychainSlot.allCases {
            switch slot {
            case .active, .pending:
                expect(await fixture.store.readCredentials(slot) == .notFound,
                       "credential slot removed")
            case .verified:
                expect(await fixture.store.readVerified() == .notFound, "verified removed")
            case .transaction:
                expect(await fixture.store.readJournal() == .notFound, "journal removed")
            }
        }
        expect(await fixture.interlock.inspectWithoutCredentials() == .absent,
               "successful removal clears marker and intent")

        let resumed = NativeVolcWorkflowFixture()
        defer { resumed.cleanup() }
        guard case let .acquired(abandoned) = await resumed.interlock.beginWriterPhaseA() else {
            fatalError("create crash fixture")
        }
        abandoned.release()
        expect(await resumed.workflow.remove(resume: true) == .removed,
               "explicit recovery resumes valid durable removal state")
    }

    private static func testPendingReadyContinueAndDiscard() async {
        let fixture = NativeVolcWorkflowFixture()
        defer { fixture.cleanup() }
        let pending = NativeVolcDebugCredentials(accessKey: "PENDING", secretKey: "PENDINGSECRET")!
        expect(await fixture.store.writeCredentials(pending, to: .pending), "seed valid pending")
        expect(await fixture.workflow.inspect() == .configuration(.pendingReady),
               "valid pending without journal has a distinct resumable state")
        expect(
            await fixture.workflow.saveAndValidate(accessKey: "NEWKEY", secretKey: "NEWSECRET")
                == .failure(.pendingReady),
            "new candidate never overwrites an existing pending candidate"
        )
        expect(await fixture.store.readCredentials(.pending) == .found(pending),
               "pending candidate remains byte-for-byte unchanged")
        expect(await fixture.workflow.validatePending()
            == .translated("好工具应该让人感觉毫不费力。", savedCandidate: true),
            "explicit continue performs one new fixture request and promotes")
        expect(fixture.transport.callCount == 1, "continue sends exactly once")

        let discard = NativeVolcWorkflowFixture()
        defer { discard.cleanup() }
        let active = NativeVolcDebugCredentials(accessKey: "ACTIVE", secretKey: "ACTIVESECRET")!
        let verified = NativeVolcDebugVerifiedRecord(fingerprint: active.fingerprint)!
        expect(await discard.store.writeCredentials(active, to: .active), "seed old active")
        expect(await discard.store.writeVerified(verified), "seed old verified")
        expect(await discard.store.writeCredentials(pending, to: .pending), "seed new pending")
        expect(await discard.workflow.discardPending() == .configuration(.ready),
               "discard removes only candidate and restores prior ready state")
        expect(await discard.store.readCredentials(.active) == .found(active),
               "discard never deletes prior active")
        expect(discard.transport.callCount == 0, "discard candidate performs zero network")
    }

    private static func testSingleFlightAndRollbackTruthfulness() async {
        let single = NativeVolcWorkflowFixture()
        defer { single.cleanup() }
        _ = await single.workflow.saveAndValidate(accessKey: "AKTEST", secretKey: "SKTEST")
        single.transport.setMode(.holdUntilCancelled)
        let before = single.transport.callCount
        let first = Task { await single.workflow.testActive() }
        while single.transport.callCount == before { await Task.yield() }
        let second = await single.workflow.testActive()
        expect(second == .failure(.cancelled), "service boundary rejects concurrent operation")
        expect(single.transport.callCount == before + 1, "concurrent click cannot send twice")
        await single.workflow.cancelNetwork()
        expect(await first.value == .failure(.cancelled), "first in-flight request cancels cleanly")

        let rollback = NativeVolcWorkflowFixture()
        defer { rollback.cleanup() }
        let old = NativeVolcDebugCredentials(accessKey: "OLDKEY", secretKey: "OLDSECRET")!
        expect(await rollback.store.writeCredentials(old, to: .active), "seed rollback active")
        expect(await rollback.store.writeVerified(
            NativeVolcDebugVerifiedRecord(fingerprint: old.fingerprint)!
        ), "seed rollback verified")
        rollback.keychain.failNextWrite(to: "verified")
        let result = await rollback.workflow.saveAndValidate(
            accessKey: "NEWKEY", secretKey: "NEWSECRET"
        )
        expect(result == .failure(.keychainUnavailable),
               "safe rollback is never misreported as candidate saved")
        expect(await rollback.store.readCredentials(.active) == .found(old),
               "rollback restores previous active exactly")
        expect(await rollback.store.readCredentials(.pending) == .notFound,
               "successful rollback clears candidate")
        expect(await rollback.store.readJournal() == .notFound,
               "successful rollback clears journal")

        let retained = NativeVolcWorkflowFixture()
        defer { retained.cleanup() }
        retained.transport.setMode(.holdUntilCancelled)
        retained.keychain.failDeletes(of: "pending")
        let operation = Task {
            await retained.workflow.saveAndValidate(accessKey: "AKTEST", secretKey: "SKTEST")
        }
        while retained.transport.callCount == 0 { await Task.yield() }
        await retained.workflow.cancelNetwork()
        expect(await operation.value == .stopped(pendingRetained: true),
               "failed pending cleanup is disclosed, never called unsaved")
        retained.keychain.failDeletes(of: nil)
        expect(await retained.workflow.inspect() == .configuration(.pendingReady),
               "retained valid candidate remains explicitly recoverable")
    }

    private static func testJournalRollForwardWithoutNetwork() async {
        let fixture = NativeVolcWorkflowFixture()
        defer { fixture.cleanup() }
        let candidate = NativeVolcDebugCredentials(accessKey: "AKTEST", secretKey: "SKTEST")!
        expect(await fixture.store.writeCredentials(candidate, to: .pending), "seed pending")
        let journal = NativeVolcPromotionJournal(
            identifier: "4A28DA80-5FA1-4E69-A58D-D2CF901D2F70",
            phase: .validated,
            candidateFingerprint: candidate.fingerprint,
            oldActive: nil,
            oldVerified: nil
        )!
        expect(await fixture.store.writeJournal(journal), "seed validated journal")
        expect(await fixture.workflow.recoverPromotion() == .configuration(.ready),
               "validated journal rolls forward without another request")
        expect(fixture.transport.callCount == 0, "crash recovery performs zero network")
        expect(await fixture.store.readCredentials(.active) == .found(candidate),
               "recovery installs exact journal candidate")
        expect(await fixture.store.readJournal() == .notFound, "recovery clears journal last")

        let blocked = NativeVolcWorkflowFixture()
        defer { blocked.cleanup() }
        expect(await blocked.store.writeCredentials(candidate, to: .pending), "seed blocked pending")
        expect(await blocked.store.writeJournal(journal), "seed blocked validated journal")
        expect(await blocked.workflow.validatePending() == .failure(.pendingRecovery),
               "journal routes to zero-network recovery, never revalidation")
        expect(blocked.transport.callCount == 0,
               "validated journal cannot cause a second billable request")
    }

    private static func testDurableRollbackCrashPhases() async {
        let phases: [NativeVolcPromotionPhase] = [
            .rollbackRequested,
            .rollbackActiveRestored,
            .rollbackVerifiedRestored,
            .rollbackPendingRemoved,
        ]
        for phase in phases {
            let fixture = NativeVolcWorkflowFixture()
            defer { fixture.cleanup() }
            let old = NativeVolcDebugCredentials(accessKey: "OLDKEY", secretKey: "OLDSECRET")!
            let candidate = NativeVolcDebugCredentials(
                accessKey: "NEWKEY", secretKey: "NEWSECRET"
            )!
            let oldVerified = NativeVolcDebugVerifiedRecord(fingerprint: old.fingerprint)!
            let candidateVerified = NativeVolcDebugVerifiedRecord(
                fingerprint: candidate.fingerprint
            )!
            let active = phase == .rollbackRequested ? candidate : old
            let verified = phase == .rollbackRequested || phase == .rollbackActiveRestored
                ? candidateVerified : oldVerified
            expect(await fixture.store.writeCredentials(active, to: .active),
                   "seed active at rollback crash cutpoint")
            expect(await fixture.store.writeVerified(verified),
                   "seed verified at rollback crash cutpoint")
            if phase != .rollbackPendingRemoved {
                expect(await fixture.store.writeCredentials(candidate, to: .pending),
                       "seed pending at rollback crash cutpoint")
            }
            let journal = NativeVolcPromotionJournal(
                identifier: UUID().uuidString,
                phase: phase,
                candidateFingerprint: candidate.fingerprint,
                oldActive: old,
                oldVerified: oldVerified
            )!
            expect(await fixture.store.writeJournal(journal), "seed durable rollback phase")
            expect(await fixture.workflow.recoverPromotion() == .configuration(.ready),
                   "each rollback cutpoint resumes to the complete old configuration")
            expect(fixture.transport.callCount == 0, "rollback recovery performs zero network")
            expect(await fixture.store.readCredentials(.active) == .found(old),
                   "rollback recovery restores exact old active")
            expect(await fixture.store.readVerified() == .found(oldVerified),
                   "rollback recovery restores exact old proof")
            expect(await fixture.store.readCredentials(.pending) == .notFound,
                   "rollback recovery removes candidate")
            expect(await fixture.store.readJournal() == .notFound,
                   "rollback recovery removes journal last")
        }
    }

    private static func testCancellationBeforeTransportStarts() async {
        let gate = NativeVolcWorkflowHookGate()
        let fixture = NativeVolcWorkflowFixture(
            hooks: NativeVolcDebugWorkflowHooks(beforeTransport: { await gate.wait() })
        )
        defer { fixture.cleanup() }
        let active = NativeVolcDebugCredentials(accessKey: "ACTIVE", secretKey: "ACTIVESECRET")!
        expect(await fixture.store.writeCredentials(active, to: .active), "seed active")
        expect(await fixture.store.writeVerified(
            NativeVolcDebugVerifiedRecord(fingerprint: active.fingerprint)!
        ), "seed verified")
        let operation = Task { await fixture.workflow.testActive() }
        await gate.waitUntilEntered()
        operation.cancel()
        await fixture.workflow.cancelNetwork()
        await gate.release()
        expect(await operation.value == .failure(.cancelled),
               "cancellation while final pre-resume check is suspended is typed cancelled")
        expect(fixture.transport.callCount == 0,
               "cancellation before child installation performs zero transport")
        guard case let .acquired(writer) = await fixture.interlock.beginWriterPhaseA() else {
            fatalError("cancelled reader must release both leases")
        }
        writer.release()
        expect(true, "cancelled pre-resume path releases the reader lease")
    }

    private static func testRemovalRevokesStaleSave() async {
        let fixture = NativeVolcWorkflowFixture()
        defer { fixture.cleanup() }
        guard case let .acquired(blocker) = await fixture.interlock.beginPromotion() else {
            fatalError("seed request-gate blocker")
        }
        let staleSave = Task {
            await fixture.workflow.saveAndValidate(accessKey: "AKTEST", secretKey: "SKTEST")
        }
        for _ in 0..<50 { await Task.yield() }
        let removal = Task { await fixture.workflow.remove() }
        while await fixture.interlock.inspectWithoutCredentials() != .present {
            await Task.yield()
        }
        blocker.release()
        expect(await removal.value == .removed, "removal completes before stale save can revive")
        let callsAtRemoval = fixture.keychain.callCount
        _ = await staleSave.value
        expect(fixture.keychain.callCount == callsAtRemoval,
               "old save performs zero Keychain work after removal commit")
        expect(fixture.transport.callCount == 0,
               "old save performs zero network after removal commit")
        let active = await fixture.store.readCredentials(.active)
        let pending = await fixture.store.readCredentials(.pending)
        let verified = await fixture.store.readVerified()
        let journal = await fixture.store.readJournal()
        expect(active == .notFound && pending == .notFound
            && verified == .notFound && journal == .notFound,
               "removed state remains empty after stale save completes")
    }

    private static func testRedaction() {
        let canary = "SECRET-CANARY"
        let values = [
            String(describing: NativeVolcDebugWorkflowResult.translated(canary, savedCandidate: true)),
            String(reflecting: NativeVolcDebugWorkflowResult.translated(canary, savedCandidate: true)),
            String(describing: NativeVolcDebugWorkflowFailure.credential),
        ]
        expect(values.allSatisfy { !$0.contains(canary) }, "workflow descriptions never echo text")
    }
}
#endif
