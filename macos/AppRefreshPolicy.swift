import Foundation

/// Inputs for AppModel's periodic refresh. Kept free of AppKit so the policy
/// can be unit-tested without launching the app.
struct AppRefreshContext: Equatable {
    var cloudSetupVisible: Bool
    var diagnosticsVisible: Bool
    var applicationActive: Bool
}

enum AppRefreshPolicy {
    static let activeInterval: TimeInterval = 2.5
    static let idleInterval: TimeInterval = 10

    /// The periodic tick only re-runs the cheap early-component detection.
    /// No engine depends on an external process, so an idle app uses the
    /// slow cadence regardless of the selected engine.
    static func interval(_ context: AppRefreshContext) -> TimeInterval {
        context.applicationActive
            || context.cloudSetupVisible
            || context.diagnosticsVisible
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
