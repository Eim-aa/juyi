#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER
import Combine
import Foundation

enum NativeVolcTranslationAdapterPhase: Equatable {
    case hidden
    case disclosure
    case checkingInterlock
    case checkingKeychain
    case missing
    case pendingReady
    case pendingRecovery
    case activeNeedsVerification
    case ready
    case savingPending
    case validatingPending
    case promoting
    case connecting
    case slow
    case success(savedCandidate: Bool)
    case removing
    case removed
    case removalBlocked
    case interlockUnavailable
    case keychainUnavailable
    case credentialError
    case networkError
    case transportSecurity
    case timeout
    case quota
    case service
    case malformed
    case stopped(pendingRetained: Bool)
    case checkStopped
    case networkStatusUnconfirmed
    case statusUnconfirmed
    case removalStatusUnconfirmed

    var isBusy: Bool {
        switch self {
        case .checkingInterlock, .checkingKeychain, .savingPending, .validatingPending,
             .promoting, .connecting, .slow, .removing:
            return true
        default:
            return false
        }
    }

    var isTerminal: Bool { !isBusy && self != .hidden && self != .disclosure }
}

struct NativeVolcTranslationAdapterSnapshot: Equatable {
    let generation: UInt64
    let phase: NativeVolcTranslationAdapterPhase
    let targetText: String?

    static let hidden = NativeVolcTranslationAdapterSnapshot(
        generation: 0, phase: .hidden, targetText: nil
    )
}

enum NativeVolcTranslationAdapterAction: Equatable, Hashable {
    case checkConfiguration
    case saveAndValidate
    case validatePending
    case discardPending
    case validateActive
    case testFixture
    case recoverPromotion
    case removeConfiguration
    case resumeRemoval
    case stopWaiting
    case close
}

struct NativeVolcTranslationAdapterActionItem: Equatable, Identifiable {
    let action: NativeVolcTranslationAdapterAction
    let title: String
    let isDestructive: Bool
    let isPrimary: Bool
    var id: NativeVolcTranslationAdapterAction { action }
}

struct NativeVolcTranslationAdapterPresentation: Equatable {
    let title: String
    let message: String
    let actions: [NativeVolcTranslationAdapterActionItem]

