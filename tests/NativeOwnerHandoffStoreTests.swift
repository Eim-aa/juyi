#if DEBUG && JUYI_NATIVE_OWNER_HANDOFF_LAB
import Darwin
import Foundation

@main
@MainActor
enum NativeOwnerHandoffStoreTests {
    private static var passed = 0

    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
        passed += 1
    }

    private static func temporaryRoot() -> String {
        let root = "/private/tmp/juyi-owner-store-\(UUID().uuidString)"
        precondition(mkdir(root, 0o700) == 0)
        return root
    }

    private static func removeRoot(_ root: String) {
        try? FileManager.default.removeItem(atPath: root)
    }

    private static func beginLease(
        _ store: NativeOwnerHandoffStore,
        instance: UUID = UUID(),
        epoch: UUID = UUID()
    ) -> NativeOwnerHandoffLease {
        guard case let .acquired(lease) = store.begin(
            nativeInstanceID: instance,
            epoch: epoch
        ) else { preconditionFailure("begin did not acquire") }
        return lease
    }

    private static func testPublishLockAndReturn() {
        let root = temporaryRoot()
        defer { removeRoot(root) }
        let store = NativeOwnerHandoffStore(directoryPath: root)
        let lease = beginLease(store)
        expect(lease.purpose == .activationCandidate, "wrong lease purpose")
        expect(!lease.description.contains(lease.request.epoch), "description leaked epoch")
        let requestPath = root + "/owner-request.json"
        let data = try! Data(contentsOf: URL(fileURLWithPath: requestPath))
        expect(NativeOwnerHandoffProtocol.decodeCanonicalRequest(data) == lease.request, "request was not canonical")
        var requestStat = stat()
        expect(lstat(requestPath, &requestStat) == 0, "request missing")
        expect((requestStat.st_mode & 0o777) == 0o600, "request mode is not 0600")
        var lockStat = stat()
        expect(lstat(root + "/native-owner.lock", &lockStat) == 0, "lock missing")
        expect((lockStat.st_mode & 0o777) == 0o600, "lock mode is not 0600")

        let contender = NativeOwnerHandoffStore(directoryPath: root)
        if case .busy = contender.begin(nativeInstanceID: UUID(), epoch: UUID()) {
            passed += 1
        } else { preconditionFailure("second native process was not blocked") }
        expect(store.returnToLegacy(lease), "return to legacy failed")
        expect(!FileManager.default.fileExists(atPath: requestPath), "request survived return")
        expect(FileManager.default.fileExists(atPath: root + "/native-owner.lock"), "stable lock was unlinked")
    }

    private static func testCrashLeavesRecoveryOnlyPath() {
        let root = temporaryRoot()
        defer { removeRoot(root) }
        let store = NativeOwnerHandoffStore(directoryPath: root)
        let lease = beginLease(store)
        lease.releasePreservingRequest()
        if case .recoveryRequired = store.begin(nativeInstanceID: UUID(), epoch: UUID()) {
            passed += 1
        } else { preconditionFailure("crash residue was overwritten") }
        guard case let .acquired(recovery) = store.recoverForReturnToLegacy() else {
            preconditionFailure("canonical recovery request rejected")
        }
        expect(recovery.purpose == .recoveryOnly, "recovery authorized activation")
        expect(store.returnToLegacy(recovery), "recovery removal failed")
        if case .absent = store.recoverForReturnToLegacy() {
            passed += 1
        } else { preconditionFailure("removed request still present") }
    }

    private static func testLockExcludesAnotherProcess() {
        let root = temporaryRoot()
        defer { removeRoot(root) }
        let lease = beginLease(NativeOwnerHandoffStore(directoryPath: root))
        let child = Process()
        child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0])
        child.arguments = ["--probe-lock", root]
        try! child.run()
        child.waitUntilExit()
        expect(child.terminationStatus == 0, "cross-process lock was not exclusive")
        expect(NativeOwnerHandoffStore(directoryPath: root).returnToLegacy(lease), "return after child failed")
    }

    private static func testMalformedAndSymlinkFailClosed() {
        let root = temporaryRoot()
        defer { removeRoot(root) }
        let path = root + "/owner-request.json"
        expect(FileManager.default.createFile(atPath: path, contents: Data("{}\n".utf8)), "fixture write failed")
        expect(chmod(path, 0o600) == 0, "fixture chmod failed")
        let store = NativeOwnerHandoffStore(directoryPath: root)
        if case .unavailable = store.recoverForReturnToLegacy() {
            passed += 1
        } else { preconditionFailure("malformed request accepted") }
        expect(unlink(path) == 0, "fixture unlink failed")
        expect(symlink("/dev/null", path) == 0, "symlink fixture failed")
        if case .unavailable = store.begin(nativeInstanceID: UUID(), epoch: UUID()) {
            passed += 1
        } else { preconditionFailure("request symlink accepted") }
    }

    private static func testUnsafeDirectoryAndLockFailClosed() {
        let root = temporaryRoot()
        defer { removeRoot(root) }
        expect(chmod(root, 0o755) == 0, "directory chmod failed")
        let store = NativeOwnerHandoffStore(directoryPath: root)
        if case .unavailable = store.begin(nativeInstanceID: UUID(), epoch: UUID()) {
            passed += 1
        } else { preconditionFailure("world-readable directory accepted") }
        expect(chmod(root, 0o700) == 0, "directory restore failed")
        expect(symlink("/dev/null", root + "/native-owner.lock") == 0, "lock symlink failed")
        if case .unavailable = store.begin(nativeInstanceID: UUID(), epoch: UUID()) {
            passed += 1
        } else { preconditionFailure("lock symlink accepted") }
    }

    private static func testStaleTemporaryDoesNotBlock() {
        let root = temporaryRoot()
        defer { removeRoot(root) }
        let stale = root + "/.owner-request.stale.tmp"
        expect(FileManager.default.createFile(atPath: stale, contents: Data("partial".utf8)), "stale temp write failed")
        expect(chmod(stale, 0o600) == 0, "stale temp chmod failed")
        let store = NativeOwnerHandoffStore(directoryPath: root)
        let lease = beginLease(store)
        expect(FileManager.default.fileExists(atPath: stale), "store mutated unrelated stale temp")
        expect(store.returnToLegacy(lease), "return after stale temp failed")
    }

    static func main() {
        if CommandLine.arguments.count == 3,
           CommandLine.arguments[1] == "--probe-lock" {
            let contender = NativeOwnerHandoffStore(
                directoryPath: CommandLine.arguments[2]
            )
            if case .busy = contender.recoverForReturnToLegacy() {
                exit(0)
            }
            exit(1)
        }
        testPublishLockAndReturn()
        testCrashLeavesRecoveryOnlyPath()
        testLockExcludesAnotherProcess()
        testMalformedAndSymlinkFailClosed()
        testUnsafeDirectoryAndLockFailClosed()
        testStaleTemporaryDoesNotBlock()
        print("NativeOwnerHandoffStoreTests: \(passed) passed")
    }
}
#endif
