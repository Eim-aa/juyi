import Foundation

@main
@MainActor
enum NativeOptionMonitorTests {
    private final class Token {}

    private final class FakeEventSource: NativeOptionEventSource {
        var optionIsCurrentlyDown = false
        var shouldFailInstall = false
        private(set) var installCount = 0
        private(set) var removeCount = 0
        private var handler: ((NativeOptionEventSnapshot) -> Void)?

        func addGlobalMonitor(
            handler: @escaping (NativeOptionEventSnapshot) -> Void
        ) -> Any? {
            installCount += 1
            guard !shouldFailInstall else { return nil }
            self.handler = handler
            return Token()
        }

        func removeMonitor(_ monitor: Any) {
            removeCount += 1
            handler = nil
        }

        func emit(_ event: NativeOptionEventSnapshot) {
            handler?(event)
        }
    }

    private final class AuthorizationBox {
        var status: AccessibilityAuthorizationStatus = .authorized
        private(set) var readCount = 0

        func read() -> AccessibilityAuthorizationStatus {
            readCount += 1
            return status
        }
    }

    private final class FrontmostBox {
        var target: NativeSelectionTarget?

        init(_ target: NativeSelectionTarget?) {
            self.target = target
        }
    }

    private final class Scheduler {
        private(set) var delays: [TimeInterval] = []
        private var actions: [() -> Void] = []

        func schedule(delay: TimeInterval, action: @escaping () -> Void) {
            delays.append(delay)
            actions.append(action)
        }

        var count: Int { actions.count }

        func run(_ index: Int) {
            actions[index]()
        }
    }

    private final class ActionScheduler {
        private var actions: [() -> Void] = []

        func schedule(_ action: @escaping () -> Void) {
            actions.append(action)
        }

        var count: Int { actions.count }

        func run(_ index: Int) {
            actions[index]()
        }
    }

