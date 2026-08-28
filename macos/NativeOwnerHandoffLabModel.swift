#if DEBUG && JUYI_NATIVE_OWNER_HANDOFF_LAB && (JUYI_NATIVE_SELECTION_CAPTURE_LAB || JUYI_NATIVE_OPTION_MONITOR || JUYI_NATIVE_TRANSLATION_DOMAIN || JUYI_NATIVE_TRANSLATION_OVERLAY || JUYI_NATIVE_TRANSLATION_RESULT_LAB || JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER || JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER || JUYI_NATIVE_APPLE_RESULT_LAB_BINDING)
#error("JUYI_NATIVE_OWNER_HANDOFF_LAB is an isolated handoff-only build and cannot be mixed with capture, Option, or translation development flags")
#endif

#if DEBUG && JUYI_NATIVE_OWNER_HANDOFF_LAB
import Combine
import Foundation

protocol NativeOwnerHandoffStatusReading: AnyObject {
    func read() -> NativeOwnerHandoffStatusReader.Snapshot
}

extension NativeOwnerHandoffStatusReader: NativeOwnerHandoffStatusReading {}

protocol NativeOwnerHandoffLabCancellation: AnyObject {
    @MainActor
    func cancel()
}

@MainActor
final class NativeOwnerHandoffLabModel: ObservableObject {
    static let pollingInterval: TimeInterval = 0.2

    enum Phase: Equatable {
        case disclosure
        case waiting
        case legacyYielded
        case returned(NativeOwnerHandoffWorkflow.ReturnReason)
        case recoveryRequired
        case busy
        case unavailable
    }

    enum InvalidationReason: Equatable {
        case close
        case sleep
        case sessionResigned
        case terminate
        case stop
        case pause
    }

    struct Dependencies {
        let workflow: NativeOwnerHandoffWorkflow
        let statusReader: NativeOwnerHandoffStatusReading
        let monotonicNow: () -> TimeInterval
        let wallNow: () -> TimeInterval
        let schedule: (
            TimeInterval,
            @escaping @MainActor @Sendable () -> Void
        ) -> NativeOwnerHandoffLabCancellation
    }

    @Published private(set) var isPresented = false
    @Published private(set) var phase: Phase = .disclosure
    @Published private(set) var statusHint = "尚未开始；Hammerspoon 仍是唯一双 Option owner。"

    private let dependencies: Dependencies
    private var generation: UInt64 = 0
    private var startedAt: TimeInterval?
    private var scheduled: NativeOwnerHandoffLabCancellation?

    init(dependencies: Dependencies) {
        self.dependencies = dependencies
    }

    func open() {
        isPresented = true
        if dependencies.workflow.holdsCandidateLease {
            syncFromWorkflow()
        } else if phase != .recoveryRequired {
            phase = .disclosure
            statusHint = "尚未开始；Hammerspoon 仍是唯一双 Option owner。"
        }
    }

    func start() {
        guard phase != .waiting, phase != .legacyYielded else { return }
        invalidatePolling()
        dependencies.workflow.begin()
        syncFromWorkflow()
        guard dependencies.workflow.phase == .waitingForLegacy else { return }
        startedAt = dependencies.monotonicNow()
        poll()
    }

    func returnToLegacy() {
        invalidatePolling()
        dependencies.workflow.cancel()
        syncFromWorkflow()
    }

    func recoverAndReturnToLegacy() {
        invalidatePolling()
        dependencies.workflow.recoverAndReturnToLegacy()
        syncFromWorkflow()
    }

    func invalidate(_ reason: InvalidationReason) {
        invalidatePolling()
        if dependencies.workflow.holdsCandidateLease {
            dependencies.workflow.cancel()
            syncFromWorkflow()
        }
        if reason == .close { isPresented = false }
    }

    func close() {
        invalidate(.close)
    }

