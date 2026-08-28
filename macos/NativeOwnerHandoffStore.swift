#if DEBUG && JUYI_NATIVE_OWNER_HANDOFF_LAB && (JUYI_NATIVE_SELECTION_CAPTURE_LAB || JUYI_NATIVE_OPTION_MONITOR || JUYI_NATIVE_TRANSLATION_DOMAIN || JUYI_NATIVE_TRANSLATION_OVERLAY || JUYI_NATIVE_TRANSLATION_RESULT_LAB || JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER || JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER || JUYI_NATIVE_APPLE_RESULT_LAB_BINDING)
#error("JUYI_NATIVE_OWNER_HANDOFF_LAB is an isolated store-only build and cannot be mixed with capture, Option, or translation development flags")
#endif

#if DEBUG && JUYI_NATIVE_OWNER_HANDOFF_LAB
import Darwin
import Foundation

/// Durable, fail-closed storage for the cooperative trigger-owner protocol.
/// This slice performs no status polling, AX read, event monitoring, or
/// translation. A future explicit coordinator must validate the legacy ack
/// while retaining the returned cross-process lease.
final class NativeOwnerHandoffStore {
    static let artifactSentinel = "juyi-native-owner-handoff-store-v1"

    enum BeginResult {
        case acquired(NativeOwnerHandoffLease)
        case busy
        case recoveryRequired
        case unavailable
    }

    enum RecoveryResult {
        case acquired(NativeOwnerHandoffLease)
        case absent
        case busy
        case unavailable
    }

    private let directoryPath: String

    init(directoryPath: String) {
        self.directoryPath = directoryPath
    }

    static func live() -> NativeOwnerHandoffStore? {
        guard let home = ProcessInfo.processInfo.environment["HOME"],
              home.hasPrefix("/") else { return nil }
        return NativeOwnerHandoffStore(
            directoryPath: home + "/.config/argos-translator"
        )
    }

    func begin(nativeInstanceID: UUID, epoch: UUID) -> BeginResult {
        guard let directory = NativeOwnerHandoffPOSIX.openPrivateDirectory(
            directoryPath
        ) else { return .unavailable }
        guard let lock = NativeOwnerHandoffPOSIX.openStableLock(
            directory: directory,
            name: NativeOwnerHandoffPOSIX.lockName
        ) else {
            close(directory)
            return .unavailable
        }
        guard NativeOwnerHandoffPOSIX.acquireExclusive(lock) else {
            let lockError = errno
            close(lock)
            close(directory)
            return lockError == EWOULDBLOCK ? .busy : .unavailable
        }
        let request = NativeOwnerHandoffProtocol.makeRequest(
            nativeInstanceID: nativeInstanceID,
            epoch: epoch
        )
        guard let payload = try? NativeOwnerHandoffProtocol.encodedRequest(request)
        else {
            NativeOwnerHandoffPOSIX.releaseLock(lock)
            close(directory)
            return .unavailable
        }
        switch NativeOwnerHandoffPOSIX.readRequest(directory: directory) {
        case .present:
            NativeOwnerHandoffPOSIX.releaseLock(lock)
            close(directory)
            return .recoveryRequired
        case .unavailable:
            NativeOwnerHandoffPOSIX.releaseLock(lock)
            close(directory)
            return .unavailable
        case .absent:
            guard NativeOwnerHandoffPOSIX.publishRequest(
                directory: directory,
                payload: payload
            ) else {
                NativeOwnerHandoffPOSIX.releaseLock(lock)
                close(directory)
                return .unavailable
            }
            return .acquired(
                NativeOwnerHandoffLease(
                    directory: directory,
                    lock: lock,
                    request: request,
                    payload: payload,
                    purpose: .activationCandidate
                )
            )
        }
    }

