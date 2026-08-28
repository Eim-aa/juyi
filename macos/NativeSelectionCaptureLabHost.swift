#if DEBUG && JUYI_NATIVE_SELECTION_CAPTURE_LAB && (JUYI_NATIVE_OPTION_MONITOR || JUYI_NATIVE_TRANSLATION_DOMAIN || JUYI_NATIVE_TRANSLATION_OVERLAY || JUYI_NATIVE_TRANSLATION_RESULT_LAB || JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER || JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER || JUYI_NATIVE_APPLE_RESULT_LAB_BINDING)
#error("JUYI_NATIVE_SELECTION_CAPTURE_LAB is an isolated capture-only build and cannot be mixed with Option or translation development flags")
#endif

#if DEBUG && JUYI_NATIVE_SELECTION_CAPTURE_LAB
import AppKit
import Combine
import SwiftUI

@MainActor
private final class NativeSelectionCaptureLabLiveCaptureClient {
    private let captureCoordinator: NativeSelectionCaptureCoordinator

    init(captureCoordinator: NativeSelectionCaptureCoordinator) {
        self.captureCoordinator = captureCoordinator
    }

    func capture(
        target: NativeSelectionTarget,
        completion: @escaping NativeSelectionCaptureLabDependencies.CaptureCompletion
    ) {
        // The exact target snapshot, including launchDate, is passed through.
        // This host never reconstructs process identity from a PID.
        captureCoordinator.capture(target: target) { result in
            completion(Self.map(result))
        }
    }

    func cancelAll() {
        captureCoordinator.cancelAll()
    }

    private static func map(
        _ result: NativeSelectionResult
    ) -> NativeSelectionCaptureLabCaptureResult {
        switch result {
        case let .success(text, didTruncate):
            return .success(text: text, didTruncate: didTruncate)
        case .accessibilityRequired: return .accessibilityRequired
        case .noFocusedElement: return .noFocusedElement
        case .noSelection: return .noSelection
        case .unsupported: return .unsupported
        case .secureField: return .secureField
        case .temporarilyUnavailable: return .temporarilyUnavailable
        case .internalFailure: return .internalFailure
        case .cancelled: return .cancelled
        }
    }
}

@MainActor
enum NativeSelectionCaptureLabLive {
    static let shared: NativeSelectionCaptureLabCoordinator = {
        let captureClient = NativeSelectionCaptureLabLiveCaptureClient(
            captureCoordinator: NativeSelectionCaptureCoordinator()
        )
        return NativeSelectionCaptureLabCoordinator(
            dependencies: NativeSelectionCaptureLabDependencies(
                authorizationStatus: currentAuthorization,
                requestAuthorization: requestAuthorization,
                targetProvider: snapshotFrontmostTarget,
                capture: { target, completion in
                    captureClient.capture(target: target, completion: completion)
                },
                cancelCapture: captureClient.cancelAll,
                applicationIsActive: { NSApp.isActive },
                now: { ProcessInfo.processInfo.systemUptime },
                schedule: { delay, action in
                    let item = DispatchWorkItem(block: action)
                    DispatchQueue.main.asyncAfter(
                        deadline: .now() + delay,
                        execute: item
                    )
                    return NativeSelectionCaptureLabScheduledTask {
                        item.cancel()
                    }
                }
            )
        )
    }()

    static func currentAuthorization() -> NativeSelectionCaptureLabAuthorization {
        switch AccessibilityController.status {
        case .authorized: return .authorized
        case .notAuthorized: return .notAuthorized
        }
    }

    private static func requestAuthorization() -> NativeSelectionCaptureLabAuthorization {
        switch AccessibilityController.requestAuthorization() {
        case .authorized: return .authorized
        case .notAuthorized: return .notAuthorized
        }
    }

    private static func snapshotFrontmostTarget() -> NativeSelectionCaptureLabTargetDecision {
        guard let application = NSWorkspace.shared.frontmostApplication else {
            return .noForegroundApplication
        }
        guard application.processIdentifier
            != ProcessInfo.processInfo.processIdentifier else {
            return .selfTarget
        }
        guard !application.isTerminated,
              application.activationPolicy == .regular,
              let target = NativeSelectionTarget(application: application),
              let bundleIdentifier = target.bundleIdentifier,
              !bundleIdentifier.trimmingCharacters(
                  in: .whitespacesAndNewlines
              ).isEmpty else {
            return .unsupportedTarget
        }
        return .target(target)
    }
}

