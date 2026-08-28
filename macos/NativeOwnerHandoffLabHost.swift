#if DEBUG && JUYI_NATIVE_OWNER_HANDOFF_LAB && (JUYI_NATIVE_SELECTION_CAPTURE_LAB || JUYI_NATIVE_OPTION_MONITOR || JUYI_NATIVE_TRANSLATION_DOMAIN || JUYI_NATIVE_TRANSLATION_OVERLAY || JUYI_NATIVE_TRANSLATION_RESULT_LAB || JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER || JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER || JUYI_NATIVE_APPLE_RESULT_LAB_BINDING)
#error("JUYI_NATIVE_OWNER_HANDOFF_LAB is an isolated handoff-only build and cannot be mixed with capture, Option, or translation development flags")
#endif

#if DEBUG && JUYI_NATIVE_OWNER_HANDOFF_LAB
import AppKit
import SwiftUI

@MainActor
enum NativeOwnerHandoffLabLive {
    static let shared: NativeOwnerHandoffLabModel = {
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".config/argos-translator", isDirectory: true)
            .path
        let workflow = NativeOwnerHandoffWorkflow(
            store: NativeOwnerHandoffStore(directoryPath: directory)
        )
        return NativeOwnerHandoffLabModel(
            dependencies: .init(
                workflow: workflow,
                statusReader: NativeOwnerHandoffStatusReader(
                    directoryPath: directory
                ),
                monotonicNow: { ProcessInfo.processInfo.systemUptime },
                wallNow: { Date().timeIntervalSince1970 },
                schedule: { delay, action in
                    NativeOwnerHandoffLabTimer.schedule(
                        after: delay,
                        action: action
                    )
                }
            )
        )
    }()
}

@MainActor
private final class NativeOwnerHandoffLabTimer: NativeOwnerHandoffLabCancellation {
    private var timer: Timer?

    static func schedule(
        after delay: TimeInterval,
        action: @escaping @MainActor @Sendable () -> Void
    ) -> NativeOwnerHandoffLabTimer {
        let token = NativeOwnerHandoffLabTimer()
        token.timer = Timer.scheduledTimer(
            withTimeInterval: delay,
            repeats: false
        ) { [weak token] _ in
            Task { @MainActor in
                guard let token, token.timer != nil else { return }
                token.timer = nil
                action()
            }
        }
        return token
    }

    func cancel() {
        timer?.invalidate()
        timer = nil
    }
}

struct NativeOwnerHandoffLabHost: View {
    @ObservedObject private var model = NativeOwnerHandoffLabLive.shared
    @AccessibilityFocusState private var focused: FocusTarget?

    private enum FocusTarget: Hashable {
        case title
        case status
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    Text("Debug：双 Option owner 交接实验室")
                        .font(.title2.bold())
                        .accessibilityFocused($focused, equals: .title)

                    Text("只验证已安装的 Hammerspoon 能否安全停止并确认让出。此实验不会启动原生 Option monitor，也不会读取辅助功能、选区、键盘字符或剪贴板；不会翻译、联网、读密钥或显示译文浮窗。")
                        .fixedSize(horizontal: false, vertical: true)

                    disclosureCard
                    statusCard
                }
                .padding(24)
            }

            Divider()
            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 14)
                .background(Color(nsColor: .windowBackgroundColor))
        }
        .frame(minWidth: 560, idealWidth: 620, minHeight: 480, idealHeight: 560)
        .onAppear { focused = .title }
        .onChange(of: model.phase) { _, phase in
            if phase != .disclosure { focused = .status }
        }
        .onExitCommand {
            switch model.phase {
            case .waiting, .legacyYielded:
                model.returnToLegacy()
            default:
                model.close()
            }
        }
    }

    private var disclosureCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("点击开始后才会执行", systemImage: "hand.raised.fill")
                .font(.headline)
            Text("打开本页为零 I/O：不会写 owner 请求，也不会读取 Hammerspoon 状态。")
            Text("句译会在用户配置目录写入一个不含正文的 owner 请求，并持有跨进程锁；随后只读 Hammerspoon 的状态，最多等待 5 秒。")
            Text("Hammerspoon 收到请求后会停止 watcher、活动翻译请求和旧浮窗。实验期间允许暂时没有 owner，但绝不会同时有两个 owner。")
            Text("若 App 崩溃，请求会保留，Hammerspoon 继续停用；重新打开后必须点击“安全归还给 Hammerspoon”。")
        }
        .padding(16)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 12))
        .fixedSize(horizontal: false, vertical: true)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(statusTitle).font(.headline)
            Text(model.statusHint)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .combine)
        .accessibilityFocused($focused, equals: .status)
    }

    @ViewBuilder
    private var footer: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) { actionButtons; Spacer(); closeButton }
            VStack(alignment: .trailing, spacing: 10) { actionButtons; closeButton }
        }
    }

    @ViewBuilder
    private var actionButtons: some View {
        switch model.phase {
        case .disclosure, .returned, .busy, .unavailable:
            Button("开始安全交接测试") { model.start() }
        case .waiting:
            Button("取消并归还 Hammerspoon") { model.returnToLegacy() }
        case .legacyYielded:
            Button("归还给 Hammerspoon") { model.returnToLegacy() }
                .keyboardShortcut(.defaultAction)
        case .recoveryRequired:
            Button("安全归还给 Hammerspoon") {
                model.recoverAndReturnToLegacy()
            }
            .keyboardShortcut(.defaultAction)
        }
    }

    private var closeButton: some View {
        Button("关闭") { model.close() }
    }

    private var statusTitle: String {
        switch model.phase {
        case .disclosure: return "尚未开始"
        case .waiting: return "正在等待 Hammerspoon 安全让出"
        case .legacyYielded: return "安全确认已通过；原生 monitor 仍未启动"
        case .returned: return "已归还 Hammerspoon"
        case .recoveryRequired: return "需要恢复"
        case .busy: return "另一个句译进程正在操作"
        case .unavailable: return "安全状态不可用"
        }
    }
}
#endif
