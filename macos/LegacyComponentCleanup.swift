import AppKit
import Darwin
import Foundation

/// A Volcengine key pair found in a pre-native plaintext `volc.env`.
struct LegacyCloudCredentials: Equatable, Sendable, CustomStringConvertible {
    let accessKey: String
    let secretKey: String

    var description: String { "LegacyCloudCredentials([REDACTED])" }
}

/// One removal performed by the cleanup. Paths are absolute and never
/// followed: a symlink is removed itself, not its target.
enum LegacyRemoval: Equatable, Sendable {
    case item(String)
    /// `init.lua` with the managed block (or, with an owned module, one bare
    /// legacy `require`) cut out. `original` guards against overwriting an
    /// edit made after detection.
    case initFile(path: String, original: Data, rewritten: Data)
    case launchAgent(label: String, plist: String)
}

struct LegacyComponentInventory: Equatable, Sendable {
    /// Components that could run a second trigger/translation path or that
    /// hold a plaintext key. Any of them keeps the native chain disabled.
    var removals: [LegacyRemoval] = []
    /// Stale data files of the old stack; removed alongside, never blocking.
    var housekeeping: [String] = []
    /// Items the app does not own. They block and are never touched.
    var manualItems: [String] = []
    /// A malformed managed block, left in place for the user.
    var malformedInitFile: String?
    var cloudCredentials: LegacyCloudCredentials?
    /// A removed item may still be loaded by a running Hammerspoon (the
    /// "module host").
    var moduleHostMayRunIt = false
    var configDirectory = ""

    var isBlocking: Bool { !removals.isEmpty || !manualItems.isEmpty }
}

/// What the home screen, onboarding and diagnostics show.
enum LegacyComponentState: Equatable, Sendable {
    case clean
    case removable
    case manual([String])
    case hammerspoonRestartRequired
}

struct LegacyCleanupEffects: Sendable {
    var readFile: @Sendable (String) -> Data?
    var removeItem: @Sendable (String) throws -> Void
    var writeFile: @Sendable (String, Data) throws -> Void
    var removeDirectoryIfEmpty: @Sendable (String) -> Void
    var bootout: @Sendable (String) -> Void
}

struct LegacyCleanupReport: Equatable, Sendable {
    var removed: [String] = []
    var failed: [String] = []
}

/// Detects and removes what pre-native installations left behind: the
/// Hammerspoon module symlink and `init.lua` managed block, the loopback
/// service LaunchAgent, and `~/.config/argos-translator`. The user's other
/// Hammerspoon configuration is never modified.
enum LegacyComponentCleanup {
    static let hammerspoonBundleIdentifier = "org.hammerspoon.Hammerspoon"
    static let moduleName = "argos-translator.lua"
    static let beginMarker = "-- BEGIN argos-translator managed block"
    static let endMarker = "-- END argos-translator managed block"
    static let requireLine = "require(\"argos-translator\")"
    static let configDirectoryPath = ".config/argos-translator"

    // MARK: Detection

