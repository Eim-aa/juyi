#if DEBUG && JUYI_NATIVE_OWNER_HANDOFF_LAB && (JUYI_NATIVE_SELECTION_CAPTURE_LAB || JUYI_NATIVE_OPTION_MONITOR || JUYI_NATIVE_TRANSLATION_DOMAIN || JUYI_NATIVE_TRANSLATION_OVERLAY || JUYI_NATIVE_TRANSLATION_RESULT_LAB || JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER || JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER || JUYI_NATIVE_APPLE_RESULT_LAB_BINDING)
#error("JUYI_NATIVE_OWNER_HANDOFF_LAB is an isolated handoff-only build and cannot be mixed with capture, Option, or translation development flags")
#endif

#if DEBUG && JUYI_NATIVE_OWNER_HANDOFF_LAB
import Foundation

protocol NativeOwnerHandoffStoring: AnyObject {
    func begin(nativeInstanceID: UUID, epoch: UUID) -> NativeOwnerHandoffStore.BeginResult
    func recoverForReturnToLegacy() -> NativeOwnerHandoffStore.RecoveryResult
    func returnToLegacy(_ lease: NativeOwnerHandoffLease) -> Bool
}

extension NativeOwnerHandoffStore: NativeOwnerHandoffStoring {}

/// Deterministic single-owner workflow. It retains the durable process lease
/// while validating injected legacy status snapshots, but deliberately has no
/// filesystem status reader, timer, UI, monitor, AX, or translation effect.
@MainActor
final class NativeOwnerHandoffWorkflow {
    static let acknowledgementDeadline: TimeInterval = 5

    enum Phase: Equatable {
        case idle
        case waitingForLegacy
        case legacyYielded
        case returnedToLegacy
        case recoveryRequired
        case busy
        case unavailable
    }

    enum ReturnReason: Equatable {
        case cancelled
        case timedOut
        case recoveredCrashResidue
        case requestAlreadyAbsent
    }

    private(set) var phase: Phase = .idle
    private(set) var latestUnsafeReason: NativeOwnerHandoffProtocol.UnsafeReason?
    private(set) var returnReason: ReturnReason?

    private let store: NativeOwnerHandoffStoring
    private let makeUUID: () -> UUID
    private var activeLease: NativeOwnerHandoffLease?
    private var acceptedLegacyLease: NativeOwnerHandoffProtocol.LegacyYieldLease?

    init(
        store: NativeOwnerHandoffStoring,
        makeUUID: @escaping () -> UUID = UUID.init
    ) {
        self.store = store
        self.makeUUID = makeUUID
    }

    var holdsCandidateLease: Bool { activeLease != nil }

    /// Publishing is allowed only when no request is retained by this workflow.
    /// Existing durable requests are never adopted as activation capabilities.
    func begin() {
        guard activeLease == nil, phase != .recoveryRequired else { return }
        latestUnsafeReason = nil
        returnReason = nil
        acceptedLegacyLease = nil
        let nativeInstanceID = makeUUID()
        let epoch = makeUUID()
        switch store.begin(nativeInstanceID: nativeInstanceID, epoch: epoch) {
        case let .acquired(lease):
            guard lease.purpose == .activationCandidate else {
                lease.releasePreservingRequest()
                phase = .unavailable
                return
            }
            activeLease = lease
            phase = .waitingForLegacy
        case .busy:
            phase = .busy
        case .recoveryRequired:
            phase = .recoveryRequired
        case .unavailable:
            phase = .unavailable
        }
    }

    /// Transitional unsafe snapshots remain waiting. The caller owns the
    /// monotonic five-second deadline and must invoke `timeOut()` when it
    /// expires. No snapshot can start a native monitor in this slice.
    func ingestLegacyStatus(_ data: Data?, now: TimeInterval) {
        guard phase == .waitingForLegacy, let activeLease else { return }
        switch NativeOwnerHandoffProtocol.evaluate(
            request: activeLease.request,
            statusData: data,
            now: now
        ) {
        case let .safeToClaim(legacyLease):
            acceptedLegacyLease = legacyLease
            latestUnsafeReason = nil
            phase = .legacyYielded
        case let .unsafe(reason):
            latestUnsafeReason = reason
        }
    }

    func timeOut() {
        guard phase == .waitingForLegacy else { return }
        returnActiveLeaseToLegacy(reason: .timedOut)
    }

    func cancel() {
        guard activeLease != nil else { return }
        returnActiveLeaseToLegacy(reason: .cancelled)
    }

    /// Explicit recovery can only remove a canonical crash residue. It never
    /// yields `.legacyYielded` and therefore cannot authorize native effects.
    func recoverAndReturnToLegacy() {
        guard activeLease == nil else { return }
        latestUnsafeReason = nil
        acceptedLegacyLease = nil
        switch store.recoverForReturnToLegacy() {
        case let .acquired(lease):
            guard lease.purpose == .recoveryOnly,
                  store.returnToLegacy(lease) else {
                phase = .recoveryRequired
                return
            }
            returnReason = .recoveredCrashResidue
            phase = .returnedToLegacy
        case .absent:
            returnReason = .requestAlreadyAbsent
            phase = .returnedToLegacy
        case .busy:
            phase = .busy
        case .unavailable:
            phase = .unavailable
        }
    }

    private func returnActiveLeaseToLegacy(reason: ReturnReason) {
        guard let lease = activeLease else { return }
        acceptedLegacyLease = nil
        if store.returnToLegacy(lease) {
            activeLease = nil
            latestUnsafeReason = nil
            returnReason = reason
            phase = .returnedToLegacy
        } else {
            phase = .recoveryRequired
        }
    }
}
#endif
