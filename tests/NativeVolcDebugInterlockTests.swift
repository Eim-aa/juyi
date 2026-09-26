#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER
import Darwin
import Foundation

private final class NativeVolcManualInterlockClock: @unchecked Sendable {
    private let lock = NSLock()
    private let origin = ContinuousClock().now
    private var offset: Duration = .zero

    var client: NativeVolcDebugInterlockClock {
        NativeVolcDebugInterlockClock(
            now: { [weak self] in self?.instant ?? ContinuousClock().now },
            sleep: { [weak self] duration in self?.advance(duration) }
        )
    }

    private var instant: ContinuousClock.Instant {
        lock.withLock { origin.advanced(by: offset) }
    }

    private func advance(_ duration: Duration) {
        lock.withLock { offset += duration }
    }
}

@main
@MainActor
enum NativeVolcDebugInterlockTests {
    private static var passed = 0

    static func main() async {
        await testReaderAndRemovalTurnstile()
        await testRemovalOwnerRejectsConcurrentWriter()
        await testPromotionLeaseIsSeparateFromRemoval()
        await testCrashResume()
        await testEpochRotationIgnoresCrashTemporary()
        await testMalformedObjectsFailClosed()
        await testUnsafeDirectoryFailsClosed()
        print("NativeVolcDebugInterlockTests: \(passed) passed")
    }

    private static func expect(
        _ condition: Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard condition else { fatalError("\(message) (\(file):\(line))") }
        passed += 1
    }

    private static func testReaderAndRemovalTurnstile() async {
        await withTemporaryRoot { base, root in
            let manual = NativeVolcManualInterlockClock()
            let interlock = NativeVolcDebugInterlock(rootPath: root, clock: manual.client)
            expect(await interlock.inspectWithoutCredentials() == .absent,
                   "explicit inspect prepares an empty private directory")
            expect(mode(of: root) == 0o700, "Debug interlock directory is 0700")

            guard case let .acquired(reader) = await interlock.beginReader() else {
                fatalError("reader should acquire")
            }
            expect(reader.hasGate && reader.hasTransport, "reader starts with both shared locks")
            expect(await interlock.revalidate(reader), "reader validates before request resume")
            reader.releaseGate()
            expect(!reader.hasGate && reader.hasTransport, "resume releases gate only")
            expect(await interlock.revalidate(reader) == false,
                   "revalidation is forbidden after gate release")

            guard case let .acquired(writer) = await interlock.beginWriterPhaseA() else {
                fatalError("writer should cross gate after reader resume")
            }
            expect(await interlock.inspectWithoutCredentials() == .present,
                   "durable writer intent blocks new work")
            if case .blocked = await interlock.beginReader() {
                expect(true, "new reader is blocked after writer intent")
            } else {
                expect(false, "new reader must not pass writer intent")
            }
            expect(
                await interlock.acquireWriterTransport(writer, timeout: .milliseconds(50)) == false,
                "writer cannot self-steal an in-flight reader transport lease"
            )
            reader.releaseTransport()
            expect(await interlock.acquireWriterTransport(writer),
                   "writer acquires transport after didComplete-style release")
            expect(await interlock.finishWriterSuccess(writer),
                   "successful writer removes marker and intent durably")
            expect(await interlock.inspectWithoutCredentials() == .absent,
                   "successful removal reopens the turnstile")
            expect(fileExists(root + "/" + NativeVolcDebugInterlockConstants.requestGate),
                   "request gate is stable and never unlinked")
            expect(fileExists(root + "/" + NativeVolcDebugInterlockConstants.transportLock),
                   "transport lock is stable and never unlinked")
            _ = base
        }
    }

    private static func testCrashResume() async {
        await withTemporaryRoot { _, root in
            let interlock = NativeVolcDebugInterlock(rootPath: root)
            guard case let .acquired(abandoned) = await interlock.beginWriterPhaseA() else {
                fatalError("writer should acquire")
            }
            abandoned.release()
            expect(await interlock.inspectWithoutCredentials() == .present,
                   "abandoned marker remains fail closed")
            guard case let .acquired(resumed) = await interlock.resumeWriterPhaseA() else {
                fatalError("valid durable writer state should resume")
            }
            expect(await interlock.acquireWriterTransport(resumed), "resumed writer gets transport")
            expect(await interlock.finishWriterSuccess(resumed), "resumed writer completes cleanup")
        }
    }

    private static func testRemovalOwnerRejectsConcurrentWriter() async {
        await withTemporaryRoot { _, root in
            let first = NativeVolcDebugInterlock(rootPath: root)
            let second = NativeVolcDebugInterlock(rootPath: root)
            guard case let .acquired(reader) = await first.beginReader() else {
                fatalError("seed shared request gate")
            }
            let firstWriter = Task { await first.beginWriterPhaseA() }
            while await first.inspectWithoutCredentials() != .present { await Task.yield() }
            if case .unavailable = await second.resumeWriterPhaseA() {
                expect(true, "second writer cannot queue behind an existing removal owner")
            } else {
                expect(false, "concurrent writer must lose without a lease")
            }
            reader.releaseGate()
            guard case let .acquired(writer) = await firstWriter.value else {
                fatalError("first writer should acquire after the old reader resumes")
            }
            reader.releaseTransport()
            expect(await first.acquireWriterTransport(writer),
                   "first owner acquires transport after reader completion")
            expect(await first.finishWriterSuccess(writer), "first owner completes removal")
            expect(await second.inspectWithoutCredentials() == .absent,
                   "losing writer cannot recreate marker after completion")
            expect(fileExists(root + "/" + NativeVolcDebugInterlockConstants.removalOwnerLock),
                   "removal owner lock is stable and never unlinked")
        }
    }

