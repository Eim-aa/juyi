import Foundation

/// Inputs for AppModel's periodic refresh. Kept free of AppKit so the policy
/// can be unit-tested without launching the app.
struct AppRefreshContext: Equatable {
    var selectedEngine: String
    var cloudSetupVisible: Bool
    var diagnosticsVisible: Bool
    var launchAgentInstalled: Bool
    var applicationActive: Bool
}

enum AppRefreshPolicy {
    static let activeInterval: TimeInterval = 2.5
    static let idleInterval: TimeInterval = 10

    /// The loopback service exists only for the optional cloud and legacy
    /// path. An Apple-only installation has nothing listening on the port, so
    /// the periodic tick reads local state files only.
    static func shouldProbeService(_ context: AppRefreshContext) -> Bool {
        context.selectedEngine != "apple"
            || context.cloudSetupVisible
            || context.diagnosticsVisible
            || context.launchAgentInstalled
    }

    /// The cloud path keeps the active cadence because its shortcut status is
    /// derived from a legacy heartbeat that expires after a few seconds.
    static func interval(_ context: AppRefreshContext) -> TimeInterval {
        context.applicationActive
            || context.cloudSetupVisible
            || context.diagnosticsVisible
            || context.selectedEngine != "apple"
            ? activeInterval
            : idleInterval
    }
}

/// Everything the status item and its menu display. The menu is rebuilt only
/// when this derived snapshot changes.
struct AppChromeSnapshot: Equatable {
    var summaryStatus: String
    var statusSymbol: String
    var primaryActionTitle: String
    var primaryActionEnabled: Bool
    var showsPauseItem: Bool
    var selectedEngine: String
    var engineMenuEnabled: Bool
    var onboardingCompleted: Bool
}

struct AppChromeRenderGate {
    private(set) var rendered: AppChromeSnapshot?

    /// Records `snapshot` and reports whether it differs from the last one
    /// rendered. Duplicate change notifications therefore cost no rebuild.
    mutating func needsRender(_ snapshot: AppChromeSnapshot) -> Bool {
        guard snapshot != rendered else { return false }
        rendered = snapshot
        return true
    }
}