    static func inventory(home: URL, fileManager: FileManager = .default) -> LegacyComponentInventory {
        let homePath = home.standardizedFileURL.path
        var result = LegacyComponentInventory(configDirectory: homePath + "/" + configDirectoryPath)
        func exists(_ path: String) -> Bool { (try? fileManager.attributesOfItem(atPath: path)) != nil }

        let module = homePath + "/.hammerspoon/" + moduleName
        var ownsModule = false
        if let target = try? fileManager.destinationOfSymbolicLink(atPath: module) {
            if (target as NSString).lastPathComponent == moduleName {
                result.removals.append(.item(module))
                ownsModule = true
                result.moduleHostMayRunIt = true
            } else {
                result.manualItems.append(module)
            }
        } else if exists(module) {
            result.manualItems.append(module)
        }

        // Like the old hook, a symlinked init.lua is edited at its target.
        let initLink = homePath + "/.hammerspoon/init.lua"
        let initPath = (try? fileManager.destinationOfSymbolicLink(atPath: initLink)) == nil
            ? initLink : URL(fileURLWithPath: initLink).resolvingSymlinksInPath().path
        if (try? fileManager.attributesOfItem(atPath: initPath))?[.type] as? FileAttributeType == .typeRegular,
           let data = fileManager.contents(atPath: initPath),
           let text = String(data: data, encoding: .utf8) {
            switch managedBlockRemoval(from: text, removeBareRequire: ownsModule) {
            case .unchanged:
                break
            case let .rewritten(rewritten):
                result.removals.append(.initFile(path: initPath, original: data, rewritten: Data(rewritten.utf8)))
                result.moduleHostMayRunIt = true
            case .malformed:
                result.malformedInitFile = initPath
            }
        }

        let agents = homePath + "/Library/LaunchAgents"
        for name in ((try? fileManager.contentsOfDirectory(atPath: agents)) ?? []).sorted()
        where name.hasPrefix("io.github.") && name.hasSuffix(".argos-translator.plist") {
            result.removals.append(.launchAgent(label: String(name.dropLast(6)), plist: agents + "/" + name))
        }

        // A symlinked configuration directory is never entered.
        let config = result.configDirectory
        guard (try? fileManager.attributesOfItem(atPath: config))?[.type] as? FileAttributeType
            == .typeDirectory else { return result }
        let status = config + "/hs-status.json"
        if exists(status) {
            result.removals.append(.item(status))
            result.moduleHostMayRunIt = true
        }
        // A plaintext key pair blocks until it has been moved into Keychain.
        let environment = config + "/volc.env"
        if let text = fileManager.contents(atPath: environment).flatMap({ String(data: $0, encoding: .utf8) }),
           let credentials = cloudCredentials(fromEnvironment: text) {
            result.cloudCredentials = credentials
            result.removals.append(.item(environment))
        }
        // Everything else in the old stack's private directory is stale data
        // (pause/engine switches, owner files, the service token).
        for name in ((try? fileManager.contentsOfDirectory(atPath: config)) ?? []).sorted()
        where name != "hs-status.json" && !(name == "volc.env" && result.cloudCredentials != nil) {
            result.housekeeping.append(config + "/" + name)
        }
        return result
    }

    static func state(of inventory: LegacyComponentInventory, hammerspoonRestartPending: Bool) -> LegacyComponentState {
        if !inventory.removals.isEmpty { return .removable }
        if !inventory.manualItems.isEmpty { return .manual(inventory.manualItems) }
        return hammerspoonRestartPending ? .hammerspoonRestartRequired : .clean
    }

    /// A Hammerspoon launched before the module was removed may still run it.
    static func hammerspoonRestartPending(cleanedAt: Date?, runningLaunchDates: [Date?]) -> Bool {
        guard let cleanedAt else { return false }
        return runningLaunchDates.contains { ($0 ?? .distantPast) < cleanedAt }
    }

    enum InitRewrite: Equatable {
        case unchanged
        case rewritten(String)
        case malformed
    }

    /// Mirrors the old hook's uninstall: only a single well-formed marker
    /// block is owned. A bare `require` outside it is removed only together
    /// with the owned module symlink and only when no block exists.
    static func managedBlockRemoval(from text: String, removeBareRequire: Bool) -> InitRewrite {
        var lines = text.components(separatedBy: "\n")
        let begins = lines.indices.filter { lines[$0] == beginMarker }
        let ends = lines.indices.filter { lines[$0] == endMarker }
        if begins.isEmpty && ends.isEmpty {
            guard removeBareRequire, let index = lines.firstIndex(of: requireLine) else { return .unchanged }
            lines.remove(at: index)
            return .rewritten(lines.joined(separator: "\n"))
        }
        guard begins.count == 1, ends.count == 1, begins[0] < ends[0] else { return .malformed }
        lines.removeSubrange(begins[0]...ends[0])
        return .rewritten(lines.joined(separator: "\n"))
    }

    // MARK: Legacy values read once for migration

    static func environmentValues(_ text: String) -> [String: String] {
        var values: [String: String] = [:]
        for rawLine in text.split(separator: "\n") {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            var value = parts[1].trimmingCharacters(in: .whitespacesAndNewlines)
            if value.count >= 2, let first = value.first, first == value.last, first == "\"" || first == "'" {
                value.removeFirst()
                value.removeLast()
            }
            values[parts[0].trimmingCharacters(in: .whitespacesAndNewlines)] = value
        }
        return values
    }

