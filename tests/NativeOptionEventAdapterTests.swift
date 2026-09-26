import Foundation

@main
enum NativeOptionEventAdapterTests {
    private static var passed = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
            exit(1)
        }
        passed += 1
    }

    private static func snapshot(
        _ kind: NativeOptionEventSnapshot.Kind,
        keyCode: UInt16,
        modifiers: DoubleOptionStateMachine.Modifiers,
        at timestamp: TimeInterval,
        repeat isAutoRepeat: Bool = false
    ) -> NativeOptionEventSnapshot {
        NativeOptionEventSnapshot(
            kind: kind,
            keyCode: keyCode,
            modifiers: modifiers,
            timestamp: timestamp,
            isAutoRepeat: isAutoRepeat
        )
    }

    private static func process(
        _ event: NativeOptionEventSnapshot,
        adapter: inout NativeOptionEventAdapter,
        machine: inout DoubleOptionStateMachine
    ) -> DoubleOptionStateMachine.Effect? {
        guard let input = adapter.input(for: event) else { return nil }
        return machine.process(input, at: event.timestamp)
    }

    @discardableResult
    private static func tap(
        keyCode: UInt16,
        down: TimeInterval,
        up: TimeInterval,
        adapter: inout NativeOptionEventAdapter,
        machine: inout DoubleOptionStateMachine
    ) -> DoubleOptionStateMachine.Effect? {
        expect(
            process(
                snapshot(.flagsChanged, keyCode: keyCode, modifiers: [.option], at: down),
                adapter: &adapter,
                machine: &machine
            ) == nil,
            "press does not trigger"
        )
        return process(
            snapshot(.flagsChanged, keyCode: keyCode, modifiers: [], at: up),
            adapter: &adapter,
            machine: &machine
        )
    }

    private static func testSidesAndStartupGuard() {
        for (first, second) in [(58, 58), (61, 61), (58, 61), (61, 58)] {
            var adapter = NativeOptionEventAdapter()
            var machine = DoubleOptionStateMachine()
            expect(
                tap(
                    keyCode: UInt16(first), down: 0, up: 0.05,
                    adapter: &adapter, machine: &machine
                ) == nil,
                "first side arms"
            )
            expect(
                tap(
                    keyCode: UInt16(second), down: 0.10, up: 0.15,
                    adapter: &adapter, machine: &machine
                ) == .trigger(after: 0.01),
                "all left/right combinations trigger"
            )
        }

        var guardedAdapter = NativeOptionEventAdapter(optionInitiallyDown: true)
        var guardedMachine = DoubleOptionStateMachine()
        expect(
            process(
                snapshot(.flagsChanged, keyCode: 58, modifiers: [], at: 0.05),
                adapter: &guardedAdapter,
                machine: &guardedMachine
            ) == nil,
            "release of Option held at startup is ignored"
        )
        expect(
            tap(
                keyCode: 58, down: 0.10, up: 0.15,
                adapter: &guardedAdapter, machine: &guardedMachine
            ) == nil,
            "first post-startup tap only arms"
        )
        expect(
            tap(
                keyCode: 61, down: 0.20, up: 0.25,
                adapter: &guardedAdapter, machine: &guardedMachine
            ) == .trigger(after: 0.01),
            "recognition resumes after a full release"
        )

        var mixedHeldAdapter = NativeOptionEventAdapter(optionInitiallyDown: true)
        var mixedHeldMachine = DoubleOptionStateMachine()
        _ = process(
            snapshot(.flagsChanged, keyCode: 61, modifiers: [.option], at: 0.01),
            adapter: &mixedHeldAdapter,
            machine: &mixedHeldMachine
        )
        _ = process(
            snapshot(.flagsChanged, keyCode: 58, modifiers: [.option], at: 0.02),
            adapter: &mixedHeldAdapter,
            machine: &mixedHeldMachine
        )
        expect(
            process(
                snapshot(.flagsChanged, keyCode: 61, modifiers: [], at: 0.03),
                adapter: &mixedHeldAdapter,
                machine: &mixedHeldMachine
            ) == nil,
            "startup guard waits until all Option keys are released"
        )
    }

    private static func testOverlapKeysModifiersAndCapsLock() {
        var adapter = NativeOptionEventAdapter()
        var machine = DoubleOptionStateMachine()
        _ = process(
            snapshot(.flagsChanged, keyCode: 58, modifiers: [.option], at: 0),
            adapter: &adapter,
            machine: &machine
        )
        _ = process(
            snapshot(.flagsChanged, keyCode: 61, modifiers: [.option], at: 0.01),
            adapter: &adapter,
            machine: &machine
        )
        _ = process(
            snapshot(.flagsChanged, keyCode: 58, modifiers: [.option], at: 0.02),
            adapter: &adapter,
            machine: &machine
        )
        expect(
            process(
                snapshot(.flagsChanged, keyCode: 61, modifiers: [], at: 0.03),
                adapter: &adapter,
                machine: &machine
            ) == nil,
            "overlapping left/right Option is represented and cancelled"
        )

        var keyAdapter = NativeOptionEventAdapter()
        var keyMachine = DoubleOptionStateMachine()
        _ = tap(
            keyCode: 58, down: 0, up: 0.05,
            adapter: &keyAdapter, machine: &keyMachine
        )
        _ = process(
            snapshot(.keyDown, keyCode: 0, modifiers: [], at: 0.10, repeat: true),
            adapter: &keyAdapter,
            machine: &keyMachine
        )
        expect(
            tap(
                keyCode: 61, down: 0.15, up: 0.20,
                adapter: &keyAdapter, machine: &keyMachine
            ) == nil,
            "ordinary key repeat between taps cancels"
        )

        var modifierAdapter = NativeOptionEventAdapter()
        var modifierMachine = DoubleOptionStateMachine()
        _ = tap(
            keyCode: 58, down: 0, up: 0.05,
            adapter: &modifierAdapter, machine: &modifierMachine
        )
        _ = process(
            snapshot(.flagsChanged, keyCode: 55, modifiers: [.command], at: 0.10),
            adapter: &modifierAdapter,
            machine: &modifierMachine
        )
        expect(
            tap(
                keyCode: 61, down: 0.15, up: 0.20,
                adapter: &modifierAdapter, machine: &modifierMachine
            ) == nil,
            "non-Option modifier snapshots cancel"
        )

        var capsAdapter = NativeOptionEventAdapter()
        var capsMachine = DoubleOptionStateMachine()
        _ = tap(
            keyCode: 58, down: 0, up: 0.05,
            adapter: &capsAdapter, machine: &capsMachine
        )
        _ = process(
            snapshot(.keyDown, keyCode: 57, modifiers: [], at: 0.10),
            adapter: &capsAdapter,
            machine: &capsMachine
        )
        expect(
            tap(
                keyCode: 61, down: 0.15, up: 0.20,
                adapter: &capsAdapter, machine: &capsMachine
            ) == .trigger(after: 0.01),
            "Caps Lock keyDown is ignored"
        )
    }

    private static func testResetAndUntrackedRelease() {
        var adapter = NativeOptionEventAdapter()
        var machine = DoubleOptionStateMachine()
        _ = tap(
            keyCode: 58, down: 0, up: 0.05,
            adapter: &adapter, machine: &machine
        )
        adapter.reset(optionInitiallyDown: false)
        machine.reset()
        expect(
            process(
                snapshot(.flagsChanged, keyCode: 61, modifiers: [], at: 0.10),
                adapter: &adapter,
                machine: &machine
            ) == nil,
            "untracked release after reset is ignored"
        )
        expect(
            tap(
                keyCode: 61, down: 0.15, up: 0.20,
                adapter: &adapter, machine: &machine
            ) == nil,
            "lifecycle reset clears prior tap"
        )
    }

    static func main() {
        testSidesAndStartupGuard()
        testOverlapKeysModifiersAndCapsLock()
        testResetAndUntrackedRelease()
        print("NativeOptionEventAdapterTests: \(passed) passed")
    }
}
