import AppKit
import Foundation

@MainActor
protocol NativeOptionEventSource: AnyObject {
    var optionIsCurrentlyDown: Bool { get }

    func addGlobalMonitor(
        handler: @escaping (NativeOptionEventSnapshot) -> Void
    ) -> Any?
    func removeMonitor(_ monitor: Any)
}

/// AppKit adapter for the production trigger. A global NSEvent monitor only
/// observes events sent to other applications and cannot alter their delivery.
/// There is intentionally no app-wide local monitor in this phase.
@MainActor
final class NSEventNativeOptionEventSource: NativeOptionEventSource {
    private static let mask: NSEvent.EventTypeMask = [.flagsChanged, .keyDown]

    var optionIsCurrentlyDown: Bool {
        NSEvent.modifierFlags.contains(.option)
    }

    func addGlobalMonitor(
        handler: @escaping (NativeOptionEventSnapshot) -> Void
    ) -> Any? {
        NSEvent.addGlobalMonitorForEvents(matching: Self.mask) { event in
            MainActor.assumeIsolated {
                handler(Self.snapshot(from: event))
            }
        }
    }

    func removeMonitor(_ monitor: Any) {
        NSEvent.removeMonitor(monitor)
    }

    private static func snapshot(from event: NSEvent) -> NativeOptionEventSnapshot {
        let kind: NativeOptionEventSnapshot.Kind = event.type == .keyDown
            ? .keyDown
            : .flagsChanged
        return NativeOptionEventSnapshot(
            kind: kind,
            keyCode: event.keyCode,
            modifiers: relevantModifiers(from: event.modifierFlags),
            timestamp: event.timestamp,
            isAutoRepeat: kind == .keyDown && event.isARepeat
        )
    }

    private static func relevantModifiers(
        from flags: NSEvent.ModifierFlags
    ) -> DoubleOptionStateMachine.Modifiers {
        let flags = flags.intersection(.deviceIndependentFlagsMask)
        var modifiers: DoubleOptionStateMachine.Modifiers = []
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.function) { modifiers.insert(.function) }
        // Caps Lock is intentionally not represented in the gesture policy.
        return modifiers
    }
}

/// Explicitly enabled native recognizer host.
///
/// The NSEvent callback only updates gesture state and captures the frontmost
/// process identity. AX selection work belongs to the separate serial worker and is
/// never performed here.
@MainActor
final class NativeOptionMonitor {
    enum StartResult: Equatable {
        case started
        case alreadyRunning
        case accessibilityRequired
        case monitorUnavailable
    }

    typealias DeliveryScheduler = (
        _ delay: TimeInterval,
        _ action: @escaping () -> Void
    ) -> Void

    private let eventSource: NativeOptionEventSource
    private let accessibilityStatus: () -> AccessibilityAuthorizationStatus
    private let frontmostApplication: () -> NativeSelectionTarget?
    private let selectionPoint: () -> NativeSelectionPoint?
    private let currentProcessIdentifier: pid_t
    private let recognitionInvalidationHandler: () -> Void
    private let recognitionHandler: (NativeSelectionTarget) -> Void
    private let deliveryScheduler: DeliveryScheduler

    private var stateMachine: DoubleOptionStateMachine
    private var eventAdapter = NativeOptionEventAdapter()
    private var globalMonitor: Any?
    private var paused = false
    private var generation = 0

    init(
        eventSource: NativeOptionEventSource? = nil,
        accessibilityStatus: @escaping () -> AccessibilityAuthorizationStatus = {
            AccessibilityController.status
        },
        frontmostApplication: @escaping () -> NativeSelectionTarget? = {
            guard let application = NSWorkspace.shared.frontmostApplication else {
                return nil
            }
            return NativeSelectionTarget(application: application)
        },
        selectionPoint: @escaping () -> NativeSelectionPoint? = {
            guard let primaryScreen = NSScreen.screens.first else { return nil }
            let appKitPoint = NSEvent.mouseLocation
            return NativeSelectionPoint(
                x: appKitPoint.x,
                y: primaryScreen.frame.maxY - appKitPoint.y
            )
        },
        currentProcessIdentifier: pid_t = ProcessInfo.processInfo.processIdentifier,
        stateMachine: DoubleOptionStateMachine = DoubleOptionStateMachine(),
        deliveryScheduler: @escaping DeliveryScheduler = { delay, action in
            let workItem = DispatchWorkItem(block: action)
            DispatchQueue.main.asyncAfter(
                deadline: .now() + delay,
                execute: workItem
            )
        },
        recognitionInvalidationHandler: @escaping () -> Void = {},
        recognitionHandler: @escaping (NativeSelectionTarget) -> Void
    ) {
        self.eventSource = eventSource ?? NSEventNativeOptionEventSource()
        self.accessibilityStatus = accessibilityStatus
        self.frontmostApplication = frontmostApplication
        self.selectionPoint = selectionPoint
        self.currentProcessIdentifier = currentProcessIdentifier
        self.stateMachine = stateMachine
        self.deliveryScheduler = deliveryScheduler
        self.recognitionInvalidationHandler = recognitionInvalidationHandler
        self.recognitionHandler = recognitionHandler
    }

