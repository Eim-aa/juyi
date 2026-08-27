import Foundation

/// Platform-neutral event snapshot used between AppKit and the gesture policy.
/// It deliberately carries no characters, Unicode scalar, or text payload.
struct NativeOptionEventSnapshot: Equatable {
    enum Kind: Equatable {
        case flagsChanged
        case keyDown
    }

    let kind: Kind
    let keyCode: UInt16
    let modifiers: DoubleOptionStateMachine.Modifiers
    let timestamp: TimeInterval
    let isAutoRepeat: Bool
}

/// Converts NSEvent-shaped snapshots into the existing pure gesture inputs.
///
/// NSEvent exposes the side that changed through `keyCode`, but its Option flag
/// is aggregate. Tracking each side lets an overlapping left/right press be
/// represented without querying a lower-level event API.
struct NativeOptionEventAdapter {
    private static let capsLockKeyCode: UInt16 = 57
    private static let leftOptionKeyCode: UInt16 = 58
    private static let rightOptionKeyCode: UInt16 = 61

    private var optionSidesDown: Set<DoubleOptionStateMachine.OptionSide> = []
    private var awaitingAllOptionRelease = false

    init(optionInitiallyDown: Bool = false) {
        reset(optionInitiallyDown: optionInitiallyDown)
    }

    mutating func reset(optionInitiallyDown: Bool) {
        optionSidesDown.removeAll()
        awaitingAllOptionRelease = optionInitiallyDown
    }

    mutating func input(
        for event: NativeOptionEventSnapshot
    ) -> DoubleOptionStateMachine.Input? {
        switch event.kind {
        case .keyDown:
            if event.keyCode == Self.capsLockKeyCode {
                return .modifiersChanged(event.modifiers)
            }
            return .keyDown(isAutoRepeat: event.isAutoRepeat)

        case .flagsChanged:
            guard let side = Self.optionSide(for: event.keyCode) else {
                return .modifiersChanged(event.modifiers)
            }

            if awaitingAllOptionRelease {
                if !event.modifiers.contains(.option) {
                    awaitingAllOptionRelease = false
                    optionSidesDown.removeAll()
                }
                return nil
            }

            if optionSidesDown.remove(side) != nil {
                return .optionChanged(
                    side: side,
                    isDown: false,
                    modifiers: event.modifiers
                )
            }

            // An untracked Option event without the aggregate Option flag is
            // a release observed after startup/resume. Ignore it rather than
            // manufacturing a press.
            guard event.modifiers.contains(.option) else { return nil }
            optionSidesDown.insert(side)
            return .optionChanged(
                side: side,
                isDown: true,
                modifiers: event.modifiers
            )
        }
    }

    private static func optionSide(
        for keyCode: UInt16
    ) -> DoubleOptionStateMachine.OptionSide? {
        switch keyCode {
        case leftOptionKeyCode: return .left
        case rightOptionKeyCode: return .right
        default: return nil
        }
    }
}
