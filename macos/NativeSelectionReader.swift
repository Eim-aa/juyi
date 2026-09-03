import AppKit
import ApplicationServices
import Foundation

struct NativeSelectionProcessIdentity: Equatable, Sendable {
    let processIdentifier: pid_t
    let launchDate: Date
}

struct NativeSelectionPoint: Equatable, Sendable {
    let x: Double
    let y: Double
}

struct NativeSelectionTarget: Equatable, Sendable {
    let processIdentity: NativeSelectionProcessIdentity
    let bundleIdentifier: String?
    let selectionPoint: NativeSelectionPoint?

    var processIdentifier: pid_t { processIdentity.processIdentifier }
    var launchDate: Date { processIdentity.launchDate }

    init(
        processIdentifier: pid_t,
        launchDate: Date,
        bundleIdentifier: String?,
        selectionPoint: NativeSelectionPoint? = nil
    ) {
        processIdentity = NativeSelectionProcessIdentity(
            processIdentifier: processIdentifier,
            launchDate: launchDate
        )
        self.bundleIdentifier = bundleIdentifier
        self.selectionPoint = selectionPoint
    }

    init?(application: NSRunningApplication) {
        guard application.processIdentifier > 0,
              let launchDate = application.launchDate else {
            return nil
        }
        self.init(
            processIdentifier: application.processIdentifier,
            launchDate: launchDate,
            bundleIdentifier: application.bundleIdentifier,
            selectionPoint: nil
        )
    }

