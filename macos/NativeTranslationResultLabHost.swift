#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && !JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
import AppKit
import SwiftUI

@MainActor
extension NativeTranslationResultLabOverlayClient {
    static let live = NativeTranslationResultLabOverlayClient(
        begin: { engine, onDismiss in
            NativeTranslationOverlayController.shared.beginExternal(
                requestedEngine: engine,
                onDismiss: onDismiss
            )
        },
        resolve: { presentation, lease in
            NativeTranslationOverlayController.shared.resolve(
                presentation: presentation,
                lease: lease
            )
        },
        invalidate: { lease, reason in
            NativeTranslationOverlayController.shared.invalidate(
                lease: lease,
                reason: reason
            )
        },
        focusCurrent: { lease in
            NativeTranslationOverlayController.shared.focusCurrentOverlay(
                lease: lease
            )
        }
    )
}

@MainActor
enum NativeTranslationResultLabLive {
    static let shared = NativeTranslationResultLabCoordinator(
        overlay: .live,
        domainFactory: .fixedInMemory,
        clock: .main
    )
}

struct NativeTranslationResultLabSheet: View {
    @ObservedObject var coordinator: NativeTranslationResultLabCoordinator
    @AccessibilityFocusState private var accessibilityFocus: AccessibilityFocus?

