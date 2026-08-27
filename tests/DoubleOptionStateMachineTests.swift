import Foundation

@main
enum DoubleOptionStateMachineTests {
    private static var passed = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
            exit(1)
        }
        passed += 1
    }

    @discardableResult
    private static func tap(
        _ machine: inout DoubleOptionStateMachine,
        side: DoubleOptionStateMachine.OptionSide,
        down: TimeInterval,
        up: TimeInterval
    ) -> DoubleOptionStateMachine.Effect? {
        let pressed: DoubleOptionStateMachine.Modifiers = [.option]
        expect(
            machine.process(
                .optionChanged(side: side, isDown: true, modifiers: pressed),
                at: down
            ) == nil,
            "an Option press never triggers"
        )
        return machine.process(
            .optionChanged(side: side, isDown: false, modifiers: []),
            at: up
        )
    }

    private static func testSidesAndReleaseWindow() {
        let pairs: [(
            DoubleOptionStateMachine.OptionSide,
            DoubleOptionStateMachine.OptionSide,
            String
        )] = [
            (.left, .left, "LL"),
            (.right, .right, "RR"),
            (.left, .right, "LR"),
            (.right, .left, "RL"),
        ]
        for (first, second, name) in pairs {
            var machine = DoubleOptionStateMachine()
            expect(tap(&machine, side: first, down: 0, up: 0.05) == nil, "\(name) first tap arms")
            expect(
                tap(&machine, side: second, down: 0.20, up: 0.35) == .trigger(after: 0.01),
                "\(name) triggers at the inclusive 350 ms release interval"
            )
        }

        var lateRelease = DoubleOptionStateMachine()
        _ = tap(&lateRelease, side: .left, down: 0, up: 0.05)
        expect(
            tap(&lateRelease, side: .right, down: 0.34, up: 0.400_001) == nil,
            "the window is release-to-release, not press-to-press"
        )
        expect(
            tap(&lateRelease, side: .left, down: 0.50, up: 0.60) == .trigger(after: 0.01),
            "an expired second tap becomes the next first tap"
        )
    }

    private static func testHoldBoundaryAndTimeout() {
        var boundary = DoubleOptionStateMachine()
        expect(tap(&boundary, side: .left, down: 0, up: 0.35) == nil, "a 350 ms hold is clean")
        expect(
            tap(&boundary, side: .right, down: 0.40, up: 0.70) == .trigger(after: 0.01),
            "a boundary-length first tap participates in a pair"
        )

        var tooLong = DoubleOptionStateMachine()
        _ = tap(&tooLong, side: .left, down: 0, up: 0.05)
        expect(
            tap(&tooLong, side: .right, down: 0.10, up: 0.450_001) == nil,
            "a hold longer than 350 ms cancels the group"
        )
        expect(tap(&tooLong, side: .left, down: 0.50, up: 0.55) == nil, "a new group starts cleanly")
        expect(
            tap(&tooLong, side: .right, down: 0.60, up: 0.65) == .trigger(after: 0.01),
            "the new group can trigger"
        )

        var expired = DoubleOptionStateMachine()
        _ = tap(&expired, side: .left, down: 1.0, up: 1.05)
        expect(tap(&expired, side: .right, down: 1.50, up: 1.55) == nil, "an expired tap is replaced")
        expect(
            tap(&expired, side: .left, down: 1.70, up: 1.75) == .trigger(after: 0.01),
            "the replacement tap can pair with the next tap"
        )
    }

    private static func testKeysAndModifiersCancelTheWholeGroup() {
        var keyInside = DoubleOptionStateMachine()
        _ = keyInside.process(
            .optionChanged(side: .left, isDown: true, modifiers: [.option]),
            at: 0
        )
        _ = keyInside.process(.keyDown(isAutoRepeat: false), at: 0.02)
        expect(
            keyInside.process(
                .optionChanged(side: .left, isDown: false, modifiers: []),
                at: 0.04
            ) == nil,
            "a normal key during a press cancels it"
        )
        expect(tap(&keyInside, side: .left, down: 0.10, up: 0.15) == nil, "cancelled press did not arm")

        var repeatInside = DoubleOptionStateMachine()
        _ = repeatInside.process(
            .optionChanged(side: .right, isDown: true, modifiers: [.option]),
            at: 0
        )
        _ = repeatInside.process(.keyDown(isAutoRepeat: true), at: 0.02)
        _ = repeatInside.process(
            .optionChanged(side: .right, isDown: false, modifiers: []),
            at: 0.04
        )
        expect(tap(&repeatInside, side: .right, down: 0.10, up: 0.15) == nil, "auto-repeat also cancels")

        var keyBetween = DoubleOptionStateMachine()
        _ = tap(&keyBetween, side: .left, down: 0, up: 0.05)
        _ = keyBetween.process(.keyDown(isAutoRepeat: false), at: 0.10)
        expect(tap(&keyBetween, side: .right, down: 0.15, up: 0.20) == nil, "a key between taps cancels")
        expect(
            tap(&keyBetween, side: .left, down: 0.25, up: 0.30) == .trigger(after: 0.01),
            "the post-key tap becomes a new first tap"
        )

        let forbidden: [DoubleOptionStateMachine.Modifiers] = [
            .command, .control, .shift, .function,
        ]
        for modifier in forbidden {
            var inside = DoubleOptionStateMachine()
            _ = inside.process(
                .optionChanged(side: .left, isDown: true, modifiers: [.option]),
                at: 0
            )
            _ = inside.process(.modifiersChanged([.option, modifier]), at: 0.02)
            _ = inside.process(
                .optionChanged(side: .left, isDown: false, modifiers: [modifier]),
                at: 0.04
            )
            expect(tap(&inside, side: .right, down: 0.10, up: 0.15) == nil, "modifier inside cancels")

            var between = DoubleOptionStateMachine()
            _ = tap(&between, side: .left, down: 0, up: 0.05)
            _ = between.process(.modifiersChanged(modifier), at: 0.10)
            _ = between.process(.modifiersChanged([]), at: 0.11)
            expect(tap(&between, side: .right, down: 0.15, up: 0.20) == nil, "modifier between cancels")
        }

        var capsLock = DoubleOptionStateMachine()
        _ = tap(&capsLock, side: .left, down: 0, up: 0.05)
        // Caps Lock is deliberately absent from Modifiers, so the adapter maps
        // its flagsChanged event to an empty relevant-modifier set.
        _ = capsLock.process(.modifiersChanged([]), at: 0.10)
        expect(
            tap(&capsLock, side: .right, down: 0.15, up: 0.20) == .trigger(after: 0.01),
            "Caps Lock is ignored"
        )
    }

    private static func testOverlapRepeatRollbackAndDebounce() {
        var overlap = DoubleOptionStateMachine()
        _ = overlap.process(
            .optionChanged(side: .left, isDown: true, modifiers: [.option]),
            at: 0
        )
        _ = overlap.process(
            .optionChanged(side: .right, isDown: true, modifiers: [.option]),
            at: 0.01
        )
        _ = overlap.process(
            .optionChanged(side: .left, isDown: false, modifiers: [.option]),
            at: 0.02
        )
        expect(
            overlap.process(
                .optionChanged(side: .right, isDown: false, modifiers: []),
                at: 0.03
            ) == nil,
            "overlapping left and right Option never trigger"
        )
        expect(tap(&overlap, side: .left, down: 0.10, up: 0.15) == nil, "overlap clears the prior group")

        var redundant = DoubleOptionStateMachine()
        _ = redundant.process(
            .optionChanged(side: .left, isDown: true, modifiers: [.option]),
            at: 0
        )
        _ = redundant.process(
            .optionChanged(side: .left, isDown: true, modifiers: [.option]),
            at: 0.01
        )
        _ = redundant.process(
            .optionChanged(side: .left, isDown: false, modifiers: []),
            at: 0.02
        )
        expect(tap(&redundant, side: .left, down: 0.10, up: 0.15) == nil, "redundant down is not a tap")

        var rollback = DoubleOptionStateMachine()
        _ = tap(&rollback, side: .left, down: 10.0, up: 10.05)
        expect(
            rollback.process(
                .optionChanged(side: .right, isDown: true, modifiers: [.option]),
                at: 9.0
            ) == nil,
            "clock rollback cannot trigger"
        )
        expect(
            rollback.process(
                .optionChanged(side: .right, isDown: false, modifiers: []),
                at: 9.05
            ) == nil,
            "post-rollback release becomes a safe first tap"
        )
        expect(
            tap(&rollback, side: .left, down: 9.10, up: 9.15) == .trigger(after: 0.01),
            "recognition recovers after a rollback"
        )

        var duplicateRelease = DoubleOptionStateMachine()
        _ = tap(&duplicateRelease, side: .left, down: 0, up: 0.05)
        expect(
            tap(&duplicateRelease, side: .right, down: 0.10, up: 0.15) == .trigger(after: 0.01),
            "a clean pair triggers once"
        )
        expect(
            duplicateRelease.process(
                .optionChanged(side: .right, isDown: false, modifiers: []),
                at: 0.151
            ) == nil,
            "duplicate release is debounced"
        )

        var rapid = DoubleOptionStateMachine()
        let releases: [TimeInterval] = [0.05, 0.15, 0.25, 0.35]
        var triggerCount = 0
        for (index, release) in releases.enumerated() {
            let effect = tap(
                &rapid,
                side: index.isMultiple(of: 2) ? .left : .right,
                down: release - 0.02,
                up: release
            )
            if effect != nil { triggerCount += 1 }
            if index == 2 { expect(triggerCount == 1, "three taps trigger only once") }
        }
        expect(triggerCount == 2, "four taps form two non-overlapping pairs")
    }

    private static func testLifecycleReset() {
        var machine = DoubleOptionStateMachine()
        _ = tap(&machine, side: .left, down: 0, up: 0.05)
        machine.reset() // Used by monitor start, stop, pause and resume.
        expect(tap(&machine, side: .right, down: 0.10, up: 0.15) == nil, "lifecycle reset clears an armed tap")
        expect(
            tap(&machine, side: .left, down: 0.20, up: 0.25) == .trigger(after: 0.01),
            "recognition resumes from clean state"
        )

        expect(
            machine.process(.keyDown(isAutoRepeat: false), at: .infinity) == nil,
            "non-finite timestamps reset without triggering"
        )
        expect(tap(&machine, side: .left, down: 1.0, up: 1.05) == nil, "non-finite reset clears the pair")
    }

    static func main() {
        testSidesAndReleaseWindow()
        testHoldBoundaryAndTimeout()
        testKeysAndModifiersCancelTheWholeGroup()
        testOverlapRepeatRollbackAndDebounce()
        testLifecycleReset()
        print("DoubleOptionStateMachineTests: \(passed) passed")
    }
}
