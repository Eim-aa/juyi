import Foundation

/// Pure recognition policy for the native double-Option experiment.
///
/// Normal timing matches the existing Hammerspoon gesture: each press must be
/// released within 350 ms and the two release timestamps must be no more than
/// 350 ms apart. The native experiment is intentionally stricter about an
/// intervening key or modifier so it cannot create surprise translations.
struct DoubleOptionStateMachine {
    struct Configuration: Equatable {
        var maximumHoldDuration: TimeInterval = 0.35
        var maximumReleaseInterval: TimeInterval = 0.35
        var deliveryDelay: TimeInterval = 0.01

        init(
            maximumHoldDuration: TimeInterval = 0.35,
            maximumReleaseInterval: TimeInterval = 0.35,
            deliveryDelay: TimeInterval = 0.01
        ) {
            precondition(maximumHoldDuration >= 0)
            precondition(maximumReleaseInterval >= 0)
            precondition(deliveryDelay >= 0)
            self.maximumHoldDuration = maximumHoldDuration
            self.maximumReleaseInterval = maximumReleaseInterval
            self.deliveryDelay = deliveryDelay
        }
    }

    struct Modifiers: OptionSet, Equatable {
        let rawValue: UInt8

        static let option = Modifiers(rawValue: 1 << 0)
        static let command = Modifiers(rawValue: 1 << 1)
        static let control = Modifiers(rawValue: 1 << 2)
        static let shift = Modifiers(rawValue: 1 << 3)
        static let function = Modifiers(rawValue: 1 << 4)

        static let disallowedDuringSequence: Modifiers = [
            .command, .control, .shift, .function,
        ]
    }

    enum OptionSide: Equatable, Hashable {
        case left
        case right
    }

    enum Input: Equatable {
        case optionChanged(side: OptionSide, isDown: Bool, modifiers: Modifiers)
        case modifiersChanged(Modifiers)
        case keyDown(isAutoRepeat: Bool)
    }

    enum Effect: Equatable {
        case trigger(after: TimeInterval)
    }

    private let configuration: Configuration
    private var optionSidesDown: Set<OptionSide> = []
    private var pressStartedAt: TimeInterval?
    private var pressIsClean = false
    private var firstCleanReleaseAt: TimeInterval?
    private var lastObservedTime: TimeInterval?

    init(configuration: Configuration = Configuration()) {
        self.configuration = configuration
    }

    mutating func process(_ input: Input, at timestamp: TimeInterval) -> Effect? {
        guard timestamp.isFinite else {
            reset()
            return nil
        }

        if let lastObservedTime, timestamp < lastObservedTime {
            // Native event timestamps are monotonic, but reset defensively if
            // an injected/test clock moves backwards so a negative gap can
            // never be mistaken for a fast tap.
            resetGestureState()
        }
        lastObservedTime = timestamp

        if let firstCleanReleaseAt,
           timestamp - firstCleanReleaseAt > configuration.maximumReleaseInterval {
            self.firstCleanReleaseAt = nil
        }

        switch input {
        case let .optionChanged(side, isDown, modifiers):
            return processOptionChange(
                side: side,
                isDown: isDown,
                modifiers: modifiers,
                at: timestamp
            )

        case let .modifiersChanged(modifiers):
            if !modifiers.intersection(.disallowedDuringSequence).isEmpty {
                cancelSequence()
            }
            return nil

        case .keyDown:
            // This includes automatic repeats. A normal key anywhere between
            // the first press and the second release cancels the whole group.
            if !optionSidesDown.isEmpty || firstCleanReleaseAt != nil {
                cancelSequence()
            }
            return nil
        }
    }

    mutating func reset() {
        resetGestureState()
        lastObservedTime = nil
    }

    private mutating func processOptionChange(
        side: OptionSide,
        isDown: Bool,
        modifiers: Modifiers,
        at timestamp: TimeInterval
    ) -> Effect? {
        if isDown {
            guard !optionSidesDown.contains(side) else {
                // Redundant modifier-down events must not synthesize taps.
                cancelSequence()
                return nil
            }

            if optionSidesDown.isEmpty {
                optionSidesDown.insert(side)
                pressStartedAt = timestamp
                pressIsClean = modifiers.contains(.option)
                    && modifiers.intersection(.disallowedDuringSequence).isEmpty
                if !pressIsClean { firstCleanReleaseAt = nil }
            } else {
                // Pressing left and right Option together is not a lone tap.
                optionSidesDown.insert(side)
                cancelSequence(keepingOptionsDown: true)
            }
            return nil
        }

        guard optionSidesDown.remove(side) != nil else {
            // A duplicate release cannot deliver a second trigger.
            return nil
        }

        guard optionSidesDown.isEmpty else {
            cancelSequence(keepingOptionsDown: true)
            return nil
        }

        defer {
            pressStartedAt = nil
            pressIsClean = false
        }

        guard let pressStartedAt else {
            firstCleanReleaseAt = nil
            return nil
        }

        let holdDuration = timestamp - pressStartedAt
        let cleanRelease = pressIsClean
            && holdDuration >= 0
            && holdDuration <= configuration.maximumHoldDuration
            && !modifiers.contains(.option)
            && modifiers.intersection(.disallowedDuringSequence).isEmpty

        guard cleanRelease else {
            firstCleanReleaseAt = nil
            return nil
        }

        if let firstCleanReleaseAt {
            let releaseInterval = timestamp - firstCleanReleaseAt
            if releaseInterval >= 0,
               releaseInterval <= configuration.maximumReleaseInterval {
                self.firstCleanReleaseAt = nil
                return .trigger(after: configuration.deliveryDelay)
            }
        }

        firstCleanReleaseAt = timestamp
        return nil
    }

    private mutating func cancelSequence(keepingOptionsDown: Bool = false) {
        firstCleanReleaseAt = nil
        pressStartedAt = keepingOptionsDown ? pressStartedAt : nil
        pressIsClean = false
    }

    private mutating func resetGestureState() {
        optionSidesDown.removeAll()
        pressStartedAt = nil
        pressIsClean = false
        firstCleanReleaseAt = nil
    }
}
