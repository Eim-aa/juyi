import Foundation

enum NativeTranslationOverlayEngine: String, Equatable {
    case apple
    case volc

    var displayName: String {
        switch self {
        case .apple: return "Apple 离线"
        case .volc: return "火山云端"
        }
    }
}

enum NativeTranslationOverlayCTA: Equatable {
    case openJuyi
    case openDiagnostics
    case prepareAppleLanguages
    case checkCloudSettings
    case chooseEngine

    var title: String {
        switch self {
        case .openJuyi: return "在句译中打开"
        case .openDiagnostics: return "打开诊断与帮助"
        case .prepareAppleLanguages: return "准备语言包"
        case .checkCloudSettings: return "检查云端设置"
        case .chooseEngine: return "选择翻译方式"
        }
    }
}

enum NativeTranslationOverlayCaptureStatus: Equatable {
    case noSelection
    case secureField
    case unsupported
    case accessibilityRequired
    case noFocusedElement
    case temporarilyUnavailable
    case cancelled
}

enum NativeTranslationOverlayBackendError: Equatable {
    case serviceUnavailable
    case requestTimeout
    case httpFailure
    case authenticationFailure
    case appleNotReady
    case volcCredential
    case volcNetwork
    case volcTimeout
    case sourceLanguageMismatch
    case noEngine
    case malformedResponse
    case emptyResult
}

enum NativeTranslationOverlayResponseWarning: Equatable {
    case usedAppleFallback
}

struct NativeTranslationOverlayResponse: Equatable {
    let requestedEngine: NativeTranslationOverlayEngine
    let actualEngine: NativeTranslationOverlayEngine?
    let result: String?
    let elapsedMilliseconds: Double?
    let error: NativeTranslationOverlayBackendError?
    let warning: NativeTranslationOverlayResponseWarning?
    let captureDidTruncate: Bool
    let responseTruncated: Bool
    let inputTruncated: Bool

    init(
        requestedEngine: NativeTranslationOverlayEngine,
        actualEngine: NativeTranslationOverlayEngine?,
        result: String?,
        elapsedMilliseconds: Double?,
        error: NativeTranslationOverlayBackendError? = nil,
        warning: NativeTranslationOverlayResponseWarning? = nil,
        captureDidTruncate: Bool = false,
        responseTruncated: Bool = false,
        inputTruncated: Bool = false
    ) {
        self.requestedEngine = requestedEngine
        self.actualEngine = actualEngine
        self.result = result
        self.elapsedMilliseconds = elapsedMilliseconds
        self.error = error
        self.warning = warning
        self.captureDidTruncate = captureDidTruncate
        self.responseTruncated = responseTruncated
        self.inputTruncated = inputTruncated
    }
}

enum NativeTranslationOverlayEvent: Equatable {
    case capture(NativeTranslationOverlayCaptureStatus)
    case response(NativeTranslationOverlayResponse)
    case loading(isExtended: Bool)
    case timeout
}

struct NativeTranslationOverlayState: Equatable {
    enum Kind: Equatable {
        case hidden
        case loading
        case notice
        case error
        case success
    }

    let kind: Kind
    let title: String
    let body: String
    let metadata: String?
    let fallbackNotice: String?
    let truncationBadge: String?
    let truncationAccessibilityHelp: String?
    let copyText: String?
    let cta: NativeTranslationOverlayCTA?
    let terminalAnnouncement: String?

    var isVisible: Bool { kind != .hidden }
    var isTerminal: Bool { kind == .notice || kind == .error || kind == .success }
    var canCopy: Bool { kind == .success && copyText != nil }

    static let hidden = NativeTranslationOverlayState(
        kind: .hidden,
        title: "",
        body: "",
        metadata: nil,
        fallbackNotice: nil,
        truncationBadge: nil,
        truncationAccessibilityHelp: nil,
        copyText: nil,
        cta: nil,
        terminalAnnouncement: nil
    )
}

enum NativeTranslationOverlayCopyResult: Equatable {
    case copied
    case failed
    case unavailable
}

enum NativeTranslationOverlayAnnouncementPolicy {
    static func shouldAnnounceTerminal(
        state: NativeTranslationOverlayState,
        stateGeneration: Int,
        currentGeneration: Int,
        panelIsVisible: Bool,
        announcedGeneration: Int?
    ) -> Bool {
        panelIsVisible
            && state.isTerminal
            && state.terminalAnnouncement != nil
            && stateGeneration == currentGeneration
            && announcedGeneration != stateGeneration
    }
}

enum NativeTranslationOverlayCopyPolicy {
    static func copy(
        state: NativeTranslationOverlayState,
        stateGeneration: Int,
        currentGeneration: Int,
        isVisible: Bool,
        writer: (String) -> Bool
    ) -> NativeTranslationOverlayCopyResult {
        guard isVisible,
              stateGeneration == currentGeneration,
              state.kind == .success,
              let fullTranslation = state.copyText else {
            return .unavailable
        }
        return writer(fullTranslation) ? .copied : .failed
    }
}