    private static func testEpochRotationIgnoresCrashTemporary() async {
        await withTemporaryRoot { _, root in
            let interlock = NativeVolcDebugInterlock(rootPath: root)
            guard case let .acquired(reader) = await interlock.beginReader() else {
                fatalError("prepare epoch")
            }
            reader.releaseGate()
            reader.releaseTransport()
            let epochPath = root + "/" + NativeVolcDebugInterlockConstants.revocationEpoch
            let oldEpoch = try! Data(contentsOf: URL(fileURLWithPath: epochPath))
            let staleTemporary = root + "/.cloud-revocation-epoch.CRASH.tmp"
            expect(writePrivate(Data((UUID().uuidString + "\n").utf8), to: staleTemporary),
                   "simulate crash after durable temporary epoch write")
            guard case let .acquired(writer) = await interlock.beginWriterPhaseA() else {
                fatalError("resume-capable removal starts with stale inert temp")
            }
            expect(await interlock.acquireWriterTransport(writer), "writer gets transport")
            expect(await interlock.finishWriterSuccess(writer),
                   "unique epoch temp lets removal complete after prior crash")
            let newEpoch = try! Data(contentsOf: URL(fileURLWithPath: epochPath))
            expect(oldEpoch != newEpoch, "successful removal atomically rotates epoch")
            expect(await interlock.inspectWithoutCredentials() == .absent,
                   "epoch rotation reopens clean state")
        }
    }

    private static func testPromotionLeaseIsSeparateFromRemoval() async {
        await withTemporaryRoot { _, root in
            let interlock = NativeVolcDebugInterlock(rootPath: root)
            guard case let .acquired(promotion) = await interlock.beginPromotion() else {
                fatalError("promotion should acquire clean request gate")
            }
            expect(await interlock.revalidatePromotion(promotion),
                   "promotion revalidates without creating removal state")
            expect(await interlock.inspectWithoutCredentials() == .absent,
                   "promotion never creates writer intent or removal marker")
            promotion.release()

            guard case let .acquired(removal) = await interlock.beginWriterPhaseA() else {
                fatalError("removal should acquire")
            }
            removal.release()
            if case .blocked = await interlock.beginPromotion() {
                expect(true, "durable removal intent blocks promotion")
            } else {
                expect(false, "promotion must not reuse removal state")
            }
        }
    }

    private static func testMalformedObjectsFailClosed() async {
        await withTemporaryRoot { _, root in
            let interlock = NativeVolcDebugInterlock(rootPath: root)
            expect(await interlock.inspectWithoutCredentials() == .absent, "prepare root")
            let intent = root + "/" + NativeVolcDebugInterlockConstants.writerIntent
            expect(writePrivate(Data("wrong\n".utf8), to: intent), "write malformed fixture")
            expect(await interlock.inspectWithoutCredentials() == .unavailable,
                   "malformed intent is unavailable, never absent")
            if case .unavailable = await interlock.beginReader() {
                expect(true, "malformed intent maps to unavailable")
            } else {
                expect(false, "malformed intent must not be a normal blocked state")
            }
        }

        await withTemporaryRoot { _, root in
            let interlock = NativeVolcDebugInterlock(rootPath: root)
            expect(await interlock.inspectWithoutCredentials() == .absent, "prepare symlink root")
            let target = root + "/untrusted"
            expect(writePrivate(NativeVolcDebugInterlockConstants.removalMarkerPayload, to: target),
                   "write symlink target")
            let marker = root + "/" + NativeVolcDebugInterlockConstants.removalMarker
            expect(symlink(target, marker) == 0, "install malicious marker symlink")
            expect(await interlock.inspectWithoutCredentials() == .unavailable,
                   "marker symlink fails closed without following")
        }
    }

    private static func testUnsafeDirectoryFailsClosed() async {
        await withTemporaryRoot(createRoot: true, rootMode: 0o755) { _, root in
            let interlock = NativeVolcDebugInterlock(rootPath: root)
            expect(await interlock.inspectWithoutCredentials() == .unavailable,
                   "non-private Debug directory is rejected")
        }
    }

    private static func withTemporaryRoot(
        createRoot: Bool = false,
        rootMode: mode_t = 0o700,
        _ operation: (String, String) async -> Void
    ) async {
        var template = Array("/private/tmp/juyi-volc-interlock.XXXXXX".utf8CString)
        let base = template.withUnsafeMutableBufferPointer { buffer -> String in
            guard let path = mkdtemp(buffer.baseAddress) else { fatalError("mkdtemp failed") }
            return String(cString: path)
        }
        let root = base + "/NativeVolcDebug"
        if createRoot {
            guard mkdir(root, rootMode) == 0 else { fatalError("mkdir fixture failed") }
        }
        await operation(base, root)
        try? FileManager.default.removeItem(atPath: base)
    }

    private static func mode(of path: String) -> mode_t {
        var status = stat()
        guard lstat(path, &status) == 0 else { return 0 }
        return status.st_mode & 0o777
    }

    private static func fileExists(_ path: String) -> Bool {
        var status = stat()
        return lstat(path, &status) == 0
    }

    private static func writePrivate(_ data: Data, to path: String) -> Bool {
        let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        let count = data.withUnsafeBytes { Darwin.write(descriptor, $0.baseAddress, $0.count) }
        return count == data.count && fsync(descriptor) == 0
    }
}
#endif
