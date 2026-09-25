import Darwin
import Foundation

/// One secure, read-only snapshot of the legacy acknowledgement file. The
/// caller decides polling and deadlines. No result ever contains a path or
/// parsed diagnostic text.
final class NativeOwnerHandoffStatusReader {
    enum Snapshot: Equatable {
        case absent
        case present(Data)
        case unavailable
    }

    private let directoryPath: String

    init(directoryPath: String) {
        self.directoryPath = directoryPath
    }

    static func live() -> NativeOwnerHandoffStatusReader? {
        guard let home = ProcessInfo.processInfo.environment["HOME"],
              home.hasPrefix("/") else { return nil }
        return NativeOwnerHandoffStatusReader(
            directoryPath: home + "/.config/argos-translator"
        )
    }

    /// Only proven absence is a clean installation. Do not interpret a stale,
    /// malformed, unreadable or dangling legacy artifact as "no legacy owner".
    static func legacyArtifactsMayExist(homePath: String) -> Bool {
        guard homePath.hasPrefix("/"), !homePath.utf8.contains(0) else { return true }
        for relative in [".hammerspoon", ".config/argos-translator/hs-status.json"] {
            var value = stat()
            let result = (homePath + "/" + relative).withCString { lstat($0, &value) }
            if result == 0 || errno != ENOENT { return true }
        }
        return false
    }

    func read() -> Snapshot {
        guard let directory = NativeOwnerHandoffStatusPOSIX.openPrivateDirectory(
            directoryPath
        ) else { return .unavailable }
        defer { close(directory) }
        return NativeOwnerHandoffStatusPOSIX.readStatus(directory: directory)
    }
}

private enum NativeOwnerHandoffStatusPOSIX {
    private static let statusName = "hs-status.json"

    static func openPrivateDirectory(_ path: String) -> Int32? {
        guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        guard !components.isEmpty,
              components.allSatisfy({ $0 != "." && $0 != ".." }) else { return nil }
        var current = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard current >= 0 else { return nil }
        for component in components {
            let name = String(component)
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

    static func readStatus(directory: Int32) -> NativeOwnerHandoffStatusReader.Snapshot {
        var before = stat()
        let result = statusName.withCString {
            fstatat(directory, $0, &before, AT_SYMLINK_NOFOLLOW)
        }
        if result != 0 {
            return errno == ENOENT ? .absent : .unavailable
        }
        guard validStatusFile(before),
              before.st_size > 0,
              before.st_size <= NativeOwnerHandoffProtocol.maximumStatusBytes else {
            return .unavailable
        }
        let descriptor = statusName.withCString {
            openat(directory, $0, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        }
        guard descriptor >= 0 else { return .unavailable }
        defer { close(descriptor) }
        var opened = stat()
        guard fstat(descriptor, &opened) == 0,
              validStatusFile(opened),
              opened.st_dev == before.st_dev,
              opened.st_ino == before.st_ino,
              opened.st_size == before.st_size else { return .unavailable }
        var data = Data(count: Int(opened.st_size))
        guard readExact(descriptor, into: &data) else { return .unavailable }
        var extra: UInt8 = 0
        var final = stat()
        var currentPath = stat()
        guard readRetrying(descriptor, &extra, 1) == 0,
              fstat(descriptor, &final) == 0,
              validStatusFile(final),
              final.st_dev == opened.st_dev,
              final.st_ino == opened.st_ino,
              final.st_size == opened.st_size,
              statusName.withCString({
                  fstatat(directory, $0, &currentPath, AT_SYMLINK_NOFOLLOW)
              }) == 0,
              validStatusFile(currentPath),
              currentPath.st_dev == final.st_dev,
              currentPath.st_ino == final.st_ino else { return .unavailable }
        return .present(data)
    }

    /// Hammerspoon currently creates status through the user's umask, so 0600
    /// and read-only 0644 are both accepted inside the owner-only 0700 parent.
    /// Any group/other write bit, foreign uid, link, or non-regular file fails.
    private static func validStatusFile(_ value: stat) -> Bool {
        (value.st_mode & S_IFMT) == S_IFREG
            && value.st_uid == getuid()
            && (value.st_mode & 0o022) == 0
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
