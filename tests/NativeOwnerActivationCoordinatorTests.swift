#if DEBUG && JUYI_NATIVE_OWNER_HANDOFF_LAB && JUYI_NATIVE_OWNER_ACTIVATION_LAB
import Foundation

@main
@MainActor
enum NativeOwnerActivationCoordinatorTests {
    private static var passed = 0
    private static let epoch = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private static let native = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private static let legacy = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
    private static let now: TimeInterval = 1_700_000_010

    private final class Effect: NativeOwnerActivatingEffect {
        var starts: [NativeOwnerActivationCoordinator.StartResult] = []
        var stops: [NativeOwnerActivationCoordinator.StopResult] = []
        var startCount = 0
        var stopCount = 0
        var onStart: (() -> Void)?
        var onStop: (() -> Void)?

        func start() -> NativeOwnerActivationCoordinator.StartResult {
            startCount += 1
            onStart?()
            return starts.isEmpty ? .notStarted : starts.removeFirst()
        }

        func stop() -> NativeOwnerActivationCoordinator.StopResult {
            stopCount += 1
            onStop?()
            return stops.isEmpty ? .uncertain : stops.removeFirst()
        }
    }

    private static func expect(
        _ value: @autoclosure () -> Bool,
        _ message: String
    ) {
        precondition(value(), message)
        passed += 1
    }

    private static func root() -> String {
        let path = "/private/tmp/juyi-owner-activation-\(UUID().uuidString)"
        precondition(mkdir(path, 0o700) == 0)
        return path
    }

    private static func make(
        _ path: String,
        effect: Effect
    ) -> NativeOwnerActivationCoordinator {
        var identifiers = [native, epoch]
        let workflow = NativeOwnerHandoffWorkflow(
            store: NativeOwnerHandoffStore(directoryPath: path),
            makeUUID: {
                identifiers.isEmpty ? UUID() : identifiers.removeFirst()
            }
        )
        return NativeOwnerActivationCoordinator(
            workflow: workflow,
            effect: effect
        )
    }