    func withSelectionPoint(_ point: NativeSelectionPoint?) -> Self {
        Self(
            processIdentifier: processIdentifier,
            launchDate: launchDate,
            bundleIdentifier: bundleIdentifier,
            selectionPoint: point
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

        // The focused editable path only admits a public, documented
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
    // Electron/WebKit and busy AppKit controls regularly need more than 100 ms
    // to answer the first focused-element query. Keep every AX message bounded,
    // but allow enough time for a real foreground control to respond.
    private static let messagingTimeout: Float = 0.50
    private static let wpsBundleIdentifier = "com.kingsoft.wpsoffice.mac"
    private static let clipboardCopyTimeout: TimeInterval = 1.20
    private static let clipboardStableInterval: TimeInterval = 0.08
    private static let maximumClipboardSnapshotBytes = 64 * 1_024 * 1_024
    private static let clipboardMarkerType = NSPasteboard.PasteboardType(
        "io.github.Eim-aa.Juyi.pdf-selection-marker"
    )
    private let cancellationCheck: () -> Bool
    private let performCriticalEffect: (@escaping () -> Bool) -> Bool
    private let performCleanupEffect: (@escaping () -> Bool) -> Bool

    init(
        cancellationCheck: @escaping () -> Bool = { false },
        performCriticalEffect: @escaping (@escaping () -> Bool) -> Bool = {
            action in action()
        },
        performCleanupEffect: @escaping (@escaping () -> Bool) -> Bool = {
            action in action()
        }
    ) {
        self.cancellationCheck = cancellationCheck
        self.performCriticalEffect = performCriticalEffect
        self.performCleanupEffect = performCleanupEffect
    }

    private struct PasteboardValueSnapshot: Equatable {
        let type: NSPasteboard.PasteboardType
        let data: Data
    }

    private struct PasteboardItemSnapshot: Equatable {
        let values: [PasteboardValueSnapshot]
    }

    private struct PasteboardSnapshot {
        let items: [PasteboardItemSnapshot]
        let changeCount: Int
        let originalString: String?

        init?(pasteboard: NSPasteboard) {
            let initialChangeCount = pasteboard.changeCount
            let initialString = pasteboard.string(forType: .string)
            var byteCount = 0
            var captured: [PasteboardItemSnapshot] = []
            for item in pasteboard.pasteboardItems ?? [] {
                guard !item.types.isEmpty else { return nil }
                var values: [PasteboardValueSnapshot] = []
                for type in item.types {
                    guard let data = item.data(forType: type) else { return nil }
                    byteCount += data.count
                    guard byteCount <= SystemNativeSelectionAXClient
                        .maximumClipboardSnapshotBytes else { return nil }
                    values.append(PasteboardValueSnapshot(type: type, data: data))
                }
                values.sort { $0.type.rawValue < $1.type.rawValue }
                captured.append(PasteboardItemSnapshot(values: values))
            }
            guard pasteboard.changeCount == initialChangeCount else { return nil }
            items = captured
            changeCount = initialChangeCount
            originalString = initialString
        }

        func restore(
            to pasteboard: NSPasteboard,
            onlyIfChangeCount expectedChangeCount: Int? = nil
        ) -> Bool {
            var restoredItems: [NSPasteboardItem] = []
            for captured in items {
                let item = NSPasteboardItem()
                for value in captured.values {
                    guard item.setData(value.data, forType: value.type) else {
                        return false
                    }
                }
                restoredItems.append(item)
            }
            if let expectedChangeCount,
               pasteboard.changeCount != expectedChangeCount {
                return false
            }
            pasteboard.clearContents()
            guard !items.isEmpty else { return true }
            return pasteboard.writeObjects(restoredItems)
        }

        func hasSamePayload(as other: PasteboardSnapshot) -> Bool {
            items == other.items
        }
    }

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
        guard !cancellationCheck() else { return .cancelled }
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
        if focusedError == .noValue ||
            (focusedError == .success && focusedValue == nil) {
            let result = copySelectedTextAtSelectionPoint(
                from: target,
                application: application
            )
            return copyWPSPDFSelectionIfEligible(
                primaryResult: result,
                from: target,
                application: application
            )
        }
        if case let .finish(result) = NativeSelectionAXPolicy.decision(
            for: focusedError,
            stage: .focusedElement
        ) {
            return copyWPSPDFSelectionIfEligible(
                primaryResult: result,
                from: target,
                application: application
            )
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
        if isStaticPointerRole(focusedElement) {
            let result = copySelectedTextAtSelectionPoint(
                from: target,
                application: application
            )
            return copyWPSPDFSelectionIfEligible(
                primaryResult: result,
                from: target,
                application: application
            )
        }

        if let result = validateIdentityRoleAndSubrole(
            of: focusedElement,
            against: target
        ) {
            return copyWPSPDFSelectionIfEligible(
                primaryResult: result,
                from: target,
                application: application
            )
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
            return copyWPSPDFSelectionIfEligible(
                primaryResult: result,
                from: target,
                application: application
            )
        }
        guard let selectedValue else {
            return copyWPSPDFSelectionIfEligible(
                primaryResult: .noSelection,
                from: target,
                application: application
            )
        }
        guard CFGetTypeID(selectedValue) == CFStringGetTypeID() else {
            return copyWPSPDFSelectionIfEligible(
                primaryResult: .unsupported,
                from: target,
                application: application
            )
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
        if selectedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return copyWPSPDFSelectionIfEligible(
                primaryResult: .noSelection,
                from: target,
                application: application
            )
        }
        return .text(selectedText)
    }

    private enum PointerCandidateAssessment {
        case candidate
        case skip
        case finish(NativeSelectionAXRead)
    }

    private enum ParentRead {
        case element(AXUIElement)
        case end
        case finish(NativeSelectionAXRead)
    }

    private enum PointerChainRead {
        case elements([AXUIElement])
        case finish(NativeSelectionAXRead)
    }

    private enum CandidateTextRead {
        case text(String, markerRange: CFTypeRef?)
        case absent
        case finish(NativeSelectionAXRead)
    }

    private func copySelectedTextAtSelectionPoint(
        from target: NativeSelectionTarget,
        application: AXUIElement
    ) -> NativeSelectionAXRead {
        guard let point = target.selectionPoint else {
            return .noFocusedElement
        }
        let elements: [AXUIElement]
        switch pointerChain(at: point, in: application, against: target) {
        case let .elements(value):
            elements = value
        case let .finish(result):
            return result
        }
        for element in elements {
            switch pointerCandidateAssessment(of: element) {
            case let .finish(result):
                return result
            case .skip:
                continue
            case .candidate:
                switch selectedText(of: element) {
                case .absent:
                    continue
                case let .finish(result):
                    return result
                case let .text(selectedText, markerRange):
                    if let result = revalidatePointerCandidate(
                        element,
                        markerRange: markerRange,
                        at: point,
                        in: application,
                        against: target
                    ) {
                        return result
                    }
                    return .text(selectedText)
                }
            }
        }
        return .noSelection
    }

    private func pointerChain(
        at point: NativeSelectionPoint,
        in application: AXUIElement,
        against target: NativeSelectionTarget
    ) -> PointerChainRead {
        var hitElement: AXUIElement?
        var hitError = AXUIElementCopyElementAtPosition(
            application,
            Float(point.x),
            Float(point.y),
            &hitElement
        )
        if hitError == .notImplemented || hitError == .attributeUnsupported {
            let systemWide = AXUIElementCreateSystemWide()
            let timeoutError = AXUIElementSetMessagingTimeout(
                systemWide,
                Self.messagingTimeout
            )
            if case let .finish(result) = NativeSelectionAXPolicy.decision(
                for: timeoutError,
                stage: .timeoutConfiguration
            ) {
                return .finish(result)
            }
            hitError = AXUIElementCopyElementAtPosition(
                systemWide,
                Float(point.x),
                Float(point.y),
                &hitElement
            )
        }
        guard hitError == .success else {
            return .finish(pointerReadFailure(for: hitError))
        }
        guard var element = hitElement else {
            return .finish(.noFocusedElement)
        }
        var elements: [AXUIElement] = []
        for _ in 0..<16 {
            if elements.contains(where: { CFEqual($0, element) }) {
                return .finish(.cancelled)
            }
            let timeoutError = AXUIElementSetMessagingTimeout(
                element,
                Self.messagingTimeout
            )
            if case let .finish(result) = NativeSelectionAXPolicy.decision(
                for: timeoutError,
                stage: .timeoutConfiguration
            ) {
                return .finish(result)
            }
            if let result = validateElementIdentity(of: element, against: target) {
                return .finish(result)
            }
            if case let .finish(result) = pointerCandidateAssessment(of: element) {
                return .finish(result)
            }
            elements.append(element)
            switch parent(of: element) {
            case let .element(parent):
                element = parent
            case .end:
                return .elements(elements)
            case let .finish(result):
                return .finish(result)
            }
        }
        return .elements(elements)
    }

    private func revalidatePointerCandidate(
        _ candidate: AXUIElement,
        markerRange: CFTypeRef?,
        at point: NativeSelectionPoint,
        in application: AXUIElement,
        against target: NativeSelectionTarget
    ) -> NativeSelectionAXRead? {
        let elements: [AXUIElement]
        switch pointerChain(at: point, in: application, against: target) {
        case let .elements(value):
            elements = value
        case let .finish(result):
            return result
        }
        guard let current = elements.first(where: { CFEqual($0, candidate) }) else {
            return .cancelled
        }
        if let markerRange {
            var currentRange: CFTypeRef?
            let rangeError = AXUIElementCopyAttributeValue(
                current,
                kAXSelectedTextMarkerRangeAttribute as CFString,
                &currentRange
            )
            guard rangeError == .success,
                  let currentRange,
                  CFGetTypeID(currentRange) == AXTextMarkerRangeGetTypeID(),
                  CFEqual(markerRange, currentRange) else {
                return .cancelled
            }
        }
        return nil
    }

    private func selectedText(of element: AXUIElement) -> CandidateTextRead {
        var markerRange: CFTypeRef?
        let markerError = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextMarkerRangeAttribute as CFString,
            &markerRange
        )
        if markerError == .success {
            guard let markerRange,
                  CFGetTypeID(markerRange) == AXTextMarkerRangeGetTypeID() else {
                return .finish(.unsupported)
            }
            var markerText: CFTypeRef?
            let markerTextError = AXUIElementCopyParameterizedAttributeValue(
                element,
                kAXStringForTextMarkerRangeParameterizedAttribute as CFString,
                markerRange,
                &markerText
            )
            if markerTextError == .success {
                guard let markerText,
                      CFGetTypeID(markerText) == CFStringGetTypeID() else {
                    return .finish(.unsupported)
                }
                let text = markerText as! String
                if !text.isEmpty {
                    return .text(text, markerRange: markerRange)
                }
            } else if markerTextError != .noValue,
                      markerTextError != .attributeUnsupported,
                      markerTextError != .notImplemented {
                return .finish(pointerReadFailure(for: markerTextError))
            }
        } else if markerError != .noValue,
                  markerError != .attributeUnsupported,
                  markerError != .notImplemented {
            return .finish(pointerReadFailure(for: markerError))
        }

        var selectedValue: CFTypeRef?
        let selectedError = AXUIElementCopyAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            &selectedValue
        )
        if selectedError == .success {
            guard let selectedValue,
                  CFGetTypeID(selectedValue) == CFStringGetTypeID() else {
                return .finish(.unsupported)
            }
            let text = selectedValue as! String
            return text.isEmpty ? .absent : .text(text, markerRange: nil)
        }
        if selectedError == .noValue ||
            selectedError == .attributeUnsupported ||
            selectedError == .notImplemented {
            return .absent
        }
        return .finish(pointerReadFailure(for: selectedError))
    }

