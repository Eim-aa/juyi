import CoreGraphics
import Foundation

private func nativeOptionEventTapCallback(
    proxy _: CGEventTapProxy,
    type: CGEventType,
    event: CGEvent,
    userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let monitor = Unmanaged<NativeOptionMonitor>.fromOpaque(userInfo).takeUnretainedValue()
    return monitor.handleTapEvent(type: type, event: event)
}

/// Listen-only CGEvent adapter for `DoubleOptionStateMachine`.
///
/// It never suppresses an event and never performs translation work in the
/// tap callback. Recognition is delivered asynchronously on the main queue.
final class NativeOptionMonitor {
    enum StartResult: Equatable {
        case started
        case alreadyRunning
        /// The event tap could not be created. This intentionally does not
        /// guess whether permission, session state, or another system limit
        /// was responsible.
        case tapUnavailable
    }

    private static let leftOptionKeyCode: CGKeyCode = 58
    private static let rightOptionKeyCode: CGKeyCode = 61
    private static let capsLockKeyCode: CGKeyCode = 57

    private let lock = NSLock()
    private let recognitionHandler: () -> Void
    private var stateMachine: DoubleOptionStateMachine
    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?
    private var runLoop: CFRunLoop?
    private var paused = false
    private var generation = 0

    init(
        stateMachine: DoubleOptionStateMachine = DoubleOptionStateMachine(),
        recognitionHandler: @escaping () -> Void
    ) {
        self.stateMachine = stateMachine
        self.recognitionHandler = recognitionHandler
    }

    deinit {
        stop()
    }

    @discardableResult
    func start() -> StartResult {
        lock.lock()
        stateMachine.reset()
        if eventTap != nil {
            generation += 1
            lock.unlock()
            return .alreadyRunning
        }

        let eventMask = (CGEventMask(1) << CGEventType.flagsChanged.rawValue)
            | (CGEventMask(1) << CGEventType.keyDown.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: eventMask,
            callback: nativeOptionEventTapCallback,
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            lock.unlock()
            return .tapUnavailable
        }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            lock.unlock()
            return .tapUnavailable
        }

        let targetRunLoop = CFRunLoopGetMain()
        eventTap = tap
        runLoopSource = source
        runLoop = targetRunLoop
        generation += 1
        let shouldEnable = !paused
        lock.unlock()

        CFRunLoopAddSource(targetRunLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: shouldEnable)
        return .started
    }

    func setPaused(_ shouldPause: Bool) {
        lock.lock()
        paused = shouldPause
        stateMachine.reset()
        generation += 1
        let tap = eventTap
        lock.unlock()

        if let tap {
            CGEvent.tapEnable(tap: tap, enable: !shouldPause)
        }
    }

    func stop() {
        lock.lock()
        stateMachine.reset()
        guard let tap = eventTap else {
            lock.unlock()
            return
        }
        let source = runLoopSource
        let targetRunLoop = runLoop
        eventTap = nil
        runLoopSource = nil
        runLoop = nil
        generation += 1
        lock.unlock()

        CGEvent.tapEnable(tap: tap, enable: false)
        if let source, let targetRunLoop {
            CFRunLoopRemoveSource(targetRunLoop, source, .commonModes)
            CFRunLoopSourceInvalidate(source)
        }
        CFMachPortInvalidate(tap)
    }

    fileprivate func handleTapEvent(
        type: CGEventType,
        event: CGEvent
    ) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            lock.lock()
            stateMachine.reset()
            generation += 1
            let tap = eventTap
            let shouldRestart = tap != nil && !paused
            lock.unlock()
            if let tap, shouldRestart {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard let input = Self.input(for: type, event: event) else {
            return Unmanaged.passUnretained(event)
        }

        let timestamp = TimeInterval(event.timestamp) / 1_000_000_000
        lock.lock()
        guard eventTap != nil, !paused else {
            lock.unlock()
            return Unmanaged.passUnretained(event)
        }
        let effect = stateMachine.process(input, at: timestamp)
        let deliveryGeneration = generation
        lock.unlock()

        if case let .trigger(delay)? = effect {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                self?.deliverRecognition(ifGenerationIs: deliveryGeneration)
            }
        }
        return Unmanaged.passUnretained(event)
    }

    private func deliverRecognition(ifGenerationIs expectedGeneration: Int) {
        lock.lock()
        let shouldDeliver = eventTap != nil
            && !paused
            && generation == expectedGeneration
        let handler = recognitionHandler
        lock.unlock()
        if shouldDeliver { handler() }
    }

    private static func input(
        for type: CGEventType,
        event: CGEvent
    ) -> DoubleOptionStateMachine.Input? {
        switch type {
        case .keyDown:
            let rawKeyCode = event.getIntegerValueField(.keyboardEventKeycode)
            if rawKeyCode == Int64(capsLockKeyCode) {
                // Some synthetic event sources represent Caps Lock as keyDown.
                // Treat it like its flagsChanged form so it remains irrelevant.
                return .modifiersChanged(relevantModifiers(from: event.flags))
            }
            let isRepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
            return .keyDown(isAutoRepeat: isRepeat)

        case .flagsChanged:
            let modifiers = relevantModifiers(from: event.flags)
            let rawKeyCode = event.getIntegerValueField(.keyboardEventKeycode)
            guard rawKeyCode >= 0, rawKeyCode <= Int64(CGKeyCode.max) else {
                return .modifiersChanged(modifiers)
            }
            let keyCode = CGKeyCode(rawKeyCode)
            let side: DoubleOptionStateMachine.OptionSide
            switch keyCode {
            case leftOptionKeyCode: side = .left
            case rightOptionKeyCode: side = .right
            default: return .modifiersChanged(modifiers)
            }
            let isDown = CGEventSource.keyState(.combinedSessionState, key: keyCode)
            return .optionChanged(side: side, isDown: isDown, modifiers: modifiers)

        default:
            return nil
        }
    }

    private static func relevantModifiers(
        from flags: CGEventFlags
    ) -> DoubleOptionStateMachine.Modifiers {
        var modifiers: DoubleOptionStateMachine.Modifiers = []
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskSecondaryFn) { modifiers.insert(.function) }
        // Caps Lock is intentionally not mapped, matching the product policy.
        return modifiers
    }
}
