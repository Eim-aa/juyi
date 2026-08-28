import AppKit
import ApplicationServices
import Foundation

struct NativeSelectionProcessIdentity: Equatable, Sendable {
    let processIdentifier: pid_t
    let launchDate: Date
}

struct NativeSelectionTarget: Equatable, Sendable {
    let processIdentity: NativeSelectionProcessIdentity
    let bundleIdentifier: String?

    var processIdentifier: pid_t { processIdentity.processIdentifier }
    var launchDate: Date { processIdentity.launchDate }

    init(
        processIdentifier: pid_t,
        launchDate: Date,
        bundleIdentifier: String?
    ) {
        processIdentity = NativeSelectionProcessIdentity(
            processIdentifier: processIdentifier,
            launchDate: launchDate
        )
        self.bundleIdentifier = bundleIdentifier
    }

    init?(application: NSRunningApplication) {
        guard application.processIdentifier > 0,
              let launchDate = application.launchDate else {
            return nil
        }
        self.init(
            processIdentifier: application.processIdentifier,
            launchDate: launchDate,
            bundleIdentifier: application.bundleIdentifier
        )
    }

    func hasSameProcess(as other: NativeSelectionTarget) -> Bool {
        processIdentity == other.processIdentity
    }
}

/// Stable, privacy-preserving outcomes for the future native capture flow.
/// No AX error description or selected text is ever logged by this layer.
enum NativeSelectionResult: Equatable, Sendable {
    case success(text: String, didTruncate: Bool)
    case accessibilityRequired
    case noFocusedElement
    case noSelection
    case unsupported
    case secureField
    case temporarilyUnavailable
    case internalFailure
    case cancelled
}

enum NativeSelectionAXRead: Equatable, Sendable {
    case text(String)
    case accessibilityRequired
    case noFocusedElement
    case noSelection
    case unsupported
    case secureField
    case temporarilyUnavailable
    case internalFailure
    case cancelled
}

/// Pure AX error/security mapping. Keeping it separate from AXUIElement calls
/// makes every fail-closed branch executable without TCC or another process.
enum NativeSelectionAXPolicy {
    enum Stage: Equatable, Sendable {
        case timeoutConfiguration
        case focusedElement
        case focusedElementRevalidation
        case elementIdentity
        case role
        case subrole
        case selectedText
    }

    enum Decision: Equatable, Sendable {
        case proceed
        case finish(NativeSelectionAXRead)
    }

    static func decision(for error: AXError, stage: Stage) -> Decision {
        guard error != .success else { return .proceed }
        if error == .apiDisabled {
            return .finish(.accessibilityRequired)
        }

        switch stage {
        case .focusedElement:
            switch error {
            case .noValue:
                return .finish(.noFocusedElement)
            case .attributeUnsupported, .notImplemented:
                return .finish(.unsupported)
            case .invalidUIElement, .cannotComplete:
                return .finish(.temporarilyUnavailable)
            default:
                return .finish(.internalFailure)
            }

        case .selectedText:
            switch error {
            case .noValue:
                return .finish(.noSelection)
            case .attributeUnsupported, .notImplemented:
                return .finish(.unsupported)
            case .invalidUIElement, .cannotComplete:
                return .finish(.temporarilyUnavailable)
            default:
                return .finish(.internalFailure)
            }

        case .role, .subrole:
            switch error {
            case .noValue, .attributeUnsupported, .notImplemented:
                return .finish(.unsupported)
            case .invalidUIElement, .cannotComplete:
                return .finish(.temporarilyUnavailable)
            default:
                return .finish(.internalFailure)
            }

        case .elementIdentity:
            switch error {
            case .invalidUIElement, .cannotComplete:
                return .finish(.temporarilyUnavailable)
            default:
                return .finish(.cancelled)
            }

        case .focusedElementRevalidation:
            switch error {
            case .invalidUIElement, .cannotComplete:
                return .finish(.temporarilyUnavailable)
            default:
                return .finish(.cancelled)
            }

        case .timeoutConfiguration:
            switch error {
            case .invalidUIElement, .cannotComplete:
                return .finish(.temporarilyUnavailable)
            default:
                return .finish(.internalFailure)
            }
        }
    }

    static func identityDecision(
        elementProcessIdentity: NativeSelectionProcessIdentity?,
        targetProcessIdentity: NativeSelectionProcessIdentity
    ) -> Decision {
        elementProcessIdentity == targetProcessIdentity
            ? .proceed
            : .finish(.cancelled)
    }

    static func focusedElementDecision(elementsMatch: Bool) -> Decision {
        elementsMatch ? .proceed : .finish(.cancelled)
    }