    private func poll() {
        guard dependencies.workflow.phase == .waitingForLegacy,
              let startedAt else { return }
        let elapsed = dependencies.monotonicNow() - startedAt
        if !elapsed.isFinite || elapsed >= NativeOwnerHandoffWorkflow.acknowledgementDeadline {
            dependencies.workflow.timeOut()
            syncFromWorkflow()
            return
        }
        switch dependencies.statusReader.read() {
        case .absent:
            dependencies.workflow.ingestLegacyStatus(
                nil,
                now: dependencies.wallNow()
            )
        case let .present(data):
            dependencies.workflow.ingestLegacyStatus(
                data,
                now: dependencies.wallNow()
            )
        case .unavailable:
            dependencies.workflow.statusBecameUnavailable()
        }
        syncFromWorkflow()
        guard dependencies.workflow.phase == .waitingForLegacy else { return }
        let currentGeneration = generation
        let remaining = max(
            0,
            NativeOwnerHandoffWorkflow.acknowledgementDeadline
                - (dependencies.monotonicNow() - startedAt)
        )
        scheduled = dependencies.schedule(
            min(Self.pollingInterval, remaining)
        ) { [weak self] in
            guard let self, self.generation == currentGeneration else { return }
            self.scheduled = nil
            self.poll()
        }
    }

    private func invalidatePolling() {
        generation &+= 1
        scheduled?.cancel()
        scheduled = nil
        startedAt = nil
    }

    private func syncFromWorkflow() {
        switch dependencies.workflow.phase {
        case .idle:
            phase = .disclosure
            statusHint = "尚未开始；Hammerspoon 仍是唯一双 Option owner。"
        case .waitingForLegacy:
            phase = .waiting
            statusHint = waitingHint(dependencies.workflow.latestUnsafeReason)
        case .legacyYielded:
            phase = .legacyYielded
            statusHint = "已验证 Hammerspoon 的 watcher、请求和浮窗全部停止；原生 monitor 仍未启动。"
        case .returnedToLegacy:
            let reason = dependencies.workflow.returnReason ?? .cancelled
            phase = .returned(reason)
            statusHint = returnedHint(reason)
        case .recoveryRequired:
            phase = .recoveryRequired
            statusHint = "发现未完成或无法清理的 owner 请求。原生功能保持关闭；请安全归还给 Hammerspoon。"
        case .busy:
            phase = .busy
            statusHint = "另一个句译进程正持有 owner 锁；本进程没有创建 monitor。"
        case .unavailable:
            phase = .unavailable
            statusHint = "无法安全验证 owner 文件；请求已尽力归还，原生功能保持关闭。"
        }
    }

    private func waitingHint(
        _ reason: NativeOwnerHandoffProtocol.UnsafeReason?
    ) -> String {
        switch reason {
        case .watcherStillActive, .requestStillActive, .popupStillVisible,
             .stateNotYielded:
            return "正在等待 Hammerspoon 停止 watcher、活动请求和浮窗…"
        case .statusStale, .statusMissing, .sequenceInvalid, .timestampInvalid:
            return "正在等待 Hammerspoon 发布新的完整状态…"
        case .none:
            return "已发布 owner 请求，正在等待 Hammerspoon 安全让出…"
        default:
            return "状态尚未通过安全检查；会在 5 秒内继续等待，不会启动原生 monitor。"
        }
    }

    private func returnedHint(
        _ reason: NativeOwnerHandoffWorkflow.ReturnReason
    ) -> String {
        switch reason {
        case .cancelled:
            return "owner 请求已移除；Hammerspoon 可在下次轮询后恢复。"
        case .timedOut:
            return "5 秒内未取得安全确认；请求已移除，原生 monitor 从未启动。"
        case .recoveredCrashResidue:
            return "崩溃残留请求已安全移除；Hammerspoon 可恢复。"
        case .requestAlreadyAbsent:
            return "没有残留 owner 请求；Hammerspoon 保持 owner。"
        case .statusUnavailable:
            return "状态文件不可安全读取；请求已移除，原生 monitor 从未启动。"
        }
    }
}
#endif