    var isRunning: Bool { globalMonitor != nil }

    @discardableResult
    func start() -> StartResult {
        guard accessibilityStatus() == .authorized else {
            invalidatePendingGesture()
            removeGlobalMonitorIfNeeded()
            return .accessibilityRequired
        }
        if globalMonitor != nil { return .alreadyRunning }
        invalidatePendingGesture()

        guard let monitor = eventSource.addGlobalMonitor(handler: { [weak self] event in
            self?.receive(event)
        }) else {
            return .monitorUnavailable
        }
        globalMonitor = monitor
        return .started
    }

    func setPaused(_ shouldPause: Bool) {
        guard paused != shouldPause else { return }
        paused = shouldPause
        invalidatePendingGesture()
        if !shouldPause, accessibilityStatus() != .authorized {
            removeGlobalMonitorIfNeeded()
        }
    }

    func stop() {
        invalidatePendingGesture(optionInitiallyDown: false)
        removeGlobalMonitorIfNeeded()
    }

    /// Called from an ordinary app lifecycle boundary, never from the NSEvent
    /// handler. Revocation invalidates pending delivery and removes the token.
    @discardableResult
    func refreshAuthorizationStatus() -> Bool {
        guard accessibilityStatus() == .authorized else {
            invalidatePendingGesture()
            removeGlobalMonitorIfNeeded()
            return false
        }
        return true
    }

    private func receive(_ event: NativeOptionEventSnapshot) {
        guard globalMonitor != nil, !paused else { return }
        guard let input = eventAdapter.input(for: event) else { return }
        guard case let .trigger(delay)? = stateMachine.process(
            input,
            at: event.timestamp
        ) else { return }

        // Every recognized second release supersedes older selection work,
        // even if this new recognition later fails identity/permission checks.
        generation += 1
        let deliveryGeneration = generation
        recognitionInvalidationHandler()

        // Snapshot PID + launch date at the second Option release. Bundle ID is
        // metadata only and is never accepted as process identity.
        // NSEvent global monitoring does not observe this app, and the explicit
        // PID check provides a second fail-closed boundary.
        guard let target = frontmostApplication()?.withSelectionPoint(selectionPoint()),
              target.processIdentifier > 0,
              target.processIdentifier != currentProcessIdentifier else {
            return
        }

        deliveryScheduler(delay) { [weak self] in
            self?.deliver(
                target: target,
                ifGenerationIs: deliveryGeneration
            )
        }
    }

    private func deliver(
        target: NativeSelectionTarget,
        ifGenerationIs expectedGeneration: Int
    ) {
        guard globalMonitor != nil,
              !paused,
              generation == expectedGeneration else { return }
        guard accessibilityStatus() == .authorized else {
            invalidatePendingGesture()
            removeGlobalMonitorIfNeeded()
            return
        }
        guard target.processIdentifier != currentProcessIdentifier,
              frontmostApplication()?.hasSameProcess(as: target) == true else {
            return
        }
        recognitionHandler(target)
    }

    private func invalidatePendingGesture(
        optionInitiallyDown: Bool? = nil
    ) {
        generation += 1
        stateMachine.reset()
        eventAdapter.reset(
            optionInitiallyDown: optionInitiallyDown
                ?? eventSource.optionIsCurrentlyDown
        )
    }

    private func removeGlobalMonitorIfNeeded() {
        guard let monitor = globalMonitor else { return }
        globalMonitor = nil
        eventSource.removeMonitor(monitor)
    }
}
