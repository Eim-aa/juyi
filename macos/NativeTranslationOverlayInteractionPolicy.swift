import CoreGraphics
import Foundation

struct NativeTranslationOverlayInteractionModifiers: OptionSet, Equatable {
    let rawValue: UInt8

    static let control = NativeTranslationOverlayInteractionModifiers(rawValue: 1 << 0)
    static let command = NativeTranslationOverlayInteractionModifiers(rawValue: 1 << 1)
    static let shift = NativeTranslationOverlayInteractionModifiers(rawValue: 1 << 2)
    static let option = NativeTranslationOverlayInteractionModifiers(rawValue: 1 << 3)
    static let function = NativeTranslationOverlayInteractionModifiers(rawValue: 1 << 4)
}

enum NativeTranslationOverlayCopyPresentation: Equatable {
    case idle
    case copied
    case failed

    var buttonTitle: String {
        switch self {
        case .idle: return "复制"
        case .copied: return "已复制"
        case .failed: return "复制失败"
        }
    }
}

#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
enum NativeTranslationAppleResultLabCopyAnnouncementOutcome: Equatable {
    case copied
    case failed
}

enum NativeTranslationAppleResultLabCopyAnnouncementPolicy {
    static func message(
        for outcome: NativeTranslationAppleResultLabCopyAnnouncementOutcome
    ) -> String {
        switch outcome {
        case .copied:
            return "句译，已复制 Debug 固定样例 Apple Translation 真实译文"
        case .failed:
            return "句译，复制失败；系统剪贴板内容可能已改变"
        }
    }
}

enum NativeTranslationAppleResultLabLoadingAnnouncementStage: Equatable {
    case initial
    case extended
}

/// One non-focus-stealing announcement per live loading stage and panel
/// generation. Controller code supplies the lease/session currentness bit;
/// stale updates therefore cannot reset the lifecycle or speak.
struct NativeTranslationAppleResultLabLoadingAnnouncementLifecycle: Equatable {
    private var generation: Int?
    private var announcedInitial = false
    private var announcedExtended = false

    mutating func consume(
        stage: NativeTranslationAppleResultLabLoadingAnnouncementStage,
        generation: Int,
        isCurrent: Bool
    ) -> String? {
        guard isCurrent else { return nil }
        if self.generation != generation {
            self.generation = generation
            announcedInitial = false
            announcedExtended = false
        }
        switch stage {
        case .initial:
            guard !announcedInitial else { return nil }
            announcedInitial = true
            return "句译，正在运行 Debug 固定样例 Apple Translation"
        case .extended:
            guard !announcedExtended else { return nil }
            announcedExtended = true
            return "句译，Debug 固定样例 Apple Translation 仍在处理中"
        }
    }

    mutating func invalidate() {
        generation = nil
        announcedInitial = false
        announcedExtended = false
    }
}
#endif

/// One-shot fixture feedback consumed by the next visible state. Keeping this
/// separate from rendering prevents a preview-specific failure state from
/// being reset before it reaches the reusable panel.
struct NativeTranslationOverlayFixtureCopyPresentationLifecycle: Equatable {
    private var pending: NativeTranslationOverlayCopyPresentation?

    mutating func queue(_ presentation: NativeTranslationOverlayCopyPresentation) {
        pending = presentation
    }

    mutating func consumeForVisibleState() -> NativeTranslationOverlayCopyPresentation {
        defer { pending = nil }
        return pending ?? .idle
    }
}

enum NativeTranslationOverlayInteractionEvent: Equatable {
    case mouseDown(globalPoint: CGPoint)
    case keyDown(keyCode: UInt16, modifiers: NativeTranslationOverlayInteractionModifiers)
}

enum NativeTranslationOverlayInteractionAction: Equatable {
    case none
    case dismiss
    case enterKeyboardMode
    case copy
    case scroll(NativeTranslationOverlayScrollCommand)
}

enum NativeTranslationOverlayScrollCommand: Equatable {
    case pageUp
    case pageDown
    case beginning
    case end
    case lineUp
    case lineDown
}

enum NativeTranslationOverlayFocusableControl: Equatable {
    case cta
    case copy
    case close
}

enum NativeTranslationOverlayFocusDecision: Equatable {
    case preserveCurrent
    case moveTo(NativeTranslationOverlayFocusableControl)
    case noTarget
}

enum NativeTranslationOverlayFocusTopologyPolicy {
    static func orderedControls(
        hasCTA: Bool,
        canCopy: Bool
    ) -> [NativeTranslationOverlayFocusableControl] {
        var controls: [NativeTranslationOverlayFocusableControl] = []
        if hasCTA { controls.append(.cta) }
        if canCopy { controls.append(.copy) }
        controls.append(.close)
        return controls
    }

