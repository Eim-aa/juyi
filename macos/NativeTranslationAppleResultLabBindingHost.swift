#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
import AppKit
import SwiftUI
import Translation

@MainActor
extension NativeTranslationAppleResultLabOverlayClient {
    static let live = NativeTranslationAppleResultLabOverlayClient(
        reserve: { onDismiss in
            NativeTranslationOverlayController.shared.reserveRealAppleExternal(
                onDismiss: onDismiss
            )
        },
        activate: { presentation, lease in
            NativeTranslationOverlayController.shared.activateRealAppleExternal(
                loading: presentation,
                lease: lease
            )
        },
        updateLoading: { presentation, lease in
            NativeTranslationOverlayController.shared.updateRealAppleLoading(
                presentation,
                lease: lease
            )
        },
        resolve: { presentation, lease in
            NativeTranslationOverlayController.shared.resolveRealAppleExternal(
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
            NativeTranslationOverlayController.shared.focusCurrentOverlay(lease: lease)
        }
    )
}

@MainActor
enum NativeTranslationAppleResultLabLive {
    static let shared = NativeTranslationAppleResultLabCoordinator(
        availability: NativeTranslationAppleResultLabAvailabilityClient {
            let source = Locale.Language(
                identifier: NativeTranslationAppleResultLabFixture.sourceLanguageIdentifier
            )
            let target = Locale.Language(
                identifier: NativeTranslationAppleResultLabFixture.targetLanguageIdentifier
            )
            let status = await LanguageAvailability().status(
                from: source,
                to: target
            )
            switch status {
            case .installed: return .installed
            case .supported: return .supportedNeedsPreparation
            case .unsupported: return .unsupported
            @unknown default: return .temporarilyUnavailable
            }
        },
        scheduler: NativeTranslationAppleResultLabSystemScheduler(),
        overlay: .live,
        domainFactory: .liveApple
    )
}

struct NativeTranslationAppleResultLabSheet: View {
    @ObservedObject var coordinator: NativeTranslationAppleResultLabCoordinator
    @State private var hostSlot: NativeTranslationAppleResultLabHostSlot?
    @AccessibilityFocusState private var accessibilityFocus: AccessibilityFocus?
    @State private var lastSheetAnnouncedPhase: NativeTranslationAppleResultLabPhase?