    static func make(for phase: NativeVolcTranslationAdapterPhase) -> Self {
        let action: (NativeVolcTranslationAdapterAction, String, Bool, Bool) ->
            NativeVolcTranslationAdapterActionItem = {
                .init(action: $0, title: $1, isDestructive: $2, isPrimary: $3)
            }
        switch phase {
        case .hidden:
            return Self(title: "", message: "", actions: [])
        case .disclosure:
            return Self(
                title: "火山云端翻译开发测试",
                message: "先阅读隐私与用量说明，再显式检查独立的 Debug 配置。",
                actions: [action(.checkConfiguration, "检查 Debug 配置", false, true)]
            )
        case .checkingInterlock:
            return Self(title: "正在确认 Debug 云端安全状态", message: "没有读取密钥或发送文字。",
                        actions: [action(.stopWaiting, "停止等待", false, false)])
        case .checkingKeychain:
            return Self(title: "正在检查 Debug 云端配置", message: "只读取独立的 Debug 钥匙串槽。",
                        actions: [action(.stopWaiting, "停止等待", false, false)])
        case .missing:
            return Self(title: "还没有 Debug 云端密钥", message: "可输入一组仅供本开发测试使用的 AK/SK。",
                        actions: [action(.saveAndValidate, "保存并验证 Debug 密钥", false, true)])
        case .removed:
            return Self(title: "Debug 云端配置已移除", message: "未发送新请求。", actions: [])
        case .pendingReady:
            return Self(
                title: "上次 Debug 密钥验证未完成",
                message: "候选密钥仍在独立 Debug 钥匙串中。继续验证会再发送一次固定样例，可能产生少量用量或费用。",
                actions: [
                    action(.validatePending, "继续验证固定样例", false, true),
                    action(.discardPending, "仅放弃候选", true, false),
                ]
            )
        case .pendingRecovery:
            return Self(
                title: "上次 Debug 配置事务需要恢复",
                message: "不会自动联网。请显式恢复已验证事务，或安全移除 Debug 配置。",
                actions: [
                    action(.recoverPromotion, "恢复之前的验证事务", false, true),
                    action(.removeConfiguration, "移除 Debug 云端配置", true, false),
                ]
            )
        case .activeNeedsVerification:
            return Self(
                title: "Debug 云端密钥尚未验证",
                message: "显式验证会发送一次固定样例，可能产生少量用量或费用。",
                actions: [
                    action(.validateActive, "验证当前 Debug 密钥", false, true),
                    action(.removeConfiguration, "移除 Debug 云端配置", true, false),
                ]
            )
        case .ready:
            return Self(
                title: "Debug 云端密钥已验证",
                message: "未启用快捷键或真实文本云翻译。",
                actions: [
                    action(.testFixture, "测试固定样例", false, true),
                    action(.removeConfiguration, "移除 Debug 云端配置", true, false),
                ]
            )
        case .savingPending:
            return Self(title: "正在保存候选 Debug 密钥", message: "尚未启用任何生产翻译流程。",
                        actions: [action(.stopWaiting, "停止等待", false, false)])
        case .validatingPending, .connecting:
            return Self(title: "正在连接真实火山翻译 API", message: "本次只发送固定样例；每次点击最多一次请求。",
                        actions: [action(.stopWaiting, "停止等待", false, false)])
        case .slow:
            return Self(title: "仍在等待火山云端响应…", message: "可停止等待；已经发出的请求可能仍会产生少量用量。",
                        actions: [action(.stopWaiting, "停止等待", false, false)])
        case .promoting:
            return Self(title: "正在安全保存已验证的 Debug 密钥", message: "不会再次发送固定样例。",
                        actions: [action(.stopWaiting, "停止等待", false, false)])
        case let .success(saved):
            return Self(
                title: "火山云端固定样例测试成功",
                message: saved
                    ? "固定样例验证成功。Debug 测试密钥已保存；未启用快捷键或真实文本云翻译。"
                    : "固定样例翻译成功；结果只保存在当前页面，关闭后丢弃。",
                actions: [
                    action(.testFixture, "再次测试固定样例", false, true),
                    action(.removeConfiguration, "移除 Debug 云端配置", true, false),
                ]
            )
        case .removing:
            return Self(title: "Debug 云端配置正在安全移除", message: "没有读取密钥或发送文字。",
                        actions: [action(.stopWaiting, "停止等待", false, false)])
        case .removalBlocked:
            return Self(
                title: "Debug 云端配置正在安全移除",
                message: "没有读取密钥或发送文字。可显式继续上次的安全移除。",
                actions: [action(.resumeRemoval, "继续安全移除", true, false)]
            )
        case .interlockUnavailable:
            return Self(title: "暂时无法确认 Debug 云端安全状态", message: "为保护隐私，没有读取密钥或发送文字。",
                        actions: [action(.checkConfiguration, "重新检查", false, true)])
        case .keychainUnavailable:
            return Self(title: "暂时无法读取 macOS 钥匙串", message: "请解锁钥匙串，或在系统要求确认访问后显式重试；句译不会自动弹出鉴权窗口。",
                        actions: [action(.checkConfiguration, "重新检查", false, true)])
        case .credentialError:
            return Self(title: "火山云端设置需要检查", message: "请检查访问密钥和机器翻译权限。",
                        actions: [action(.saveAndValidate, "重新输入并验证", false, true)])
        case .networkError:
            return Self(title: "暂时无法连接火山云端", message: "请检查网络后重试。",
                        actions: [action(.checkConfiguration, "重新检查", false, true)])
        case .timeout:
            return Self(title: "暂时无法连接火山云端", message: "连接超时。请求可能已经发送，并可能产生少量用量或费用；迟到译文不会显示或保存在此页面。当前配置状态尚未确认，请显式检查。",
                        actions: [action(.checkConfiguration, "重新检查", false, true)])
        case .quota:
            return Self(title: "火山云端额度或调用频率受限", message: "请稍后再试或检查火山控制台额度。",
                        actions: [action(.checkConfiguration, "检查 Debug 配置", false, true)])
        case .service:
            return Self(title: "火山云端暂时无法完成翻译", message: "请稍后重试。",
                        actions: [action(.checkConfiguration, "重新检查", false, true)])
        case .transportSecurity:
            return Self(title: "无法安全连接火山云端", message: "连接已停止，没有展示或保存上游内容。",
                        actions: [action(.checkConfiguration, "重新检查", false, true)])
        case .malformed:
            return Self(title: "没有收到有效译文", message: "未展示上游响应；请稍后重试。",
                        actions: [action(.checkConfiguration, "重新检查", false, true)])
        case let .stopped(retained):
            return Self(
                title: "已停止等待",
                message: retained
                    ? "验证请求可能已经发送，并可能产生少量用量或费用；未完成候选仍保存在 Debug 钥匙串中，可显式继续或放弃。"
                    : "已停止等待。验证请求可能已经发送，并可能产生少量用量或费用；不会保存或启用这次更改。",
                actions: [action(.checkConfiguration, "检查当前状态", false, true)]
            )
        case .checkStopped:
            return Self(title: "已停止检查", message: "没有发送固定样例。可随时重新检查 Debug 配置。",
                        actions: [action(.checkConfiguration, "重新检查", false, true)])
        case .networkStatusUnconfirmed:
            return Self(title: "已停止等待", message: "请求可能已经发送，并可能产生少量用量或费用；迟到译文不会显示或保存在此页面。当前配置状态尚未确认，请显式检查。",
                        actions: [action(.checkConfiguration, "检查当前状态", false, true)])
        case .statusUnconfirmed:
            return Self(title: "当前 Debug 云端状态尚未确认", message: "为避免误报，请显式检查后再继续。",
                        actions: [action(.checkConfiguration, "检查当前状态", false, true)])
        case .removalStatusUnconfirmed:
            return Self(title: "Debug 云端移除状态尚未确认", message: "不会读取密钥或发送文字；请检查安全移除状态。",
                        actions: [action(.checkConfiguration, "检查移除状态", false, true)])
        }
    }
}

