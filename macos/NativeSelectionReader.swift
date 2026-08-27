import AppKit
import ApplicationServices
import Foundation

struct NativeSelectionTarget: Equatable {
    let processIdentifier: pid_t
    let bundleIdentifier: String?
}

/// Stable, privacy-preserving outcomes for the future native capture flow.
/// No AX error description or selected text is ever logged by this layer.
enum NativeSelectionResult: Equatable {
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

enum NativeSelectionAXRead: Equatable {
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
    enum Stage: Equatable {
        case timeoutConfiguration
        case focusedElement
        case elementIdentity
        case subrole
        case selectedText
    }

    enum Decision: Equatable {
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

        case .subrole:
            switch error {
            case .noValue, .attributeUnsupported:
                return .proceed
            case .notImplemented:
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
        elementProcessIdentifier: pid_t,
        targetProcessIdentifier: pid_t
    ) -> Decision {
        elementProcessIdentifier == targetProcessIdentifier
            ? .proceed
            : .finish(.cancelled)
    }

    static func subroleDecision(_ subrole: String) -> Decision {
        subrole == (kAXSecureTextFieldSubrole as String)
            ? .finish(.secureField)
            : .proceed
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
        return NativeSelectionTarget(
            processIdentifier: application.processIdentifier,
            bundleIdentifier: application.bundleIdentifier
        )
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

        var elementPID: pid_t = 0
        let pidError = AXUIElementGetPid(focusedElement, &elementPID)
        if case let .finish(result) = NativeSelectionAXPolicy.decision(
            for: pidError,
            stage: .elementIdentity
        ) {
            return result
        }
        if case let .finish(result) = NativeSelectionAXPolicy.identityDecision(
            elementProcessIdentifier: elementPID,
            targetProcessIdentifier: target.processIdentifier
        ) {
            return result
        }

        // Fail closed before touching AXSelectedText. The public AX contract
        // identifies secure password controls by this exact subrole.
        var subroleValue: CFTypeRef?
        let subroleError = AXUIElementCopyAttributeValue(
            focusedElement,
            kAXSubroleAttribute as CFString,
            &subroleValue
        )
        switch NativeSelectionAXPolicy.decision(
            for: subroleError,
            stage: .subrole
        ) {
        case .proceed where subroleError == .success:
            guard let subroleValue,
                  CFGetTypeID(subroleValue) == CFStringGetTypeID() else {
                return .internalFailure
            }
            let subrole = subroleValue as! String
            if case let .finish(result) = NativeSelectionAXPolicy.subroleDecision(
                subrole
            ) {
                return result
            }
        case .proceed:
            break // Subrole is optional for ordinary text elements.
        case let .finish(result):
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
        return .text(selectedValue as! String)
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
        guard client.frontmostApplication?.processIdentifier == targetPID else {
            return .cancelled
        }

        let selection = client.copySelectedText(from: target)
        // Synchronous AX can span several bounded messages. Recheck after it
        // returns so a focus switch during the read can never deliver old-App
        // text to the caller.
        guard client.frontmostApplication?.processIdentifier == targetPID else {
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
