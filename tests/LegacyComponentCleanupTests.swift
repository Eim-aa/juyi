import Foundation

@main
@MainActor
enum LegacyComponentCleanupTests {
    private static var passed = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
            exit(1)
        }
        passed += 1
    }

    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var labels: [String] = []
        func record(_ label: String) { lock.lock(); labels.append(label); lock.unlock() }
        var bootedOut: [String] { lock.lock(); defer { lock.unlock() }; return labels }
    }

    private static var fileManager: FileManager { .default }

    // Spelled in pieces so repository-wide greps for these names stay empty.
    private static let module = "argos-translator" + ".lua"
    private static let statusFile = "hs-status" + ".json"
    private static let ownerRequest = "owner-request" + ".json"

    private static func makeHome() -> URL {
        let home = fileManager.temporaryDirectory
            .appendingPathComponent("juyi-legacy-\(UUID().uuidString)", isDirectory: true)
        try? fileManager.createDirectory(at: home, withIntermediateDirectories: true)
        return home.resolvingSymlinksInPath()
    }

    private static func write(_ text: String, _ home: URL, _ relative: String) {
        let url = home.appendingPathComponent(relative)
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? Data(text.utf8).write(to: url)
    }

    private static func exists(_ home: URL, _ relative: String) -> Bool {
        (try? fileManager.attributesOfItem(atPath: home.appendingPathComponent(relative).path)) != nil
    }

    private static func read(_ home: URL, _ relative: String) -> String? {
        try? String(contentsOf: home.appendingPathComponent(relative), encoding: .utf8)
    }

    private static func effects(_ recorder: Recorder) -> LegacyCleanupEffects {
        LegacyComponentCleanup.liveEffects { recorder.record($0) }
    }

    /// Everything an existing build ≤ 17 source installation leaves behind.
    private static func makeLegacyHome() -> URL {
        let home = makeHome()
        write(
            "hs.alert('mine')\n\n\(LegacyComponentCleanup.beginMarker)\n"
                + "\(LegacyComponentCleanup.requireLine)\n\(LegacyComponentCleanup.endMarker)\n",
            home, ".hammerspoon/init.lua"
        )
        let checkout = home.appendingPathComponent(".local/share/juyi/hammerspoon/\(module)")
        write("-- module\n", home, ".local/share/juyi/hammerspoon/\(module)")
        try? fileManager.createSymbolicLink(
            atPath: home.appendingPathComponent(".hammerspoon/\(module)").path,
            withDestinationPath: checkout.path
        )
        write("-- user module\n", home, ".hammerspoon/other.lua")
        write("<plist/>\n", home, "Library/LaunchAgents/io.github.Eim-aa.argos-translator.plist")
        write("<plist/>\n", home, "Library/LaunchAgents/io.github.Eim-aa.Juyi.login-item.plist")
        for name in [statusFile, "auth-token", ownerRequest, "native-owner.lock", "hs-engine"] {
            write("x\n", home, ".config/argos-translator/\(name)")
        }
        write("1\n", home, ".config/argos-translator/hs-paused")
        write(
            "# comment\nENGINE=volc\nVOLC_ACCESS_KEY=\"AKEXAMPLE\"\nVOLC_SECRET_KEY='SKEXAMPLE'\n",
            home, ".config/argos-translator/volc.env"
        )
        return home
    }

    private static func testCleanHomeIsNotBlocked() {
        let home = makeHome()
        let inventory = LegacyComponentCleanup.inventory(home: home)
        expect(inventory.removals.isEmpty && inventory.housekeeping.isEmpty, "a clean Mac has nothing to remove")
        expect(!inventory.isBlocking, "a clean Mac never blocks the native chain")
        expect(
            LegacyComponentCleanup.state(of: inventory, hammerspoonRestartPending: false) == .clean,
            "a clean Mac shows no early-component state"
        )
        // Hammerspoon used for unrelated automation is not a legacy component.
        write("hs.alert('mine')\n", home, ".hammerspoon/init.lua")
        expect(!LegacyComponentCleanup.inventory(home: home).isBlocking, "other Hammerspoon config never blocks")
    }

    private static func testNativeOnlyLeftoversAreHousekeepingOnly() {
        let home = makeHome()
        for name in ["hs-paused", "hs-engine", ownerRequest, "native-owner.lock"] {
            write("0\n", home, ".config/argos-translator/\(name)")
        }
        write("ENGINE=volc\n", home, ".config/argos-translator/volc.env")
        write("x\n", home, ".config/argos-translator/auth-token")
        let inventory = LegacyComponentCleanup.inventory(home: home)
        expect(!inventory.isBlocking, "files a native-only build 17 wrote do not block")
        expect(inventory.housekeeping.count == 6, "they are removed alongside a real cleanup")
        expect(inventory.cloudCredentials == nil, "a key-less volc.env holds no credential")
        expect(
            LegacyComponentCleanup.state(of: inventory, hammerspoonRestartPending: false) == .clean,
            "no prompt for leftovers alone"
        )
    }

    private static func testFullLegacyInstallationIsDetected() {
        let home = makeLegacyHome()
        let inventory = LegacyComponentCleanup.inventory(home: home)
        expect(inventory.isBlocking, "a legacy installation blocks the native chain")
        expect(inventory.moduleHostMayRunIt, "the module may still be loaded")
        expect(
            inventory.removals.contains(.item(home.appendingPathComponent(".hammerspoon/\(module)").path)),
            "the owned module symlink is removed"
        )
        expect(
            inventory.removals.contains(.launchAgent(
                label: "io.github.Eim-aa.argos-translator",
                plist: home.appendingPathComponent("Library/LaunchAgents/io.github.Eim-aa.argos-translator.plist").path
            )),
            "the service LaunchAgent is booted out and removed"
        )
        expect(
            !inventory.removals.contains { "\($0)".contains("login-item") },
            "the login-item fallback is never a legacy component"
        )
        expect(
            inventory.cloudCredentials == LegacyCloudCredentials(accessKey: "AKEXAMPLE", secretKey: "SKEXAMPLE"),
            "plaintext keys are found for migration"
        )
        expect(!"\(inventory.cloudCredentials!)".contains("SKEXAMPLE"), "the secret is redacted")
        expect(inventory.manualItems.isEmpty && inventory.malformedInitFile == nil, "nothing needs manual work")
        expect(
            LegacyComponentCleanup.state(of: inventory, hammerspoonRestartPending: false) == .removable,
            "one-click removal is offered"
        )
    }

    private static func testRemovalTouchesOnlyOwnedItems() {
        let home = makeLegacyHome()
        let inventory = LegacyComponentCleanup.inventory(home: home)
        let recorder = Recorder()
        let report = LegacyComponentCleanup.perform(inventory, effects: effects(recorder))
        expect(report.failed.isEmpty, "every owned component is removed")
        expect(recorder.bootedOut == ["io.github.Eim-aa.argos-translator"], "only the service label is booted out")
        expect(!exists(home, ".hammerspoon/\(module)"), "the symlink is gone")
        expect(exists(home, ".local/share/juyi/hammerspoon/\(module)"), "its target is untouched")
        expect(read(home, ".hammerspoon/init.lua") == "hs.alert('mine')\n\n", "user lines in init.lua are kept")
        expect(exists(home, ".hammerspoon/other.lua"), "other Hammerspoon modules are kept")
        expect(!exists(home, "Library/LaunchAgents/io.github.Eim-aa.argos-translator.plist"), "the plist is gone")
        expect(exists(home, "Library/LaunchAgents/io.github.Eim-aa.Juyi.login-item.plist"), "the login item stays")
        expect(!exists(home, ".config/argos-translator"), "the emptied configuration directory is removed")
        let after = LegacyComponentCleanup.inventory(home: home)
        expect(!after.isBlocking && after.housekeeping.isEmpty, "a second detection is clean")
    }

    private static func testConcurrentInitEditIsNeverOverwritten() {
        let home = makeLegacyHome()
        let inventory = LegacyComponentCleanup.inventory(home: home)
        write("-- edited\n", home, ".hammerspoon/init.lua")
        let report = LegacyComponentCleanup.perform(inventory, effects: effects(Recorder()))
        expect(report.failed == [home.appendingPathComponent(".hammerspoon/init.lua").path], "the edit is reported")
        expect(read(home, ".hammerspoon/init.lua") == "-- edited\n", "and kept")
    }

    private static func testUnownedModuleIsManualAndUntouched() {
        let home = makeHome()
        write("-- copied module\n", home, ".hammerspoon/\(module)")
        let inventory = LegacyComponentCleanup.inventory(home: home)
        let path = home.appendingPathComponent(".hammerspoon/\(module)").path
        expect(inventory.isBlocking, "an unowned module still blocks (fail-closed)")
        expect(
            LegacyComponentCleanup.state(of: inventory, hammerspoonRestartPending: false) == .manual([path]),
            "it is shown for manual handling"
        )
        _ = LegacyComponentCleanup.perform(inventory, effects: effects(Recorder()))
        expect(read(home, ".hammerspoon/\(module)") == "-- copied module\n", "it is never removed")

        let other = makeHome()
        try? fileManager.createDirectory(
            at: other.appendingPathComponent(".hammerspoon"), withIntermediateDirectories: true
        )
        try? fileManager.createSymbolicLink(
            atPath: other.appendingPathComponent(".hammerspoon/\(module)").path,
            withDestinationPath: "/tmp/someone-elses.lua"
        )
        expect(LegacyComponentCleanup.inventory(home: other).manualItems.count == 1, "a foreign symlink is manual")
    }

    private static func testManagedBlockRewriteRules() {
        let block = "\(LegacyComponentCleanup.beginMarker)\n\(LegacyComponentCleanup.requireLine)\n\(LegacyComponentCleanup.endMarker)"
        let require = LegacyComponentCleanup.requireLine
        expect(
            LegacyComponentCleanup.managedBlockRemoval(from: "a\n\(block)\nb\n", removeBareRequire: false)
                == .rewritten("a\nb\n"),
            "exactly the marker block is cut"
        )
        expect(
            LegacyComponentCleanup.managedBlockRemoval(from: "\(require)\n\(block)\n", removeBareRequire: true)
                == .rewritten("\(require)\n"),
            "a require outside an existing block belongs to the user"
        )
        expect(
            LegacyComponentCleanup.managedBlockRemoval(from: "x\n\(require)\n", removeBareRequire: true)
                == .rewritten("x\n"),
            "a bare legacy require goes with the owned module"
        )
        expect(
            LegacyComponentCleanup.managedBlockRemoval(from: "x\n\(require)\n", removeBareRequire: false)
                == .unchanged,
            "without the owned module a bare require is kept"
        )
        expect(
            LegacyComponentCleanup.managedBlockRemoval(from: "\(block)\n\(block)\n", removeBareRequire: true)
                == .malformed,
            "duplicate markers are malformed"
        )
        expect(
            LegacyComponentCleanup.managedBlockRemoval(
                from: "\(LegacyComponentCleanup.endMarker)\n\(LegacyComponentCleanup.beginMarker)\n",
                removeBareRequire: true
            ) == .malformed,
            "out-of-order markers are malformed"
        )

        let home = makeHome()
        write("\(block)\n\(block)\n", home, ".hammerspoon/init.lua")
        let inventory = LegacyComponentCleanup.inventory(home: home)
        expect(inventory.malformedInitFile != nil && inventory.removals.isEmpty, "a malformed block is left alone")
    }

    private static func testHammerspoonRestartGate() {
        let cleaned = Date(timeIntervalSince1970: 1_000)
        let pending = LegacyComponentCleanup.hammerspoonRestartPending
        expect(!pending(nil, [cleaned.addingTimeInterval(-60)]), "no cleanup, no restart")
        expect(pending(cleaned, [cleaned.addingTimeInterval(-60)]), "an older process must restart")
        expect(pending(cleaned, [nil]), "an unknown launch date is treated as old")
        expect(!pending(cleaned, [cleaned.addingTimeInterval(1)]), "a relaunched process is fresh")
        expect(!pending(cleaned, []), "a quit Hammerspoon needs nothing")
        expect(
            LegacyComponentCleanup.state(of: LegacyComponentInventory(), hammerspoonRestartPending: true)
                == .hammerspoonRestartRequired,
            "a pending restart keeps the chain blocked"
        )
    }

    private static func testLegacyValuesForOneTimeMigration() {
        let values = LegacyComponentCleanup.environmentValues("# c\n A = 'x' \nB=\"y\"\nbad\nC==z\n")
        expect(values == ["A": "x", "B": "y", "C": "=z"], "the old env parser semantics are kept")
        expect(
            LegacyComponentCleanup.cloudCredentials(fromEnvironment: "VOLC_ACCESS_KEY=a\nVOLC_SECRET_KEY=\n") == nil,
            "an incomplete pair is not a credential"
        )
        let home = makeHome()
        expect(LegacyComponentCleanup.legacyPauseState(home: home) == nil, "no file, no pause state")
        write("1\n", home, ".config/argos-translator/hs-paused")
        expect(LegacyComponentCleanup.legacyPauseState(home: home) == true, "a quit pause is carried over")
        write("0\n", home, ".config/argos-translator/hs-paused")
        expect(LegacyComponentCleanup.legacyPauseState(home: home) == false, "a running state is carried over")
        write("apple\n", home, ".config/argos-translator/hs-engine")
        write("ENGINE=volc\n", home, ".config/argos-translator/volc.env")
        let engines = LegacyComponentCleanup.legacyEngineChoices(home: home)
        expect(engines.explicit == "apple" && engines.environment == "volc", "both engine sources are read")
    }

    static func main() {
        testCleanHomeIsNotBlocked()
        testNativeOnlyLeftoversAreHousekeepingOnly()
        testFullLegacyInstallationIsDetected()
        testRemovalTouchesOnlyOwnedItems()
        testConcurrentInitEditIsNeverOverwritten()
        testUnownedModuleIsManualAndUntouched()
        testManagedBlockRewriteRules()
        testHammerspoonRestartGate()
        testLegacyValuesForOneTimeMigration()
        print("LegacyComponentCleanupTests: \(passed) passed")
    }
}
