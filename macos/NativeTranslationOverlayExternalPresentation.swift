#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB
import Foundation

/// An opaque capability for one already-created overlay session. It is minted
/// before simulated domain work starts; a late result can only resolve this
/// exact session and can never create a replacement panel.
struct NativeTranslationOverlayExternalPresentationLease: Equatable, CustomStringConvertible {
    fileprivate let nonce: UInt64
    fileprivate let sessionGeneration: Int

    fileprivate init(nonce: UInt64, sessionGeneration: Int) {
        self.nonce = nonce
        self.sessionGeneration = sessionGeneration
    }

    var description: String {
        "NativeTranslationOverlayExternalPresentationLease([REDACTED])"
    }
}

/// Exact-once logical owner for the controller-facing presentation capability.
/// Clearing the active record before invoking callbacks makes replacement and
/// reentrant dismissal safe.
@MainActor
final class NativeTranslationOverlayExternalPresentationRegistry {
    typealias DismissHandler = (NativeTranslationOverlayDismissReason) -> Void

    private struct Active {
        let lease: NativeTranslationOverlayExternalPresentationLease
        let onDismiss: DismissHandler
        var didResolveTerminal = false
    }

    private var nextNonce: UInt64 = 0
    private var active: Active?

    var hasActiveLease: Bool { active != nil }
    var currentLease: NativeTranslationOverlayExternalPresentationLease? {
        active?.lease
    }

    @discardableResult
    func begin(
        sessionGeneration: Int,
        replacingReason: NativeTranslationOverlayDismissReason = .stop,
        onDismiss: @escaping DismissHandler
    ) -> NativeTranslationOverlayExternalPresentationLease {
        let dismissed = active
        nextNonce &+= 1
        let lease = NativeTranslationOverlayExternalPresentationLease(
            nonce: nextNonce,
            sessionGeneration: sessionGeneration
        )
        active = Active(lease: lease, onDismiss: onDismiss)
        // Install the replacement before notifying the old owner. If that
        // callback reenters begin(), the reentrant lease becomes the newest
        // linearized owner and explicitly revokes this one. The outer call
        // then returns a stale capability instead of silently overwriting it.
        dismissed?.onDismiss(replacingReason)
        return lease
    }

    func isCurrent(
        _ lease: NativeTranslationOverlayExternalPresentationLease,
        sessionGeneration: Int
    ) -> Bool {
        guard let active else { return false }
        return matches(lease, sessionGeneration: sessionGeneration)
            && !active.didResolveTerminal
    }

    func matches(
        _ lease: NativeTranslationOverlayExternalPresentationLease,
        sessionGeneration: Int
    ) -> Bool {
        active?.lease == lease && lease.sessionGeneration == sessionGeneration
    }

    /// Atomically consumes the single terminal allowance for this lease.
    func acceptTerminal(
        _ lease: NativeTranslationOverlayExternalPresentationLease,
        sessionGeneration: Int
    ) -> Bool {
        guard isCurrent(lease, sessionGeneration: sessionGeneration) else {
            return false
        }
        active?.didResolveTerminal = true
        return true
    }

    @discardableResult
    func invalidate(
        _ lease: NativeTranslationOverlayExternalPresentationLease,
        reason: NativeTranslationOverlayDismissReason
    ) -> Bool {
        guard active?.lease == lease else { return false }
        invalidateActive(reason: reason)
        return true
    }

    func invalidateActive(reason: NativeTranslationOverlayDismissReason) {
        guard let dismissed = active else { return }
        active = nil
        dismissed.onDismiss(reason)
    }
}
#endif
