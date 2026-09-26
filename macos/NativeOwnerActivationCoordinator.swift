import Foundation

@MainActor
protocol NativeOwnerActivatingEffect: AnyObject {
    func start() -> NativeOwnerActivationCoordinator.StartResult
    func stop() -> NativeOwnerActivationCoordinator.StopResult
}

/// Linearizes the native trigger effect with the durable Hammerspoon
/// handoff lease. This coordinator has no event monitor, AX, selection,
/// translation, clipboard, network, or UI implementation.
///
/// An existing legacy installation must provide its exact yield. A clean
/// native-only installation retains the same durable request and process lock.
/// The production effect rechecks absence of the legacy environment. Returning
/// the request is ordered strictly after a confirmed stop. An uncertain stop
/// preserves the request and process lock, so Hammerspoon remains yielded and
/// the system has at most one trigger owner.
@MainActor
final class NativeOwnerActivationCoordinator {
    enum StartResult: Equatable {
        case started
        case notStarted
        case uncertain
    }

    enum StopResult: Equatable {
        case stopped
        case uncertain
    }

    enum Phase: Equatable {
        case idle
        case waitingForLegacy
        case readyToActivate
        case nativeActive
        case returnedToLegacy
        case revocationRequired
        case recoveryRequired
        case busy
        case unavailable
    }

    enum DeactivationReason: Equatable {
        case user
        case pause
        case stop
        case sleep
        case sessionResigned
        case terminate
        case authorizationRevoked
    }

    private enum EffectState {
        case stopped
        case activeOrUncertain
    }

    private(set) var phase: Phase = .idle
    private(set) var lastDeactivationReason: DeactivationReason?

    private let workflow: NativeOwnerHandoffWorkflow
    private let effect: NativeOwnerActivatingEffect
    private var effectState: EffectState = .stopped

    init(
        workflow: NativeOwnerHandoffWorkflow,
        effect: NativeOwnerActivatingEffect
    ) {
        self.workflow = workflow
        self.effect = effect
        syncFromWorkflow()
    }

    var holdsOwnerLease: Bool { workflow.holdsCandidateLease }

    func beginHandoff(requiresLegacyAcknowledgement: Bool = true) {
        guard effectState == .stopped,
              phase != .nativeActive,
              phase != .revocationRequired else { return }
        lastDeactivationReason = nil
        workflow.begin(requiresLegacyAcknowledgement: requiresLegacyAcknowledgement)
        syncFromWorkflow()
    }

    func ingestLegacyStatus(_ data: Data?, now: TimeInterval) {
        guard phase == .waitingForLegacy else { return }
        workflow.ingestLegacyStatus(data, now: now)
        syncFromWorkflow()
    }

    func handoffTimedOut() {
        guard phase == .waitingForLegacy else { return }
        workflow.timeOut()
        syncFromWorkflow()
    }

    func statusBecameUnavailable() {
        guard phase == .waitingForLegacy else { return }
        workflow.statusBecameUnavailable()
        syncFromWorkflow()
    }

    func activate() {
        guard phase == .readyToActivate,
              (workflow.phase == .legacyYielded || workflow.phase == .nativeOnlyReady),
              workflow.holdsCandidateLease,
              effectState == .stopped else { return }

        switch effect.start() {
        case .started:
            effectState = .activeOrUncertain
            phase = .nativeActive
        case .notStarted:
            returnLeaseAfterConfirmedStop(reason: .user)
        case .uncertain:
            effectState = .activeOrUncertain
            revokeEffectAndReturn(reason: .user)
        }
    }

    func deactivate(_ reason: DeactivationReason) {
        lastDeactivationReason = reason
        switch phase {
        case .readyToActivate, .waitingForLegacy:
            guard effectState == .stopped else {
                phase = .revocationRequired
                return
            }
            workflow.cancel()
            syncFromWorkflow()
        case .nativeActive, .revocationRequired:
            revokeEffectAndReturn(reason: reason)
        case .idle, .returnedToLegacy, .recoveryRequired, .busy, .unavailable:
            break
        }
    }

    func retryRevocation() {
        guard phase == .revocationRequired,
              effectState == .activeOrUncertain else { return }
        revokeEffectAndReturn(reason: lastDeactivationReason ?? .user)
    }

    func recoverAndReturnToLegacy() {
        guard effectState == .stopped,
              phase != .nativeActive,
              phase != .revocationRequired else { return }
        workflow.recoverAndReturnToLegacy()
        syncFromWorkflow()
    }

    private func revokeEffectAndReturn(reason: DeactivationReason) {
        guard effectState == .activeOrUncertain else {
            returnLeaseAfterConfirmedStop(reason: reason)
            return
        }
        switch effect.stop() {
        case .stopped:
            effectState = .stopped
            returnLeaseAfterConfirmedStop(reason: reason)
        case .uncertain:
            // Keep both the durable request and cross-process process lock.
            // Returning either could let Hammerspoon start while the native
            // effect may still be alive.
            phase = .revocationRequired
        }
    }

    private func returnLeaseAfterConfirmedStop(reason: DeactivationReason) {
        guard effectState == .stopped else {
            phase = .revocationRequired
            return
        }
        lastDeactivationReason = reason
        workflow.cancel()
        syncFromWorkflow()
    }

    private func syncFromWorkflow() {
        switch workflow.phase {
        case .idle:
            phase = .idle
        case .waitingForLegacy:
            phase = .waitingForLegacy
        case .legacyYielded, .nativeOnlyReady:
            phase = .readyToActivate
        case .returnedToLegacy:
            phase = .returnedToLegacy
        case .recoveryRequired:
            phase = .recoveryRequired
        case .busy:
            phase = .busy
        case .unavailable:
            phase = .unavailable
        }
    }
}
