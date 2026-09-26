import Foundation

enum OnboardingDisposition: String, Equatable {
    case neverStarted, inProgress, deferred, completed
}

enum OnboardingScreen: Equatable {
    case welcome, prepare, permission, practice, complete
}

/// Pure onboarding decisions kept separate from AppKit, networking and disk IO.
/// This makes migration, routing and engine-preservation behavior executable in
/// a small Swift test without launching the app or touching user preferences.
struct OnboardingPolicy {
    static let currentVersion = 1

    static func migratedDisposition(
        storedRawValue: String?,
        storedVersion: Int?,
        legacyConfirmed: Bool
    ) -> OnboardingDisposition {
        if storedVersion == currentVersion,
           let raw = storedRawValue,
           let stored = OnboardingDisposition(rawValue: raw) {
            return stored
        }
        if legacyConfirmed { return .completed }
        return .neverStarted
    }

    /// Existing explicit choices always win. Credentials alone are not consent
    /// to upload, so absent an explicit choice the privacy-safe default is Apple.
    static func preferredEngine(
        explicitEngine: String?,
        environmentEngine: String?
    ) -> String {
        if let explicitEngine, ["apple", "volc"].contains(explicitEngine) {
            return explicitEngine
        }
        if let environmentEngine, ["apple", "volc"].contains(environmentEngine) {
            return environmentEngine
        }
        return "apple"
    }

    static func firstIncompleteScreen(
        serviceReady: Bool,
        engineReady: Bool,
        hotkeyReady: Bool
    ) -> OnboardingScreen {
        if !serviceReady || !engineReady { return .prepare }
        if !hotkeyReady { return .permission }
        return .practice
    }

    static func preservesCompletionDuringRerun(_ disposition: OnboardingDisposition) -> Bool {
        disposition == .completed
    }

    static func dispositionWhenStarting(
        current: OnboardingDisposition,
        preservesCompletion: Bool
    ) -> OnboardingDisposition {
        preservesCompletion && current == .completed ? .completed : .inProgress
    }

    static func dispositionWhenDeferred(
        current: OnboardingDisposition,
        preservesCompletion: Bool
    ) -> OnboardingDisposition {
        preservesCompletion && current == .completed ? .completed : .deferred
    }
}