struct NativeVolcTranslationWorkflowClient: Sendable {
    let inspect: @Sendable () async -> NativeVolcDebugWorkflowResult
    let saveAndValidate: @Sendable (String, String) async -> NativeVolcDebugWorkflowResult
    let validatePending: @Sendable () async -> NativeVolcDebugWorkflowResult
    let discardPending: @Sendable () async -> NativeVolcDebugWorkflowResult
    let validateActive: @Sendable () async -> NativeVolcDebugWorkflowResult
    let testFixture: @Sendable () async -> NativeVolcDebugWorkflowResult
    let recoverPromotion: @Sendable () async -> NativeVolcDebugWorkflowResult
    let remove: @Sendable (Bool) async -> NativeVolcDebugWorkflowResult
    let cancelNetwork: @Sendable () async -> Void

    static func live(_ workflow: NativeVolcDebugWorkflow) -> Self {
        Self(
            inspect: { await workflow.inspect() },
            saveAndValidate: { accessKey, secretKey in
                await workflow.saveAndValidate(accessKey: accessKey, secretKey: secretKey)
            },
            validatePending: { await workflow.validatePending() },
            discardPending: { await workflow.discardPending() },
            validateActive: { await workflow.validateActive() },
            testFixture: { await workflow.testActive() },
            recoverPromotion: { await workflow.recoverPromotion() },
            remove: { resume in await workflow.remove(resume: resume) },
            cancelNetwork: { await workflow.cancelNetwork() }
        )
    }
}

@MainActor
protocol NativeVolcAdapterScheduledTask: AnyObject { func cancel() }

@MainActor
protocol NativeVolcAdapterScheduling: AnyObject {
    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> any NativeVolcAdapterScheduledTask
}

@MainActor
final class NativeVolcAdapterSystemScheduledTask: NativeVolcAdapterScheduledTask {
    private var task: Task<Void, Never>?
    init(_ task: Task<Void, Never>) { self.task = task }
    func cancel() { task?.cancel(); task = nil }
}