    static func roleAndSubroleValueDecision(
        roleValue: CFTypeRef?,
        subroleValue: CFTypeRef?
    ) -> Decision {
        guard let roleValue,
              CFGetTypeID(roleValue) == CFStringGetTypeID(),
              let subroleValue,
              CFGetTypeID(subroleValue) == CFStringGetTypeID() else {
            return .finish(.unsupported)
        }
        return roleAndSubroleDecision(
            role: roleValue as! String,
            subrole: subroleValue as! String
        )
    }

    static func roleAndSubroleDecision(
        role: String,
        subrole: String
    ) -> Decision {
        if subrole == (kAXSecureTextFieldSubrole as String) {
            return .finish(.secureField)
        }
        guard !role.isEmpty,
              !subrole.isEmpty,
              role != (kAXUnknownRole as String),
              subrole != (kAXUnknownSubrole as String) else {
            return .finish(.unsupported)
        }

        // This default-off foundation only admits a public, documented
        // non-secure pair. Additional app-specific pairs require compatibility
        // evidence and explicit review before activation.
        if role == (kAXTextFieldRole as String),
           subrole == (kAXSearchFieldSubrole as String) {
            return .proceed
        }
        return .finish(.unsupported)
    }
}

/// Injectable AX seam. Tests never touch TCC or another process.
protocol NativeSelectionAXClient {
    var isTrusted: Bool { get }
    var currentProcessIdentifier: pid_t { get }
    var frontmostApplication: NativeSelectionTarget? { get }

    func copySelectedText(
        from target: NativeSelectionTarget
    ) -> NativeSelectionAXRead
}

struct SystemNativeSelectionAXClient: NativeSelectionAXClient {
    private static let messagingTimeout: Float = 0.10

    var isTrusted: Bool {
        AccessibilityController.status == .authorized
    }

    var currentProcessIdentifier: pid_t {
        ProcessInfo.processInfo.processIdentifier
    }

    var frontmostApplication: NativeSelectionTarget? {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return nil
        }
        return NativeSelectionTarget(application: application)
    }

    func copySelectedText(
        from target: NativeSelectionTarget
    ) -> NativeSelectionAXRead {
        let application = AXUIElementCreateApplication(target.processIdentifier)
        let applicationTimeoutError = AXUIElementSetMessagingTimeout(
            application,
            Self.messagingTimeout
        )
        if case let .finish(result) = NativeSelectionAXPolicy.decision(
            for: applicationTimeoutError,
            stage: .timeoutConfiguration
        ) {
            return result
        }
        var focusedValue: CFTypeRef?
        let focusedError = AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &focusedValue
        )
        if case let .finish(result) = NativeSelectionAXPolicy.decision(
            for: focusedError,
            stage: .focusedElement
        ) {
            return result
        }
        guard let focusedValue else { return .noFocusedElement }
        guard CFGetTypeID(focusedValue) == AXUIElementGetTypeID() else {
            return .internalFailure
        }
        let focusedElement = focusedValue as! AXUIElement
        let focusedTimeoutError = AXUIElementSetMessagingTimeout(
            focusedElement,
            Self.messagingTimeout
        )
        if case let .finish(result) = NativeSelectionAXPolicy.decision(
            for: focusedTimeoutError,
            stage: .timeoutConfiguration
        ) {
            return result
        }

        if let result = validateIdentityRoleAndSubrole(
            of: focusedElement,
            against: target
        ) {
            return result
        }

        var selectedValue: CFTypeRef?
        let selectedError = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        )
        if case let .finish(result) = NativeSelectionAXPolicy.decision(
            for: selectedError,
            stage: .selectedText
        ) {
            return result
        }
        guard let selectedValue else { return .noSelection }
        guard CFGetTypeID(selectedValue) == CFStringGetTypeID() else {
            return .unsupported
        }
        let selectedText = selectedValue as! String

        // AXSelectedText is not an atomic snapshot with focus. Re-read the
        // focused element after the text call, require CF identity, and repeat
        // process/role/subrole validation before releasing the in-memory string.
        var revalidatedFocusedValue: CFTypeRef?
        let revalidatedFocusedError = AXUIElementCopyAttributeValue(
            application,
            kAXFocusedUIElementAttribute as CFString,
            &revalidatedFocusedValue
        )
        if case let .finish(result) = NativeSelectionAXPolicy.decision(
            for: revalidatedFocusedError,
            stage: .focusedElementRevalidation
        ) {
            return result
        }
        guard let revalidatedFocusedValue,
              CFGetTypeID(revalidatedFocusedValue) == AXUIElementGetTypeID() else {
            return .cancelled
        }
        let revalidatedFocusedElement = revalidatedFocusedValue as! AXUIElement
        if case let .finish(result) = NativeSelectionAXPolicy.focusedElementDecision(
            elementsMatch: CFEqual(focusedElement, revalidatedFocusedElement)
        ) {
            return result
        }
        let revalidatedTimeoutError = AXUIElementSetMessagingTimeout(
            revalidatedFocusedElement,
            Self.messagingTimeout
        )
        if case let .finish(result) = NativeSelectionAXPolicy.decision(
            for: revalidatedTimeoutError,
            stage: .timeoutConfiguration
        ) {
            return result
        }
        if let result = validateIdentityRoleAndSubrole(
            of: revalidatedFocusedElement,
            against: target
        ) {
            return result
        }
        return .text(selectedText)
    }

    private func validateIdentityRoleAndSubrole(
        of element: AXUIElement,
        against target: NativeSelectionTarget
    ) -> NativeSelectionAXRead? {
        var elementPID: pid_t = 0
        let pidError = AXUIElementGetPid(element, &elementPID)
        if case let .finish(result) = NativeSelectionAXPolicy.decision(
            for: pidError,
            stage: .elementIdentity
        ) {
            return result
        }
        let elementIdentity = NSRunningApplication(processIdentifier: elementPID)
            .flatMap { NativeSelectionTarget(application: $0) }?
            .processIdentity
        if case let .finish(result) = NativeSelectionAXPolicy.identityDecision(
            elementProcessIdentity: elementIdentity,
            targetProcessIdentity: target.processIdentity
        ) {
            return result
        }

        // Fail closed before touching AXSelectedText. Missing, unsupported,
        // non-string, unknown, or unapproved role/subrole values are not safe.
        var roleValue: CFTypeRef?
        let roleError = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleValue
        )
        if case let .finish(result) = NativeSelectionAXPolicy.decision(
            for: roleError,
            stage: .role
        ) {
            return result
        }
        var subroleValue: CFTypeRef?
        let subroleError = AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &subroleValue
        )
        if case let .finish(result) = NativeSelectionAXPolicy.decision(
            for: subroleError,
            stage: .subrole
        ) {
            return result
        }
        if case let .finish(result) = NativeSelectionAXPolicy.roleAndSubroleValueDecision(
            roleValue: roleValue,
            subroleValue: subroleValue
        ) {
            return result
        }
        return nil
    }
}

