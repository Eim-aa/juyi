import Foundation

@main
enum OnboardingPolicyTests {
    static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
            exit(1)
        }
    }

    static func main() {
        expect(
            OnboardingPolicy.migratedDisposition(
                storedRawValue: nil, storedVersion: nil, legacyConfirmed: true
            ) == .completed,
            "legacy confirmation migrates to completed"
        )
        expect(
            OnboardingPolicy.migratedDisposition(
                storedRawValue: "deferred", storedVersion: 1, legacyConfirmed: false
            ) == .deferred,
            "current deferred state is preserved"
        )
        expect(
            OnboardingPolicy.migratedDisposition(
                storedRawValue: "inProgress", storedVersion: 1, legacyConfirmed: false
            ) == .inProgress,
            "current in-progress state is preserved"
        )
        expect(
            OnboardingPolicy.migratedDisposition(
                storedRawValue: "completed", storedVersion: 1, legacyConfirmed: false
            ) == .completed,
            "current completed state is preserved"
        )
        expect(
            OnboardingPolicy.migratedDisposition(
                storedRawValue: nil, storedVersion: nil, legacyConfirmed: false
            ) == .neverStarted,
            "missing state is a true first run"
        )

        expect(
            OnboardingPolicy.preferredEngine(
                explicitEngine: "volc", environmentEngine: nil
            ) == "volc",
            "explicit Volc choice is never overwritten"
        )
        expect(
            OnboardingPolicy.preferredEngine(
                explicitEngine: "apple", environmentEngine: "volc"
            ) == "apple",
            "explicit Apple choice is never overwritten"
        )
        expect(
            OnboardingPolicy.preferredEngine(
                explicitEngine: nil, environmentEngine: "volc"
            ) == "volc",
            "legacy volc.env ENGINE choice is respected"
        )
        expect(
            OnboardingPolicy.preferredEngine(
                explicitEngine: nil, environmentEngine: nil
            ) == "apple",
            "credentials alone never imply consent to use cloud"
        )
        expect(
            OnboardingPolicy.preferredEngine(
                explicitEngine: nil, environmentEngine: nil
            ) == "apple",
            "only a genuinely new user defaults to Apple"
        )

        expect(
            OnboardingPolicy.firstIncompleteScreen(
                serviceReady: true, engineReady: true, hotkeyReady: false
            ) == .permission,
            "completed user with a broken hotkey routes directly to permission"
        )
        expect(
            OnboardingPolicy.firstIncompleteScreen(
                serviceReady: true, engineReady: true, hotkeyReady: true
            ) == .practice,
            "routing uses live readiness, not an ephemeral self-test flag"
        )

        let preserved = OnboardingPolicy.preservesCompletionDuringRerun(.completed)
        expect(preserved, "completed rerun preserves completion")
        expect(
            OnboardingPolicy.dispositionWhenDeferred(
                current: .completed, preservesCompletion: preserved
            ) == .completed,
            "interrupting a completed user's full rerun stays completed"
        )
        expect(
            OnboardingPolicy.dispositionWhenDeferred(
                current: .inProgress, preservesCompletion: false
            ) == .deferred,
            "closing unfinished onboarding defers and never completes it"
        )

        print("OnboardingPolicyTests: 15 passed")
    }
}