    private static func status(
        watcher: Bool = false,
        activeRequest: Bool = false,
        popup: Bool = false
    ) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "module_loaded": true,
            "watcher_active": watcher,
            "active_request": activeRequest,
            "popup_visible": popup,
            "owner_protocol_version": 1,
            "legacy_instance_id": legacy.uuidString.lowercased(),
            "owner_state": "yielded",
            "owner_request_epoch": epoch.uuidString.lowercased(),
            "owner_request_native_instance_id": native.uuidString.lowercased(),
            "status_sequence": 7,
            "updated_at": now - 1,
        ], options: [.sortedKeys])
    }

    private static func requestExists(_ path: String) -> Bool {
        FileManager.default.fileExists(atPath: path + "/owner-request.json")
    }

    private static func acknowledge(
        _ coordinator: NativeOwnerActivationCoordinator
    ) {
        coordinator.beginHandoff()
        coordinator.ingestLegacyStatus(status(), now: now)
        expect(
            coordinator.phase == .readyToActivate,
            "safe acknowledgement did not produce a ready capability"
        )
    }

    private static func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private static func testEffectCannotStartBeforeExactYield() {
        let path = root(); defer { cleanup(path) }
        let effect = Effect(); effect.starts = [.started]
        let coordinator = make(path, effect: effect)
        coordinator.activate()
        expect(effect.startCount == 0, "effect started before handoff")
        coordinator.beginHandoff()
        coordinator.ingestLegacyStatus(status(watcher: true), now: now)
        coordinator.activate()
        expect(effect.startCount == 0, "unsafe status authorized effect")
        coordinator.deactivate(.user)
        expect(!requestExists(path), "cancel did not return legacy owner")
    }

    private static func testStartAndStopOrderingProtectsRequest() {
        let path = root(); defer { cleanup(path) }
        let effect = Effect(); effect.starts = [.started]; effect.stops = [.stopped]
        effect.onStart = {
            expect(requestExists(path), "request missing before native start")
        }
        effect.onStop = {
            expect(requestExists(path), "request removed before native stop")
        }
        let coordinator = make(path, effect: effect)
        acknowledge(coordinator)
        coordinator.activate()
        expect(coordinator.phase == .nativeActive, "effect did not activate")
        expect(requestExists(path), "active owner lost durable request")
        coordinator.deactivate(.pause)
        expect(effect.stopCount == 1, "pause did not stop effect exactly once")
        expect(!requestExists(path), "request survived confirmed stop")
        expect(coordinator.phase == .returnedToLegacy, "owner was not returned")
        expect(coordinator.lastDeactivationReason == .pause, "reason was lost")
    }

    private static func testNotStartedReturnsWithoutStop() {
        let path = root(); defer { cleanup(path) }
        let effect = Effect(); effect.starts = [.notStarted]
        let coordinator = make(path, effect: effect)
        acknowledge(coordinator)
        coordinator.activate()
        expect(effect.startCount == 1, "start was not attempted")
        expect(effect.stopCount == 0, "known-not-started effect was stopped")
        expect(!requestExists(path), "known start failure retained request")
        expect(coordinator.phase == .returnedToLegacy, "start failure did not return")
    }

    private static func testUncertainStartMustStopBeforeReturn() {
        let path = root(); defer { cleanup(path) }
        let effect = Effect()
        effect.starts = [.uncertain]
        effect.stops = [.uncertain, .stopped]
        let coordinator = make(path, effect: effect)
        acknowledge(coordinator)
        coordinator.activate()
        expect(coordinator.phase == .revocationRequired, "uncertain start was trusted")
        expect(requestExists(path), "uncertain effect returned legacy owner")
        expect(coordinator.holdsOwnerLease, "uncertain effect released process lock")
        coordinator.retryRevocation()
        expect(effect.stopCount == 2, "revocation retry count was wrong")
        expect(!requestExists(path), "confirmed retry did not return owner")
        expect(coordinator.phase == .returnedToLegacy, "retry did not finish")
    }

    private static func testUncertainActiveStopNeverReturnsEarly() {
        let path = root(); defer { cleanup(path) }
        let effect = Effect()
        effect.starts = [.started]
        effect.stops = [.uncertain, .stopped]
        let coordinator = make(path, effect: effect)
        acknowledge(coordinator)
        coordinator.activate()
        coordinator.deactivate(.terminate)
        expect(coordinator.phase == .revocationRequired, "uncertain stop was accepted")
        expect(requestExists(path), "terminate returned owner before stop proof")
        coordinator.retryRevocation()
        expect(!requestExists(path), "retry left request behind")
        expect(coordinator.lastDeactivationReason == .terminate, "terminate reason changed")
    }

    private static func testDuplicateActivationAndLateStatusAreIgnored() {
        let path = root(); defer { cleanup(path) }
        let effect = Effect(); effect.starts = [.started]; effect.stops = [.stopped]
        let coordinator = make(path, effect: effect)
        acknowledge(coordinator)
        coordinator.activate()
        coordinator.activate()
        coordinator.ingestLegacyStatus(status(watcher: true), now: now)
        expect(effect.startCount == 1, "duplicate activation restarted effect")
        expect(coordinator.phase == .nativeActive, "late status changed active owner")
        coordinator.deactivate(.user)
    }

    private static func testTimeoutAndStatusFailureNeverStartEffect() {
        let firstPath = root(); defer { cleanup(firstPath) }
        let firstEffect = Effect(); firstEffect.starts = [.started]
        let first = make(firstPath, effect: firstEffect)
        first.beginHandoff(); first.handoffTimedOut(); first.activate()
        expect(firstEffect.startCount == 0, "timeout started effect")
        expect(!requestExists(firstPath), "timeout kept request")

        let secondPath = root(); defer { cleanup(secondPath) }
        let secondEffect = Effect(); secondEffect.starts = [.started]
        let second = make(secondPath, effect: secondEffect)
        second.beginHandoff(); second.statusBecameUnavailable(); second.activate()
        expect(secondEffect.startCount == 0, "unavailable status started effect")
        expect(!requestExists(secondPath), "unavailable status kept request")
    }

    private static func testNativeOnlyUsesTheSameExclusiveLease() {
        let path = root(); defer { cleanup(path) }
        let effect = Effect(); effect.starts = [.started]; effect.stops = [.uncertain, .stopped]
        let coordinator = make(path, effect: effect)
        coordinator.beginHandoff(requiresLegacyAcknowledgement: false)
        expect(coordinator.phase == .readyToActivate, "clean install still waited for a legacy process")
        expect(requestExists(path), "native-only owner omitted the existing durable request")
        let other = make(path, effect: Effect())
        other.beginHandoff(requiresLegacyAcknowledgement: false)
        expect(other.phase == .busy, "native-only mode bypassed the process lock")
        coordinator.activate()
        expect(coordinator.phase == .nativeActive, "native-only activation failed")
        coordinator.deactivate(.pause)
        expect(coordinator.phase == .revocationRequired, "native-only uncertain stop was trusted")
        expect(requestExists(path), "native-only stop returned its request too early")
        coordinator.retryRevocation()
        expect(!requestExists(path), "native-only request survived confirmed stop")

        let deniedEffect = Effect(); deniedEffect.starts = [.notStarted]
        let denied = make(path, effect: deniedEffect)
        denied.beginHandoff(requiresLegacyAcknowledgement: false)
        denied.activate()
        expect(denied.phase == .returnedToLegacy, "failed environment recheck retained an active owner")
        expect(!requestExists(path), "failed native-only start leaked its request")
    }

    static func main() {
        testNativeOnlyUsesTheSameExclusiveLease()
        testEffectCannotStartBeforeExactYield()
        testStartAndStopOrderingProtectsRequest()
        testNotStartedReturnsWithoutStop()
        testUncertainStartMustStopBeforeReturn()
        testUncertainActiveStopNeverReturnsEarly()
        testDuplicateActivationAndLateStatusAreIgnored()
        testTimeoutAndStatusFailureNeverStartEffect()
        print("NativeOwnerActivationCoordinatorTests: \(passed) passed")
    }
}
#endif