@MainActor
final class NativeVolcAdapterSystemScheduler: NativeVolcAdapterScheduling {
    private let clock = ContinuousClock()
    func schedule(
        after delay: TimeInterval,
        _ action: @escaping @MainActor () -> Void
    ) -> any NativeVolcAdapterScheduledTask {
        let nanoseconds = Int64(max(0, delay) * 1_000_000_000)
        return NativeVolcAdapterSystemScheduledTask(Task { @MainActor in
            do { try await clock.sleep(for: .nanoseconds(nanoseconds)) } catch { return }
            guard !Task.isCancelled else { return }
            action()
        })
    }
}

enum NativeVolcTranslationAdapterInvalidationReason: Equatable {
    case close
    case newRequest
    case pause
    case stop
    case engineChanged
    case credentialChanged
    case removal
    case terminate
    case sleep
    case wake
    case sessionResigned
}

@MainActor
final class NativeVolcTranslationAdapterCoordinator: ObservableObject {
    typealias Announcement = @MainActor (String) -> Void

    @Published private(set) var isPresented = false
    @Published private(set) var snapshot = NativeVolcTranslationAdapterSnapshot.hidden
    @Published var accessKey = ""
    @Published var secretKey = ""

    private let workflow: NativeVolcTranslationWorkflowClient
    private let scheduler: any NativeVolcAdapterScheduling
    private let announce: Announcement
    private var generation: UInt64 = 0
    private var operation: Task<NativeVolcDebugWorkflowResult, Never>?
    private var observer: Task<Void, Never>?
    private var timers: [any NativeVolcAdapterScheduledTask] = []
    private var announcedGeneration: UInt64?
    private var operationContext: OperationContext?

    private enum OperationContext {
        case check
        case save
        case validatePending
        case discardPending
        case validateActive
        case testFixture
        case recover
        case removal

        var usesNetwork: Bool {
            switch self {
            case .save, .validatePending, .validateActive, .testFixture: return true
            default: return false
            }
        }
    }

    init(
        workflow: NativeVolcTranslationWorkflowClient,
        scheduler: (any NativeVolcAdapterScheduling)? = nil,
        announce: @escaping Announcement = { _ in }
    ) {
        self.workflow = workflow
        self.scheduler = scheduler ?? NativeVolcAdapterSystemScheduler()
        self.announce = announce
    }

    var presentation: NativeVolcTranslationAdapterPresentation {
        .make(for: snapshot.phase)
    }

    func open() {
        invalidateCurrent(clearPresentation: true)
        isPresented = true
        publish(.disclosure, targetText: nil, announceTerminal: false)
    }

    func perform(_ action: NativeVolcTranslationAdapterAction) {
        let allowed = Set(presentation.actions.map(\.action)).union([.close])
        guard allowed.contains(action) else { return }
        switch action {
        case .checkConfiguration:
            start(context: .check, initial: .checkingInterlock,
                  intermediate: (0.12, .checkingKeychain)) {
                await self.workflow.inspect()
            }
        case .saveAndValidate:
            let accessKey = self.accessKey
            let secretKey = self.secretKey
            guard NativeVolcDebugCredentials(accessKey: accessKey, secretKey: secretKey) != nil else {
                clearSensitiveFields()
                publish(.credentialError, targetText: nil, announceTerminal: true)
                return
            }
            start(context: .save, initial: .savingPending,
                  intermediate: (0.12, .validatingPending)) {
                await self.workflow.saveAndValidate(accessKey, secretKey)
            }
        case .validatePending:
            start(context: .validatePending, initial: .validatingPending) {
                await self.workflow.validatePending()
            }
        case .discardPending:
            start(context: .discardPending, initial: .promoting) {
                await self.workflow.discardPending()
            }
        case .validateActive:
            start(context: .validateActive, initial: .connecting) {
                await self.workflow.validateActive()
            }
        case .testFixture:
            start(context: .testFixture, initial: .connecting) {
                await self.workflow.testFixture()
            }
        case .recoverPromotion:
            start(context: .recover, initial: .promoting) {
                await self.workflow.recoverPromotion()
            }
        case .removeConfiguration:
            start(context: .removal, initial: .removing) { await self.workflow.remove(false) }
        case .resumeRemoval:
            start(context: .removal, initial: .removing) { await self.workflow.remove(true) }
        case .stopWaiting:
            stopWaiting(timedOut: false)
        case .close:
            close()
        }
    }