    private enum AccessibilityFocus: Hashable {
        case title
        case status
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    header
                        .accessibilitySortPriority(60)
                    disclosure
                        .accessibilitySortPriority(50)
                    fixtureCard
                        .accessibilitySortPriority(40)
                    statusCard
                        .accessibilitySortPriority(30)
                }
                .padding(26)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            actionFooter
                .padding(.horizontal, 26)
                .padding(.vertical, 16)
                .background(.bar)
                .accessibilitySortPriority(20)
        }
        .frame(minWidth: 540, idealWidth: 590, minHeight: 500, idealHeight: 570)
        .background(Color(nsColor: .windowBackgroundColor))
        .background(alignment: .topLeading) {
            if let hostSlot {
                NativeTranslationAppleResultLabTranslationHostSlot(
                    slot: hostSlot,
                    coordinator: coordinator
                )
                .id(hostSlot.id)
            }
        }
        .onAppear {
            coordinator.attachHostConfigurationControl { command in
                switch command {
                case let .install(request):
                    hostSlot = NativeTranslationAppleResultLabHostSlot(request: request)
                case let .invalidateAndClear(ownerGeneration):
                    guard hostSlot?.request.ownerGeneration == ownerGeneration else { return }
                    hostSlot = nil
                }
            }
            DispatchQueue.main.async { accessibilityFocus = .title }
        }
        .onChange(of: coordinator.phase) { _, phase in
            guard NativeTranslationAppleResultLabSheetAnnouncementPolicy
                    .sheetOwnsStatusAnnouncement(
                        for: phase,
                        hasVisibleResult: coordinator.hasVisibleResult
                    ),
                  lastSheetAnnouncedPhase != phase
            else { return }
            lastSheetAnnouncedPhase = phase
            accessibilityFocus = .status
        }
        .onExitCommand {
            coordinator.handleEscape()
        }
        .onDisappear {
            coordinator.detachHostConfigurationControl()
            hostSlot = nil
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "apple.logo")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("真实 Apple 结果实验室")
                    .font(.title2.weight(.semibold))
                Text("Debug 固定样例 · 真实 Apple Translation")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("真实 Apple 结果实验室，Debug 固定样例，真实 Apple Translation")
        .accessibilityFocused($accessibilityFocus, equals: .title)
    }

    private var disclosure: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("真实处理与隐私边界", systemImage: "hand.raised.fill")
                .font(.headline)
            Text("固定原文会交给 Apple Translation 在这台 Mac 上处理。准备语言包可能由 macOS 联网；Apple 可能处理 App 标识、语言对及不含正文的使用和性能信息。句译不会读取真实选区、剪贴板现有内容、键盘正文或云端密钥，也不会调用火山翻译。")
                .font(.callout)
            Text("只有你点击“复制 Apple 译文”或在已聚焦浮窗中按⌘C时，句译才会替换系统剪贴板；之后其他 App 或剪贴板管理器可能读取并继续保留译文。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("浮窗可见时只检查鼠标位置、键码和修饰键来识别关闭、聚焦、滚动与复制；不读取字符正文，也不记录这些事件。复制不会读取旧剪贴板；若系统写入失败，旧内容不保证恢复。此实验不接双击 Option、Hammerspoon 或生产翻译流程。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("此固定样例无需辅助功能授权，也不会弹出辅助功能授权提示。若句译再次成为前台并检测到运行中的辅助功能权限已撤销，会停止当时请求；之后可重新打开。")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .modifier(NativeTranslationAppleResultLabSurface())
    }

    private var fixtureCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("源码内置固定原文")
                .font(.headline)
            Text(NativeTranslationAppleResultLabFixture.sourceText)
                .font(.body.monospaced())
                .textSelection(.disabled)
                .accessibilityLabel("固定原文，The weather is pleasant today.")
            Text("英语 → 简体中文")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .modifier(NativeTranslationAppleResultLabSurface())
    }

    private var statusCard: some View {
        let presentation = coordinator.presentation
        return VStack(alignment: .leading, spacing: 7) {
            Text(presentation.title)
                .font(.headline)
            Text(presentation.message)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .modifier(NativeTranslationAppleResultLabSurface())
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(presentation.title)。\(presentation.message)")
        .accessibilityFocused($accessibilityFocus, equals: .status)
    }

    private var actionFooter: some View {
        let presentation = coordinator.presentation
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                actionButtons(presentation)
            }
            VStack(alignment: .trailing, spacing: 9) {
                actionButtons(presentation)
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private func actionButtons(
        _ presentation: NativeTranslationAppleResultLabPresentation
    ) -> some View {
        if let action = presentation.primaryAction,
           let title = presentation.primaryTitle {
            Button(title) { coordinator.perform(action) }
                .buttonStyle(.borderedProminent)
        }
        if let action = presentation.secondaryAction,
           let title = presentation.secondaryTitle {
            Button(title) { coordinator.perform(action) }
        }
        if coordinator.hasVisibleResult {
            Button("聚焦当前结果") { coordinator.focusCurrentResult() }
        }
        Button("关闭") { coordinator.close() }
    }

}

private struct NativeTranslationAppleResultLabHostSlot: Equatable, Identifiable {
    let request: NativeTranslationAppleResultLabHostRequest

    var id: String {
        "\(request.ownerGeneration):\(request.requestGeneration)"
    }
}

private struct NativeTranslationAppleResultLabTranslationHostSlot: View {
    let slot: NativeTranslationAppleResultLabHostSlot
    @ObservedObject var coordinator: NativeTranslationAppleResultLabCoordinator
    @State private var configuration: TranslationSession.Configuration

    private static let sourceLanguage = Locale.Language(
        identifier: NativeTranslationAppleResultLabFixture.sourceLanguageIdentifier
    )
    private static let targetLanguage = Locale.Language(
        identifier: NativeTranslationAppleResultLabFixture.targetLanguageIdentifier
    )

    init(
        slot: NativeTranslationAppleResultLabHostSlot,
        coordinator: NativeTranslationAppleResultLabCoordinator
    ) {
        self.slot = slot
        self.coordinator = coordinator
        _configuration = State(
            initialValue: TranslationSession.Configuration(
                source: Self.sourceLanguage,
                target: Self.targetLanguage
            )
        )
    }

    var body: some View {
        let request = slot.request
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .translationTask(configuration) { [request] session in
                guard let claim = coordinator.claimHost(request) else { return }
                let completion: NativeTranslationAppleResultLabHostCompletion
                switch claim.request.intent {
                case .prepare:
                    do {
                        try await session.prepareTranslation()
                        completion = .prepared
                    } catch is CancellationError {
                        completion = .cancelled
                    } catch {
                        completion = .failure(Self.classify(error))
                    }

                case .translate:
                    guard let sourceText = claim.sourceText,
                          claim.receipt != nil,
                          sourceText == NativeTranslationAppleResultLabFixture.sourceText
                    else {
                        coordinator.completeHost(
                            .failure(.appleExecutionFailed),
                            claim: claim
                        )
                        return
                    }
                    do {
                        let response = try await session.translate(sourceText)
                        guard response.sourceText == sourceText,
                              response.sourceLanguage == Self.sourceLanguage,
                              response.targetLanguage == Self.targetLanguage
                        else {
                            coordinator.completeHost(
                                .failure(.appleExecutionFailed),
                                claim: claim
                            )
                            return
                        }
                        completion = .translated(response.targetText)
                    } catch is CancellationError {
                        completion = .cancelled
                    } catch {
                        completion = .failure(Self.classify(error))
                    }
                }
                coordinator.completeHost(completion, claim: claim)
            }
            .onDisappear {
                coordinator.hostSlotWillDisappear(request)
                configuration.invalidate()
            }
    }

    private static func classify(_ error: Error) -> NativeTranslationFailure {
        switch error {
        case TranslationError.unsupportedSourceLanguage,
             TranslationError.unsupportedTargetLanguage,
             TranslationError.unsupportedLanguagePairing:
            return .appleUnsupported
        case TranslationError.unableToIdentifyLanguage,
             TranslationError.nothingToTranslate,
             TranslationError.internalError:
            return .appleExecutionFailed
        default:
            return .appleExecutionFailed
        }
    }
}

private struct NativeTranslationAppleResultLabSurface: ViewModifier {
    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .fill(Color(nsColor: .controlBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.primary.opacity(0.10), lineWidth: 1)
            )
    }
}
#endif
