import Foundation

@main
enum AppRefreshPolicyTests {
    private static var passed = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
            exit(1)
        }
        passed += 1
    }

    private static let appleOnlyIdle = AppRefreshContext(
        cloudSetupVisible: false,
        diagnosticsVisible: false,
        applicationActive: false
    )

    private static func testIdleCadenceAndRecovery() {
        expect(
            AppRefreshPolicy.interval(appleOnlyIdle) == 10,
            "an idle Apple-only app refreshes every 10 s"
        )
        var active = appleOnlyIdle
        active.applicationActive = true
        expect(AppRefreshPolicy.interval(active) == 2.5, "activation restores 2.5 s")
        var sheet = appleOnlyIdle
        sheet.diagnosticsVisible = true
        expect(AppRefreshPolicy.interval(sheet) == 2.5, "an open sheet restores 2.5 s")
        var cloudSheet = appleOnlyIdle
        cloudSheet.cloudSetupVisible = true
        expect(AppRefreshPolicy.interval(cloudSheet) == 2.5, "cloud setup restores 2.5 s")
    }

    private static func snapshot(
        status: String = "已就绪",
        paused: Bool = false
    ) -> AppChromeSnapshot {
        AppChromeSnapshot(
            summaryStatus: paused ? "已暂停" : status,
            statusSymbol: paused ? "pause.circle.fill" : "character.bubble.fill",
            primaryActionTitle: paused ? "恢复翻译" : "暂停翻译",
            primaryActionEnabled: true,
            showsPauseItem: false,
            selectedEngine: "apple",
            engineMenuEnabled: true,
            onboardingCompleted: true
        )
    }

    private static func testMenuRebuildsOnlyWhenTheSnapshotChanges() {
        var gate = AppChromeRenderGate()
        expect(gate.needsRender(snapshot()), "the first chrome update renders the menu")
        // A periodic refresh and a coordinator change with no visible effect
        // (formerly two subscriptions, two rebuilds) cost nothing.
        expect(!gate.needsRender(snapshot()), "an unchanged refresh does not rebuild")
        expect(!gate.needsRender(snapshot()), "a duplicate notification does not rebuild")
        expect(gate.needsRender(snapshot(paused: true)), "pausing rebuilds exactly once")
        expect(!gate.needsRender(snapshot(paused: true)), "the paused state is not rebuilt again")
        var engine = snapshot()
        engine.selectedEngine = "volc"
        expect(gate.needsRender(engine), "an engine change rebuilds the menu")
        var disabled = engine
        disabled.engineMenuEnabled = false
        expect(gate.needsRender(disabled), "a menu enablement change rebuilds the menu")
        var pauseItem = disabled
        pauseItem.showsPauseItem = true
        expect(gate.needsRender(pauseItem), "showing the pause item rebuilds the menu")
        expect(gate.rendered == pauseItem, "the gate remembers the last rendered snapshot")
    }

    private static func testSingleChangeCountsOneRebuild() {
        // Model a burst of notifications for one coordinator state change:
        // AppModel.onChange plus a periodic refresh landing in the same tick.
        var gate = AppChromeRenderGate()
        _ = gate.needsRender(snapshot(status: "设置中"))
        var rebuilds = 0
        for _ in 0..<3 {
            if gate.needsRender(snapshot()) { rebuilds += 1 }
        }
        expect(rebuilds == 1, "one state change triggers exactly one menu rebuild")
    }

    static func main() {
        testIdleCadenceAndRecovery()
        testMenuRebuildsOnlyWhenTheSnapshotChanges()
        testSingleChangeCountsOneRebuild()
        print("AppRefreshPolicyTests: \(passed) passed")
    }
}
