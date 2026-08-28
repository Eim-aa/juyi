#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER
import Darwin
import Foundation

enum NativeVolcDebugInterlockConstants {
    static let relativeDirectory =
        "Library/Application Support/io.github.Eim-aa.Juyi/NativeVolcDebug"
    static let requestGate = "cloud-request-gate.lock"
    static let transportLock = "cloud-transport.lock"
    static let removalOwnerLock = "cloud-removal-owner.lock"
    static let revocationEpoch = "cloud-revocation-epoch"
    static let writerIntent = "cloud-writer-intent"
    static let removalMarker = "cloud-removal-pending"
    static let writerIntentPayload = Data("juyi-native-volc-debug-writer-intent-v1\n".utf8)
    static let removalMarkerPayload = Data("juyi-native-volc-debug-removal-pending-v1\n".utf8)
}

enum NativeVolcSecureObjectState: Equatable, Sendable {
    case absent
    case present
    case unavailable
}

enum NativeVolcReaderLeaseResult: CustomStringConvertible, CustomDebugStringConvertible {
    case acquired(NativeVolcReaderLease)
    case blocked
    case unavailable

    var description: String {
        switch self {
        case .acquired: return "acquired([LEASE])"
        case .blocked: return "blocked"
        case .unavailable: return "unavailable"
        }
    }

    var debugDescription: String { description }
}

final class NativeVolcReaderLease: @unchecked Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    private let lock = NSLock()
    private var directoryDescriptor: Int32
    private var gateDescriptor: Int32
    private var transportDescriptor: Int32
    private let revocationEpoch: Data

    fileprivate init(directory: Int32, gate: Int32, transport: Int32, epoch: Data) {
        directoryDescriptor = directory
        gateDescriptor = gate
        transportDescriptor = transport
        revocationEpoch = epoch
    }

    var hasGate: Bool { lock.withLock { gateDescriptor >= 0 } }
    var hasTransport: Bool { lock.withLock { transportDescriptor >= 0 } }

    fileprivate func snapshot() -> (
        directory: Int32, hasGate: Bool, hasTransport: Bool, epoch: Data
    ) {
        lock.withLock {
            (directoryDescriptor, gateDescriptor >= 0, transportDescriptor >= 0, revocationEpoch)
        }
    }

    func hasSameRevocationEpoch(as other: NativeVolcReaderLease) -> Bool {
        let otherEpoch = other.lock.withLock { other.revocationEpoch }
        return lock.withLock { revocationEpoch == otherEpoch }
    }

    func releaseGate() {
        let descriptor = lock.withLock { () -> Int32 in
            let value = gateDescriptor
            gateDescriptor = -1
            return value
        }
        NativeVolcPOSIX.releaseLock(descriptor)
    }

    func releaseTransport() {
        let descriptors = lock.withLock { () -> (Int32, Int32) in
            let transport = transportDescriptor
            transportDescriptor = -1
            let directory = directoryDescriptor
            directoryDescriptor = -1
            return (transport, directory)
        }
        NativeVolcPOSIX.releaseLock(descriptors.0)
        if descriptors.1 >= 0 { close(descriptors.1) }
    }

    deinit {
        releaseGate()
        releaseTransport()
    }

    var description: String { "NativeVolcReaderLease([REDACTED])" }
    var debugDescription: String { description }
}

final class NativeVolcWriterLease: @unchecked Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    private let lock = NSLock()
    private var directoryDescriptor: Int32
    private var ownerDescriptor: Int32
    private var gateDescriptor: Int32
    private var transportDescriptor: Int32 = -1

    fileprivate init(directory: Int32, owner: Int32, gate: Int32) {
        directoryDescriptor = directory
        ownerDescriptor = owner
        gateDescriptor = gate
    }

    fileprivate func installTransport(_ descriptor: Int32) -> Bool {
        lock.withLock {
            guard transportDescriptor < 0 else { return false }
            transportDescriptor = descriptor
            return true
        }
    }

    var holdsTransport: Bool { lock.withLock { transportDescriptor >= 0 } }

    fileprivate func snapshot() -> (directory: Int32, hasOwner: Bool, hasTransport: Bool) {
        lock.withLock {
            (directoryDescriptor, ownerDescriptor >= 0, transportDescriptor >= 0)
        }
    }

    func release() {
        let descriptors = lock.withLock { () -> (Int32, Int32, Int32, Int32) in
            let value = (
                transportDescriptor, gateDescriptor, ownerDescriptor, directoryDescriptor
            )
            transportDescriptor = -1
            gateDescriptor = -1
            ownerDescriptor = -1
            directoryDescriptor = -1
            return value
        }
        NativeVolcPOSIX.releaseLock(descriptors.0)
        NativeVolcPOSIX.releaseLock(descriptors.1)
        NativeVolcPOSIX.releaseLock(descriptors.2)
        if descriptors.3 >= 0 { close(descriptors.3) }
    }

    deinit { release() }

    var description: String { "NativeVolcWriterLease([REDACTED])" }
    var debugDescription: String { description }
}