enum NativeTranslationOverlayReducer {
    static func reduce(_ event: NativeTranslationOverlayEvent) -> NativeTranslationOverlayState {
        switch event {
        case let .loading(isExtended):
            return NativeTranslationOverlayState(
                kind: .loading,
                title: "正在翻译…",
                body: isExtended ? "仍在翻译，请稍候…" : "",
                metadata: nil,
                fallbackNotice: nil,
                truncationBadge: nil,
                truncationAccessibilityHelp: nil,
                copyText: nil,
                cta: nil,
                terminalAnnouncement: nil
            )

        case .timeout:
            return serviceUnavailableState()

        case let .capture(status):
            return captureState(status)

        case let .response(response):
            return responseState(response)
        }
    }

    private static func captureState(
        _ status: NativeTranslationOverlayCaptureStatus
    ) -> NativeTranslationOverlayState {
        switch status {
        case .cancelled:
            return .hidden
        case .noSelection:
            return terminal(
                kind: .notice,
                title: "没有检测到选中文字",
                body: "请先选中英文，再连按两次 Option。"
            )
        case .secureField:
            return terminal(
                kind: .notice,
                title: "安全输入框不会被读取",
                body: "为保护隐私，句译没有读取或发送这里的内容。"
            )
        case .unsupported:
            return terminal(
                kind: .notice,
                title: "此 App 暂不支持直接取词",
                body: "句译没有使用剪贴板。请换到支持选中文字的 App 后重试。"
            )
        case .accessibilityRequired:
            return terminal(
                kind: .error,
                title: "需要开启辅助功能权限",
                body: "打开句译，按引导完成设置后再试。",
                cta: .openJuyi
            )
        case .noFocusedElement, .temporarilyUnavailable:
            return terminal(
                kind: .notice,
                title: "暂时无法读取选中文字",
                body: "请保持选中状态，再试一次。"
            )
        }
    }

    private static func responseState(
        _ response: NativeTranslationOverlayResponse
    ) -> NativeTranslationOverlayState {
        // Privacy boundary: any typed error wins before result is inspected.
        if let error = response.error {
            return backendErrorState(error)
        }

        guard let actualEngine = response.actualEngine,
              let elapsedValue = response.elapsedMilliseconds,
              elapsedValue.isFinite,
              elapsedValue >= 0,
              elapsedValue <= Double(Int.max),
              elapsedValue.rounded() == elapsedValue,
              let result = response.result,
              !result.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return malformedState()
        }
        let elapsedMilliseconds = Int(elapsedValue)

        let fallbackNotice: String?
        switch (response.requestedEngine, actualEngine, response.warning) {
        case (.volc, .apple, .usedAppleFallback):
            fallbackNotice = "已改用 Apple 离线"
        case let (requested, actual, nil) where requested == actual:
            fallbackNotice = nil
        default:
            // Apple→Volc is a privacy violation. Every other unexplained
            // engine mismatch/warning is malformed. Never expose its result.
            return malformedState()
        }

        let isTruncated = response.captureDidTruncate
            || response.responseTruncated
            || response.inputTruncated
        return NativeTranslationOverlayState(
            kind: .success,
            title: "译文",
            body: result,
            metadata: "\(actualEngine.displayName) · \(elapsedMilliseconds) 毫秒",
            fallbackNotice: fallbackNotice,
            truncationBadge: isTruncated ? "原文已截断" : nil,
            truncationAccessibilityHelp: isTruncated
                ? "仅翻译原文前 5000 个 Unicode 标量"
                : nil,
            copyText: result,
            cta: nil,
            terminalAnnouncement: "句译，翻译完成，来自 \(actualEngine.displayName)"
        )
    }

    private static func backendErrorState(
        _ error: NativeTranslationOverlayBackendError
    ) -> NativeTranslationOverlayState {
        switch error {
        case .serviceUnavailable, .requestTimeout, .httpFailure, .authenticationFailure:
            return serviceUnavailableState()
        case .appleNotReady:
            return terminal(
                kind: .error,
                title: "Apple 离线翻译未准备好",
                body: "打开句译准备中英语言包。",
                cta: .prepareAppleLanguages
            )
        case .volcCredential:
            return terminal(
                kind: .error,
                title: "火山云端设置需要检查",
                body: "请检查访问密钥和机器翻译权限。",
                cta: .checkCloudSettings
            )
        case .volcNetwork, .volcTimeout:
            return terminal(
                kind: .error,
                title: "暂时无法连接火山云端",
                body: "请检查网络后再试。"
            )
        case .sourceLanguageMismatch:
            return terminal(
                kind: .notice,
                title: "选中的内容不像英文",
                body: "请重新选择英文文本。"
            )
        case .noEngine:
            return terminal(
                kind: .error,
                title: "没有可用的翻译方式",
                body: "请在句译中选择一种翻译方式。",
                cta: .chooseEngine
            )
        case .malformedResponse, .emptyResult:
            return malformedState()
        }
    }

    private static func serviceUnavailableState() -> NativeTranslationOverlayState {
        terminal(
            kind: .error,
            title: "翻译组件没有响应",
            body: "打开句译，在“诊断与帮助”中自动修复。",
            cta: .openDiagnostics
        )
    }

    private static func malformedState() -> NativeTranslationOverlayState {
        terminal(
            kind: .error,
            title: "没有收到译文",
            body: "打开句译，在“诊断与帮助”中自动修复。",
            cta: .openDiagnostics
        )
    }

    private static func terminal(
        kind: NativeTranslationOverlayState.Kind,
        title: String,
        body: String,
        cta: NativeTranslationOverlayCTA? = nil
    ) -> NativeTranslationOverlayState {
        NativeTranslationOverlayState(
            kind: kind,
            title: title,
            body: body,
            metadata: nil,
            fallbackNotice: nil,
            truncationBadge: nil,
            truncationAccessibilityHelp: nil,
            copyText: nil,
            cta: cta,
            terminalAnnouncement: "句译，\(title)"
        )
    }
}

