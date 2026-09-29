import Foundation

/// The cached answer the double-Option trigger path would otherwise re-query
/// on every recognition: Apple language readiness (a `LanguageAvailability`
/// round trip).
///
/// Readiness is trusted only after a successful check and is dropped on any
/// translation failure or disable (pause, sleep, session change, permission
/// loss, language preparation, engine switch).
struct NativeTriggerPreflight: Equatable {
    enum Decision: Equatable {
        /// Readiness is unknown; check it before capturing the selection.
        case checkAppleReadiness
        /// Readiness is known-good; capture immediately.
        case capture
    }

    private(set) var appleReadinessConfirmed = false

    mutating func recordAppleReadiness(installed: Bool) {
        appleReadinessConfirmed = installed
    }

    mutating func invalidateAppleReadiness() {
        appleReadinessConfirmed = false
    }

    mutating func reset() {
        self = NativeTriggerPreflight()
    }

    var decision: Decision {
        appleReadinessConfirmed ? .capture : .checkAppleReadiness
    }
}