    /// Acquires an existing canonical request only so an explicit recovery UI
    /// can safely remove it and return ownership to Hammerspoon. This lease is
    /// never an authorization to start a native monitor.
    func recoverForReturnToLegacy() -> RecoveryResult {
        guard let directory = NativeOwnerHandoffPOSIX.openPrivateDirectory(
            directoryPath
        ) else { return .unavailable }
        guard let lock = NativeOwnerHandoffPOSIX.openStableLock(
            directory: directory,
            name: NativeOwnerHandoffPOSIX.lockName
        ) else {
            close(directory)
            return .unavailable
        }
        guard NativeOwnerHandoffPOSIX.acquireExclusive(lock) else {
            let lockError = errno
            close(lock)
            close(directory)
            return lockError == EWOULDBLOCK ? .busy : .unavailable
        }
        switch NativeOwnerHandoffPOSIX.readRequest(directory: directory) {
        case .absent:
            NativeOwnerHandoffPOSIX.releaseLock(lock)
            close(directory)
            return .absent
        case .unavailable:
            NativeOwnerHandoffPOSIX.releaseLock(lock)
            close(directory)
            return .unavailable
        case let .present(request, payload):
            return .acquired(
                NativeOwnerHandoffLease(
                    directory: directory,
                    lock: lock,
                    request: request,
                    payload: payload,
                    purpose: .recoveryOnly
                )
            )
        }
    }

    func returnToLegacy(_ lease: NativeOwnerHandoffLease) -> Bool {
        lease.removeRequestAndRelease()
    }
}

final class NativeOwnerHandoffLease: CustomStringConvertible {
    enum Purpose: String {
        case activationCandidate
        case recoveryOnly
    }

    let request: NativeOwnerHandoffProtocol.Request
    let purpose: Purpose

    private let stateLock = NSLock()
    private var directory: Int32
    private var lock: Int32
    private let payload: Data

    fileprivate init(
        directory: Int32,
        lock: Int32,
        request: NativeOwnerHandoffProtocol.Request,
        payload: Data,
        purpose: Purpose
    ) {
        self.directory = directory
        self.lock = lock
        self.request = request
        self.payload = payload
        self.purpose = purpose
    }

    var description: String {
        "NativeOwnerHandoffLease(purpose: \(purpose.rawValue), identifiers: [REDACTED])"
    }

    /// Simulates process loss in tests and supports fail-closed shutdown. It
    /// intentionally preserves the durable request, leaving zero active owner.
    func releasePreservingRequest() {
        stateLock.lock()
        defer { stateLock.unlock() }
        releaseDescriptors()
    }

    fileprivate func removeRequestAndRelease() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        guard directory >= 0, lock >= 0,
              NativeOwnerHandoffPOSIX.removeRequest(
                  directory: directory,
                  expected: payload
              ) else { return false }
        releaseDescriptors()
        return true
    }

    private func releaseDescriptors() {
        if lock >= 0 {
            NativeOwnerHandoffPOSIX.releaseLock(lock)
            lock = -1
        }
        if directory >= 0 {
            close(directory)
            directory = -1
        }
    }

    deinit {
        stateLock.lock()
        releaseDescriptors()
        stateLock.unlock()
    }
}

private enum NativeOwnerHandoffRequestState {
    case absent
    case present(NativeOwnerHandoffProtocol.Request, Data)
    case unavailable
}

private enum NativeOwnerHandoffPOSIX {
    static let lockName = "native-owner.lock"
    private static let requestName = "owner-request.json"