    static func cloudCredentials(fromEnvironment text: String) -> LegacyCloudCredentials? {
        let values = environmentValues(text)
        guard let access = values["VOLC_ACCESS_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              let secret = values["VOLC_SECRET_KEY"]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !access.isEmpty, !secret.isEmpty else { return nil }
        return LegacyCloudCredentials(accessKey: access, secretKey: secret)
    }

    /// The old `hs-engine` choice and the `ENGINE=` line of `volc.env`.
    static func legacyEngineChoices(home: URL) -> (explicit: String?, environment: String?) {
        let config = home.appendingPathComponent(configDirectoryPath, isDirectory: true)
        let explicit = (try? String(contentsOf: config.appendingPathComponent("hs-engine"), encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let environment = (try? String(contentsOf: config.appendingPathComponent("volc.env"), encoding: .utf8))
            .flatMap { environmentValues($0)["ENGINE"] }
        return (explicit, environment)
    }

    /// The old `hs-paused` switch: "1" paused, "0" running, otherwise unknown.
    static func legacyPauseState(home: URL) -> Bool? {
        let file = home.appendingPathComponent(configDirectoryPath, isDirectory: true)
            .appendingPathComponent("hs-paused")
        switch (try? String(contentsOf: file, encoding: .utf8))?.trimmingCharacters(in: .whitespacesAndNewlines) {
        case "1": return true
        case "0": return false
        default: return nil
        }
    }

    // MARK: Removal

    static func perform(_ inventory: LegacyComponentInventory, effects: LegacyCleanupEffects) -> LegacyCleanupReport {
        var report = LegacyCleanupReport()
        func remove(_ path: String) {
            do {
                try effects.removeItem(path)
                report.removed.append(path)
            } catch {
                report.failed.append(path)
            }
        }
        let agents = inventory.removals.compactMap { removal -> (String, String)? in
            if case let .launchAgent(label, plist) = removal { return (label, plist) }
            return nil
        }
        for (label, plist) in agents {
            effects.bootout(label)
            remove(plist)
        }
        for removal in inventory.removals {
            switch removal {
            case let .item(path):
                remove(path)
            case let .initFile(path, original, rewritten):
                guard effects.readFile(path) == original else {
                    report.failed.append(path)
                    continue
                }
                do {
                    try effects.writeFile(path, rewritten)
                    report.removed.append(path)
                } catch {
                    report.failed.append(path)
                }
            case .launchAgent:
                continue
            }
        }
        inventory.housekeeping.forEach(remove)
        effects.removeDirectoryIfEmpty(inventory.configDirectory)
        return report
    }

    static func liveEffects(bootout: @escaping @Sendable (String) -> Void) -> LegacyCleanupEffects {
        LegacyCleanupEffects(
            readFile: { FileManager.default.contents(atPath: $0) },
            removeItem: { path in
                do {
                    try FileManager.default.removeItem(atPath: path)
                } catch CocoaError.fileNoSuchFile {
                    return
                }
            },
            writeFile: { path, data in try data.write(to: URL(fileURLWithPath: path), options: .atomic) },
            // rmdir(2) removes only an empty directory.
            removeDirectoryIfEmpty: { path in _ = rmdir(path) },
            bootout: bootout
        )
    }

    // MARK: Running Hammerspoon

    @MainActor static func runningModuleHostLaunchDates() -> [Date?] {
        NSRunningApplication.runningApplications(withBundleIdentifier: hammerspoonBundleIdentifier)
            .map(\.launchDate)
    }

    /// Quits and reopens Hammerspoon so it reloads a configuration without
    /// the removed module. Returns whether a fresh process is running.
    @MainActor static func restartModuleHost() async -> Bool {
        guard let applicationURL = NSWorkspace.shared.urlForApplication(
            withBundleIdentifier: hammerspoonBundleIdentifier
        ) else { return false }
        let running = NSRunningApplication.runningApplications(withBundleIdentifier: hammerspoonBundleIdentifier)
        running.forEach { _ = $0.terminate() }
        for _ in 0..<15 where !running.allSatisfy(\.isTerminated) {
            try? await Task.sleep(for: .milliseconds(200))
        }
        guard running.allSatisfy(\.isTerminated) else { return false }
        NSWorkspace.shared.openApplication(at: applicationURL, configuration: .init(), completionHandler: nil)
        for _ in 0..<15 {
            if !runningModuleHostLaunchDates().isEmpty { return true }
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }
}