enum NativeVolcWriterPhaseAResult {
    case acquired(NativeVolcWriterLease)
    case unavailable
}

final class NativeVolcPromotionLease: @unchecked Sendable {
    private let lock = NSLock()
    private var directoryDescriptor: Int32
    private var gateDescriptor: Int32
    private let revocationEpoch: Data

    fileprivate init(directory: Int32, gate: Int32, epoch: Data) {
        directoryDescriptor = directory
        gateDescriptor = gate
        revocationEpoch = epoch
    }

    fileprivate func snapshot() -> (directory: Int32, hasGate: Bool, epoch: Data) {
        lock.withLock { (directoryDescriptor, gateDescriptor >= 0, revocationEpoch) }
    }

    func release() {
        let value = lock.withLock { () -> (Int32, Int32) in
            let result = (gateDescriptor, directoryDescriptor)
            gateDescriptor = -1
            directoryDescriptor = -1
            return result
        }
        NativeVolcPOSIX.releaseLock(value.0)
        if value.1 >= 0 { close(value.1) }
    }

    deinit { release() }
}

enum NativeVolcPromotionLeaseResult {
    case acquired(NativeVolcPromotionLease)
    case blocked
    case unavailable
}

struct NativeVolcDebugInterlockClock: Sendable {
    let now: @Sendable () -> ContinuousClock.Instant
    let sleep: @Sendable (Duration) async -> Void

    static let continuous = NativeVolcDebugInterlockClock(
        now: { ContinuousClock().now },
        sleep: { duration in try? await ContinuousClock().sleep(for: duration) }
    )
}