struct NativeSelectionCaptureLabHostDependencies {
    let authorizationStatus: () -> NativeSelectionCaptureLabAuthorization
    let announce: (String) -> Void
    let openAccessibilitySettings: () -> Void

    @MainActor
    static let live = NativeSelectionCaptureLabHostDependencies(
        authorizationStatus: NativeSelectionCaptureLabLive.currentAuthorization,
        announce: { message in
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [.announcement: message]
            )
        },
        openAccessibilitySettings: {
            guard let url = URL(
                string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            ) else { return }
            NSWorkspace.shared.open(url)
        }
    )
}

@MainActor
struct NativeSelectionCaptureLabHost: View {
    @Environment(\.dismiss) private var dismiss
    @AccessibilityFocusState private var titleIsFocused: Bool
    @ObservedObject private var coordinator: NativeSelectionCaptureLabCoordinator
    private let dependencies: NativeSelectionCaptureLabHostDependencies

    init() {
        coordinator = NativeSelectionCaptureLabLive.shared
        dependencies = .live
    }

    init(
        coordinator: NativeSelectionCaptureLabCoordinator,
        dependencies: NativeSelectionCaptureLabHostDependencies
    ) {
        self.coordinator = coordinator
        self.dependencies = dependencies
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                    disclosure
                    statusCard
                    resultCard
                }
                .padding(26)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            actions
                .padding(.horizontal, 26)
                .padding(.vertical, 16)
        }
        .frame(minWidth: 540, idealWidth: 580, minHeight: 500, idealHeight: 560)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear {
            if !coordinator.isPresented { coordinator.open() }
            DispatchQueue.main.async { titleIsFocused = true }
        }
        .onDisappear {
            coordinator.close()
        }
        .onChange(of: coordinator.phase) { _, _ in
            announcePendingFeedback()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.didBecomeActiveNotification
            )
        ) { _ in
            coordinator.expireIfNeeded()
            if coordinator.phase != .paused,
               dependencies.authorizationStatus() == .notAuthorized {
                coordinator.invalidate(.accessibilityRevoked)
            }
            announcePendingFeedback()
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.willSleepNotification
            )
        ) { _ in
            coordinator.invalidate(.sleep)
        }
        .onReceive(
            NSWorkspace.shared.notificationCenter.publisher(
                for: NSWorkspace.sessionDidResignActiveNotification
            )
        ) { _ in
            coordinator.invalidate(.sessionResigned)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: NSApplication.willTerminateNotification
            )
        ) { _ in
            coordinator.invalidate(.terminate)
        }
        .onExitCommand {
            if coordinator.canPerform(.cancel) {
                coordinator.perform(.cancel)
            } else {
                closeAndDismiss()
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("一次性取词实验室")
                .font(.title2.weight(.semibold))
                .accessibilityFocused($titleIsFocused)
            Text("独立开发入口；Hammerspoon 仍是生产双 Option 的唯一 owner。")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("本次演练会做什么", systemImage: "hand.raised.fill")
                .font(.headline)
            Text("点击“开始一次取词演练（5 秒）”后，请在 5 秒内手动切回目标 App，并保持文字选中。倒计时结束时，句译只快照一次当前前台 App，并只读取一次该 App 的选中文字；不会自动激活或切换任何 App。")
            Text("本实验的按钮和取词动作不会监听双 Option，不会调用 Apple Translation、Volc、localhost、本机翻译 Domain、overlay 或 Keychain，也不会读取或写入剪贴板、记录或持久化文字。Hammerspoon 仍是生产双 Option 的唯一 owner，并继续遵循其现有运行边界。")
            Text("当前只验证已审核的搜索文本框；普通正文、网页或其他控件可能显示为不支持，句译不会为兼容性绕过安全检查。")
            Text("结果可被 macOS 辅助功能读取，只在本窗口显示。正常运行时会在 30 秒后自动清除；若进程或主线程暂停，会在恢复调度的最早时机清除。关闭、暂停、停止、系统睡眠、会话切换、辅助功能权限撤销或退出时会立即使旧代次失效并清除窗口可达的文字。正在收尾的系统读取可能在运行时内存中短暂存在，迟到结果不会显示或保存；Swift 与 macOS 不保证对已释放内存进行物理覆写。")
            Text("只有点击“请求辅助功能权限…”才会触发 macOS 权限请求；“重新检查权限”只读取当前状态，不会请求权限。该权限不替代、移交或接管 Hammerspoon 的生产 owner。")
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
    }

    private var statusCard: some View {
        let presentation = statusPresentation
        return VStack(alignment: .leading, spacing: 7) {
            Text(presentation.title)
                .font(.headline)
            Text(presentation.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var resultCard: some View {
        if case let .result(text, didTruncate, _) = coordinator.phase {
            VStack(alignment: .leading, spacing: 8) {
                Text("一次性读取结果")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(text.value)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.disabled)
                if didTruncate {
                    Text("文字已按 5,000 个 Unicode scalar 上限截断。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("正常运行时 30 秒后自动清除；恢复调度时会立即复核。本实验不提供复制操作。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private var actions: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                primaryActions
                Spacer(minLength: 8)
                closeButton
            }
            VStack(alignment: .leading, spacing: 10) {
                primaryActions
                closeButton
            }
        }
    }

    @ViewBuilder
    private var primaryActions: some View {
        if coordinator.canPerform(.requestAuthorization) {
            Button("请求辅助功能权限…") {
                coordinator.perform(.requestAuthorization)
            }
        }
        if coordinator.canPerform(.recheckAuthorization) {
            Button("重新检查权限") {
                coordinator.perform(.recheckAuthorization)
            }
            Button("打开辅助功能设置…") {
                dependencies.openAccessibilitySettings()
            }
        }
        if coordinator.canPerform(.beginOneShotCapture) {
            Button("开始一次取词演练（5 秒）") {
                coordinator.perform(.beginOneShotCapture)
            }
            .keyboardShortcut(.defaultAction)
        }
        if coordinator.canPerform(.cancel) {
            Button("取消本次演练") {
                coordinator.perform(.cancel)
            }
        }
        if coordinator.canPerform(.clearNow) {
            Button("立即清除文字") {
                coordinator.perform(.clearNow)
            }
        }
    }

    private var closeButton: some View {
        Button("关闭") {
            closeAndDismiss()
        }
        .keyboardShortcut("w", modifiers: .command)
    }

    private var statusPresentation: (title: String, message: String) {
        switch coordinator.phase {
        case let .idle(authorization):
            switch authorization {
            case .authorized:
                return ("辅助功能权限已允许", "准备好后可开始一次 5 秒手动切换演练。")
            case .notAuthorized:
                return ("需要辅助功能权限", "请显式请求权限，或在系统设置中允许后重新检查。")
            }
        case .requestingAuthorization:
            return ("正在请求权限", "请在 macOS 提示中自行决定是否允许。")
        case let .countdown(remaining):
            return ("请手动切回目标 App", "将在 \(remaining) 秒后读取一次当前选中文字。")
        case .reading:
            return ("正在读取一次选区", "不会翻译、联网、显示浮窗或访问剪贴板。")
        case .result:
            return ("一次读取完成", "文字仅保留在本窗口内存中，并将在 30 秒后清除。")
        case let .failure(failure):
            return ("本次未读取", failureMessage(failure))
        case .expired:
            return ("文字已清除", "如需重试，请重新开始一次演练。")
        case .paused:
            return ("实验室已暂停", "暂停期间不会读取；恢复后也不会自动开始。")
        }
    }

    private func failureMessage(_ failure: NativeSelectionCaptureLabFailure) -> String {
        switch failure {
        case .accessibilityRequired: return "辅助功能权限不可用，请重新检查。"
        case .noForegroundApplication: return "截止时没有可读取的前台 App。"
        case .selfTarget: return "截止时前台仍是句译；不会读取自身窗口。"
        case .unsupportedTarget: return "截止时的前台目标不受支持。"
        case .noFocusedElement: return "目标 App 中没有可读取的聚焦控件。"
        case .noSelection: return "截止时没有读取到选中文字。"
        case .unsupported: return "该控件类型不在本实验的允许范围内。"
        case .secureField: return "安全输入控件禁止读取。"
        case .temporarilyUnavailable: return "目标暂时不可用，请稍后重试。"
        case .internalFailure: return "读取失败，且没有保留任何文字。"
        case .cancelled: return "本次演练已取消。"
        }
    }

    private func announcePendingFeedback() {
        guard let message = coordinator
            .consumeAccessibilityFeedbackIfApplicationIsActive() else { return }
        dependencies.announce(message)
    }

    private func closeAndDismiss() {
        coordinator.perform(.close)
        dismiss()
    }
}
#endif
