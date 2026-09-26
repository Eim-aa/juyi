#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER
import AppKit
import SwiftUI

@MainActor
extension NativeVolcTranslationAdapterCoordinator {
    static let shared = NativeVolcTranslationAdapterCoordinator(
        workflow: .live(NativeVolcDebugWorkflow()),
        announce: { message in
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [.announcement: message]
            )
        }
    )
}

struct NativeVolcTranslationAdapterSheet: View {
    @ObservedObject var coordinator: NativeVolcTranslationAdapterCoordinator
    @FocusState private var focusedCredentialField: CredentialField?

    private enum CredentialField: Hashable {
        case accessKey
        case secretKey
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                disclosure
                status
                if showsCredentialForm { credentialForm }
                fixture
                actionRow
            }
            .padding(24)
        }
        .frame(minWidth: 560, idealWidth: 620, maxWidth: 720, minHeight: 520, idealHeight: 650)
        .background(Color(nsColor: .windowBackgroundColor))
        .onExitCommand { coordinator.perform(.close) }
        .onDisappear {
            if coordinator.isPresented { coordinator.close() }
        }
        .onChange(of: coordinator.snapshot.phase) { _, phase in
            if phase == .missing || phase == .credentialError {
                focusedCredentialField = .accessKey
            } else {
                focusedCredentialField = nil
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("火山云端翻译开发测试")
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "cloud.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("火山云端翻译开发测试")
                    .font(.title2.weight(.semibold))
                Text("仅验证源码内置固定样例，不会接管当前双 Option 翻译流程。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
    }

    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("真实 API、隐私与可能用量", systemImage: "hand.raised.fill")
                .font(.headline)
            Text("此页面连接真实火山翻译 API，不是模拟器。只有你点击验证或测试时，固定样例 “Good tools should feel effortless.” 才会通过 HTTPS 发送；每次点击最多发送一次，可能产生少量 API 用量或费用。不会读取用于翻译的选区或剪贴板；除你在此表单主动输入的 AK/SK 外，不采集键盘内容，也不会启用快捷键云端翻译。")
            Text("AK 与 SK 都保存在独立的 Debug 钥匙串中。AK 作为账号标识会随签名请求发送给火山；SK 只在本机派生签名，SK 本身不会发送或写入日志。请求还会包含固定样例；火山服务会获得你的 IP 地址和正常连接元数据。")
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(NativeVolcAdapterSurface())
        .accessibilityElement(children: .combine)
    }

    private var status: some View {
        let presentation = coordinator.presentation
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 10) {
                if coordinator.snapshot.phase.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel("正在处理 Debug 云端操作")
                        .accessibilityValue("进度未知")
                } else {
                    Image(systemName: statusSymbol)
                        .foregroundStyle(statusColor)
                        .accessibilityHidden(true)
                }
                Text(presentation.title).font(.headline)
            }
            Text(presentation.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .modifier(NativeVolcAdapterSurface())
        .accessibilityElement(children: .combine)
    }

    private var credentialForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("独立 Debug 密钥").font(.headline)
            TextField("Access Key", text: $coordinator.accessKey)
                .textFieldStyle(.roundedBorder)
                .focused($focusedCredentialField, equals: .accessKey)
                .accessibilityLabel("Debug Access Key")
                .accessibilityHint("会保存在独立 Debug 钥匙串，并作为账号标识随签名请求发送；不会回填已有值")
            SecureField("Secret Key", text: $coordinator.secretKey)
                .textFieldStyle(.roundedBorder)
                .focused($focusedCredentialField, equals: .secretKey)
                .accessibilityLabel("Debug Secret Key，安全输入")
                .accessibilityHint("会保存在独立 Debug 钥匙串；仅在本机派生签名，不发送且不写日志")
            Text("已有密钥绝不会回填。关闭页面或开始新操作会立即清空输入框。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .modifier(NativeVolcAdapterSurface())
    }

    private var fixture: some View {
        VStack(alignment: .leading, spacing: 9) {
            Text("固定样例").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            Text(NativeVolcDebugFixture.sourceText)
                .font(.body)
                .textSelection(.disabled)
            if let target = coordinator.snapshot.targetText,
               case .success = coordinator.snapshot.phase
            {
                Divider()
                Text("测试译文").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Text(target)
                    .font(.body)
                    .textSelection(.disabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .modifier(NativeVolcAdapterSurface())
        .accessibilityElement(children: .contain)
    }

    private var actionRow: some View {
        HStack(spacing: 10) {
            ForEach(coordinator.presentation.actions) { item in
                Button(item.title) { coordinator.perform(item.action) }
                    .buttonStyle(.bordered)
                    .tint(item.isDestructive ? Color(nsColor: .systemRed) : .accentColor)
                    .keyboardShortcut(item.isPrimary && !item.isDestructive ? .defaultAction : nil)
                    .disabled(item.action == .saveAndValidate && !credentialFormIsLocallyValid)
                    .accessibilitySortPriority(item.isPrimary ? 3 : 2)
            }
            Spacer()
            Button("关闭") { coordinator.perform(.close) }
                .keyboardShortcut("w", modifiers: .command)
                .accessibilitySortPriority(1)
        }
    }

    private var showsCredentialForm: Bool {
        coordinator.snapshot.phase == .missing || coordinator.snapshot.phase == .credentialError
    }

    private var credentialFormIsLocallyValid: Bool {
        NativeVolcDebugCredentials(
            accessKey: coordinator.accessKey,
            secretKey: coordinator.secretKey
        ) != nil
    }

    private var statusSymbol: String {
        switch coordinator.snapshot.phase {
        case .ready, .success, .removed: return "checkmark.circle.fill"
        case .disclosure, .missing, .pendingReady, .activeNeedsVerification:
            return "info.circle.fill"
        case .hidden, .checkingInterlock, .checkingKeychain, .savingPending,
             .validatingPending, .promoting, .connecting, .slow, .removing:
            return "clock.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch coordinator.snapshot.phase {
        case .ready, .success, .removed: return Color(nsColor: .systemGreen)
        case .disclosure, .missing, .pendingReady, .activeNeedsVerification:
            return Color(nsColor: .systemBlue)
        default: return Color(nsColor: .systemRed)
        }
    }
}

private struct NativeVolcAdapterSurface: ViewModifier {
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