final class NativeTranslationOverlayScheduledTask {
    private let cancelAction: () -> Void
    private(set) var isCancelled = false

    init(cancelAction: @escaping () -> Void) {
        self.cancelAction = cancelAction
    }

    func cancel() {
        guard !isCancelled else { return }
        isCancelled = true
        cancelAction()
    }
}

struct NativeTranslationOverlayClock {
    typealias Schedule = (
        _ delay: TimeInterval,
        _ action: @escaping () -> Void
    ) -> NativeTranslationOverlayScheduledTask

    let schedule: Schedule

    static let main = NativeTranslationOverlayClock { delay, action in
        let item = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: item)
        return NativeTranslationOverlayScheduledTask { item.cancel() }
    }
}

/// Generation-gated loading owner. It has no AppKit, network, selection or
/// clipboard dependency, so timing and stale-result behavior are executable.
final class NativeTranslationOverlaySession {
    typealias StateHandler = (
        _ generation: Int,
        _ state: NativeTranslationOverlayState
    ) -> Void

    private let clock: NativeTranslationOverlayClock
    private let stateHandler: StateHandler
    private var scheduledTasks: [NativeTranslationOverlayScheduledTask] = []
    private var terminalGeneration: Int?

    private(set) var generation = 0
    private(set) var state: NativeTranslationOverlayState = .hidden

    init(
        clock: NativeTranslationOverlayClock = .main,
        stateHandler: @escaping StateHandler
    ) {
        self.clock = clock
        self.stateHandler = stateHandler
    }

    @discardableResult
    func begin() -> Int {
        generation += 1
        cancelScheduledTasks()
        terminalGeneration = nil
        publish(.hidden)
        let requestGeneration = generation
        schedule(after: 0.15, generation: requestGeneration) { [weak self] in
            self?.publish(NativeTranslationOverlayReducer.reduce(.loading(isExtended: false)))
        }
        schedule(after: 2.0, generation: requestGeneration) { [weak self] in
            self?.publish(NativeTranslationOverlayReducer.reduce(.loading(isExtended: true)))
        }
        schedule(after: 12.0, generation: requestGeneration) { [weak self] in
            self?.resolve(.timeout, for: requestGeneration)
        }
        return requestGeneration
    }

    func resolve(
        _ event: NativeTranslationOverlayEvent,
        for expectedGeneration: Int
    ) {
        guard generation == expectedGeneration,
              terminalGeneration != expectedGeneration else { return }
        let terminal = NativeTranslationOverlayReducer.reduce(event)
        if terminal.kind == .hidden {
            invalidate()
            return
        }
        guard terminal.isTerminal else { return }
        terminalGeneration = expectedGeneration
        cancelScheduledTasks()
        publish(terminal)
    }

    func invalidate() {
        generation += 1
        cancelScheduledTasks()
        terminalGeneration = nil
        publish(.hidden)
    }

    private func schedule(
        after delay: TimeInterval,
        generation expectedGeneration: Int,
        action: @escaping () -> Void
    ) {
        let task = clock.schedule(delay) { [weak self] in
            guard let self,
                  self.generation == expectedGeneration,
                  self.terminalGeneration != expectedGeneration else { return }
            action()
        }
        scheduledTasks.append(task)
    }

    private func publish(_ newState: NativeTranslationOverlayState) {
        state = newState
        stateHandler(generation, newState)
    }

    private func cancelScheduledTasks() {
        scheduledTasks.forEach { $0.cancel() }
        scheduledTasks.removeAll()
    }
}
