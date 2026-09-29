import Foundation

@main
enum NativeTriggerPreflightTests {
    private static var passed = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
            exit(1)
        }
        passed += 1
    }

    /// Mirrors the coordinator: `enable` checks readiness once; each trigger
    /// consults only the cache and asks the injected fake for readiness when
    /// the cache says so.
    private struct FakeCoordinator {
        var preflight = NativeTriggerPreflight()
        var readinessQueries = 0
        var captures = 0
        var languageInstalled = true

        mutating func enable() {
            readinessQueries += 1
            preflight.recordAppleReadiness(installed: languageInstalled)
        }

        mutating func disable() {
            preflight.reset()
        }

        mutating func trigger() {
            switch preflight.decision {
            case .checkAppleReadiness:
                readinessQueries += 1
                guard languageInstalled else { disable(); return }
                preflight.recordAppleReadiness(installed: true)
                captures += 1
            case .capture:
                captures += 1
            }
        }
    }

    private static func testTriggersUseTheCacheAfterEnable() {
        var coordinator = FakeCoordinator()
        coordinator.enable()
        let queriesAfterEnable = coordinator.readinessQueries
        for _ in 0..<5 { coordinator.trigger() }
        expect(coordinator.captures == 5, "every trigger reaches capture")
        expect(
            coordinator.readinessQueries == queriesAfterEnable,
            "no LanguageAvailability query between trigger and capture"
        )
    }

    private static func testFailureAndDisableInvalidateReadiness() {
        var preflight = NativeTriggerPreflight()
        expect(
            preflight.decision == .checkAppleReadiness,
            "readiness is unknown until a check succeeds"
        )
        preflight.recordAppleReadiness(installed: false)
        expect(
            preflight.decision == .checkAppleReadiness,
            "an unsuccessful check is never cached as ready"
        )
        preflight.recordAppleReadiness(installed: true)
        expect(preflight.decision == .capture, "success is cached")
        preflight.invalidateAppleReadiness()
        expect(
            preflight.decision == .checkAppleReadiness,
            "a translation failure, timeout or engine switch forces a new check"
        )
        preflight.recordAppleReadiness(installed: true)
        preflight.reset()
        expect(
            preflight == NativeTriggerPreflight(),
            "disable (pause, sleep, session, permission, preparation) clears the answer"
        )

        var coordinator = FakeCoordinator()
        coordinator.enable()
        coordinator.trigger()
        coordinator.disable()
        coordinator.enable()
        let queries = coordinator.readinessQueries
        coordinator.preflight.invalidateAppleReadiness()
        coordinator.trigger()
        expect(
            coordinator.readinessQueries == queries + 1,
            "the first trigger after invalidation checks readiness once"
        )
        coordinator.trigger()
        expect(
            coordinator.readinessQueries == queries + 1,
            "the re-established cache serves later triggers"
        )
    }

    private static func testMissingLanguagesStopTheSession() {
        var coordinator = FakeCoordinator()
        coordinator.languageInstalled = false
        coordinator.enable()
        coordinator.trigger()
        expect(coordinator.captures == 0, "no capture without language resources")
        expect(
            coordinator.preflight == NativeTriggerPreflight(),
            "a failed check leaves nothing cached"
        )
        coordinator.languageInstalled = true
        coordinator.trigger()
        expect(coordinator.captures == 1, "a later successful check captures")
        expect(coordinator.preflight.decision == .capture, "and caches the answer")
    }

    static func main() {
        testTriggersUseTheCacheAfterEnable()
        testFailureAndDisableInvalidateReadiness()
        testMissingLanguagesStopTheSession()
        print("NativeTriggerPreflightTests: \(passed) passed")
    }
}
