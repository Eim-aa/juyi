import Foundation

/// Cached answers the double-Option trigger path would otherwise re-query on
/// every recognition: Apple language readiness (a `LanguageAvailability`
/// round trip) and whether a legacy Hammerspoon environment appeared (lstat
/// plus a running-application scan).
///
/// Readiness is trusted only after a successful check and is dropped on any
/// translation failure or disable (pause, sleep, session change, permission
/// loss, language preparation). The legacy answer is recorded when a native
/// session is enabled and refreshed from workspace launch/terminate events.
struct NativeTriggerPreflight: Equatable {
    enum Decision: Equatable {
        /// A legacy component appeared during a native-only session.
        case legacyHandoffRequired
        /// Readiness is unknown; check it before capturing the selection.
        case checkAppleReadiness
        /// Everything is known-good; capture immediately.
        case capture
    }

    private(set) var appleReadinessConfirmed = false
    private(set) var legacyHandoffDetected = false

    mutating func recordAppleReadiness(installed: Bool) {
        appleReadinessConfirmed = installed
    }

    mutating func invalidateAppleReadiness() {
        appleReadinessConfirmed = false
    }

    mutating func recordLegacyEnvironment(handoffRequired: Bool) {
        legacyHandoffDetected = handoffRequired
    }

    mutating func reset() {
        self = NativeTriggerPreflight()
    }

    func decision(nativeOnlySession: Bool) -> Decision {
        if nativeOnlySession && legacyHandoffDetected {
            return .legacyHandoffRequired
        }
        return appleReadinessConfirmed ? .capture : .checkAppleReadiness
    }

    /// Only a native-only session can be invalidated by a legacy component
    /// appearing, so other sessions never pay for the probe.
    static func shouldProbeLegacyEnvironment(nativeOnlySession: Bool) -> Bool {
        nativeOnlySession
    }
}