    private func pointerCandidateAssessment(
        of element: AXUIElement
    ) -> PointerCandidateAssessment {
        var protectedValue: CFTypeRef?
        let protectedError = AXUIElementCopyAttributeValue(
            element,
            "AXContainsProtectedContent" as CFString,
            &protectedValue
        )
        if protectedError == .success {
            guard let protectedValue,
                  CFGetTypeID(protectedValue) == CFBooleanGetTypeID() else {
                return .finish(.unsupported)
            }
            if CFBooleanGetValue((protectedValue as! CFBoolean)) {
                return .finish(.secureField)
            }
        }
        if protectedError != .success,
           protectedError != .noValue,
           protectedError != .attributeUnsupported,
           protectedError != .notImplemented {
            return .finish(pointerReadFailure(for: protectedError))
        }

        var roleValue: CFTypeRef?
        let roleError = AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleValue
        )
        guard roleError == .success,
              let roleValue,
              CFGetTypeID(roleValue) == CFStringGetTypeID() else {
            if roleError == .noValue ||
                roleError == .attributeUnsupported ||
                roleError == .notImplemented {
                return .skip
            }
            return .finish(pointerReadFailure(for: roleError))
        }
        let role = roleValue as! String

        var subroleValue: CFTypeRef?
        let subroleError = AXUIElementCopyAttributeValue(
            element,
            kAXSubroleAttribute as CFString,
            &subroleValue
        )
        if subroleError == .success {
            guard let subroleValue,
                  CFGetTypeID(subroleValue) == CFStringGetTypeID() else {
                return .finish(.unsupported)
            }
            if (subroleValue as! String) == (kAXSecureTextFieldSubrole as String) {
                return .finish(.secureField)
            }
        } else if subroleError != .noValue,
                  subroleError != .attributeUnsupported,
                  subroleError != .notImplemented {
            return .finish(pointerReadFailure(for: subroleError))
        }

