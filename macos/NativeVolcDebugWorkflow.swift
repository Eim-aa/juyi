#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER
import Foundation

enum NativeVolcDebugConfigurationState: Equatable, Sendable {
    case missing
    case pendingReady
    case pendingRecovery
    case activeNeedsVerification
    case ready
    case removalBlocked
    case interlockUnavailable
    case keychainUnavailable
}

enum NativeVolcDebugWorkflowFailure: Error, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    case interlockUnavailable
    case keychainUnavailable
    case credential
    case network
    case transportSecurity
    case timeout
    case quota
    case service
    case malformed
    case pendingReady
    case pendingRecovery
    case removalBlocked
    case revoked
    case cancelled

    var description: String {
        switch self {
        case .interlockUnavailable: return "interlock_unavailable"
        case .keychainUnavailable: return "keychain_unavailable"
        case .credential: return "credential"
        case .network: return "network"
        case .transportSecurity: return "transport_security"
        case .timeout: return "timeout"
        case .quota: return "quota"
        case .service: return "service"
        case .malformed: return "malformed"
        case .pendingReady: return "pending_ready"
        case .pendingRecovery: return "pending_recovery"
        case .removalBlocked: return "removal_blocked"
        case .revoked: return "revoked"
        case .cancelled: return "cancelled"
        }
    }

    var debugDescription: String { description }
}

enum NativeVolcDebugWorkflowResult: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    case configuration(NativeVolcDebugConfigurationState)
    case translated(String, savedCandidate: Bool)
    case removed
    case stopped(pendingRetained: Bool)
    case failure(NativeVolcDebugWorkflowFailure)

    var description: String {
        switch self {
        case let .configuration(state): return "configuration(\(state))"
        case let .translated(_, saved): return "translated([REDACTED], saved: \(saved))"
        case .removed: return "removed"
        case let .stopped(retained): return "stopped(pendingRetained: \(retained))"
        case let .failure(failure): return "failure(\(failure.description))"
        }
    }

    var debugDescription: String { description }
}

struct NativeVolcDebugWallClock: Sendable {
    let now: @Sendable () -> Date
    static let system = NativeVolcDebugWallClock(now: { Date() })
}

struct NativeVolcDebugWorkflowHooks: Sendable {
    let beforeInspectionKeychain: @Sendable () async -> Void
    let beforeTransport: @Sendable () async -> Void
    let afterVerifiedTransport: @Sendable () async -> Void

    init(
        beforeInspectionKeychain: @escaping @Sendable () async -> Void = {},
        beforeTransport: @escaping @Sendable () async -> Void = {},
        afterVerifiedTransport: @escaping @Sendable () async -> Void = {}
    ) {
        self.beforeInspectionKeychain = beforeInspectionKeychain
        self.beforeTransport = beforeTransport
        self.afterVerifiedTransport = afterVerifiedTransport
    }

    static let none = NativeVolcDebugWorkflowHooks()
}

private final class NativeVolcWorkflowTransportCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    private var task: Task<NativeVolcTransportResult, Never>?

    var isCancelled: Bool { lock.withLock { cancelled } }

    func install(_ task: Task<NativeVolcTransportResult, Never>) {
        let cancelImmediately = lock.withLock { () -> Bool in
            guard !cancelled else { return true }
            self.task = task
            return false
        }
        if cancelImmediately { task.cancel() }
    }

    func cancel() {
        let task = lock.withLock { () -> Task<NativeVolcTransportResult, Never>? in
            cancelled = true
            return self.task
        }
        task?.cancel()
    }

    func finish() { lock.withLock { task = nil } }
}