    func close() {
        invalidate(.close)
        isPresented = false
        snapshot = .hidden
    }

    func invalidate(_ reason: NativeVolcTranslationAdapterInvalidationReason) {
        if reason == .close || reason == .terminate {
            invalidateCurrent(clearPresentation: true)
            if reason == .terminate { isPresented = false; snapshot = .hidden }
            return
        }
        if operation != nil {
            stopWaiting(timedOut: false, invalidated: true)
        } else {
            generation &+= 1
            clearSensitiveFields()
            publish(.statusUnconfirmed, targetText: nil, announceTerminal: false)
        }
    }

    private func start(
        context: OperationContext,
        initial: NativeVolcTranslationAdapterPhase,
        intermediate: (TimeInterval, NativeVolcTranslationAdapterPhase)? = nil,
        operation action: @escaping @Sendable () async -> NativeVolcDebugWorkflowResult
    ) {
        let previous = operation
        generation &+= 1
        let current = generation
        operationContext = context
        cancelTimers()
        observer?.cancel()
        previous?.cancel()
        clearSensitiveFields()
        publish(initial, targetText: nil, announceTerminal: false)

        if let intermediate {
            timers.append(scheduler.schedule(after: intermediate.0) { [weak self] in
                guard let self, self.generation == current, self.snapshot.phase.isBusy else { return }
                self.publish(intermediate.1, targetText: nil, announceTerminal: false)
            })
        }
        if context.usesNetwork {
            timers.append(scheduler.schedule(after: 2) { [weak self] in
            guard let self, self.generation == current,
                  self.snapshot.phase.isBusy, self.snapshot.phase != .removing
            else { return }
            self.publish(.slow, targetText: nil, announceTerminal: false)
            })
        }
        timers.append(scheduler.schedule(after: 12) { [weak self] in
            guard let self, self.generation == current, self.snapshot.phase.isBusy else { return }
            self.stopWaiting(timedOut: true)
        })

        let workflow = self.workflow
        let task = Task<NativeVolcDebugWorkflowResult, Never> {
            if let previous {
                await workflow.cancelNetwork()
                _ = await previous.value
            }
            guard !Task.isCancelled else { return .failure(.cancelled) }
            return await action()
        }
        operation = task
        observer = Task { @MainActor [weak self] in
            let result = await task.value
            guard let self, self.generation == current, !Task.isCancelled else { return }
            self.operation = nil
            self.operationContext = nil
            self.cancelTimers()
            self.apply(result, context: context)
        }
    }

    private func stopWaiting(timedOut: Bool, invalidated: Bool = false) {
        let previous = operation
        let context = operationContext
        generation &+= 1
        let current = generation
        cancelTimers()
        observer?.cancel()
        previous?.cancel()
        clearSensitiveFields()
        let workflow = self.workflow
        observer = Task { @MainActor [weak self] in
            await workflow.cancelNetwork()
            let result = await previous?.value
            guard let self, self.generation == current else { return }
            self.operation = nil
            self.operationContext = nil
            let phase = self.phaseAfterStopping(
                result: result,
                context: context,
                timedOut: timedOut,
                invalidated: invalidated
            )
            self.publish(phase, targetText: nil, announceTerminal: true)
        }
    }

    private func apply(
        _ result: NativeVolcDebugWorkflowResult,
        context: OperationContext? = nil
    ) {
        switch result {
        case let .configuration(state):
            publish(Self.phase(for: state), targetText: nil, announceTerminal: true)
        case let .translated(text, saved):
            publish(.success(savedCandidate: saved), targetText: text, announceTerminal: true)
        case .removed:
            publish(.removed, targetText: nil, announceTerminal: true)
        case let .stopped(retained):
            publish(.stopped(pendingRetained: retained), targetText: nil, announceTerminal: true)
        case let .failure(failure):
            publish(
                failure == .cancelled
                    ? (context?.usesNetwork == true ? .networkStatusUnconfirmed : .statusUnconfirmed)
                    : Self.phase(for: failure),
                targetText: nil,
                announceTerminal: true
            )
        }
    }