    static func decision(
        current: NativeTranslationOverlayFocusableControl?,
        orderedControls: [NativeTranslationOverlayFocusableControl]
    ) -> NativeTranslationOverlayFocusDecision {
        if let current, orderedControls.contains(current) {
            return .preserveCurrent
        }
        guard let first = orderedControls.first else { return .noTarget }
        return .moveTo(first)
    }
}

enum NativeTranslationOverlayDismissReason: Equatable {
    case close
    case outside
    case escape
    case pause
    case stop
    case revoke
    case displayRemoved
    case space
    case session
    case sleep
    case terminate
}

enum NativeTranslationOverlayScopedEventSource: Equatable {
    case global
    case local
}

#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB
/// The Result Lab sheet and its App menu are the explicit owner surface for
/// the external preview. Local mouse events must reach those controls before
/// any dismissal; a mouse event from another application remains outside.
enum NativeTranslationResultLabOwnerSurfacePolicy {
    static func suppressesDismiss(
        from source: NativeTranslationOverlayScopedEventSource,
        eventIsKeyDown: Bool,
        panelIsKey: Bool
    ) -> Bool {
        guard source == .local else { return false }
        if eventIsKeyDown { return !panelIsKey }
        return true
    }
}
#endif

enum NativeTranslationOverlayFocusRestorePolicy {
    static func shouldRestoreSourceApplication(
        reason: NativeTranslationOverlayDismissReason?,
        hadExplicitKeyboardFocus: Bool,
        ownerIsStillFrontmost: Bool
    ) -> Bool {
        guard hadExplicitKeyboardFocus, ownerIsStillFrontmost else { return false }
        return reason == .close || reason == .escape
    }
}

enum NativeTranslationOverlayInteractionPolicy {
    private static let escapeKeyCode: UInt16 = 53
    private static let cKeyCode: UInt16 = 8
    private static let f6KeyCode: UInt16 = 97
    private static let homeKeyCode: UInt16 = 115
    private static let pageUpKeyCode: UInt16 = 116
    private static let endKeyCode: UInt16 = 119
    private static let pageDownKeyCode: UInt16 = 121
    private static let downArrowKeyCode: UInt16 = 125
    private static let upArrowKeyCode: UInt16 = 126

    static func action(
        for event: NativeTranslationOverlayInteractionEvent,
        panelFrame: CGRect,
        panelIsKey: Bool,
        canCopy: Bool
    ) -> NativeTranslationOverlayInteractionAction {
        switch event {
        case let .mouseDown(globalPoint):
            guard globalPoint.x.isFinite, globalPoint.y.isFinite else {
                return .dismiss
            }
            return panelFrame.contains(globalPoint) ? .none : .dismiss

        case let .keyDown(keyCode, modifiers):
            if keyCode == escapeKeyCode { return .dismiss }
            if keyCode == f6KeyCode, modifiers.contains(.control) {
                return .enterKeyboardMode
            }
            if keyCode == cKeyCode,
               modifiers.contains(.command),
               panelIsKey,
               canCopy {
                return .copy
            }
            guard panelIsKey, modifiers.isEmpty else { return .none }
            switch keyCode {
            case pageUpKeyCode: return .scroll(.pageUp)
            case pageDownKeyCode: return .scroll(.pageDown)
            case homeKeyCode: return .scroll(.beginning)
            case endKeyCode: return .scroll(.end)
            case upArrowKeyCode: return .scroll(.lineUp)
            case downArrowKeyCode: return .scroll(.lineDown)
            default: break
            }
            return .none
        }
    }
}

enum NativeTranslationOverlayPanelKeyRoutingPolicy {
    static func scrollCommand(
        for action: NativeTranslationOverlayInteractionAction
    ) -> NativeTranslationOverlayScrollCommand? {
        guard case let .scroll(command) = action else { return nil }
        return command
    }
}

/// Copy and CTA are bound to the generation currently rendered in the panel,
/// not to a newer session that is still waiting or fading out the old visual.
enum NativeTranslationOverlayStatefulActionPolicy {
    static func bindingIsCurrent(
        displayedGeneration: Int,
        sessionGeneration: Int
    ) -> Bool {
        displayedGeneration == sessionGeneration
    }

    static func permitsAction(
        displayedGeneration: Int,
        sessionGeneration: Int,
        panelIsVisible: Bool
    ) -> Bool {
        panelIsVisible && bindingIsCurrent(
            displayedGeneration: displayedGeneration,
            sessionGeneration: sessionGeneration
        )
    }
}

/// A write-only replacement transaction used after the user explicitly asks
/// to copy a translation. The item is fully materialized before the existing
/// pasteboard is cleared; no previous pasteboard content is read or retained.
enum NativeTranslationOverlayPasteboardReplacePolicy {
    static func replace<Item>(
        text: String,
        makeItem: (String) -> Item?,
        clearExistingContents: () -> Void,
        writeSingleItem: (Item) -> Bool
    ) -> Bool {
        guard let item = makeItem(text) else { return false }
        clearExistingContents()
        return writeSingleItem(item)
    }
}

