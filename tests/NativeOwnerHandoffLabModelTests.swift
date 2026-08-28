#if DEBUG && JUYI_NATIVE_OWNER_HANDOFF_LAB
import Foundation

@main
@MainActor
enum NativeOwnerHandoffLabModelTests {
    private final class Reader: NativeOwnerHandoffStatusReading {
        var snapshots: [NativeOwnerHandoffStatusReader.Snapshot] = []
        var reads = 0
        func read() -> NativeOwnerHandoffStatusReader.Snapshot {
            reads += 1
            return snapshots.isEmpty ? .absent : snapshots.removeFirst()
        }
    }

    @MainActor
    private final class Token: NativeOwnerHandoffLabCancellation {
        var cancelled = false
        let action: @MainActor @Sendable () -> Void
        init(action: @escaping @MainActor @Sendable () -> Void) { self.action = action }
        func cancel() { cancelled = true }
        func fire(ignoreCancellation: Bool = false) {
            if ignoreCancellation || !cancelled { action() }
        }
    }

    @MainActor
    private final class Clock {
        var monotonic: TimeInterval = 100
        var wall: TimeInterval = 1_700_000_010
        var tokens: [Token] = []
        func schedule(
            _ delay: TimeInterval,
            _ action: @escaping @MainActor @Sendable () -> Void
        ) -> NativeOwnerHandoffLabCancellation {
            precondition(delay >= 0 && delay <= 0.2)
            let token = Token(action: action)
            tokens.append(token)
            return token
        }
    }

    private static var passed = 0
    private static let native = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private static let epoch = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
        passed += 1
    }

    private static func root() -> String {
        "/private/tmp/juyi-owner-lab-\(UUID().uuidString)"
    }

    private static func status() -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "module_loaded": true,
            "watcher_active": false,
            "active_request": false,
            "popup_visible": false,
            "owner_protocol_version": 1,
            "legacy_instance_id": "99999999-8888-7777-6666-555555555555",
            "owner_state": "yielded",
            "owner_request_epoch": epoch.uuidString.lowercased(),
            "owner_request_native_instance_id": native.uuidString.lowercased(),
            "status_sequence": 9,
            "updated_at": 1_700_000_009,
        ], options: [.sortedKeys])
    }

    private static func make(
        path: String,
        reader: Reader,
        clock: Clock
    ) -> NativeOwnerHandoffLabModel {
        var identifiers = [native, epoch]
        let workflow = NativeOwnerHandoffWorkflow(
            store: NativeOwnerHandoffStore(directoryPath: path),
            makeUUID: { identifiers.isEmpty ? UUID() : identifiers.removeFirst() }
        )
        return NativeOwnerHandoffLabModel(
            dependencies: .init(
                workflow: workflow,
                statusReader: reader,
                monotonicNow: { clock.monotonic },
                wallNow: { clock.wall },
                schedule: { delay, action in clock.schedule(delay, action) }
            )
        )
    }

    private static func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private static func testOpenIsZeroIOAndExplicitStartYields() {
        let path = root(); defer { cleanup(path) }
        let reader = Reader(), clock = Clock()
        let model = make(path: path, reader: reader, clock: clock)
        model.open()
        expect(model.isPresented && model.phase == .disclosure, "open did not disclose")
        expect(reader.reads == 0, "open read status")
        expect(!FileManager.default.fileExists(atPath: path), "open created owner directory")
        model.start()
        expect(model.phase == .waiting, "start did not wait")
        expect(reader.reads == 1, "start did not read exactly once")
        reader.snapshots = [.present(status())]
        clock.monotonic += 0.2
        clock.wall += 0.2
        clock.tokens.removeFirst().fire()
        expect(model.phase == .legacyYielded, "safe ack did not yield")
        expect(model.statusHint.contains("原生 monitor 仍未启动"), "yield overclaimed activation")
        model.returnToLegacy()
        guard case .returned(.cancelled) = model.phase else {
            preconditionFailure("explicit return lost reason")
        }
    }

    private static func testMonotonicTimeoutReturnsRequest() {
        let path = root(); defer { cleanup(path) }
        let reader = Reader(), clock = Clock()
        let model = make(path: path, reader: reader, clock: clock)
        model.open(); model.start()
        clock.monotonic += 5
        clock.wall -= 500
        clock.tokens.removeFirst().fire()
        guard case .returned(.timedOut) = model.phase else {
            preconditionFailure("monotonic timeout did not return")
        }
        expect(!FileManager.default.fileExists(atPath: path + "/owner-request.json"), "timeout left request")
    }

    private static func testUnavailableStatusFailsClosedAndReturns() {
        let path = root(); defer { cleanup(path) }
        let reader = Reader(), clock = Clock()
        reader.snapshots = [.unavailable]
        let model = make(path: path, reader: reader, clock: clock)
        model.open(); model.start()
        expect(model.phase == .unavailable, "unavailable status kept waiting")
        expect(!FileManager.default.fileExists(atPath: path + "/owner-request.json"), "unavailable status left request")
    }

    private static func testCloseCancelsAndLatePollCannotReopen() {
        let path = root(); defer { cleanup(path) }
        let reader = Reader(), clock = Clock()
        let model = make(path: path, reader: reader, clock: clock)
        model.open(); model.start()
        let late = clock.tokens.removeFirst()
        model.close()
        expect(!model.isPresented, "close did not hide")
        let reads = reader.reads
        reader.snapshots = [.present(status())]
        late.fire(ignoreCancellation: true)
        expect(reader.reads == reads, "stale poll read status")
        expect(!FileManager.default.fileExists(atPath: path + "/owner-request.json"), "close left request")
    }

    private static func testLifecycleReturnsYieldedLease() {
        let path = root(); defer { cleanup(path) }
        let reader = Reader(), clock = Clock()
        reader.snapshots = [.present(status())]
        let model = make(path: path, reader: reader, clock: clock)
        model.open(); model.start()
        expect(model.phase == .legacyYielded, "immediate yield failed")
        model.invalidate(.sleep)
        guard case .returned(.cancelled) = model.phase else {
            preconditionFailure("sleep did not return")
        }
        expect(!FileManager.default.fileExists(atPath: path + "/owner-request.json"), "sleep left request")
    }

    private static func testRecoveryNeverCreatesCandidate() {
        let path = root(); defer { cleanup(path) }
        let store = NativeOwnerHandoffStore(directoryPath: path)
        guard case let .acquired(lease) = store.begin(
            nativeInstanceID: UUID(), epoch: UUID()
        ) else { preconditionFailure("fixture begin failed") }
        lease.releasePreservingRequest()
        let reader = Reader(), clock = Clock()
        let model = make(path: path, reader: reader, clock: clock)
        model.open(); model.start()
        expect(model.phase == .recoveryRequired, "residue was not detected")
        expect(reader.reads == 0, "recovery read legacy status")
        model.recoverAndReturnToLegacy()
        guard case .returned(.recoveredCrashResidue) = model.phase else {
            preconditionFailure("recovery did not return")
        }
    }

    static func main() {
        testOpenIsZeroIOAndExplicitStartYields()
        testMonotonicTimeoutReturnsRequest()
        testUnavailableStatusFailsClosedAndReturns()
        testCloseCancelsAndLatePollCannotReopen()
        testLifecycleReturnsYieldedLease()
        testRecoveryNeverCreatesCandidate()
        print("NativeOwnerHandoffLabModelTests: \(passed) passed")
    }
}
#endif
