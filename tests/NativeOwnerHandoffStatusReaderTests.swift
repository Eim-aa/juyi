#if DEBUG && JUYI_NATIVE_OWNER_HANDOFF_LAB
import Darwin
import Foundation

@main
@MainActor
enum NativeOwnerHandoffStatusReaderTests {
    private static var passed = 0

    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message)
        passed += 1
    }

    private static func root() -> String {
        let path = "/private/tmp/juyi-owner-status-\(UUID().uuidString)"
        precondition(mkdir(path, 0o700) == 0)
        return path
    }

    private static func cleanup(_ path: String) {
        try? FileManager.default.removeItem(atPath: path)
    }

    @discardableResult
    private static func write(
        _ data: Data,
        to path: String,
        mode: mode_t = 0o600
    ) -> Bool {
        let ok = FileManager.default.createFile(atPath: path, contents: data)
        return ok && chmod(path, mode) == 0
    }

    private static func testAbsentAndExactSnapshot() {
        let path = root(); defer { cleanup(path) }
        let reader = NativeOwnerHandoffStatusReader(directoryPath: path)
        expect(reader.read() == .absent, "missing status was not absent")
        let payload = Data("{\"module_loaded\":true}\n".utf8)
        expect(write(payload, to: path + "/hs-status.json"), "status write failed")
        expect(reader.read() == .present(payload), "0600 status changed")
        expect(chmod(path + "/hs-status.json", 0o644) == 0, "chmod failed")
        expect(reader.read() == .present(payload), "read-only 0644 status rejected")
    }

    private static func testUnsafeEnvelopeFailsClosed() {
        let path = root(); defer { cleanup(path) }
        let file = path + "/hs-status.json"
        let reader = NativeOwnerHandoffStatusReader(directoryPath: path)
        expect(write(Data(), to: file), "empty fixture failed")
        expect(reader.read() == .unavailable, "empty status accepted")
        expect(unlink(file) == 0, "empty unlink failed")
        expect(write(Data(repeating: 0x20, count: 4_097), to: file), "large fixture failed")
        expect(reader.read() == .unavailable, "oversized status accepted")
        expect(chmod(file, 0o666) == 0, "unsafe chmod failed")
        expect(reader.read() == .unavailable, "writable status accepted")
    }

    private static func testSymlinkHardlinkAndDirectoryFailClosed() {
        let path = root(); defer { cleanup(path) }
        let file = path + "/hs-status.json"
        let reader = NativeOwnerHandoffStatusReader(directoryPath: path)
        expect(symlink("/dev/null", file) == 0, "symlink fixture failed")
        expect(reader.read() == .unavailable, "status symlink accepted")
        expect(unlink(file) == 0, "symlink unlink failed")
        let other = path + "/other"
        expect(write(Data("{}\n".utf8), to: other), "hardlink source failed")
        expect(link(other, file) == 0, "hardlink fixture failed")
        expect(reader.read() == .unavailable, "hardlinked status accepted")
        expect(unlink(file) == 0 && unlink(other) == 0, "hardlinks unlink failed")
        expect(chmod(path, 0o755) == 0, "directory chmod failed")
        expect(reader.read() == .unavailable, "nonprivate directory accepted")
    }

    private static func testProtocolConsumesUnchangedBytes() {
        let path = root(); defer { cleanup(path) }
        let request = NativeOwnerHandoffProtocol.makeRequest(
            nativeInstanceID: UUID(), epoch: UUID()
        )
        let payload = try! JSONSerialization.data(withJSONObject: [
            "module_loaded": true,
            "watcher_active": false,
            "active_request": false,
            "popup_visible": false,
            "owner_protocol_version": 1,
            "legacy_instance_id": UUID().uuidString.lowercased(),
            "owner_state": "yielded",
            "owner_request_epoch": request.epoch,
            "owner_request_native_instance_id": request.nativeInstanceID,
            "status_sequence": 1,
            "updated_at": 1_700_000_000,
        ], options: [.sortedKeys])
        expect(write(payload, to: path + "/hs-status.json"), "valid fixture failed")
        guard case let .present(read) = NativeOwnerHandoffStatusReader(
            directoryPath: path
        ).read() else { preconditionFailure("valid status unavailable") }
        expect(read == payload, "reader rewrote status")
        if case .safeToClaim = NativeOwnerHandoffProtocol.evaluate(
            request: request,
            statusData: read,
            now: 1_700_000_001
        ) { passed += 1 } else { preconditionFailure("unchanged status rejected") }
    }

    private static func testCleanInstallRequiresProvenAbsence() {
        let path = root(); defer { cleanup(path) }
        expect(!NativeOwnerHandoffStatusReader.legacyArtifactsMayExist(homePath: path), "clean home required a companion")
        expect(symlink("missing-target", path + "/.hammerspoon") == 0, "link creation failed")
        expect(NativeOwnerHandoffStatusReader.legacyArtifactsMayExist(homePath: path), "dangling legacy config was treated as clean")
        expect(unlink(path + "/.hammerspoon") == 0, "link cleanup failed")
        try! FileManager.default.createDirectory(atPath: path + "/.config/argos-translator", withIntermediateDirectories: true)
        expect(write(Data("old status".utf8), to: path + "/.config/argos-translator/hs-status.json"), "status creation failed")
        expect(NativeOwnerHandoffStatusReader.legacyArtifactsMayExist(homePath: path), "malformed old status bypassed handoff")
        expect(NativeOwnerHandoffStatusReader.legacyArtifactsMayExist(homePath: "relative"), "invalid home was treated as clean")
    }

    static func main() {
        testCleanInstallRequiresProvenAbsence()
        testAbsentAndExactSnapshot()
        testUnsafeEnvelopeFailsClosed()
        testSymlinkHardlinkAndDirectoryFailClosed()
        testProtocolConsumesUnchangedBytes()
        print("NativeOwnerHandoffStatusReaderTests: \(passed) passed")
    }
}
#endif