/// Idempotent owner for the two scoped NSEvent monitor tokens. Concrete event
/// observation remains in the Debug-only AppKit controller; this class makes
/// token cleanup executable without installing a real monitor.
final class NativeTranslationOverlayScopedMonitorOwner {
    typealias Installer = () -> Any?
    typealias Remover = (Any) -> Void

    private let installGlobal: Installer
    private let installLocal: Installer
    private let remove: Remover
    private var globalToken: Any?
    private var localToken: Any?

    init(
        installGlobal: @escaping Installer,
        installLocal: @escaping Installer,
        remove: @escaping Remover
    ) {
        self.installGlobal = installGlobal
        self.installLocal = installLocal
        self.remove = remove
    }

    var isActive: Bool { globalToken != nil || localToken != nil }

    func start() {
        guard !isActive else { return }
        globalToken = installGlobal()
        localToken = installLocal()
    }

    func stop() {
        if let globalToken {
            self.globalToken = nil
            remove(globalToken)
        }
        if let localToken {
            self.localToken = nil
            remove(localToken)
        }
    }
}

/// Presentation animations have a lifecycle independent from translation
/// generations. A new show must revoke an in-flight hide completion before it
/// can order out the one reusable panel.
struct NativeTranslationOverlayPresentationLifecycle: Equatable {
    enum Phase: Equatable {
        case hidden
        case visible
        case hiding
    }

    private(set) var phase: Phase = .hidden
    private(set) var revision = 0
    private(set) var monitorsShouldBeActive = false

    mutating func beginShow() -> Int {
        revision += 1
        phase = .visible
        monitorsShouldBeActive = true
        return revision
    }

    mutating func beginHide() -> Int {
        revision += 1
        phase = .hiding
        monitorsShouldBeActive = false
        return revision
    }

    func acceptsVisibleCompletion(_ candidateRevision: Int) -> Bool {
        candidateRevision == revision && phase == .visible
    }

    mutating func completeHide(_ candidateRevision: Int) -> Bool {
        guard candidateRevision == revision, phase == .hiding else { return false }
        phase = .hidden
        return true
    }
}

enum NativeTranslationOverlayVisibleReplacementPolicy {
    static func preservesCurrentContent(
        panelIsVisible: Bool,
        presentationPhase: NativeTranslationOverlayPresentationLifecycle.Phase
    ) -> Bool {
        panelIsVisible && presentationPhase == .visible
    }
}

/// Owns the not-yet-rendered state while old content fades out. Every access
/// is generation checked so a newer session cannot resurrect a cancelled
/// presentation during a screen or accessibility relayout.
struct NativeTranslationOverlayPendingPresentationLifecycle<State, CopyPresentation> {
    struct Entry {
        let state: State
        let generation: Int
        let copyPresentation: CopyPresentation
    }

    private var pending: Entry?

    mutating func stage(
        state: State,
        generation: Int,
        copyPresentation: CopyPresentation
    ) {
        pending = Entry(
            state: state,
            generation: generation,
            copyPresentation: copyPresentation
        )
    }

    func validEntry(for sessionGeneration: Int) -> Entry? {
        guard pending?.generation == sessionGeneration else { return nil }
        return pending
    }

    mutating func cancel() {
        pending = nil
    }
}

enum NativeTranslationOverlayRelayoutPolicy {
    /// Relayout always asks the terminal announcement gate. The gate itself
    /// checks visibility/current generation/terminal/once, covering relayouts
    /// both before and after a pending crossfade swap without replaying VO.
    static let requestsTerminalAnnouncement = true
}

/// The content transition is independent from translation and layout
/// generations. It makes the required ordering executable: old content fades
/// out, the current revision swaps content, then the new content fades in.
struct NativeTranslationOverlayContentTransitionLifecycle: Equatable {
    enum Phase: Equatable {
        case idle
        case fadingOut
        case swapping
        case fadingIn
    }

    private(set) var phase: Phase = .idle
    private(set) var revision = 0

    mutating func begin() -> Int {
        revision += 1
        phase = .fadingOut
        return revision
    }

    mutating func beginSwap(_ candidateRevision: Int) -> Bool {
        guard candidateRevision == revision, phase == .fadingOut else { return false }
        phase = .swapping
        return true
    }

    mutating func beginFadeIn(_ candidateRevision: Int) -> Bool {
        guard candidateRevision == revision, phase == .swapping else { return false }
        phase = .fadingIn
        return true
    }

    mutating func complete(_ candidateRevision: Int) -> Bool {
        guard candidateRevision == revision, phase == .fadingIn else { return false }
        phase = .idle
        return true
    }

    mutating func invalidate() {
        revision += 1
        phase = .idle
    }
}
