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
/// Internal-only harness. Recognition increments a private counter and never
/// invokes selection capture, the backend, Hammerspoon or translation UI.
final class NativeOptionDevelopmentHarness {
    private(set) var recognitionCount = 0
    private var monitor: NativeOptionMonitor?

    func startIfEnabled() {
        guard NativeOptionFeature.isEnabled, monitor == nil else { return }
        let candidate = NativeOptionMonitor { [weak self] in
            self?.recognitionCount += 1
        }
        switch candidate.start() {
        case .started, .alreadyRunning:
            monitor = candidate
        case .tapUnavailable:
            break
        }
    }

    func stop() {
        monitor?.stop()
        monitor = nil
    }
}
#endif