    private enum AccessibilityFocus: Hashable {
        case title
        case status
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header.accessibilitySortPriority(60)
                    disclosure.accessibilitySortPriority(50)
                    fixtureSummary.accessibilitySortPriority(40)
                    statusCard.accessibilitySortPriority(30)
                }
                .padding(26)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            actionRow
                .padding(.horizontal, 26)
                .padding(.vertical, 14)
                .accessibilitySortPriority(20)
        }
        .frame(minWidth: 540, idealWidth: 590, minHeight: 520, idealHeight: 610)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand {
            switch NativeTranslationResultLabSheetInteractionPolicy.escapeAction(
                isBusy: coordinator.isBusy
            ) {
            case .stop: coordinator.stopSimulation()
            case .close: coordinator.close()
            }
        }
        .onDisappear {
            if coordinator.isPresented { coordinator.close() }
        }
        .onAppear {
            DispatchQueue.main.async { accessibilityFocus = .title }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("句译 Result Lab，Debug 固定样例模拟")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "rectangle.and.hand.point.up.left.filled")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                Text("结果界面实验室")
                    .font(.title2.weight(.semibold))
                    .accessibilityFocused($accessibilityFocus, equals: .title)
                Text("Debug 固定样例 · 模拟执行")
                    .font(.headline)
                Text("验证原生浮窗、状态映射、键盘与辅助功能；不会接管双 Option 翻译。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
    }

    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 9) {
            Label("模拟边界与隐私", systemImage: "hand.raised.fill")
                .font(.headline)
            Text("不会读取真实选区、剪贴板现有内容或文本输入；浮窗可见时会检查按键的键码与修饰键，以识别关闭、聚焦、滚动和复制操作，但不会读取字符正文或记录按键。")
            Text("Apple 模拟不会调用 Apple Translation。火山模拟不会读取密钥、不会联网、不会签名，也不会产生 API 用量或费用。")
            Text("只有你在浮窗中点击“复制固定译文”，或显式聚焦成功浮窗后按 Command-C 时，句译才会用完整固定译文替换系统剪贴板；复制后，其他 App 或剪贴板管理器可能读取并长期保留它。")
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(NativeTranslationResultLabSurface())
        .accessibilityElement(children: .combine)
    }

    private var fixtureSummary: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("固定非敏感样例").font(.headline)
            fixtureRow(
                title: "Apple 离线（模拟）",
                source: NativeTranslationResultLabFixtures.appleSource,
                detail: "未调用 Apple Translation"
            )
            Divider()
            fixtureRow(
                title: "火山云端（模拟）",
                source: NativeTranslationResultLabFixtures.volcSource,
                detail: "未读密钥、未联网、不计费"
            )
        }
        .modifier(NativeTranslationResultLabSurface())
    }

    private func fixtureRow(
        title: String,
        source: String,
        detail: String
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline.weight(.semibold))
            Text(source).font(.body).textSelection(.disabled)
            Text(detail).font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    private var statusCard: some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 10) {
                if coordinator.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在运行固定样例模拟")
                        .accessibilityValue("进度未知")
                } else {
                    Image(systemName: statusSymbol)
                        .foregroundStyle(statusColor)
                        .accessibilityHidden(true)
                }
                Text(statusTitle).font(.headline)
            }
            Text(statusMessage)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .modifier(NativeTranslationResultLabSurface())
        .accessibilityElement(children: .combine)
        .accessibilityFocused($accessibilityFocus, equals: .status)
    }

    private var actionRow: some View {
        Group {
            if coordinator.isBusy {
                HStack(spacing: 10) {
                    Button("停止模拟") { coordinator.stopSimulation() }
                        .accessibilityHint("停止当前内存模拟；迟到结果不会显示或复制")
                    Spacer()
                    closeButton
                }
            } else {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 10) {
                        idleActionButtons
                        Spacer()
                        closeButton
                    }
                    VStack(alignment: .leading, spacing: 10) {
                        idleActionButtons
                        closeButton
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var idleActionButtons: some View {
        Button("运行 Apple 模拟") { coordinator.runAppleSimulation() }
            .keyboardShortcut(.defaultAction)
        Button("运行火山模拟") { coordinator.runVolcSimulation() }
        if coordinator.hasVisibleResult {
            Button("聚焦当前结果") { coordinator.focusCurrentResult() }
                .accessibilityHint("显式进入浮窗键盘模式，不读取或更改选区")
        }
    }

    private var closeButton: some View {
        Button("关闭") { coordinator.close() }
            .keyboardShortcut("w", modifiers: .command)
            .accessibilityHint("停止当前模拟并关闭 Result Lab")
    }

    private var statusTitle: String {
        switch coordinator.phase {
        case .disclosure: return "尚未运行模拟"
        case let .running(engine, isSlow):
            if isSlow {
                return engine == .apple ? "Apple 模拟仍在进行…" : "火山模拟仍在进行…"
            }
            return engine == .apple ? "正在运行 Apple 模拟…" : "正在运行火山模拟…"
        case let .completed(engine):
            return engine == .apple ? "Apple 模拟结果已显示" : "火山模拟结果已显示"
        case let .typedNotice(engine):
            return engine == .apple ? "Apple 模拟返回提示" : "火山模拟返回提示"
        case let .typedError(engine):
            return engine == .apple ? "Apple 模拟返回错误" : "火山模拟返回错误"
        case let .debugSafetyFailure(engine):
            guard let engine else { return "结果未通过 Debug 安全检查" }
            return engine == .apple
                ? "Apple 模拟结果未通过 Debug 安全检查"
                : "火山模拟结果未通过 Debug 安全检查"
        case let .timeout(engine):
            return engine == .apple ? "Apple 模拟执行超时" : "火山模拟执行超时"
        case let .stopped(engine):
            guard let engine else { return "已停止模拟" }
            return engine == .apple ? "已停止 Apple 模拟" : "已停止火山模拟"
        }
    }

    private var statusMessage: String {
        switch coordinator.phase {
        case .disclosure:
            return "选择一个固定样例后，结果会显示在同一个原生浮窗中。"
        case let .running(engine, isSlow):
            if isSlow { return "仍在等待内存模拟；未调用真实翻译服务。" }
            return engine == .apple
                ? "只运行固定内存执行器，未调用 Apple Translation。"
                : "只运行固定内存执行器，未读密钥、未联网、不计费。"
        case .completed:
            return "浮窗仅显示固定译文；模拟耗时会明确标注。"
        case .typedNotice, .typedError:
            return "浮窗显示经过类型检查的 Debug 状态，不含原始错误或生产设置入口。"
        case let .debugSafetyFailure(engine):
            guard let engine else {
                return "没有显示或保留不符合固定契约的结果；未调用任何真实翻译服务。"
            }
            return engine == .volc
                ? "没有显示或保留不符合固定契约的结果；未读密钥、未联网、不计费。"
                : "没有显示或保留不符合固定契约的结果；未调用 Apple Translation。"
        case let .timeout(engine):
            return engine == .volc
                ? "已停止火山模拟；迟到结果不会显示或复制。未读密钥、未联网、不计费。"
                : "已停止 Apple 模拟；迟到结果不会显示或复制。未调用 Apple Translation。"
        case let .stopped(engine):
            guard let engine else {
                return "已停止模拟；迟到结果不会显示或复制，且未调用任何真实翻译服务。"
            }
            return engine == .volc
                ? "已停止火山模拟；迟到结果不会显示或复制。未读密钥、未联网、不计费。"
                : "已停止 Apple 模拟；迟到结果不会显示或复制。未调用 Apple Translation。"
        }
    }

    private var statusSymbol: String {
        switch coordinator.phase {
        case .completed: return "checkmark.circle.fill"
        case .disclosure, .stopped: return "circle.dashed"
        case .typedNotice: return "info.circle.fill"
        case .running: return "clock.fill"
        case .typedError, .debugSafetyFailure, .timeout:
            return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch coordinator.phase {
        case .completed: return Color(nsColor: .systemGreen)
        case .typedNotice: return Color(nsColor: .systemOrange)
        case .typedError, .debugSafetyFailure, .timeout:
            return Color(nsColor: .systemRed)
        default: return .secondary
        }
    }
}

private struct NativeTranslationResultLabSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 13, style: .continuous)
                    .stroke(Color(nsColor: .separatorColor), lineWidth: 1)
            )
    }
}
#endif
