import ApplicationServices
import Foundation

enum AccessibilityAuthorizationStatus: Equatable {
    case authorized
    case notAuthorized
}

/// Read-only status plus an explicitly named prompt operation.
///
/// The production app does not call `requestAuthorization()` in this phase.
enum AccessibilityController {
    static var status: AccessibilityAuthorizationStatus {
        AXIsProcessTrusted() ? .authorized : .notAuthorized
    }

    @discardableResult
    static func requestAuthorization() -> AccessibilityAuthorizationStatus {
        let promptKey = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options) ? .authorized : .notAuthorized
    }
}
