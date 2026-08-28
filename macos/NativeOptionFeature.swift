#if !JUYI_NATIVE_SELECTION_CAPTURE_LAB
import Foundation

enum NativeOptionFeature {
    // Release is hard-disabled even if a caller injects the custom condition.
    // Debug requires an explicit compile-time opt-in; there is no defaults,
    // environment, remote-config or runtime switch.
    #if DEBUG && JUYI_NATIVE_OPTION_MONITOR
    static let isEnabled = true
    #else
    static let isEnabled = false
    #endif
}

#if DEBUG
/// Internal-only harness. Recognition exercises AX selection capture into
/// private memory, but never invokes the backend, Hammerspoon or translation UI.
@MainActor
final class NativeOptionDevelopmentHarness {
    private(set) var recognitionCount = 0
    private(set) var lastCaptureResult: NativeSelectionResult?
    private var monitor: NativeOptionMonitor?
    private var captureCoordinator: NativeSelectionCaptureCoordinator?
    private var isPaused = false

    func startIfEnabled() {
        guard NativeOptionFeature.isEnabled, monitor == nil else { return }
        let captureCoordinator = NativeSelectionCaptureCoordinator()
        let candidate = NativeOptionMonitor(
            recognitionInvalidationHandler: { [weak self, weak captureCoordinator] in
                captureCoordinator?.cancelAll()
                self?.lastCaptureResult = nil
            }
        ) { [weak self, weak captureCoordinator] target in
            self?.recognitionCount += 1
            captureCoordinator?.capture(target: target) { [weak self] result in
                MainActor.assumeIsolated {
                    self?.lastCaptureResult = result
                }
            }
        }
        switch candidate.start() {
        case .started, .alreadyRunning:
            candidate.setPaused(isPaused)
            monitor = candidate
            self.captureCoordinator = captureCoordinator
        case .accessibilityRequired, .monitorUnavailable:
            captureCoordinator.cancelAll()
            break
        }
    }

    func applicationBecameActive() {
        guard NativeOptionFeature.isEnabled else { return }
        if let monitor {
            if monitor.refreshAuthorizationStatus() {
                if !monitor.isRunning { _ = monitor.start() }
                return
            }
            captureCoordinator?.cancelAll()
            captureCoordinator = nil
            lastCaptureResult = nil
            self.monitor = nil
        }
        startIfEnabled()
    }

    func setPaused(_ paused: Bool) {
        guard NativeOptionFeature.isEnabled else { return }
        isPaused = paused
        monitor?.setPaused(paused)
        if paused {
            captureCoordinator?.cancelAll()
            lastCaptureResult = nil
        }
    }

    func stop() {
        monitor?.stop()
        captureCoordinator?.cancelAll()
        monitor = nil
        captureCoordinator = nil
        lastCaptureResult = nil
    }
}
#endif
#endif