actor NativeVolcDebugInterlock {
    private let rootPath: String
    private let clock: NativeVolcDebugInterlockClock

    init(
        rootPath: String = NSHomeDirectory() + "/"
            + NativeVolcDebugInterlockConstants.relativeDirectory,
        clock: NativeVolcDebugInterlockClock = .continuous
    ) {
        self.rootPath = rootPath
        self.clock = clock
    }

    func inspectWithoutCredentials() -> NativeVolcSecureObjectState {
        guard let directory = NativeVolcPOSIX.openOrCreatePrivateDirectory(rootPath) else {
            return .unavailable
        }
        defer { close(directory) }
        let intent = NativeVolcPOSIX.controlState(
            directory: directory,
            name: NativeVolcDebugInterlockConstants.writerIntent,
            expected: NativeVolcDebugInterlockConstants.writerIntentPayload
        )
        guard intent == .absent else { return intent == .present ? .present : .unavailable }
        return NativeVolcPOSIX.controlState(
            directory: directory,
            name: NativeVolcDebugInterlockConstants.removalMarker,
            expected: NativeVolcDebugInterlockConstants.removalMarkerPayload
        )
    }

    func beginReader() async -> NativeVolcReaderLeaseResult {
        guard let directory = NativeVolcPOSIX.openOrCreatePrivateDirectory(rootPath) else {
            return .unavailable
        }
        var directoryOwned = true
        defer { if directoryOwned { close(directory) } }
        guard let initialEpoch = NativeVolcPOSIX.readOrCreateRevocationEpoch(
            directory: directory
        ) else { return .unavailable }

        switch NativeVolcPOSIX.controlState(
            directory: directory,
            name: NativeVolcDebugInterlockConstants.writerIntent,
            expected: NativeVolcDebugInterlockConstants.writerIntentPayload
        ) {
        case .absent: break
        case .present: return .blocked
        case .unavailable: return .unavailable
        }
        guard NativeVolcPOSIX.readRevocationEpoch(directory: directory) == initialEpoch else {
            return .blocked
        }
        guard let gate = NativeVolcPOSIX.openStableLock(
            directory: directory,
            name: NativeVolcDebugInterlockConstants.requestGate
        ) else {
            return .unavailable
        }
        guard await acquireWithTimeout(gate, operation: LOCK_SH) else {
            close(gate)
            return .unavailable
        }
        var gateOwned = true
        defer { if gateOwned { NativeVolcPOSIX.releaseLock(gate) } }

        switch NativeVolcPOSIX.controlState(
            directory: directory,
            name: NativeVolcDebugInterlockConstants.writerIntent,
            expected: NativeVolcDebugInterlockConstants.writerIntentPayload
        ) {
        case .absent: break
        case .present: return .blocked
        case .unavailable: return .unavailable
        }
        guard let transport = NativeVolcPOSIX.openStableLock(
            directory: directory,
            name: NativeVolcDebugInterlockConstants.transportLock
        ) else {
            return .unavailable
        }
        guard await acquireWithTimeout(transport, operation: LOCK_SH) else {
            close(transport)
            return .unavailable
        }
        var transportOwned = true
        defer { if transportOwned { NativeVolcPOSIX.releaseLock(transport) } }

        switch NativeVolcPOSIX.controlState(
            directory: directory,
            name: NativeVolcDebugInterlockConstants.removalMarker,
            expected: NativeVolcDebugInterlockConstants.removalMarkerPayload
        ) {
        case .absent: break
        case .present: return .blocked
        case .unavailable: return .unavailable
        }

        directoryOwned = false
        gateOwned = false
        transportOwned = false
        return .acquired(
            NativeVolcReaderLease(
                directory: directory, gate: gate, transport: transport, epoch: initialEpoch
            )
        )
    }

    func revalidate(_ lease: NativeVolcReaderLease) -> Bool {
        revalidationState(lease) == .absent
    }

    func revalidationState(_ lease: NativeVolcReaderLease) -> NativeVolcSecureObjectState {
        let snapshot = lease.snapshot()
        let directory = snapshot.directory
        guard directory >= 0, snapshot.hasGate, snapshot.hasTransport else {
            return .unavailable
        }
        let intent = NativeVolcPOSIX.controlState(
            directory: directory,
            name: NativeVolcDebugInterlockConstants.writerIntent,
            expected: NativeVolcDebugInterlockConstants.writerIntentPayload
        )
        guard intent == .absent else { return intent }
        let marker = NativeVolcPOSIX.controlState(
            directory: directory,
            name: NativeVolcDebugInterlockConstants.removalMarker,
            expected: NativeVolcDebugInterlockConstants.removalMarkerPayload
        )
        guard marker == .absent else { return marker }
        guard let epoch = NativeVolcPOSIX.readRevocationEpoch(directory: directory) else {
            return .unavailable
        }
        return epoch == snapshot.epoch ? .absent : .present
    }

    func beginPromotion() async -> NativeVolcPromotionLeaseResult {
        guard let directory = NativeVolcPOSIX.openOrCreatePrivateDirectory(rootPath) else {
            return .unavailable
        }
        var directoryOwned = true
        defer { if directoryOwned { close(directory) } }
        guard let initialEpoch = NativeVolcPOSIX.readOrCreateRevocationEpoch(
            directory: directory
        ) else { return .unavailable }
        switch NativeVolcPOSIX.controlState(
            directory: directory,
            name: NativeVolcDebugInterlockConstants.writerIntent,
            expected: NativeVolcDebugInterlockConstants.writerIntentPayload
        ) {
        case .absent: break
        case .present: return .blocked
        case .unavailable: return .unavailable
        }
        guard let gate = NativeVolcPOSIX.openStableLock(
            directory: directory,
            name: NativeVolcDebugInterlockConstants.requestGate
        ) else {
            return .unavailable
        }
        guard await acquireWithTimeout(gate, operation: LOCK_EX) else {
            close(gate)
            return .unavailable
        }
        var gateOwned = true
        defer { if gateOwned { NativeVolcPOSIX.releaseLock(gate) } }
        let intent = NativeVolcPOSIX.controlState(
            directory: directory,
            name: NativeVolcDebugInterlockConstants.writerIntent,
            expected: NativeVolcDebugInterlockConstants.writerIntentPayload
        )
        let marker = NativeVolcPOSIX.controlState(
            directory: directory,
            name: NativeVolcDebugInterlockConstants.removalMarker,
            expected: NativeVolcDebugInterlockConstants.removalMarkerPayload
        )
        guard intent == .absent, marker == .absent else {
            return intent == .unavailable || marker == .unavailable ? .unavailable : .blocked
        }
        guard NativeVolcPOSIX.readRevocationEpoch(directory: directory) == initialEpoch else {
            return .blocked
        }
        directoryOwned = false
        gateOwned = false
        return .acquired(
            NativeVolcPromotionLease(directory: directory, gate: gate, epoch: initialEpoch)
        )
    }

    func revalidatePromotion(_ lease: NativeVolcPromotionLease) -> Bool {
        let snapshot = lease.snapshot()
        guard snapshot.directory >= 0, snapshot.hasGate else { return false }
        return NativeVolcPOSIX.controlState(
            directory: snapshot.directory,
            name: NativeVolcDebugInterlockConstants.writerIntent,
            expected: NativeVolcDebugInterlockConstants.writerIntentPayload
        ) == .absent && NativeVolcPOSIX.controlState(
            directory: snapshot.directory,
            name: NativeVolcDebugInterlockConstants.removalMarker,
            expected: NativeVolcDebugInterlockConstants.removalMarkerPayload
        ) == .absent
            && NativeVolcPOSIX.readRevocationEpoch(directory: snapshot.directory)
                == snapshot.epoch
    }

    func beginWriterPhaseA() async -> NativeVolcWriterPhaseAResult {
        guard let directory = NativeVolcPOSIX.openOrCreatePrivateDirectory(rootPath) else {
            return .unavailable
        }
        var directoryOwned = true
        defer { if directoryOwned { close(directory) } }
        guard NativeVolcPOSIX.readOrCreateRevocationEpoch(directory: directory) != nil,
              let owner = NativeVolcPOSIX.openStableLock(
                  directory: directory,
                  name: NativeVolcDebugInterlockConstants.removalOwnerLock
              ),
              NativeVolcPOSIX.acquireLock(
                  owner, operation: LOCK_EX | LOCK_NB, closeOnFailure: false
              )
        else { return .unavailable }
        var ownerOwned = true
        defer { if ownerOwned { NativeVolcPOSIX.releaseLock(owner) } }
        guard NativeVolcPOSIX.createControlFile(
            directory: directory,
            name: NativeVolcDebugInterlockConstants.writerIntent,
            payload: NativeVolcDebugInterlockConstants.writerIntentPayload
        ) else { return .unavailable }
        guard let gate = NativeVolcPOSIX.openStableLock(
            directory: directory,
            name: NativeVolcDebugInterlockConstants.requestGate
        ) else {
            return .unavailable
        }
        guard await acquireWithTimeout(gate, operation: LOCK_EX) else {
            close(gate)
            return .unavailable
        }
        var gateOwned = true
        defer { if gateOwned { NativeVolcPOSIX.releaseLock(gate) } }
        guard NativeVolcPOSIX.controlState(
            directory: directory,
            name: NativeVolcDebugInterlockConstants.writerIntent,
            expected: NativeVolcDebugInterlockConstants.writerIntentPayload
        ) == .present,
              NativeVolcPOSIX.controlState(
                  directory: directory,
                  name: NativeVolcDebugInterlockConstants.removalMarker,
                  expected: NativeVolcDebugInterlockConstants.removalMarkerPayload
              ) == .absent,
              NativeVolcPOSIX.createControlFile(
            directory: directory,
            name: NativeVolcDebugInterlockConstants.removalMarker,
            payload: NativeVolcDebugInterlockConstants.removalMarkerPayload
        ) else { return .unavailable }

        directoryOwned = false
        ownerOwned = false
        gateOwned = false
        return .acquired(
            NativeVolcWriterLease(directory: directory, owner: owner, gate: gate)
        )
    }

    func resumeWriterPhaseA() async -> NativeVolcWriterPhaseAResult {
        guard let directory = NativeVolcPOSIX.openOrCreatePrivateDirectory(rootPath) else {
            return .unavailable
        }
        var directoryOwned = true
        defer { if directoryOwned { close(directory) } }
        guard NativeVolcPOSIX.readRevocationEpoch(directory: directory) != nil,
              let owner = NativeVolcPOSIX.openStableLock(
                  directory: directory,
                  name: NativeVolcDebugInterlockConstants.removalOwnerLock
              ),
              NativeVolcPOSIX.acquireLock(
                  owner, operation: LOCK_EX | LOCK_NB, closeOnFailure: false
              )
        else { return .unavailable }
        var ownerOwned = true
        defer { if ownerOwned { NativeVolcPOSIX.releaseLock(owner) } }
        guard NativeVolcPOSIX.controlState(
            directory: directory,
            name: NativeVolcDebugInterlockConstants.writerIntent,
            expected: NativeVolcDebugInterlockConstants.writerIntentPayload
        ) == .present else { return .unavailable }
        guard let gate = NativeVolcPOSIX.openStableLock(
            directory: directory,
            name: NativeVolcDebugInterlockConstants.requestGate
        ) else {
            return .unavailable
        }
        guard await acquireWithTimeout(gate, operation: LOCK_EX) else {
            close(gate)
            return .unavailable
        }
        var gateOwned = true
        defer { if gateOwned { NativeVolcPOSIX.releaseLock(gate) } }
        guard NativeVolcPOSIX.controlState(
            directory: directory,
            name: NativeVolcDebugInterlockConstants.writerIntent,
            expected: NativeVolcDebugInterlockConstants.writerIntentPayload
        ) == .present else { return .unavailable }
        switch NativeVolcPOSIX.controlState(
            directory: directory,
            name: NativeVolcDebugInterlockConstants.removalMarker,
            expected: NativeVolcDebugInterlockConstants.removalMarkerPayload
        ) {
        case .present:
            break
        case .absent:
            guard NativeVolcPOSIX.createControlFile(
                directory: directory,
                name: NativeVolcDebugInterlockConstants.removalMarker,
                payload: NativeVolcDebugInterlockConstants.removalMarkerPayload
            ) else { return .unavailable }
        case .unavailable:
            return .unavailable
        }
        directoryOwned = false
        ownerOwned = false
        gateOwned = false
        return .acquired(
            NativeVolcWriterLease(directory: directory, owner: owner, gate: gate)
        )
    }

    func acquireWriterTransport(
        _ lease: NativeVolcWriterLease,
        timeout: Duration = .seconds(12)
    ) async -> Bool {
        let snapshot = lease.snapshot()
        guard snapshot.directory >= 0,
              let descriptor = NativeVolcPOSIX.openStableLock(
                  directory: snapshot.directory,
                  name: NativeVolcDebugInterlockConstants.transportLock
              )
        else { return false }
        let deadline = clock.now().advanced(by: timeout)
        while true {
            if Task.isCancelled {
                close(descriptor)
                return false
            }
            if NativeVolcPOSIX.acquireLock(
                descriptor,
                operation: LOCK_EX | LOCK_NB,
                closeOnFailure: false
            ) {
                guard lease.installTransport(descriptor) else {
                    NativeVolcPOSIX.releaseLock(descriptor)
                    return false
                }
                return true
            }
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else {
                close(descriptor)
                return false
            }
            if clock.now() >= deadline {
                close(descriptor)
                return false
            }
            await clock.sleep(.milliseconds(25))
        }
    }

    func finishWriterSuccess(_ lease: NativeVolcWriterLease) -> Bool {
        let snapshot = lease.snapshot()
        guard snapshot.hasOwner, snapshot.hasTransport, snapshot.directory >= 0,
              NativeVolcPOSIX.rotateRevocationEpoch(directory: snapshot.directory)
        else { return false }
        guard NativeVolcPOSIX.removeControlFile(
            directory: snapshot.directory,
            name: NativeVolcDebugInterlockConstants.removalMarker,
            expected: NativeVolcDebugInterlockConstants.removalMarkerPayload
        ) else { return false }
        guard NativeVolcPOSIX.removeControlFile(
            directory: snapshot.directory,
            name: NativeVolcDebugInterlockConstants.writerIntent,
            expected: NativeVolcDebugInterlockConstants.writerIntentPayload
        ) else { return false }
        lease.release()
        return true
    }

    private func acquireWithTimeout(
        _ descriptor: Int32,
        operation: Int32,
        timeout: Duration = .seconds(5)
    ) async -> Bool {
        let deadline = clock.now().advanced(by: timeout)
        while true {
            if Task.isCancelled { return false }
            if NativeVolcPOSIX.acquireLock(
                descriptor,
                operation: operation | LOCK_NB,
                closeOnFailure: false
            ) { return true }
            guard errno == EWOULDBLOCK || errno == EAGAIN || errno == EINTR else {
                return false
            }
            if clock.now() >= deadline { return false }
            await clock.sleep(.milliseconds(25))
        }
    }
}

