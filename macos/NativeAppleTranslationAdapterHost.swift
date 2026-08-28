#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER
import AppKit
import SwiftUI
import Translation

@MainActor
extension NativeAppleTranslationAdapterCoordinator {
    static let shared = NativeAppleTranslationAdapterCoordinator(
        availability: NativeAppleTranslationAvailabilityClient {
            let source = Locale.Language(
                identifier: NativeAppleTranslationAdapterFixture.sourceLanguageIdentifier
            )
            let target = Locale.Language(
                identifier: NativeAppleTranslationAdapterFixture.targetLanguageIdentifier
            )
            let status = await LanguageAvailability().status(from: source, to: target)
            switch status {
            case .installed: return .installed
            case .supported: return .supportedNeedsPreparation
            case .unsupported: return .unsupported
            @unknown default: return .temporarilyUnavailable
            }
        },
        scheduler: NativeAppleTranslationSystemScheduler(),
        announce: { message in
            NSAccessibility.post(
                element: NSApplication.shared,
                notification: .announcementRequested,
                userInfo: [.announcement: message]
            )
        }
    )
}

enum NativeAppleTranslationErrorPolicy {
    static func classify(_ error: any Error) -> NativeTranslationFailure {
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

struct NativeAppleTranslationAdapterSheet: View {
    @ObservedObject var coordinator: NativeAppleTranslationAdapterCoordinator
    @State private var configuration: TranslationSession.Configuration?
    @State private var configuredRequest: NativeAppleTranslationHostRequest?

    private static let sourceLanguage = Locale.Language(
        identifier: NativeAppleTranslationAdapterFixture.sourceLanguageIdentifier
    )
    private static let targetLanguage = Locale.Language(
        identifier: NativeAppleTranslationAdapterFixture.targetLanguageIdentifier
    )

    var body: some View {
        let request = coordinator.hostRequest
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                    .accessibilitySortPriority(60)
                privacyNotice
                    .accessibilitySortPriority(50)
                statusCard
                    .accessibilitySortPriority(40)
                fixtureCard
                    .accessibilitySortPriority(30)
                actionRow
                    .accessibilitySortPriority(20)
            }
            .padding(26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 480, idealHeight: 540)
        .background(Color(nsColor: .windowBackgroundColor))
        .translationTask(configuration) { [request] session in
            guard let request,
                  let claim = coordinator.claimHost(request)
            else { return }
            let completion: NativeAppleTranslationHostCompletion
            switch claim.intent {
            case .prepare:
                do {
                    try await session.prepareTranslation()
                    completion = .prepared
                } catch {
                    completion = .failure(NativeAppleTranslationErrorPolicy.classify(error))
                }

            case .translate:
                guard let sourceText = claim.sourceText,
                      sourceText == NativeAppleTranslationAdapterFixture.sourceText
                else {
                    coordinator.completeHost(.failure(.appleExecutionFailed), request: request)
                    return
                }
                do {
                    let response = try await session.translate(sourceText)
                    guard response.sourceText == sourceText,
                          response.sourceLanguage == Self.sourceLanguage,
                          response.targetLanguage == Self.targetLanguage
                    else {
                        coordinator.completeHost(.failure(.appleExecutionFailed), request: request)
                        return
                    }
                    completion = .translated(response.targetText)
                } catch {
                    completion = .failure(NativeAppleTranslationErrorPolicy.classify(error))
                }
            }
            coordinator.completeHost(completion, request: request)
        }
        .onChange(of: request, initial: true) { _, newRequest in
            updateConfiguration(for: newRequest)
        }
        .onExitCommand {
            coordinator.handleEscape()
        }
        .onDisappear {
            configuration = nil
            configuredRequest = nil
            if coordinator.isPresented { coordinator.close() }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "character.book.closed.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text("Apple 离线翻译开发测试")
                    .font(.title2.weight(.semibold))
                Text("仅供开发验证，不会接管当前双 Option 翻译流程。")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
    }

    private var privacyNotice: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("固定样例与隐私", systemImage: "hand.raised.fill")
                .font(.headline)
            Text("只处理源码内置句子，不读取选区、剪贴板、键盘输入或云端配置。结果仅保存在当前窗口，关闭后即丢弃。")
            Text("翻译正文由 Apple Translation 在这台 Mac 上处理。准备语言包可能由 macOS 联网下载语言资源。Apple 可能收集 App 标识、原文语言和译文语言等不含正文的使用与性能信息。")
        }
        .font(.callout)
        .fixedSize(horizontal: false, vertical: true)
        .modifier(NativeAppleTranslationAdapterSurface())
    }