    private static let editor = NativeSelectionTarget(
        processIdentifier: 200,
        bundleIdentifier: "com.example.editor"
    )
    private static let juyi = NativeSelectionTarget(
        processIdentifier: 100,
        bundleIdentifier: "io.github.Eim-aa.Juyi"
    )
    private static var passed = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
            exit(1)
        }
        passed += 1
    }

    private static func snapshot(
        _ kind: NativeOptionEventSnapshot.Kind,
        keyCode: UInt16,
        modifiers: DoubleOptionStateMachine.Modifiers,
        at timestamp: TimeInterval
    ) -> NativeOptionEventSnapshot {
        NativeOptionEventSnapshot(
            kind: kind,
            keyCode: keyCode,
            modifiers: modifiers,
            timestamp: timestamp,
            isAutoRepeat: false
        )
    }

    private static func emitTap(
        _ source: FakeEventSource,
        keyCode: UInt16,
        down: TimeInterval,
        up: TimeInterval
    ) {
        source.emit(
            snapshot(.flagsChanged, keyCode: keyCode, modifiers: [.option], at: down)
        )
        source.emit(
            snapshot(.flagsChanged, keyCode: keyCode, modifiers: [], at: up)
        )
    }

    private static func makeMonitor(
        source: FakeEventSource,
        authorization: AuthorizationBox,
        frontmost: FrontmostBox,
        scheduler: Scheduler,
        invalidated: @escaping () -> Void = {},
        received: @escaping (NativeSelectionTarget) -> Void
    ) -> NativeOptionMonitor {
        NativeOptionMonitor(
            eventSource: source,
            accessibilityStatus: { authorization.read() },
            frontmostApplication: { frontmost.target },
            currentProcessIdentifier: 100,
            deliveryScheduler: { delay, action in
                scheduler.schedule(delay: delay, action: action)
            },
            recognitionInvalidationHandler: invalidated,
            recognitionHandler: received
        )
    }

    private static func testPermissionAndInstallFailures() {
        let deniedSource = FakeEventSource()
        let deniedAuthorization = AuthorizationBox()
        deniedAuthorization.status = .notAuthorized
        let deniedMonitor = makeMonitor(
            source: deniedSource,
            authorization: deniedAuthorization,
            frontmost: FrontmostBox(editor),
            scheduler: Scheduler(),
            received: { _ in }
        )
        expect(deniedMonitor.start() == .accessibilityRequired, "trust is required")
        expect(deniedSource.installCount == 0, "denied start installs no monitor")

        let failedSource = FakeEventSource()
        failedSource.shouldFailInstall = true
        let failedMonitor = makeMonitor(
            source: failedSource,
            authorization: AuthorizationBox(),
            frontmost: FrontmostBox(editor),
            scheduler: Scheduler(),
            received: { _ in }
        )
        expect(failedMonitor.start() == .monitorUnavailable, "install failure is distinct")
        expect(!failedMonitor.isRunning, "failed installation is not reported active")
    }

    private static func testStartStopAndPauseAreIdempotent() {
        let source = FakeEventSource()
        let authorization = AuthorizationBox()
        let scheduler = Scheduler()
        var received: [NativeSelectionTarget] = []
        let monitor = makeMonitor(
            source: source,
            authorization: authorization,
            frontmost: FrontmostBox(editor),
            scheduler: scheduler,
            received: { received.append($0) }
        )

        expect(monitor.start() == .started, "first start installs")
        emitTap(source, keyCode: 58, down: 0, up: 0.05)
        expect(monitor.start() == .alreadyRunning, "duplicate start is idempotent")
        expect(source.installCount == 1, "duplicate start does not reinstall")
        emitTap(source, keyCode: 61, down: 0.10, up: 0.15)
        expect(scheduler.count == 1, "duplicate start preserves an in-flight gesture")

        monitor.setPaused(true)
        monitor.setPaused(true)
        scheduler.run(0)
        expect(received.isEmpty, "pause invalidates pending delivery")
        monitor.setPaused(false)
        monitor.setPaused(false)
        emitTap(source, keyCode: 58, down: 0.20, up: 0.25)
        emitTap(source, keyCode: 61, down: 0.30, up: 0.35)
        expect(scheduler.count == 2, "resume recognizes from a clean state")
        scheduler.run(1)
        expect(received == [editor], "idempotent resume does not cancel new work")

        monitor.stop()
        monitor.stop()
        expect(source.removeCount == 1, "monitor token is removed exactly once")
        expect(!monitor.isRunning, "stop clears active state")
    }

    private static func testStartupHeldOptionAndLatestGeneration() {
        let source = FakeEventSource()
        source.optionIsCurrentlyDown = true
        let authorization = AuthorizationBox()
        let scheduler = Scheduler()
        var received: [NativeSelectionTarget] = []
        let monitor = makeMonitor(
            source: source,
            authorization: authorization,
            frontmost: FrontmostBox(editor),
            scheduler: scheduler,
            received: { received.append($0) }
        )
        expect(monitor.start() == .started, "held-Option monitor starts")
        source.emit(snapshot(.flagsChanged, keyCode: 58, modifiers: [], at: 0.05))
        emitTap(source, keyCode: 58, down: 0.10, up: 0.15)
        emitTap(source, keyCode: 61, down: 0.20, up: 0.25)
        expect(scheduler.count == 1, "startup release cannot become a first tap")

        emitTap(source, keyCode: 58, down: 0.30, up: 0.35)
        emitTap(source, keyCode: 61, down: 0.40, up: 0.45)
        expect(scheduler.count == 2, "a second pair schedules newer work")
        scheduler.run(0)
        scheduler.run(1)
        expect(received == [editor], "new trigger cancels the older generation")
        monitor.stop()
    }

    private static func testRevocationAndExplicitRecovery() {
        let source = FakeEventSource()
        let authorization = AuthorizationBox()
        let scheduler = Scheduler()
        var received = 0
        let monitor = makeMonitor(
            source: source,
            authorization: authorization,
            frontmost: FrontmostBox(editor),
            scheduler: scheduler,
            received: { _ in received += 1 }
        )
        _ = monitor.start()
        let readsAfterStart = authorization.readCount
        emitTap(source, keyCode: 58, down: 0, up: 0.05)
        emitTap(source, keyCode: 61, down: 0.10, up: 0.15)
        expect(
            authorization.readCount == readsAfterStart,
            "NSEvent handler performs no AX trust or selection call"
        )

        authorization.status = .notAuthorized
        expect(!monitor.refreshAuthorizationStatus(), "revocation is detected at lifecycle boundary")
        expect(source.removeCount == 1, "revocation removes the global token")
        scheduler.run(0)
        expect(received == 0, "revocation invalidates queued delivery")

        authorization.status = .authorized
        expect(monitor.refreshAuthorizationStatus(), "restored trust is observable")
        expect(!monitor.isRunning, "trust alone never claims the monitor is active")
        expect(monitor.start() == .started, "explicit start rebuilds after restored trust")
        expect(source.installCount == 2, "recovery performs a fresh installation")
        monitor.stop()
    }

    private static func testOwnPIDAndFocusRaceFailClosed() {
        let ownSource = FakeEventSource()
        let ownScheduler = Scheduler()
        let ownMonitor = makeMonitor(
            source: ownSource,
            authorization: AuthorizationBox(),
            frontmost: FrontmostBox(juyi),
            scheduler: ownScheduler,
            received: { _ in }
        )
        _ = ownMonitor.start()
        emitTap(ownSource, keyCode: 58, down: 0, up: 0.05)
        emitTap(ownSource, keyCode: 61, down: 0.10, up: 0.15)
        expect(ownScheduler.count == 0, "own PID never schedules capture")
        ownMonitor.stop()

        let raceSource = FakeEventSource()
        let raceScheduler = Scheduler()
        let frontmost = FrontmostBox(editor)
        var received = 0
        let raceMonitor = makeMonitor(
            source: raceSource,
            authorization: AuthorizationBox(),
            frontmost: frontmost,
            scheduler: raceScheduler,
            received: { _ in received += 1 }
        )
        _ = raceMonitor.start()
        emitTap(raceSource, keyCode: 58, down: 0, up: 0.05)
        emitTap(raceSource, keyCode: 61, down: 0.10, up: 0.15)
        frontmost.target = NativeSelectionTarget(
            processIdentifier: 300,
            bundleIdentifier: "com.apple.systempreferences"
        )
        raceScheduler.run(0)
        expect(received == 0, "frontmost PID race cancels delivery")
        raceMonitor.stop()
    }

    private static func testNewRecognitionInvalidatesAXEvenWhenDeliveryFails() {
        let source = FakeEventSource()
        let authorization = AuthorizationBox()
        let frontmost = FrontmostBox(editor)
        let delivery = Scheduler()
        let worker = ActionScheduler()
        let completion = ActionScheduler()
        var lastResult: NativeSelectionResult?
        var monitor: NativeOptionMonitor!

        let coordinator = NativeSelectionCaptureCoordinator(
            reader: { _ in
                // Recognition 2 occurs while recognition 1 is inside AX.
                emitTap(source, keyCode: 58, down: 0.20, up: 0.25)
                emitTap(source, keyCode: 61, down: 0.30, up: 0.35)
                frontmost.target = NativeSelectionTarget(
                    processIdentifier: 300,
                    bundleIdentifier: "com.example.other"
                )
                return .success(text: "stale sensitive text", didTruncate: false)
            },
            workScheduler: worker.schedule,
            completionScheduler: completion.schedule
        )
        monitor = makeMonitor(
            source: source,
            authorization: authorization,
            frontmost: frontmost,
            scheduler: delivery,
            invalidated: {
                coordinator.cancelAll()
                lastResult = nil
            },
            received: { target in
                coordinator.capture(target: target) { lastResult = $0 }
            }
        )

        _ = monitor.start()
        emitTap(source, keyCode: 58, down: 0, up: 0.05)
        emitTap(source, keyCode: 61, down: 0.10, up: 0.15)
        delivery.run(0)
        expect(worker.count == 1, "first recognition starts one deferred AX capture")
        worker.run(0)
        expect(
            completion.count == 0,
            "second recognition cancels the AX result before it reaches main"
        )
        expect(lastResult == nil, "stale selected text is not retained")
        expect(delivery.count == 2, "second recognition reached delayed identity gate")
        delivery.run(1)
        expect(lastResult == nil, "failed new delivery cannot revive the old result")
        monitor.stop()
    }

    static func main() {
        testPermissionAndInstallFailures()
        testStartStopAndPauseAreIdempotent()
        testStartupHeldOptionAndLatestGeneration()
        testRevocationAndExplicitRecovery()
        testOwnPIDAndFocusRaceFailClosed()
        testNewRecognitionInvalidatesAXEvenWhenDeliveryFails()
        print("NativeOptionMonitorTests: \(passed) passed")
    }
}