        // Editable controls still require the strict focused-element path,
        // including a reviewed non-secure subrole. The pointer fallback is
        // only for static web/Electron selection exposed on an AXGroup parent.
        if role == (kAXTextFieldRole as String) ||
            role == (kAXTextAreaRole as String) {
            return .finish(.unsupported)
        }
        let staticRoles = [
            kAXGroupRole as String,
            kAXStaticTextRole as String,
            "AXWebArea",
            "AXPage"
        ]
        return staticRoles.contains(role) ? .candidate : .skip
    }

    private func parent(of element: AXUIElement) -> ParentRead {
        var parentValue: CFTypeRef?
        let parentError = AXUIElementCopyAttributeValue(
            element,
            kAXParentAttribute as CFString,
            &parentValue
        )
        if parentError == .noValue ||
            parentError == .attributeUnsupported ||
            parentError == .notImplemented {
            return .end
        }
        guard parentError == .success,
              let parentValue,
              CFGetTypeID(parentValue) == AXUIElementGetTypeID() else {
            return .finish(pointerReadFailure(for: parentError))
        }
        return .element(parentValue as! AXUIElement)
    }

    private func pointerReadFailure(for error: AXError) -> NativeSelectionAXRead {
        switch error {
        case .apiDisabled:
            return .accessibilityRequired
        case .invalidUIElement, .cannotComplete:
            return .temporarilyUnavailable
        case .noValue:
            return .noSelection
        case .attributeUnsupported, .notImplemented:
            return .unsupported
        default:
            return .internalFailure
        }
    }

    private func validateIdentityRoleAndSubrole(
        of element: AXUIElement,
        against target: NativeSelectionTarget
    ) -> NativeSelectionAXRead? {
        if let result = validateElementIdentity(of: element, against: target) {
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
        guard let roleValue,
              CFGetTypeID(roleValue) == CFStringGetTypeID() else {
            return .unsupported
        }
        let role = roleValue as! String

        if role == (kAXTextAreaRole as String) {
            var protectedValue: CFTypeRef?
            let protectedError = AXUIElementCopyAttributeValue(
                element,
                "AXContainsProtectedContent" as CFString,
                &protectedValue
            )
            if protectedError == .success {
                guard let protectedValue,
                      CFGetTypeID(protectedValue) == CFBooleanGetTypeID() else {
                    return .unsupported
                }
                if CFBooleanGetValue((protectedValue as! CFBoolean)) {
                    return .secureField
                }
            } else if protectedError != .noValue,
                      protectedError != .attributeUnsupported,
                      protectedError != .notImplemented {
                return pointerReadFailure(for: protectedError)
            }

            var textAreaSubrole: CFTypeRef?
            let textAreaSubroleError = AXUIElementCopyAttributeValue(
                element,
                kAXSubroleAttribute as CFString,
                &textAreaSubrole
            )
            if textAreaSubroleError == .success {
                guard let textAreaSubrole,
                      CFGetTypeID(textAreaSubrole) == CFStringGetTypeID() else {
                    return .unsupported
                }
                if (textAreaSubrole as! String) ==
                    (kAXSecureTextFieldSubrole as String) {
                    return .secureField
                }
            } else if textAreaSubroleError != .noValue,
                      textAreaSubroleError != .attributeUnsupported,
                      textAreaSubroleError != .notImplemented {
                return pointerReadFailure(for: textAreaSubroleError)
            }
            return nil
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

    private func isStaticPointerRole(_ element: AXUIElement) -> Bool {
        var roleValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            element,
            kAXRoleAttribute as CFString,
            &roleValue
        ) == .success,
        let roleValue,
        CFGetTypeID(roleValue) == CFStringGetTypeID() else {
            return false
        }
        let role = roleValue as! String
        return role == (kAXGroupRole as String) ||
            role == (kAXStaticTextRole as String) ||
            role == "AXWebArea" ||
            role == "AXPage"
    }

    private struct WPSPDFContext {
        let window: AXUIElement
        let documentIdentifier: String
    }

    private enum WPSClipboardAttempt {
        case candidate(text: String, snapshot: PasteboardSnapshot)
        case noCandidate
        case cancelled
        case unavailable
    }

    private func copyWPSPDFSelectionIfEligible(
        primaryResult: NativeSelectionAXRead,
        from target: NativeSelectionTarget,
        application: AXUIElement
    ) -> NativeSelectionAXRead {
        switch primaryResult {
        case .unsupported, .noSelection, .noFocusedElement:
            break
        default:
            return primaryResult
        }
        guard target.bundleIdentifier == Self.wpsBundleIdentifier,
              !cancellationCheck(),
              frontmostApplication?.hasSameProcess(as: target) == true,
              let context = wpsPDFContext(
                application: application,
                target: target
              ) else {
            return primaryResult
        }

        let pasteboard = NSPasteboard.general
        guard let snapshot = PasteboardSnapshot(pasteboard: pasteboard) else {
            return .temporarilyUnavailable
        }
        let deadline = ProcessInfo.processInfo.systemUptime
            + Self.clipboardCopyTimeout
        let firstAttempt = captureStableWPSClipboardCandidate(
            pasteboard: pasteboard,
            snapshot: snapshot,
            expectedChangeCount: snapshot.changeCount,
            context: context,
            application: application,
            target: target,
            deadline: deadline
        )
        let firstText: String
        let firstCandidateSnapshot: PasteboardSnapshot
        switch firstAttempt {
        case let .candidate(text, candidateSnapshot):
            firstText = text
            firstCandidateSnapshot = candidateSnapshot
        case .noCandidate:
            return primaryResult
        case .cancelled:
            return .cancelled
        case .unavailable:
            return .temporarilyUnavailable
        }
        guard !cancellationCheck() else { return .cancelled }

        // A pasteboard change has no source identity. Require WPS to reproduce
        // the same selection after a second, independently marked Copy before
        // any text is allowed into the translation pipeline.
        let confirmation = captureStableWPSClipboardCandidate(
            pasteboard: pasteboard,
            snapshot: snapshot,
            expectedChangeCount: firstCandidateSnapshot.changeCount,
            context: context,
            application: application,
            target: target,
            deadline: deadline
        )
        guard case let .candidate(confirmedText, confirmedSnapshot) = confirmation,
              confirmedText == firstText,
              confirmedSnapshot.hasSamePayload(as: firstCandidateSnapshot) else {
            return .temporarilyUnavailable
        }
        guard !cancellationCheck() else {
            _ = restorePasteboardSnapshot(
                snapshot,
                to: pasteboard,
                onlyIfChangeCount: confirmedSnapshot.changeCount
            )
            return .cancelled
        }
        guard restorePasteboardSnapshot(
            snapshot,
            to: pasteboard,
            onlyIfChangeCount: confirmedSnapshot.changeCount
        ) else { return .temporarilyUnavailable }
        return .text(firstText)
    }

    private func captureStableWPSClipboardCandidate(
        pasteboard: NSPasteboard,
        snapshot: PasteboardSnapshot,
        expectedChangeCount: Int,
        context: WPSPDFContext,
        application: AXUIElement,
        target: NativeSelectionTarget,
        deadline: TimeInterval
    ) -> WPSClipboardAttempt {
        guard !cancellationCheck(),
              ProcessInfo.processInfo.systemUptime < deadline,
              frontmostApplication?.hasSameProcess(as: target) == true,
              isCurrentWPSPDFContext(
                context,
                application: application,
                target: target
              ) else {
            return .cancelled
        }

        let markerValue = UUID().uuidString
        let marker = NSPasteboardItem()
        guard marker.setData(
            Data(markerValue.utf8),
            forType: Self.clipboardMarkerType
        ), marker.setString(markerValue, forType: .string) else {
            return .unavailable
        }
        // The AX/context checks above are bounded but not instantaneous. Re-run
        // the ownership checks immediately before the destructive pasteboard
        // write so a newer clipboard state is never knowingly overwritten.
        guard !cancellationCheck(),
              ProcessInfo.processInfo.systemUptime < deadline,
              pasteboard.changeCount == expectedChangeCount,
              frontmostApplication?.hasSameProcess(as: target) == true,
              isCurrentWPSPDFContext(
                context,
                application: application,
                target: target
        ) else {
            return .cancelled
        }
        var installedMarkerChangeCount: Int?
        let installedMarker = performCriticalEffect {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  pasteboard.changeCount == expectedChangeCount else {
                return false
            }
            pasteboard.clearContents()
            guard pasteboard.writeObjects([marker]) else {
                let failedWriteChangeCount = pasteboard.changeCount
                _ = snapshot.restore(
                    to: pasteboard,
                    onlyIfChangeCount: failedWriteChangeCount
                )
                return false
            }
            installedMarkerChangeCount = pasteboard.changeCount
            return true
        }
        guard installedMarker, let markerChangeCount = installedMarkerChangeCount else {
            return cancellationCheck() ? .cancelled : .unavailable
        }

        guard !cancellationCheck(),
              isCurrentWPSPDFContext(
            context,
            application: application,
            target: target
        ) else {
            _ = restorePasteboardSnapshot(
                snapshot,
                to: pasteboard,
                onlyIfChangeCount: markerChangeCount
            )
            return .cancelled
        }
        let postedCopy = performCriticalEffect {
            guard ProcessInfo.processInfo.systemUptime < deadline,
                  pasteboard.changeCount == markerChangeCount,
                  frontmostApplication?.hasSameProcess(as: target) == true else {
                return false
            }
            return postCopyKeystroke()
        }
        guard postedCopy else {
            _ = restorePasteboardSnapshot(
                snapshot,
                to: pasteboard,
                onlyIfChangeCount: markerChangeCount
            )
            return cancellationCheck() ? .cancelled : .unavailable
        }

        var candidateText: String?
        var candidateChangeCount: Int?
        var stableSince: TimeInterval?
        while ProcessInfo.processInfo.systemUptime < deadline {
            Thread.sleep(forTimeInterval: 0.02)
            let changeCount = pasteboard.changeCount
            guard !cancellationCheck(),
                  frontmostApplication?.hasSameProcess(as: target) == true,
                  isCurrentWPSPDFContext(
                    context,
                    application: application,
                    target: target
                  ) else {
                if changeCount == markerChangeCount {
                    _ = restorePasteboardSnapshot(
                        snapshot,
                        to: pasteboard,
                        onlyIfChangeCount: markerChangeCount
                    )
                }
                return .cancelled
            }
            guard changeCount != markerChangeCount else { continue }
            guard let candidate = pasteboard.string(forType: .string),
                  !candidate.isEmpty else {
                return .unavailable
            }
            // Marker rewrites and restoration of the previous plain text do
            // not prove WPS handled Copy. Restore the exact snapshot only
            // while the rejected write is still the newest pasteboard state.
            if candidate == markerValue {
                guard restorePasteboardSnapshot(
                    snapshot,
                    to: pasteboard,
                    onlyIfChangeCount: changeCount
                ) else { return .unavailable }
                return .noCandidate
            }
            if candidate == snapshot.originalString {
                guard let currentSnapshot = PasteboardSnapshot(
                    pasteboard: pasteboard
                ), currentSnapshot.changeCount == changeCount else {
                    return .unavailable
                }
                guard currentSnapshot.hasSamePayload(as: snapshot) else {
                    // The same plain string with different rich/file payload is
                    // an unknown concurrent write. Leave it untouched.
                    return .unavailable
                }
                return .noCandidate
            }
            if candidateChangeCount != changeCount {
                candidateChangeCount = changeCount
                candidateText = candidate
                stableSince = ProcessInfo.processInfo.systemUptime
            } else if let stableSince,
                      ProcessInfo.processInfo.systemUptime - stableSince
                        >= Self.clipboardStableInterval,
                      let candidateText {
                guard let candidateSnapshot = PasteboardSnapshot(
                    pasteboard: pasteboard
                ), candidateSnapshot.changeCount == changeCount else {
                    return .unavailable
                }
                return .candidate(text: candidateText, snapshot: candidateSnapshot)
            }
        }

        let finalChangeCount = pasteboard.changeCount
        if finalChangeCount == markerChangeCount {
            guard restorePasteboardSnapshot(
                snapshot,
                to: pasteboard,
                onlyIfChangeCount: markerChangeCount
            ) else { return .unavailable }
            return .noCandidate
        }
        return .unavailable
    }

    private func restorePasteboardSnapshot(
        _ snapshot: PasteboardSnapshot,
        to pasteboard: NSPasteboard,
        onlyIfChangeCount expectedChangeCount: Int
    ) -> Bool {
        performCleanupEffect {
            snapshot.restore(
                to: pasteboard,
                onlyIfChangeCount: expectedChangeCount
            )
        }
    }

    private func wpsPDFContext(
        application: AXUIElement,
        target: NativeSelectionTarget
    ) -> WPSPDFContext? {
        var windowValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            application,
            kAXFocusedWindowAttribute as CFString,
            &windowValue
        ) == .success,
        let windowValue,
        CFGetTypeID(windowValue) == AXUIElementGetTypeID() else { return nil }
        let window = windowValue as! AXUIElement
        guard AXUIElementSetMessagingTimeout(window, Self.messagingTimeout)
            == .success,
            validateElementIdentity(of: window, against: target) == nil else {
            return nil
        }

        for attribute in [
            kAXDocumentAttribute as CFString,
            kAXFilenameAttribute as CFString,
            kAXTitleAttribute as CFString
        ] {
            var value: CFTypeRef?
            guard AXUIElementCopyAttributeValue(window, attribute, &value)
                == .success,
                let value,
                CFGetTypeID(value) == CFStringGetTypeID() else { continue }
            let name = (value as! String)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if URL(string: name)?.pathExtension.lowercased() == "pdf" ||
                URL(fileURLWithPath: name).pathExtension.lowercased() == "pdf" ||
                name.range(
                    of: #"(?i)\.pdf(?:\s*[-–—|]\s*.+)?$"#,
                    options: .regularExpression
                ) != nil {
                return WPSPDFContext(
                    window: window,
                    documentIdentifier: "\(attribute):\(name)"
                )
            }
        }
        return nil
    }

    private func isCurrentWPSPDFContext(
        _ expected: WPSPDFContext,
        application: AXUIElement,
        target: NativeSelectionTarget
    ) -> Bool {
        guard frontmostApplication?.hasSameProcess(as: target) == true,
              let current = wpsPDFContext(
                application: application,
                target: target
              ) else {
            return false
        }
        return CFEqual(expected.window, current.window)
            && expected.documentIdentifier == current.documentIdentifier
    }

    private func postCopyKeystroke() -> Bool {
        guard let source = CGEventSource(stateID: .combinedSessionState),
              let keyDown = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0x08,
                keyDown: true
              ),
              let keyUp = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0x08,
                keyDown: false
              ) else { return false }
        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand
        keyDown.post(tap: .cghidEventTap)
        Thread.sleep(forTimeInterval: 0.05)
        keyUp.post(tap: .cghidEventTap)
        return true
    }

    private func validateElementIdentity(
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
        return nil
    }
}

/// Selection policy and privacy normalizer. Capture is delegated to the client;
/// the production client has one disclosed WPS-PDF-only clipboard compatibility
/// path. This layer performs no backend, popup, persistence, or logging work.
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