private enum NativeVolcPOSIX {
    private static let revocationEpochByteCount = 37

    static func openOrCreatePrivateDirectory(_ path: String) -> Int32? {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." })
        else { return nil }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { return nil }
        for component in components {
            let name = String(component)
            let createResult = name.withCString { mkdirat(current, $0, 0o700) }
            if createResult != 0 && errno != EEXIST {
                close(current)
                return nil
            }
            if createResult == 0 && fsync(current) != 0 {
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
        var status = stat()
        guard fstat(current, &status) == 0,
              (status.st_mode & S_IFMT) == S_IFDIR,
              status.st_uid == getuid(),
              (status.st_mode & 0o777) == 0o700
        else {
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
        let wasAbsent = beforeResult != 0 && errno == ENOENT
        guard beforeResult == 0 || wasAbsent else { return nil }
        if beforeResult == 0 && !validPrivateRegularFile(before) { return nil }
        let descriptor = name.withCString {
            openat(
                directory,
                $0,
                O_RDWR | O_CREAT | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC,
                0o600
            )
        }
        guard descriptor >= 0 else { return nil }
        var opened = stat()
        var currentPath = stat()
        guard fstat(descriptor, &opened) == 0,
              validPrivateRegularFile(opened),
              name.withCString({ fstatat(directory, $0, &currentPath, AT_SYMLINK_NOFOLLOW) }) == 0,
              validPrivateRegularFile(currentPath),
              opened.st_dev == currentPath.st_dev,
              opened.st_ino == currentPath.st_ino,
              (wasAbsent ? fsync(directory) == 0 : true)
        else {
            close(descriptor)
            return nil
        }
        return descriptor
    }

    static func readOrCreateRevocationEpoch(directory: Int32) -> Data? {
        switch readRevocationEpochState(directory: directory) {
        case let .present(value): return value
        case .unavailable: return nil
        case .absent:
            let value = Data((UUID().uuidString + "\n").utf8)
            guard value.count == revocationEpochByteCount else { return nil }
            if createControlFile(
                directory: directory,
                name: NativeVolcDebugInterlockConstants.revocationEpoch,
                payload: value
            ) {
                return value
            }
            if case let .present(existing) = readRevocationEpochState(directory: directory) {
                return existing
            }
            return nil
        }
    }

    static func readRevocationEpoch(directory: Int32) -> Data? {
        if case let .present(value) = readRevocationEpochState(directory: directory) {
            return value
        }
        return nil
    }

    static func rotateRevocationEpoch(directory: Int32) -> Bool {
        guard readRevocationEpoch(directory: directory) != nil else { return false }
        let value = Data((UUID().uuidString + "\n").utf8)
        guard value.count == revocationEpochByteCount else { return false }
        let temporaryName = ".cloud-revocation-epoch.\(UUID().uuidString).tmp"
        guard createControlFile(directory: directory, name: temporaryName, payload: value)
        else { return false }
        let renamed = temporaryName.withCString { source in
            NativeVolcDebugInterlockConstants.revocationEpoch.withCString { destination in
                renameat(directory, source, directory, destination)
            }
        }
        guard renamed == 0, fsync(directory) == 0 else { return false }
        return readRevocationEpoch(directory: directory) == value
    }

    static func acquireLock(
        _ descriptor: Int32,
        operation: Int32,
        closeOnFailure: Bool = true
    ) -> Bool {
        guard descriptor >= 0 else { return false }
        if flock(descriptor, operation) == 0 { return true }
        if closeOnFailure { close(descriptor) }
        return false
    }

    static func releaseLock(_ descriptor: Int32) {
        guard descriptor >= 0 else { return }
        _ = flock(descriptor, LOCK_UN)
        close(descriptor)
    }

    static func controlState(
        directory: Int32,
        name: String,
        expected: Data
    ) -> NativeVolcSecureObjectState {
        var before = stat()
        let statResult = name.withCString {
            fstatat(directory, $0, &before, AT_SYMLINK_NOFOLLOW)
        }
        if statResult != 0 {
            return errno == ENOENT ? .absent : .unavailable
        }
        guard validPrivateRegularFile(before), before.st_size == expected.count else {
            return .unavailable
        }
        let descriptor = name.withCString {
            openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return .unavailable }
        defer { close(descriptor) }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              validPrivateRegularFile(after),
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              after.st_size == expected.count
        else { return .unavailable }
        var payload = Data(count: expected.count)
        guard readExact(descriptor, into: &payload) else { return .unavailable }
        var extra: UInt8 = 0
        let trailing = readRetryingInterrupt(descriptor, &extra, 1)
        var final = stat()
        guard trailing == 0,
              fstat(descriptor, &final) == 0,
              final.st_dev == after.st_dev,
              final.st_ino == after.st_ino,
              final.st_size == expected.count,
              payload == expected
        else {
            return .unavailable
        }
        return .present
    }

    private enum EpochState {
        case absent
        case present(Data)
        case unavailable
    }

    private static func readRevocationEpochState(directory: Int32) -> EpochState {
        let name = NativeVolcDebugInterlockConstants.revocationEpoch
        var before = stat()
        let statResult = name.withCString {
            fstatat(directory, $0, &before, AT_SYMLINK_NOFOLLOW)
        }
        if statResult != 0 { return errno == ENOENT ? .absent : .unavailable }
        guard validPrivateRegularFile(before), before.st_size == revocationEpochByteCount else {
            return .unavailable
        }
        let descriptor = name.withCString {
            openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return .unavailable }
        defer { close(descriptor) }
        var after = stat()
        guard fstat(descriptor, &after) == 0,
              validPrivateRegularFile(after),
              before.st_dev == after.st_dev,
              before.st_ino == after.st_ino,
              after.st_size == revocationEpochByteCount
        else { return .unavailable }
        var value = Data(count: revocationEpochByteCount)
        guard readExact(descriptor, into: &value) else { return .unavailable }
        var extra: UInt8 = 0
        let trailing = readRetryingInterrupt(descriptor, &extra, 1)
        var final = stat()
        guard trailing == 0,
              fstat(descriptor, &final) == 0,
              final.st_dev == after.st_dev,
              final.st_ino == after.st_ino,
              final.st_size == revocationEpochByteCount,
              value.last == 0x0A,
              let identifier = String(data: value.dropLast(), encoding: .utf8),
              UUID(uuidString: identifier) != nil
        else { return .unavailable }
        return .present(value)
    }

    static func createControlFile(directory: Int32, name: String, payload: Data) -> Bool {
        let descriptor = name.withCString {
            openat(
                directory,
                $0,
                O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,
                0o600
            )
        }
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var status = stat()
        guard fstat(descriptor, &status) == 0, validPrivateRegularFile(status) else {
            return false
        }
        guard writeExact(descriptor, payload: payload),
              fsync(descriptor) == 0,
              fsync(directory) == 0,
              controlState(directory: directory, name: name, expected: payload) == .present
        else {
            return false
        }
        return true
    }

    static func removeControlFile(directory: Int32, name: String, expected: Data) -> Bool {
        guard controlState(directory: directory, name: name, expected: expected) == .present,
              name.withCString({ unlinkat(directory, $0, 0) }) == 0,
              fsync(directory) == 0
        else { return false }
        return controlState(directory: directory, name: name, expected: expected) == .absent
    }

    private static func validPrivateRegularFile(_ status: stat) -> Bool {
        (status.st_mode & S_IFMT) == S_IFREG
            && status.st_uid == getuid()
            && (status.st_mode & 0o777) == 0o600
            && status.st_nlink == 1
    }

    private static func readExact(_ descriptor: Int32, into data: inout Data) -> Bool {
        data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else { return buffer.count == 0 }
            var offset = 0
            while offset < buffer.count {
                let count = readRetryingInterrupt(
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

    private static func readRetryingInterrupt(
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
