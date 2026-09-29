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

    /// Mirrors the coordinator: `enable` checks readiness and the legacy
    /// environment once; each trigger consults only the cache and asks the
    /// injected fake for readiness when the cache says so.
    private struct FakeCoordinator {
        var preflight = NativeTriggerPreflight()
        var nativeOnlySession = false
        var readinessQueries = 0
        var legacyProbes = 0
        var captures = 0
        var languageInstalled = true
        var legacyPresent = false

        mutating func enable() {
            readinessQueries += 1
            preflight.recordAppleReadiness(installed: languageInstalled)
            legacyProbes += 1
            preflight.recordLegacyEnvironment(handoffRequired: legacyPresent)
            nativeOnlySession = !legacyPresent
        }

        mutating func disable() {
            nativeOnlySession = false
            preflight.reset()
        }

        mutating func trigger() {
            switch preflight.decision(nativeOnlySession: nativeOnlySession) {
            case .legacyHandoffRequired:
                disable()
            case .checkAppleReadiness:
                readinessQueries += 1
                guard languageInstalled else { disable(); return }
                preflight.recordAppleReadiness(installed: true)
                captures += 1
            case .capture:
                captures += 1
            }
        }

        mutating func workspaceChanged() {
            guard NativeTriggerPreflight.shouldProbeLegacyEnvironment(
                nativeOnlySession: nativeOnlySession
            ) else { return }
            legacyProbes += 1
            preflight.recordLegacyEnvironment(handoffRequired: legacyPresent)
            if preflight.decision(nativeOnlySession: nativeOnlySession)
                == .legacyHandoffRequired {
                disable()
            }
        }
    }

    private static func testTriggersUseTheCacheAfterEnable() {
        var coordinator = FakeCoordinator()
        coordinator.enable()
        let queriesAfterEnable = coordinator.readinessQueries
        let probesAfterEnable = coordinator.legacyProbes
        for _ in 0..<5 { coordinator.trigger() }
        expect(coordinator.captures == 5, "every trigger reaches capture")
        expect(
            coordinator.readinessQueries == queriesAfterEnable,
            "no LanguageAvailability query between trigger and capture"
        )
        expect(
            coordinator.legacyProbes == probesAfterEnable,
            "no legacy lstat/runningApplications probe on trigger"
        )
    }

    private static func testFailureAndDisableInvalidateReadiness() {
        var preflight = NativeTriggerPreflight()
        expect(
            preflight.decision(nativeOnlySession: true) == .checkAppleReadiness,
            "readiness is unknown until a check succeeds"
        )
        preflight.recordAppleReadiness(installed: false)
        expect(
            preflight.decision(nativeOnlySession: true) == .checkAppleReadiness,
            "an unsuccessful check is never cached as ready"
        )
        preflight.recordAppleReadiness(installed: true)
        expect(preflight.decision(nativeOnlySession: true) == .capture, "success is cached")
        preflight.invalidateAppleReadiness()
        expect(
            preflight.decision(nativeOnlySession: true) == .checkAppleReadiness,
            "a translation failure or timeout forces a new check"
        )
        preflight.recordAppleReadiness(installed: true)
        preflight.recordLegacyEnvironment(handoffRequired: true)
        preflight.reset()
        expect(
            preflight == NativeTriggerPreflight(),
            "disable (pause, sleep, session, permission, preparation) clears both answers"
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

    private static func testLegacyEnvironmentIsRefreshedFromWorkspaceEvents() {
        var coordinator = FakeCoordinator()
        coordinator.enable()
        expect(coordinator.nativeOnlySession, "a clean Mac starts a native-only session")
        coordinator.legacyPresent = true
        coordinator.workspaceChanged()
        expect(
            !coordinator.nativeOnlySession,
            "a launched legacy component stops the native-only session"
        )
        expect(
            coordinator.preflight == NativeTriggerPreflight(),
            "stopping the session drops the cached readiness as well"
        )

        var legacySession = FakeCoordinator()
        legacySession.legacyPresent = true
        legacySession.enable()
        let probes = legacySession.legacyProbes
        legacySession.workspaceChanged()
        expect(
            legacySession.legacyProbes == probes,
            "a handoff session does not probe on unrelated workspace events"
        )
        expect(
            legacySession.preflight.decision(nativeOnlySession: legacySession.nativeOnlySession)
                == .capture,
            "a completed legacy handoff still captures from the cache"
        )

        var preflight = NativeTriggerPreflight()
        preflight.recordAppleReadiness(installed: true)
        preflight.recordLegacyEnvironment(handoffRequired: true)
        expect(
            preflight.decision(nativeOnlySession: true) == .legacyHandoffRequired,
            "a native-only session with a detected legacy component must stop"
        )
        expect(
            preflight.decision(nativeOnlySession: false) == .capture,
            "the legacy answer only matters to a native-only session"
        )
        preflight.recordLegacyEnvironment(handoffRequired: false)
        expect(
            preflight.decision(nativeOnlySession: true) == .capture,
            "a terminate event can clear the legacy answer"
        )
        expect(
            !NativeTriggerPreflight.shouldProbeLegacyEnvironment(nativeOnlySession: false)
                && NativeTriggerPreflight.shouldProbeLegacyEnvironment(nativeOnlySession: true),
            "workspace events probe only during a native-only session"
        )
    }

    static func main() {
        testTriggersUseTheCacheAfterEnable()
        testFailureAndDisableInvalidateReadiness()
        testLegacyEnvironmentIsRefreshedFromWorkspaceEvents()
        print("NativeTriggerPreflightTests: \(passed) passed")
    }
}