    private func publish(
        _ phase: NativeVolcTranslationAdapterPhase,
        targetText: String?,
        announceTerminal: Bool
    ) {
        snapshot = NativeVolcTranslationAdapterSnapshot(
            generation: generation, phase: phase, targetText: targetText
        )
        guard announceTerminal, phase.isTerminal,
              announcedGeneration != generation, isPresented
        else { return }
        announcedGeneration = generation
        announce("句译，\(NativeVolcTranslationAdapterPresentation.make(for: phase).title)")
    }

    private func invalidateCurrent(clearPresentation: Bool) {
        let hadOperation = operation != nil
        generation &+= 1
        cancelTimers()
        observer?.cancel()
        operation?.cancel()
        operation = nil
        observer = nil
        operationContext = nil
        clearSensitiveFields()
        if clearPresentation {
            snapshot = NativeVolcTranslationAdapterSnapshot(
                generation: generation, phase: .hidden, targetText: nil
            )
        }
        if hadOperation {
            let workflow = self.workflow
            Task { await workflow.cancelNetwork() }
        }
    }

    private func clearSensitiveFields() {
        accessKey = ""
        secretKey = ""
        if snapshot.targetText != nil {
            snapshot = NativeVolcTranslationAdapterSnapshot(
                generation: generation, phase: snapshot.phase, targetText: nil
            )
        }
    }

    private func cancelTimers() {
        timers.forEach { $0.cancel() }
        timers.removeAll()
    }

    private static func phase(
        for state: NativeVolcDebugConfigurationState
    ) -> NativeVolcTranslationAdapterPhase {
        switch state {
        case .missing: return .missing
        case .pendingReady: return .pendingReady
        case .pendingRecovery: return .pendingRecovery
        case .activeNeedsVerification: return .activeNeedsVerification
        case .ready: return .ready
        case .removalBlocked: return .removalBlocked
        case .interlockUnavailable: return .interlockUnavailable
        case .keychainUnavailable: return .keychainUnavailable
        }
    }

    private static func phase(
        for failure: NativeVolcDebugWorkflowFailure
    ) -> NativeVolcTranslationAdapterPhase {
        switch failure {
        case .interlockUnavailable: return .interlockUnavailable
        case .keychainUnavailable: return .keychainUnavailable
        case .credential: return .credentialError
        case .network: return .networkError
        case .transportSecurity: return .transportSecurity
        case .timeout: return .timeout
        case .quota: return .quota
        case .service: return .service
        case .malformed: return .malformed
        case .pendingReady: return .pendingReady
        case .pendingRecovery: return .pendingRecovery
        case .removalBlocked: return .removalBlocked
        case .revoked: return .networkStatusUnconfirmed
        case .cancelled: return .stopped(pendingRetained: false)
        }
    }

    private func phaseAfterStopping(
        result: NativeVolcDebugWorkflowResult?,
        context: OperationContext?,
        timedOut: Bool,
        invalidated: Bool
    ) -> NativeVolcTranslationAdapterPhase {
        if context?.usesNetwork == true {
            return timedOut && !invalidated ? .timeout : .networkStatusUnconfirmed
        }
        if let result {
            switch result {
            case let .translated(_, saved): return .success(savedCandidate: saved)
            case .removed: return .removed
            case let .stopped(retained): return .stopped(pendingRetained: retained)
            case let .configuration(state): return Self.phase(for: state)
            case let .failure(failure):
                if failure != .cancelled { return Self.phase(for: failure) }
            }
        }
        switch context {
        case .check: return .checkStopped
        case .removal: return .removalStatusUnconfirmed
        case .save, .validatePending, .validateActive, .testFixture:
            return timedOut && !invalidated ? .timeout : .networkStatusUnconfirmed
        case .discardPending, .recover:
            return .statusUnconfirmed
        case nil:
            return .statusUnconfirmed
        }
    }
}
#endif