actor NativeVolcDebugWorkflow {
    private struct FixtureExecution {
        let text: String
        let credentials: NativeVolcDebugCredentials
    }
    private struct ActiveNetwork {
        let identifier: UUID
        let task: Task<NativeVolcTransportResult, Never>
    }

    private enum PromotionResult {
        case promoted
        case rolledBack
        case recoveryRequired
    }

    private let interlock: NativeVolcDebugInterlock
    private let store: NativeVolcDebugCredentialStore
    private let transport: NativeVolcDebugTransportClient
    private let wallClock: NativeVolcDebugWallClock
    private let hooks: NativeVolcDebugWorkflowHooks
    private var activeNetwork: ActiveNetwork?
    private var operationToken: UUID?
    private var networkCancellationGeneration: UInt64 = 0
    private var removing = false

    init(
        interlock: NativeVolcDebugInterlock = NativeVolcDebugInterlock(),
        store: NativeVolcDebugCredentialStore = NativeVolcDebugCredentialStore(),
        transport: NativeVolcDebugTransportClient = .live,
        wallClock: NativeVolcDebugWallClock = .system,
        hooks: NativeVolcDebugWorkflowHooks = .none
    ) {
        self.interlock = interlock
        self.store = store
        self.transport = transport
        self.wallClock = wallClock
        self.hooks = hooks
    }

    func inspect() async -> NativeVolcDebugWorkflowResult {
        guard let token = beginOperation() else { return .failure(.cancelled) }
        defer { finishOperation(token) }
        let reader: NativeVolcReaderLease
        switch await interlock.beginReader() {
        case let .acquired(lease): reader = lease
        case .blocked: return .configuration(.removalBlocked)
        case .unavailable: return .configuration(.interlockUnavailable)
        }
        defer {
            reader.releaseGate()
            reader.releaseTransport()
        }
        await hooks.beforeInspectionKeychain()
        guard operationIsCurrent(token) else { return .failure(.cancelled) }
        switch await interlock.revalidationState(reader) {
        case .present: return .configuration(.removalBlocked)
        case .unavailable: return .configuration(.interlockUnavailable)
        case .absent: break
        }

        let journal = await store.readJournal()
        let pending = await store.readCredentials(.pending)
        let active = await store.readCredentials(.active)
        let verified = await store.readVerified()
        guard operationIsCurrent(token) else { return .failure(.cancelled) }
        switch await interlock.revalidationState(reader) {
        case .present: return .configuration(.removalBlocked)
        case .unavailable: return .configuration(.interlockUnavailable)
        case .absent: break
        }

        switch journal {
        case .found, .invalid: return .configuration(.pendingRecovery)
        case .unavailable: return .configuration(.keychainUnavailable)
        case .notFound: break
        }
        switch pending {
        case .found: return .configuration(.pendingReady)
        case .invalid: return .configuration(.pendingRecovery)
        case .unavailable: return .configuration(.keychainUnavailable)
        case .notFound: break
        }
        switch (active, verified) {
        case (.notFound, .notFound): return .configuration(.missing)
        case let (.found(credentials), .found(record)):
            return .configuration(
                record.fingerprint == credentials.fingerprint
                    && record.profile == NativeVolcDebugProfile.identifier
                    ? .ready : .activeNeedsVerification
            )
        case (.found, .notFound):
            return .configuration(.activeNeedsVerification)
        case (.found, .invalid):
            return .configuration(.pendingRecovery)
        case (.notFound, .found), (.notFound, .invalid), (.invalid, _):
            return .configuration(.pendingRecovery)
        case (.unavailable, _), (_, .unavailable):
            return .configuration(.keychainUnavailable)
        }
    }

    func saveAndValidate(
        accessKey: String,
        secretKey: String
    ) async -> NativeVolcDebugWorkflowResult {
        guard !removing,
              let candidate = NativeVolcDebugCredentials(
                  accessKey: accessKey,
                  secretKey: secretKey
              )
        else { return .failure(.credential) }
        guard let token = beginOperation() else { return .failure(.cancelled) }
        defer { finishOperation(token) }
        guard case let .acquired(stageLease) = await interlock.beginPromotion() else {
            return .failure(.interlockUnavailable)
        }
        guard operationIsCurrent(token) else {
            stageLease.release()
            return .failure(.cancelled)
        }
        let journal = await store.readJournal()
        let pending = await store.readCredentials(.pending)
        guard operationIsCurrent(token) else {
            stageLease.release()
            return .failure(.cancelled)
        }
        guard journal == .notFound else {
            stageLease.release()
            return .failure(.pendingRecovery)
        }
        guard pending == .notFound else {
            stageLease.release()
            return .failure(pending.isUnavailableOrInvalid ? .pendingRecovery : .pendingReady)
        }
        guard operationIsCurrent(token),
              await store.writeCredentials(candidate, to: .pending)
        else {
            stageLease.release()
            return .failure(operationIsCurrent(token) ? .keychainUnavailable : .cancelled)
        }
        guard operationIsCurrent(token),
              await interlock.revalidatePromotion(stageLease)
        else {
            let cleaned = await store.delete(.pending)
            stageLease.release()
            if !operationIsCurrent(token) {
                return cleaned ? .failure(.cancelled) : .failure(.pendingReady)
            }
            return .failure(cleaned ? .interlockUnavailable : .pendingReady)
        }
        stageLease.release()

        let network = await executeFixture(
            expectedCredentials: candidate,
            slot: .pending,
            verified: false,
            requireUnverified: false,
            requireNoJournal: true
        )
        guard operationIsCurrent(token) else { return .failure(.cancelled) }
        switch network {
        case let .success(execution):
            guard execution.credentials == candidate else { return .failure(.credential) }
            switch await promoteValidatedCandidate(candidate, operationToken: token) {
            case .promoted:
                return .translated(execution.text, savedCandidate: true)
            case .rolledBack:
                return .failure(.keychainUnavailable)
            case .recoveryRequired:
                return .failure(.pendingRecovery)
            }
        case let .failure(failure):
            let cleaned = await cleanupPending(candidate, operationToken: token)
            if failure == .cancelled {
                return .stopped(pendingRetained: !cleaned)
            }
            return cleaned ? .failure(failure) : .failure(.pendingReady)
        }
    }

    func validatePending() async -> NativeVolcDebugWorkflowResult {
        guard let token = beginOperation() else { return .failure(.cancelled) }
        defer { finishOperation(token) }
        guard case let .acquired(preflight) = await interlock.beginPromotion() else {
            return .failure(.interlockUnavailable)
        }
        guard operationIsCurrent(token) else {
            preflight.release()
            return .failure(.cancelled)
        }
        let journal = await store.readJournal()
        let pending = await store.readCredentials(.pending)
        let promotionIsCurrent = await interlock.revalidatePromotion(preflight)
        let safeToValidate = operationIsCurrent(token)
            && promotionIsCurrent && journal == .notFound && pending.isFound
        preflight.release()
        guard safeToValidate else {
            return .failure(journal == .notFound && !pending.isUnavailableOrInvalid
                ? .pendingReady : .pendingRecovery)
        }
        let network = await executeFixture(
            expectedCredentials: nil,
            slot: .pending,
            verified: false,
            requireUnverified: false,
            requireNoJournal: true
        )
        guard operationIsCurrent(token) else { return .failure(.cancelled) }
        switch network {
        case .failure(.cancelled): return .stopped(pendingRetained: true)
        case let .failure(failure): return .failure(failure)
        case let .success(execution):
            switch await promoteValidatedCandidate(execution.credentials, operationToken: token) {
            case .promoted:
                return .translated(execution.text, savedCandidate: true)
            case .rolledBack:
                return .failure(.keychainUnavailable)
            case .recoveryRequired:
                return .failure(.pendingRecovery)
            }
        }
    }

    func discardPending() async -> NativeVolcDebugWorkflowResult {
        guard let token = beginOperation() else { return .failure(.cancelled) }
        defer { finishOperation(token) }
        guard case let .acquired(lease) = await interlock.beginPromotion() else {
            return .failure(.interlockUnavailable)
        }
        defer { lease.release() }
        guard operationIsCurrent(token),
              await interlock.revalidatePromotion(lease),
              await store.readJournal() == .notFound,
              case .found = await store.readCredentials(.pending),
              operationIsCurrent(token),
              await store.delete(.pending)
        else { return .failure(.pendingRecovery) }
        let active = await store.readCredentials(.active)
        let verified = await store.readVerified()
        if case let .found(credentials) = active,
           case let .found(record) = verified,
           record.fingerprint == credentials.fingerprint
        { return .configuration(.ready) }
        if active == .notFound, verified == .notFound { return .configuration(.missing) }
        if case .found = active { return .configuration(.activeNeedsVerification) }
        return .configuration(.pendingRecovery)
    }

    func validateActive() async -> NativeVolcDebugWorkflowResult {
        guard let token = beginOperation() else { return .failure(.cancelled) }
        defer { finishOperation(token) }
        let network = await executeFixture(
            expectedCredentials: nil,
            slot: .active,
            verified: false,
            requireUnverified: true,
            requireNoJournal: true
        )
        guard operationIsCurrent(token) else { return .failure(.cancelled) }
        switch network {
        case let .failure(failure): return .failure(failure)
        case let .success(execution):
            guard case let .acquired(lease) = await interlock.beginPromotion() else {
                return .failure(.interlockUnavailable)
            }
            defer { lease.release() }
            guard operationIsCurrent(token),
                  await interlock.revalidatePromotion(lease),
                  await store.readCredentials(.active) == .found(execution.credentials),
                  operationIsCurrent(token),
                  let record = NativeVolcDebugVerifiedRecord(
                      fingerprint: execution.credentials.fingerprint
                  ),
                  await store.writeVerified(record)
            else { return .failure(.keychainUnavailable) }
            return .translated(execution.text, savedCandidate: true)
        }
    }

    func testActive() async -> NativeVolcDebugWorkflowResult {
        guard let token = beginOperation() else { return .failure(.cancelled) }
        defer { finishOperation(token) }
        let result = await executeFixture(
            expectedCredentials: nil,
            slot: .active,
            verified: true,
            requireUnverified: false,
            requireNoJournal: true
        )
        guard operationIsCurrent(token) else { return .failure(.cancelled) }
        switch result {
        case let .success(execution):
            return .translated(execution.text, savedCandidate: false)
        case let .failure(failure): return .failure(failure)
        }
    }

    func recoverPromotion() async -> NativeVolcDebugWorkflowResult {
        guard let token = beginOperation() else { return .failure(.cancelled) }
        defer { finishOperation(token) }
        guard operationIsCurrent(token),
              case let .acquired(lease) = await interlock.beginPromotion()
        else { return .failure(.interlockUnavailable) }
        defer { lease.release() }
        guard operationIsCurrent(token),
              await interlock.revalidatePromotion(lease),
              case let .found(journal) = await store.readJournal(),
              journal.phase != .staged
        else { return .failure(.pendingRecovery) }
        guard await rollForward(journal) else { return .failure(.pendingRecovery) }
        return await recoveredConfiguration()
    }

    func cancelNetwork() {
        networkCancellationGeneration &+= 1
        activeNetwork?.task.cancel()
    }

    func remove(resume: Bool = false) async -> NativeVolcDebugWorkflowResult {
        guard !removing else { return .failure(.removalBlocked) }
        removing = true
        operationToken = nil
        networkCancellationGeneration &+= 1
        defer { removing = false }
        let inFlight = activeNetwork?.task
        inFlight?.cancel()

        let phaseA = resume
            ? await interlock.resumeWriterPhaseA()
            : await interlock.beginWriterPhaseA()
        guard case let .acquired(writer) = phaseA else {
            return .failure(.interlockUnavailable)
        }
        activeNetwork?.task.cancel()
        _ = await inFlight?.value
        guard await interlock.acquireWriterTransport(writer) else {
            writer.release()
            return .failure(.removalBlocked)
        }
        let removalOrder: [NativeVolcDebugKeychainSlot] = [
            .verified, .active, .pending, .transaction,
        ]
        for slot in removalOrder {
            guard await store.delete(slot) else {
                writer.release()
                return .failure(.removalBlocked)
            }
        }
        guard await interlock.finishWriterSuccess(writer) else {
            writer.release()
            return .failure(.removalBlocked)
        }
        return .removed
    }

    private func executeFixture(
        expectedCredentials: NativeVolcDebugCredentials?,
        slot: NativeVolcDebugKeychainSlot,
        verified mustBeVerified: Bool,
        requireUnverified: Bool,
        requireNoJournal: Bool
    ) async -> Result<FixtureExecution, NativeVolcDebugWorkflowFailure> {
        let cancellationGeneration = networkCancellationGeneration
        guard executionIsCurrent(cancellationGeneration) else { return .failure(.cancelled) }
        let readerResult = await interlock.beginReader()
        guard executionIsCurrent(cancellationGeneration) else {
            if case let .acquired(lease) = readerResult {
                lease.releaseGate()
                lease.releaseTransport()
            }
            return .failure(.cancelled)
        }
        guard case let .acquired(lease) = readerResult else {
            switch readerResult {
            case .blocked: return .failure(.removalBlocked)
            case .unavailable: return .failure(.interlockUnavailable)
            case .acquired: return .failure(.interlockUnavailable)
            }
        }
        func releaseBeforeResume() {
            lease.releaseGate()
            lease.releaseTransport()
        }
        guard case let .found(snapshot) = await store.readCredentials(slot),
              expectedCredentials.map({ $0 == snapshot }) ?? true
        else {
            releaseBeforeResume()
            return .failure(.credential)
        }
        guard executionIsCurrent(cancellationGeneration) else {
            releaseBeforeResume()
            return .failure(.cancelled)
        }
        if requireNoJournal {
            guard await store.readJournal() == .notFound else {
                releaseBeforeResume()
                return .failure(.pendingRecovery)
            }
        }
        if mustBeVerified {
            guard case let .found(record) = await store.readVerified(),
                  record.fingerprint == snapshot.fingerprint,
                  record.profile == NativeVolcDebugProfile.identifier
            else {
                releaseBeforeResume()
                return .failure(.credential)
            }
        } else if requireUnverified {
            switch await store.readVerified() {
            case .notFound:
                break
            case let .found(record) where record.fingerprint != snapshot.fingerprint
                || record.profile != NativeVolcDebugProfile.identifier:
                break
            default:
                releaseBeforeResume()
                return .failure(.pendingRecovery)
            }
        }
        let signed: VolcV4SignedRequest
        do {
            signed = try VolcV4RequestBuilder.build(
                text: NativeVolcDebugFixture.sourceText,
                credentials: snapshot.v4Credentials,
                sourceLanguage: NativeVolcDebugFixture.sourceLanguage,
                targetLanguage: NativeVolcDebugFixture.targetLanguage,
                instant: wallClock.now()
            )
        } catch {
            releaseBeforeResume()
            return .failure(.credential)
        }
        let journalStillAbsent = !requireNoJournal
            ? true : await store.readJournal() == .notFound
        guard executionIsCurrent(cancellationGeneration),
              await interlock.revalidate(lease),
              await store.readCredentials(slot) == .found(snapshot),
              journalStillAbsent
        else {
            releaseBeforeResume()
            return .failure(.credential)
        }
        if mustBeVerified {
            guard case let .found(record) = await store.readVerified(),
                  record.fingerprint == snapshot.fingerprint,
                  record.profile == NativeVolcDebugProfile.identifier
            else {
                releaseBeforeResume()
                return .failure(.credential)
            }
        } else if requireUnverified {
            switch await store.readVerified() {
            case .notFound:
                break
            case let .found(record) where record.fingerprint != snapshot.fingerprint
                || record.profile != NativeVolcDebugProfile.identifier:
                break
            default:
                releaseBeforeResume()
                return .failure(.pendingRecovery)
            }
        }

        await hooks.beforeTransport()
        let finalInterlockCheck = await interlock.revalidate(lease)
        guard executionIsCurrent(cancellationGeneration), finalInterlockCheck
        else {
            releaseBeforeResume()
            return .failure(.cancelled)
        }

        let parentCancellation = NativeVolcWorkflowTransportCancellation()
        let result: NativeVolcTransportResult = await withTaskCancellationHandler {
            guard executionIsCurrent(cancellationGeneration),
                  !parentCancellation.isCancelled
            else {
                lease.releaseGate()
                lease.releaseTransport()
                return .failure(.cancelled)
            }
            let identifier = UUID()
            let task = Task {
                guard !parentCancellation.isCancelled, !Task.isCancelled else {
                    lease.releaseGate()
                    lease.releaseTransport()
                    return NativeVolcTransportResult.failure(.cancelled)
                }
                return await transport.execute(signed, lease)
            }
            parentCancellation.install(task)
            activeNetwork = ActiveNetwork(identifier: identifier, task: task)
            let value = await task.value
            if activeNetwork?.identifier == identifier { activeNetwork = nil }
            parentCancellation.finish()
            return value
        } onCancel: {
            parentCancellation.cancel()
        }
        if !executionIsCurrent(cancellationGeneration) { return .failure(.cancelled) }
        switch result {
        case let .response(status, data):
            switch VolcTranslationResponseParser.parse(statusCode: status, data: data) {
            case let .success(text):
                if mustBeVerified {
                    await hooks.afterVerifiedTransport()
                    guard executionIsCurrent(cancellationGeneration) else {
                        return .failure(.cancelled)
                    }
                    let postflightResult = await interlock.beginReader()
                    guard executionIsCurrent(cancellationGeneration) else {
                        if case let .acquired(postflight) = postflightResult {
                            postflight.releaseGate()
                            postflight.releaseTransport()
                        }
                        return .failure(.cancelled)
                    }
                    guard case let .acquired(postflight) = postflightResult else {
                        switch postflightResult {
                        case .blocked: return .failure(.removalBlocked)
                        case .unavailable: return .failure(.interlockUnavailable)
                        case .acquired: return .failure(.interlockUnavailable)
                        }
                    }
                    defer {
                        postflight.releaseGate()
                        postflight.releaseTransport()
                    }
                    guard lease.hasSameRevocationEpoch(as: postflight) else {
                        return .failure(.revoked)
                    }
                    switch await interlock.revalidationState(postflight) {
                    case .present: return .failure(.removalBlocked)
                    case .unavailable: return .failure(.interlockUnavailable)
                    case .absent: break
                    }
                    switch await store.readJournal() {
                    case .notFound: break
                    case .found, .invalid: return .failure(.pendingRecovery)
                    case .unavailable: return .failure(.keychainUnavailable)
                    }
                    switch await store.readCredentials(slot) {
                    case let .found(current) where current == snapshot: break
                    case .found, .notFound: return .failure(.credential)
                    case .invalid: return .failure(.pendingRecovery)
                    case .unavailable: return .failure(.keychainUnavailable)
                    }
                    switch await store.readVerified() {
                    case let .found(record)
                        where record.fingerprint == snapshot.fingerprint
                            && record.profile == NativeVolcDebugProfile.identifier:
                        break
                    case .found, .notFound: return .failure(.credential)
                    case .invalid: return .failure(.pendingRecovery)
                    case .unavailable: return .failure(.keychainUnavailable)
                    }
                    guard executionIsCurrent(cancellationGeneration) else {
                        return .failure(.cancelled)
                    }
                    switch await interlock.revalidationState(postflight) {
                    case .present: return .failure(.removalBlocked)
                    case .unavailable: return .failure(.interlockUnavailable)
                    case .absent: break
                    }
                }
                return .success(FixtureExecution(text: text, credentials: snapshot))
            case let .failure(failure): return .failure(Self.map(failure))
            }
        case let .failure(failure):
            return .failure(Self.map(failure))
        }
    }

    private func promoteValidatedCandidate(
        _ candidate: NativeVolcDebugCredentials,
        operationToken token: UUID
    ) async -> PromotionResult {
        guard operationIsCurrent(token),
              case let .acquired(lease) = await interlock.beginPromotion()
        else {
            return .recoveryRequired
        }
        defer { lease.release() }
        guard operationIsCurrent(token),
              await interlock.revalidatePromotion(lease),
              await store.readCredentials(.pending) == .found(candidate),
              await store.readJournal() == .notFound,
              operationIsCurrent(token)
        else { return .recoveryRequired }
        let oldActive = await store.readCredentials(.active)
        let oldVerified = await store.readVerified()
        guard let oldActiveValue = recoverable(oldActive),
              let oldVerifiedValue = recoverable(oldVerified),
              let journal = NativeVolcPromotionJournal(
                  identifier: UUID().uuidString,
                  phase: .validated,
                  candidateFingerprint: candidate.fingerprint,
                  oldActive: oldActiveValue,
                  oldVerified: oldVerifiedValue
              ),
              operationIsCurrent(token),
              await store.writeJournal(journal)
        else { return .recoveryRequired }

        guard operationIsCurrent(token),
              await store.writeCredentials(candidate, to: .active),
              let activeJournal = journal.advancing(to: .activeWritten),
              operationIsCurrent(token),
              await store.writeJournal(activeJournal),
              let verified = NativeVolcDebugVerifiedRecord(fingerprint: candidate.fingerprint),
              operationIsCurrent(token),
              await store.writeVerified(verified),
              let verifiedJournal = activeJournal.advancing(to: .verifiedWritten),
              operationIsCurrent(token),
              await store.writeJournal(verifiedJournal),
              operationIsCurrent(token),
              await store.delete(.pending),
              operationIsCurrent(token),
              await store.delete(.transaction)
        else {
            return await beginOrResumeRollback(journal) ? .rolledBack : .recoveryRequired
        }
        return .promoted
    }

    private func beginOrResumeRollback(_ journal: NativeVolcPromotionJournal) async -> Bool {
        guard let rollback = journal.beginningRollback() else { return false }
        if !journal.isRollingBack {
            guard await store.writeJournal(rollback) else { return false }
        }
        return await resumeRollback(rollback)
    }

    private func resumeRollback(_ journal: NativeVolcPromotionJournal) async -> Bool {
        switch journal.phase {
        case .rollbackRequested:
            let restored: Bool
            if journal.oldActiveWasPresent, let oldActive = journal.oldActive {
                restored = await store.writeCredentials(oldActive, to: .active)
            } else {
                restored = await store.delete(.active)
            }
            guard restored,
                  let next = journal.advancingRollback(to: .rollbackActiveRestored),
                  await store.writeJournal(next)
            else { return false }
            return await resumeRollback(next)
        case .rollbackActiveRestored:
            let restored: Bool
            if journal.oldVerifiedWasPresent, let oldVerified = journal.oldVerified {
                restored = await store.writeVerified(oldVerified)
            } else {
                restored = await store.delete(.verified)
            }
            guard restored,
                  let next = journal.advancingRollback(to: .rollbackVerifiedRestored),
                  await store.writeJournal(next)
            else { return false }
            return await resumeRollback(next)
        case .rollbackVerifiedRestored:
            guard await store.delete(.pending),
                  let next = journal.advancingRollback(to: .rollbackPendingRemoved),
                  await store.writeJournal(next)
            else { return false }
            return await resumeRollback(next)
        case .rollbackPendingRemoved:
            return await store.delete(.transaction)
        case .staged, .validated, .activeWritten, .verifiedWritten:
            return false
        }
    }

    private func rollForward(_ journal: NativeVolcPromotionJournal) async -> Bool {
        switch journal.phase {
        case .staged:
            return false
        case .validated:
            guard case let .found(value) = await store.readCredentials(.pending),
                  value.fingerprint == journal.candidateFingerprint,
                  await store.writeCredentials(value, to: .active),
                  let next = journal.advancing(to: .activeWritten),
                  await store.writeJournal(next)
            else { return false }
            return await rollForward(next)
        case .activeWritten:
            guard case let .found(value) = await store.readCredentials(.active),
                  value.fingerprint == journal.candidateFingerprint,
                  let verified = NativeVolcDebugVerifiedRecord(fingerprint: value.fingerprint),
                  await store.writeVerified(verified),
                  let next = journal.advancing(to: .verifiedWritten),
                  await store.writeJournal(next)
            else { return false }
            return await rollForward(next)
        case .verifiedWritten:
            guard case let .found(active) = await store.readCredentials(.active),
                  case let .found(verified) = await store.readVerified(),
                  active.fingerprint == journal.candidateFingerprint,
                  verified.fingerprint == journal.candidateFingerprint
            else { return false }
            let pending = await store.readCredentials(.pending)
            if case let .found(value) = pending, value.fingerprint != journal.candidateFingerprint {
                return false
            }
            guard pending == .notFound || (pending == .found(active)) else { return false }
            guard await store.delete(.pending) else { return false }
            return await store.delete(.transaction)
        case .rollbackRequested, .rollbackActiveRestored,
             .rollbackVerifiedRestored, .rollbackPendingRemoved:
            return await resumeRollback(journal)
        }
    }

    private func cleanupPending(
        _ candidate: NativeVolcDebugCredentials,
        operationToken token: UUID
    ) async -> Bool {
        guard operationOwnsState(token),
              case let .acquired(lease) = await interlock.beginPromotion()
        else { return false }
        defer { lease.release() }
        guard operationOwnsState(token),
              await interlock.revalidatePromotion(lease)
        else { return false }
        switch await store.readCredentials(.pending) {
        case .notFound: return true
        case .found(candidate):
            guard operationOwnsState(token) else { return false }
            return await store.delete(.pending)
        default: return false
        }
    }

    private func recoveredConfiguration() async -> NativeVolcDebugWorkflowResult {
        guard await store.readJournal() == .notFound,
              await store.readCredentials(.pending) == .notFound
        else { return .failure(.pendingRecovery) }
        let active = await store.readCredentials(.active)
        let verified = await store.readVerified()
        switch (active, verified) {
        case (.notFound, .notFound): return .configuration(.missing)
        case let (.found(credentials), .found(record))
            where record.fingerprint == credentials.fingerprint
                && record.profile == NativeVolcDebugProfile.identifier:
            return .configuration(.ready)
        case (.found, .notFound): return .configuration(.activeNeedsVerification)
        case (.unavailable, _), (_, .unavailable):
            return .failure(.keychainUnavailable)
        default:
            return .failure(.pendingRecovery)
        }
    }

    private func recoverable<T: Equatable & Sendable>(
        _ read: NativeVolcDebugItemRead<T>
    ) -> T?? {
        switch read {
        case let .found(value): return .some(value)
        case .notFound: return .some(nil)
        case .invalid, .unavailable: return nil
        }
    }

    private static func map(_ failure: NativeTranslationFailure) -> NativeVolcDebugWorkflowFailure {
        switch failure {
        case .volcCredential: return .credential
        case .volcTimeout: return .timeout
        case .volcQuota: return .quota
        case .volcMalformedResponse: return .malformed
        case .volcService, .volcHTTP: return .service
        case .volcNetwork: return .network
        case .volcTransportSecurity: return .transportSecurity
        default: return .service
        }
    }

    private static func map(_ failure: NativeVolcTransportFailure) -> NativeVolcDebugWorkflowFailure {
        switch failure {
        case .network: return .network
        case .transportSecurity: return .transportSecurity
        case .timeout: return .timeout
        case .cancelled: return .cancelled
        }
    }

    private func beginOperation() -> UUID? {
        guard !removing, operationToken == nil, activeNetwork == nil else { return nil }
        let token = UUID()
        operationToken = token
        return token
    }

    private func executionIsCurrent(_ generation: UInt64) -> Bool {
        !removing && !Task.isCancelled && networkCancellationGeneration == generation
    }

    private func finishOperation(_ token: UUID) {
        if operationToken == token { operationToken = nil }
    }

    private func operationIsCurrent(_ token: UUID) -> Bool {
        operationOwnsState(token) && !Task.isCancelled
    }

    private func operationOwnsState(_ token: UUID) -> Bool {
        !removing && operationToken == token
    }
}

private extension NativeVolcDebugItemRead {
    var isFound: Bool {
        if case .found = self { return true }
        return false
    }
    var isUnavailableOrInvalid: Bool {
        switch self {
        case .invalid, .unavailable: return true
        case .found, .notFound: return false
        }
    }
}
#endif
