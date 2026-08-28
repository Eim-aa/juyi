#if DEBUG && JUYI_NATIVE_OWNER_HANDOFF_LAB
import Foundation

@main
@MainActor
enum NativeOwnerHandoffWorkflowTests {
    private static var passed = 0
    private static let epoch = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!
    private static let native = UUID(uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee")!
    private static let legacy = UUID(uuidString: "99999999-8888-7777-6666-555555555555")!
    private static let now: TimeInterval = 1_700_000_010

    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
        passed += 1
    }

    private static func root() -> String {
        let path = "/private/tmp/juyi-owner-workflow-\(UUID().uuidString)"
        precondition(mkdir(path, 0o700) == 0)
        return path
    }

    private static func status(
        ownerState: String = "yielded",
        epoch customEpoch: UUID = epoch,
        nativeInstance: UUID = native,
        watcher: Bool = false,
        activeRequest: Bool = false,
        popup: Bool = false,
        updatedAt: TimeInterval = now - 1
    ) -> Data {
        try! JSONSerialization.data(withJSONObject: [
            "module_loaded": true,
            "watcher_active": watcher,
            "active_request": activeRequest,
            "popup_visible": popup,
            "owner_protocol_version": 1,
            "legacy_instance_id": legacy.uuidString.lowercased(),
            "owner_state": ownerState,
            "owner_request_epoch": customEpoch.uuidString.lowercased(),
            "owner_request_native_instance_id": nativeInstance.uuidString.lowercased(),
            "status_sequence": 7,
            "updated_at": updatedAt,
        ], options: [.sortedKeys])
    }

    private static func make(_ path: String) -> NativeOwnerHandoffWorkflow {
        var identifiers = [native, epoch]
        return NativeOwnerHandoffWorkflow(
            store: NativeOwnerHandoffStore(directoryPath: path),
            makeUUID: {
                identifiers.isEmpty ? UUID() : identifiers.removeFirst()
            }
        )
    }

    private static func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    private static func testValidYieldAndExplicitReturn() {
        let path = root(); defer { cleanup(path) }
        let workflow = make(path)
        workflow.begin()
        expect(workflow.phase == .waitingForLegacy, "begin did not wait")
        expect(workflow.holdsCandidateLease, "candidate lease missing")
        workflow.ingestLegacyStatus(status(), now: now)
        expect(workflow.phase == .legacyYielded, "valid yield rejected")
        workflow.cancel()
        expect(workflow.phase == .returnedToLegacy, "cancel did not return")
        expect(workflow.returnReason == .cancelled, "cancel reason was lost")
        expect(!workflow.holdsCandidateLease, "lease survived return")
        expect(!FileManager.default.fileExists(atPath: path + "/owner-request.json"), "request survived return")
    }

    private static func testUnsafeSnapshotsNeverClaim() {
        let path = root(); defer { cleanup(path) }
        let workflow = make(path)
        workflow.begin()
        workflow.ingestLegacyStatus(nil, now: now)
        expect(workflow.phase == .waitingForLegacy, "missing status terminated early")
        expect(workflow.latestUnsafeReason == .statusMissing, "missing reason lost")
        workflow.ingestLegacyStatus(status(watcher: true), now: now)
        expect(workflow.phase == .waitingForLegacy, "active watcher was accepted")
        expect(workflow.latestUnsafeReason == .watcherStillActive, "watcher reason lost")
        workflow.ingestLegacyStatus(status(epoch: UUID()), now: now)
        expect(workflow.phase == .waitingForLegacy, "wrong epoch was accepted")
        workflow.timeOut()
        expect(workflow.phase == .returnedToLegacy, "timeout did not return")
        expect(workflow.returnReason == .timedOut, "timeout reason was lost")
    }

    private static func testCrashResidueRequiresRecoveryOnly() {
        let path = root(); defer { cleanup(path) }
        var first: NativeOwnerHandoffWorkflow? = make(path)
        first!.begin()
        first = nil
        let second = make(path)
        second.begin()
        expect(second.phase == .recoveryRequired, "residue was overwritten")
        second.recoverAndReturnToLegacy()
        expect(second.phase == .returnedToLegacy, "recovery did not return")
        expect(second.returnReason == .recoveredCrashResidue, "recovery reason lost")
        expect(!second.holdsCandidateLease, "recovery authorized candidate")
    }

    private static func testSecondProcessCapabilityIsBusy() {
        let path = root(); defer { cleanup(path) }
        let first = make(path); first.begin()
        let second = make(path); second.begin()
        expect(second.phase == .busy, "second workflow was not blocked")
        first.cancel()
        second.begin()
        expect(second.phase == .waitingForLegacy, "workflow could not retry after busy")
        second.cancel()
    }

    private static func testTerminalSnapshotsAreIgnored() {
        let path = root(); defer { cleanup(path) }
        let workflow = make(path); workflow.begin()
        workflow.ingestLegacyStatus(status(), now: now)
        workflow.ingestLegacyStatus(status(watcher: true), now: now)
        expect(workflow.phase == .legacyYielded, "late status revoked accepted yield")
        expect(workflow.latestUnsafeReason == nil, "late status mutated terminal")
        workflow.cancel()
        workflow.ingestLegacyStatus(status(), now: now)
        expect(workflow.phase == .returnedToLegacy, "late status reopened workflow")
    }

    static func main() {
        testValidYieldAndExplicitReturn()
        testUnsafeSnapshotsNeverClaim()
        testCrashResidueRequiresRecoveryOnly()
        testSecondProcessCapabilityIsBusy()
        testTerminalSnapshotsAreIgnored()
        print("NativeOwnerHandoffWorkflowTests: \(passed) passed")
    }
}
#endif