    private var statusCard: some View {
        let presentation = coordinator.presentation
        return VStack(alignment: .leading, spacing: 9) {
            HStack(alignment: .center, spacing: 10) {
                if coordinator.snapshot.phase.isBusy {
                    ProgressView()
                        .controlSize(.small)
                        .accessibilityLabel(progressAccessibilityLabel)
                        .accessibilityValue("进度未知")
                } else {
                    Image(systemName: statusSymbol)
                        .foregroundStyle(statusColor)
                        .accessibilityHidden(true)
                }
                Text(presentation.title)
                    .font(.headline)
            }
            Text(presentation.message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .modifier(NativeAppleTranslationAdapterSurface())
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var fixtureCard: some View {
        if let fixture = coordinator.fixtureSourceText {
            VStack(alignment: .leading, spacing: 9) {
                Text("固定原文")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(fixture)
                    .font(.body)
                    .fixedSize(horizontal: false, vertical: true)
                if let target = coordinator.snapshot.targetText {
                    Divider()
                    Text("测试译文")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text(target)
                        .font(.body)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .modifier(NativeAppleTranslationAdapterSurface())
        }
    }

    private var actionRow: some View {
        let presentation = coordinator.presentation
        let actions = NativeAppleTranslationAdapterInteractionPolicy.orderedActions(
            phase: coordinator.snapshot.phase,
            presentation: presentation
        )
        return HStack(spacing: 10) {
            ForEach(actions) { item in
                if item.action == .close { Spacer() }
                Button(item.title) { coordinator.perform(item.action) }
                    .keyboardShortcut(
                        item.action == .close ? KeyboardShortcut("w", modifiers: .command)
                            : (item.isPrimary ? .defaultAction : nil)
                    )
                    .disabled(
                        coordinator.snapshot.phase.isBusy
                            && item.action != .cancelOperation
                            && item.action != .close
                    )
                    .accessibilitySortPriority(item.isPrimary ? 3 : (item.action == .close ? 1 : 2))
            }
        }
    }

    private var progressAccessibilityLabel: String {
        switch coordinator.snapshot.phase {
        case .preparing:
            return "正在等待 macOS 准备中英语言包"
        case .translating:
            return "正在翻译固定样例"
        default:
            return "正在检查 Apple 离线翻译"
        }
    }

    private var statusSymbol: String {
        switch coordinator.snapshot.phase {
        case .ready, .success: return "checkmark.circle.fill"
        case .needsPreparation, .preparationWaitStopped: return "arrow.down.circle.fill"
        case .hidden, .checking, .preparing, .translating: return "clock.fill"
        default: return "exclamationmark.triangle.fill"
        }
    }

    private var statusColor: Color {
        switch coordinator.snapshot.phase {
        case .ready, .success: return Color(nsColor: .systemGreen)
        case .needsPreparation, .preparationWaitStopped: return Color(nsColor: .systemOrange)
        default: return Color(nsColor: .systemRed)
        }
    }

    private func updateConfiguration(for request: NativeAppleTranslationHostRequest?) {
        let transition = NativeAppleTranslationHostConfigurationPolicy.transition(
            from: configuredRequest,
            to: request,
            hasConfiguration: configuration != nil
        )
        switch transition {
        case .noChange:
            break
        case .clear:
            configuration = nil
        case .create:
            configuration = TranslationSession.Configuration(
                source: Self.sourceLanguage,
                target: Self.targetLanguage
            )
        case .invalidate:
            guard var current = configuration else {
                configuration = TranslationSession.Configuration(
                    source: Self.sourceLanguage,
                    target: Self.targetLanguage
                )
                configuredRequest = request
                return
            }
            current.invalidate()
            configuration = current
        }
        configuredRequest = request
    }

}

private struct NativeAppleTranslationAdapterSurface: ViewModifier {
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