/// AX-only selection policy. It has no clipboard fallback and performs no
/// backend, popup, activation, persistence, or logging work.
struct NativeSelectionReader<Client: NativeSelectionAXClient> {
    // Mirrors config.MAX_INPUT_CHARS; a static contract keeps both in sync.
    static var maximumInputCharacters: Int { 5_000 }

    private let client: Client

    init(client: Client) {
        self.client = client
    }

    func readSelection(
        for target: NativeSelectionTarget
    ) -> NativeSelectionResult {
        let targetPID = target.processIdentifier
        guard targetPID > 0 else { return .cancelled }
        guard targetPID != client.currentProcessIdentifier else {
            return .cancelled
        }
        guard client.isTrusted else { return .accessibilityRequired }
        guard client.frontmostApplication?.hasSameProcess(as: target) == true else {
            return .cancelled
        }

        let selection = client.copySelectedText(from: target)
        // Synchronous AX can span several bounded messages. Recheck after it
        // returns so a focus switch during the read can never deliver old-App
        // text to the caller.
        guard client.frontmostApplication?.hasSameProcess(as: target) == true else {
            return .cancelled
        }

        switch selection {
        case let .text(rawText):
            return Self.normalize(rawText)
        case .accessibilityRequired:
            return .accessibilityRequired
        case .noFocusedElement:
            return .noFocusedElement
        case .noSelection:
            return .noSelection
        case .unsupported:
            return .unsupported
        case .secureField:
            return .secureField
        case .temporarilyUnavailable:
            return .temporarilyUnavailable
        case .internalFailure:
            return .internalFailure
        case .cancelled:
            return .cancelled
        }
    }

    private static func normalize(_ rawText: String) -> NativeSelectionResult {
        let normalized = rawText
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return .noSelection }

        let scalars = normalized.unicodeScalars
        guard scalars.count > maximumInputCharacters else {
            return .success(text: normalized, didTruncate: false)
        }
        return .success(
            text: String(scalars.prefix(maximumInputCharacters)),
            didTruncate: true
        )
    }
}

extension NativeSelectionReader where Client == SystemNativeSelectionAXClient {
    init() {
        self.init(client: SystemNativeSelectionAXClient())
    }
}