    static func openPrivateDirectory(_ path: String) -> Int32? {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else { return nil }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { return nil }
        for component in components {
            let name = String(component)
            let created = name.withCString { mkdirat(current, $0, 0o700) }
            if created != 0 && errno != EEXIST {
                close(current)
                return nil
            }
            if created == 0 && fsync(current) != 0 {
                close(current)
                return nil
            }
            let next = name.withCString {
                openat(current, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            }
            guard next >= 0 else {
                close(current)
                return nil
            }
            close(current)
            current = next
        }
        var value = stat()
        guard fstat(current, &value) == 0,
              (value.st_mode & S_IFMT) == S_IFDIR,
              value.st_uid == getuid(),
              (value.st_mode & 0o777) == 0o700 else {
            close(current)
            return nil
        }
        return current
    }

    static func openStableLock(directory: Int32, name: String) -> Int32? {
        var before = stat()
        let beforeResult = name.withCString {
            fstatat(directory, $0, &before, AT_SYMLINK_NOFOLLOW)
        }
        let absent = beforeResult != 0 && errno == ENOENT
        guard beforeResult == 0 || absent else { return nil }
        if beforeResult == 0 && !validPrivateFile(before) { return nil }
        let descriptor = name.withCString {
            openat(directory, $0, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else { return nil }
        var opened = stat()
        var path = stat()
        guard fstat(descriptor, &opened) == 0,
              validPrivateFile(opened),
              name.withCString({ fstatat(directory, $0, &path, AT_SYMLINK_NOFOLLOW) }) == 0,
              validPrivateFile(path),
              opened.st_dev == path.st_dev,
              opened.st_ino == path.st_ino,
              (!absent || fsync(directory) == 0) else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    static func acquireExclusive(_ descriptor: Int32) -> Bool {
        flock(descriptor, LOCK_EX | LOCK_NB) == 0
    }

    static func releaseLock(_ descriptor: Int32) {
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    static func readRequest(directory: Int32) -> NativeOwnerHandoffRequestState {
        var before = stat()
        let result = requestName.withCString {
            fstatat(directory, $0, &before, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            return errno == ENOENT ? .absent : .unavailable
        }
        guard validPrivateFile(before),
              before.st_size > 0,
              before.st_size <= NativeOwnerHandoffProtocol.maximumRequestBytes else {
            return .unavailable
        }
        let descriptor = requestName.withCString {
            openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return .unavailable }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              validPrivateFile(opened),
              before.st_dev == opened.st_dev,
              before.st_ino == opened.st_ino,
              before.st_size == opened.st_size else { return .unavailable }
        var payload = Data(count: Int(opened.st_size))
        guard readExact(descriptor, into: &payload) else { return .unavailable }
        var extra: UInt8 = 0
        var final = stat()
        guard readRetrying(descriptor, &extra, 1) == 0,
              fstat(descriptor, &final) == 0,
              final.st_dev == opened.st_dev,
              final.st_ino == opened.st_ino,
              final.st_size == opened.st_size,
              let request = NativeOwnerHandoffProtocol.decodeCanonicalRequest(payload)
        else { return .unavailable }
        return .present(request, payload)
    }

    static func publishRequest(directory: Int32, payload: Data) -> Bool {
        let temporary = ".owner-request.\(UUID().uuidString).tmp"
        let descriptor = temporary.withCString {
            openat(directory, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        }
        guard descriptor >= 0 else { return false }
        var shouldRemoveTemporary = true
        defer {
            close(descriptor)
            if shouldRemoveTemporary {
                _ = temporary.withCString { unlinkat(directory, $0, 0) }
            }
        }
        var value = stat()
        guard fstat(descriptor, &value) == 0,
              validPrivateFile(value),
              writeExact(descriptor, payload: payload),
              fsync(descriptor) == 0 else { return false }
        let renamed = temporary.withCString { source in
            requestName.withCString { destination in
                renameatx_np(directory, source, directory, destination, UInt32(RENAME_EXCL))
            }
        }
        guard renamed == 0, fsync(directory) == 0 else { return false }
        shouldRemoveTemporary = false
        guard case let .present(_, written) = readRequest(directory: directory),
              written == payload else { return false }
        return true
    }

    static func removeRequest(directory: Int32, expected: Data) -> Bool {
        guard case let .present(_, current) = readRequest(directory: directory),
              current == expected,
              requestName.withCString({ unlinkat(directory, $0, 0) }) == 0,
              fsync(directory) == 0,
              case .absent = readRequest(directory: directory) else { return false }
        return true
    }

    private static func validPrivateFile(_ value: stat) -> Bool {
        (value.st_mode & S_IFMT) == S_IFREG
            && value.st_uid == getuid()
            && (value.st_mode & 0o777) == 0o600
            && value.st_nlink == 1
    }

    private static func readExact(_ descriptor: Int32, into data: inout Data) -> Bool {
        data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return buffer.count == 0 }
            var offset = 0
            while offset < buffer.count {
                let count = readRetrying(
                    descriptor,
                    base.advanced(by: offset),
                    buffer.count - offset
                )
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }

    private static func writeExact(_ descriptor: Int32, payload: Data) -> Bool {
        payload.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return buffer.count == 0 }
            var offset = 0
            while offset < buffer.count {
                var count: Int
                repeat {
                    count = Darwin.write(
                        descriptor,
                        base.advanced(by: offset),
                        buffer.count - offset
                    )
                } while count < 0 && errno == EINTR
                guard count > 0 else { return false }
                offset += count
            }
            return true
        }
    }

    private static func readRetrying(
        _ descriptor: Int32,
        _ buffer: UnsafeMutableRawPointer,
        _ count: Int
    ) -> Int {
        var result: Int
        repeat {
            result = Darwin.read(descriptor, buffer, count)
        } while result < 0 && errno == EINTR
        return result
    }
}
#endif
