import AppKit
import CoreGraphics
import Foundation
import QuartzCore

#if DEBUG && JUYI_NATIVE_TRANSLATION_OVERLAY && !JUYI_NATIVE_APPLE_RESULT_LAB_BINDING

private enum NativeTranslationOverlayFixture: CaseIterable {
    case loading
    case appleSuccess
    case volcSuccess
    case volcAppleFallback
    case volcNetwork
    case copyFailure
    case longTruncated
    case noSelection
    case secure
    case unsupported
    case accessibility
    case serviceError
    case applePackage
    case volcCredential
    case privacyRefusal

    static let buildSentinel = "juyi-native-overlay-fixed-fixture-v1"
    static let fullTranslation = "好工具应当让复杂的事情感觉自然。\n这是固定的非敏感 Debug 预览内容。"
    static let longTranslation = Array(
        repeating: "固定长译文用于验证滚动、截断标记与粘性页脚。",
        count: 36
    ).joined(separator: "\n")

    var displayName: String {
        switch self {
        case .loading: return "载入中"
        case .appleSuccess: return "Apple 成功"
        case .volcSuccess: return "火山成功"
        case .volcAppleFallback: return "火山转 Apple"
        case .volcNetwork: return "火山网络错误"
        case .copyFailure: return "复制失败反馈"
        case .longTruncated: return "长文与截断"
        case .noSelection: return "未选中文字"
        case .secure: return "安全输入框"
        case .unsupported: return "不支持的 App"
        case .accessibility: return "辅助功能权限"
        case .serviceError: return "翻译组件错误"
        case .applePackage: return "Apple 语言包"
        case .volcCredential: return "火山云端设置"
        case .privacyRefusal: return "隐私拒绝"
        }
    }

    var event: NativeTranslationOverlayEvent? {
        switch self {
        case .loading:
            return nil
        case .appleSuccess:
            return .response(
                NativeTranslationOverlayResponse(
                    requestedEngine: .apple,
                    actualEngine: .apple,
                    result: Self.fullTranslation,
                    elapsedMilliseconds: 218
                )
            )
        case .volcSuccess:
            return .response(
                NativeTranslationOverlayResponse(
                    requestedEngine: .volc,
                    actualEngine: .volc,
                    result: "这是固定的火山云端成功预览译文。",
                    elapsedMilliseconds: 386
                )
            )
        case .volcAppleFallback:
            return .response(
                NativeTranslationOverlayResponse(
                    requestedEngine: .volc,
                    actualEngine: .apple,
                    result: "这是固定的火山转 Apple 离线预览译文。",
                    elapsedMilliseconds: 274,
                    warning: .usedAppleFallback
                )
            )
        case .volcNetwork:
            return .response(
                NativeTranslationOverlayResponse(
                    requestedEngine: .volc,
                    actualEngine: .volc,
                    result: nil,
                    elapsedMilliseconds: nil,
                    error: .volcNetwork
                )
            )
        case .copyFailure:
            return .response(
                NativeTranslationOverlayResponse(
                    requestedEngine: .apple,
                    actualEngine: .apple,
                    result: Self.fullTranslation,
                    elapsedMilliseconds: 231
                )
            )
        case .longTruncated:
            return .response(
                NativeTranslationOverlayResponse(
                    requestedEngine: .apple,
                    actualEngine: .apple,
                    result: Self.longTranslation,
                    elapsedMilliseconds: 742,
                    captureDidTruncate: true
                )
            )
        case .noSelection:
            return .capture(.noSelection)
        case .secure:
            return .capture(.secureField)
        case .unsupported:
            return .capture(.unsupported)
        case .accessibility:
            return .capture(.accessibilityRequired)
        case .serviceError:
            return .response(
                NativeTranslationOverlayResponse(
                    requestedEngine: .apple,
                    actualEngine: .apple,
                    result: "此固定错误回显绝不能出现在界面中。",
                    elapsedMilliseconds: 999,
                    error: .serviceUnavailable
                )
            )
        case .applePackage:
            return .response(
                NativeTranslationOverlayResponse(
                    requestedEngine: .apple,
                    actualEngine: .apple,
                    result: nil,
                    elapsedMilliseconds: nil,
                    error: .appleNotReady
                )
            )
        case .volcCredential:
            return .response(
                NativeTranslationOverlayResponse(
                    requestedEngine: .volc,
                    actualEngine: .volc,
                    result: nil,
                    elapsedMilliseconds: nil,
                    error: .volcCredential
                )
            )
        case .privacyRefusal:
            return .response(
                NativeTranslationOverlayResponse(
                    requestedEngine: .apple,
                    actualEngine: .volc,
                    result: "此固定隐私拒绝结果绝不能出现在界面中。",
                    elapsedMilliseconds: 420
                )
            )
        }
    }

    var initialCopyPresentation: NativeTranslationOverlayCopyPresentation {
        switch self {
        case .copyFailure: return .failed
        default: return .idle
        }
    }
}
#endif

private final class NativeTranslationOverlayButton: NSButton {
    var keyboardFocusEnabled = false {
        didSet { refusesFirstResponder = !keyboardFocusEnabled }
    }

    override var acceptsFirstResponder: Bool { keyboardFocusEnabled }
}

private final class NativeTranslationOverlayPanel: NSPanel {
    var scrollKeyHandler: ((UInt16, NSEvent.ModifierFlags) -> Bool)?

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    override func sendEvent(_ event: NSEvent) {
        if event.type == .keyDown,
           scrollKeyHandler?(event.keyCode, event.modifierFlags) == true {
            return
        }
        super.sendEvent(event)
    }
}

#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB
private enum NativeTranslationOverlayExternalIdentity: Equatable {
    case simulated(NativeTranslationEngine)
    #if JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
    case realAppleFixed
    #endif

    var engine: NativeTranslationEngine {
        switch self {
        case let .simulated(engine): return engine
        #if JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
        case .realAppleFixed: return .apple
        #endif
        }
    }
}
#endif

@MainActor
private final class NativeTranslationOverlayContentView: NSVisualEffectView {
    var closeHandler: (() -> Void)?
    var copyHandler: (() -> Void)?
    var ctaHandler: (() -> Void)?

    private let iconView = NSImageView()
    private let loadingIndicator = NSProgressIndicator()
    private let titleField = NSTextField(wrappingLabelWithString: "")
    private let bodyField = NSTextField(wrappingLabelWithString: "")
    private let metadataField = NSTextField(labelWithString: "")
    private let fallbackField = NSTextField(labelWithString: "")
    private let truncationField = NSTextField(labelWithString: "")
    private let truncationIcon = NSImageView()
    private let truncationBadgeView = NSStackView()
    private let separator = NSBox()
    private let bodyScrollView = NSScrollView()
    private let closeButton = NativeTranslationOverlayButton()
    private let copyButton = NativeTranslationOverlayButton()
    private let ctaButton = NativeTranslationOverlayButton()
    private let metadataStack = NSStackView()
    private let actionsStack = NSStackView()
    #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB
    private var resultLabIdentity: NativeTranslationOverlayExternalIdentity?
    #endif
    private let footerStack = NSStackView()
    private let headerStack = NSStackView()
    private let bodyStack = NSStackView()
    private var bodyHeightConstraint: NSLayoutConstraint!
    private var separatorHeightConstraint: NSLayoutConstraint!

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configureView()
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        applyAccessibilityAppearance()
    }

    func render(
        _ state: NativeTranslationOverlayState,
        copyPresentation: NativeTranslationOverlayCopyPresentation,
        availablePanelHeight: CGFloat? = nil,
        statefulActionsEnabled: Bool = true
    ) {
        titleField.stringValue = state.title
        let isSuccess = state.kind == .success
        headerStack.isHidden = isSuccess
        // Keep the same close control and keyboard topology. Success puts it
        // beside the translation instead of spending a row on a "译文" title.
        let closeContainer = isSuccess ? bodyStack : headerStack
        if closeButton.superview !== closeContainer {
            closeButton.removeFromSuperview()
            closeContainer.addArrangedSubview(closeButton)
        }
        setAccessibilityLabel(isSuccess ? state.title : nil)
        bodyField.attributedStringValue = attributedBody(state)
        bodyScrollView.isHidden = state.body.isEmpty
        bodyStack.isHidden = state.body.isEmpty
        metadataField.stringValue = state.metadata ?? ""
        metadataField.isHidden = state.metadata == nil
        fallbackField.stringValue = state.fallbackNotice ?? ""
        fallbackField.isHidden = state.fallbackNotice == nil
        truncationField.stringValue = state.truncationBadge ?? ""
        truncationBadgeView.isHidden = state.truncationBadge == nil
        truncationBadgeView.setAccessibilityLabel(state.truncationBadge)
        truncationBadgeView.setAccessibilityHelp(state.truncationAccessibilityHelp)
        metadataStack.isHidden = state.metadata == nil
            && state.fallbackNotice == nil
            && state.truncationBadge == nil

        ctaButton.title = state.cta?.title ?? ""
        ctaButton.isHidden = state.cta == nil
        ctaButton.setAccessibilityLabel(state.cta?.title)
        ctaButton.setAccessibilityHelp(
            state.cta == nil ? nil : "仅在你点击后打开句译中的对应页面"
        )
        copyButton.isHidden = !state.canCopy
        #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB
        #if JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
        let copyTitle = resultLabIdentity == .realAppleFixed && copyPresentation == .idle
            ? "复制 Apple 译文"
            : copyPresentation.buttonTitle
        #else
        let copyTitle = resultLabIdentity != nil && copyPresentation == .idle
            ? "复制固定译文"
            : copyPresentation.buttonTitle
        #endif
        #else
        let copyTitle = copyPresentation.buttonTitle
        #endif
        copyButton.title = copyTitle
        copyButton.setAccessibilityLabel(copyTitle)
        #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB
        #if JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
        copyButton.setAccessibilityHelp(
            state.canCopy && resultLabIdentity == .realAppleFixed
                ? "复制完整真实 Apple 固定样例译文并替换系统剪贴板；其他 App 或剪贴板管理器之后可能读取并保留它"
                : (state.canCopy ? "复制完整译文，浮窗会继续保留" : nil)
        )
        #else
        copyButton.setAccessibilityHelp(
            state.canCopy && resultLabIdentity != nil
                ? "复制完整固定译文并替换系统剪贴板；其他 App 或剪贴板管理器之后可能读取并保留它"
                : (state.canCopy ? "复制完整译文，浮窗会继续保留" : nil)
        )
        #endif
        closeButton.setAccessibilityLabel("关闭")
        closeButton.setAccessibilityHelp(
            resultLabIdentity != nil
                ? "关闭当前 Result Lab 浮窗并停止本次请求；迟到结果不会显示或复制"
                : "关闭当前译文，不停止句译"
        )
        #else
        copyButton.setAccessibilityHelp(
            state.canCopy ? "复制完整译文，浮窗会继续保留" : nil
        )
        closeButton.setAccessibilityLabel("关闭")
        closeButton.setAccessibilityHelp("关闭当前译文，不停止句译")
        #endif
        actionsStack.isHidden = state.cta == nil && !state.canCopy
        setStatefulActionsEnabled(statefulActionsEnabled)
        footerStack.isHidden = metadataStack.isHidden && actionsStack.isHidden
        separator.isHidden = footerStack.isHidden

        let isLoading = state.kind == .loading
        loadingIndicator.isHidden = !isLoading
        iconView.isHidden = isLoading
        if isLoading {
            loadingIndicator.startAnimation(nil)
        } else {
            loadingIndicator.stopAnimation(nil)
            iconView.image = icon(for: state.kind)
            iconView.contentTintColor = tint(for: state.kind)
        }
        titleField.font = scaledSystemFont(ofSize: 13, weight: .semibold)
        bodyField.font = scaledSystemFont(
            ofSize: state.kind == .success ? 15 : 13,
            weight: .regular
        )
        for field in [metadataField, fallbackField] {
            field.font = scaledSystemFont(ofSize: 11, weight: .regular)
        }
        truncationField.font = scaledSystemFont(ofSize: 11, weight: .semibold)
        for button in [closeButton, copyButton, ctaButton] {
            button.font = scaledSystemFont(ofSize: 12, weight: .medium)
        }
        bodyHeightConstraint.constant = bodyViewportHeight(
            for: state,
            availablePanelHeight: availablePanelHeight
        )
        updateAccessibilityOrder(state)
        needsLayout = true
    }

    #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB
    func setResultLabPresentation(
        _ identity: NativeTranslationOverlayExternalIdentity?
    ) {
        resultLabIdentity = identity
    }
    #endif

    func desiredSize(for state: NativeTranslationOverlayState) -> CGSize {
        let scale = accessibilityFontScale
        switch state.kind {
        case .hidden:
            return CGSize(width: 360, height: 0)
        case .loading:
            let metadataExpansion: CGFloat = state.metadata == nil ? 0 : 40
            let bodyExpansion: CGFloat = state.body.isEmpty ? 0 : 44
            return CGSize(
                width: 360,
                height: (76 + metadataExpansion + bodyExpansion) * scale
            )
        case .notice, .error:
            let extra = state.cta == nil ? 0 : 28
            let baseline = min(152, max(104, 116 + extra))
            return CGSize(width: 360, height: CGFloat(baseline) * scale)
        case .success:
            let textHeight = attributedBody(state).boundingRect(
                with: CGSize(width: 296, height: CGFloat.greatestFiniteMagnitude),
                options: [.usesLineFragmentOrigin, .usesFontLeading]
            ).height
            let estimated = 28 + 17 + footerHeight(for: state)
                + max(28 * scale, ceil(textHeight) + 4)
            return CGSize(
                width: 360,
                height: min(320 * scale, max(104 * scale, estimated))
            )
        }
    }

    func maximumSuccessSize() -> CGSize {
        CGSize(width: 360, height: 320 * accessibilityFontScale)
    }

    func setKeyboardFocusEnabled(
        _ enabled: Bool,
        currentFirstResponder: NSResponder? = nil
    ) -> NSView? {
        let controls = NativeTranslationOverlayFocusTopologyPolicy.orderedControls(
            hasCTA: !ctaButton.isHidden,
            canCopy: !copyButton.isHidden
        )
        let viewForControl: [NativeTranslationOverlayFocusableControl: NativeTranslationOverlayButton] = [
            .cta: ctaButton,
            .copy: copyButton,
            .close: closeButton,
        ]
        for button in [ctaButton, copyButton, closeButton] {
            button.keyboardFocusEnabled = enabled && !button.isHidden
            button.nextKeyView = nil
        }
        guard enabled else { return nil }
        let ordered = controls.compactMap { viewForControl[$0] }
        guard !ordered.isEmpty else { return nil }
        for (index, button) in ordered.enumerated() {
            button.nextKeyView = ordered[(index + 1) % ordered.count]
        }
        let currentControl = controls.first { control in
            guard let view = viewForControl[control] else { return false }
            return currentFirstResponder === view
        }
        switch NativeTranslationOverlayFocusTopologyPolicy.decision(
            current: currentControl,
            orderedControls: controls
        ) {
        case .preserveCurrent, .noTarget:
            return nil
        case let .moveTo(control):
            return viewForControl[control]
        }
    }

    func setStatefulActionsEnabled(_ enabled: Bool) {
        ctaButton.isEnabled = enabled && !ctaButton.isHidden
        copyButton.isEnabled = enabled && !copyButton.isHidden
    }

    func scrollBody(_ command: NativeTranslationOverlayScrollCommand) {
        guard !bodyScrollView.isHidden else { return }
        switch command {
        case .pageUp: bodyScrollView.scrollPageUp(nil)
        case .pageDown: bodyScrollView.scrollPageDown(nil)
        case .beginning: bodyScrollView.scrollToBeginningOfDocument(nil)
        case .end: bodyScrollView.scrollToEndOfDocument(nil)
        case .lineUp: bodyScrollView.scrollLineUp(nil)
        case .lineDown: bodyScrollView.scrollLineDown(nil)
        }
    }

    func applyAccessibilityAppearance() {
        guard separatorHeightConstraint != nil else { return }
        let workspace = NSWorkspace.shared
        separatorHeightConstraint.constant = workspace.accessibilityDisplayShouldIncreaseContrast
            ? 2
            : 1
        layer?.borderWidth = workspace.accessibilityDisplayShouldIncreaseContrast ? 2 : 1
        layer?.borderColor = NSColor.separatorColor.cgColor
        truncationBadgeView.layer?.borderWidth = workspace.accessibilityDisplayShouldIncreaseContrast
            ? 1
            : 0
        truncationBadgeView.layer?.borderColor = NSColor.systemOrange.cgColor
        truncationBadgeView.layer?.backgroundColor = NSColor.systemOrange
            .withAlphaComponent(workspace.accessibilityDisplayShouldIncreaseContrast ? 0.20 : 0.12)
            .cgColor
        if workspace.accessibilityDisplayShouldReduceTransparency {
            blendingMode = .withinWindow
            layer?.backgroundColor = NSColor.windowBackgroundColor.cgColor
        } else {
            blendingMode = .behindWindow
            layer?.backgroundColor = NSColor.clear.cgColor
        }
    }

    private func configureView() {
        material = .popover
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 14
        layer?.cornerCurve = .continuous
        layer?.masksToBounds = true
        setAccessibilityElement(true)
        setAccessibilityRole(.group)

        iconView.translatesAutoresizingMaskIntoConstraints = false
        iconView.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: 13, weight: .semibold)
        iconView.setAccessibilityElement(false)

        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isIndeterminate = true
        loadingIndicator.isDisplayedWhenStopped = false
        loadingIndicator.translatesAutoresizingMaskIntoConstraints = false
        loadingIndicator.setAccessibilityElement(false)
        loadingIndicator.isHidden = true

        titleField.font = scaledSystemFont(ofSize: 13, weight: .semibold)
        titleField.textColor = .labelColor
        titleField.maximumNumberOfLines = 2

        configureButton(closeButton, title: "关闭", imageName: "xmark")
        closeButton.bezelStyle = .inline
        closeButton.target = self
        closeButton.action = #selector(closePressed)

        configureButton(copyButton, title: "复制")
        copyButton.target = self
        copyButton.action = #selector(copyPressed)

        configureButton(ctaButton, title: "")
        ctaButton.target = self
        ctaButton.action = #selector(ctaPressed)

        let header = headerStack
        header.setViews([loadingIndicator, iconView, titleField, NSView(), closeButton], in: .leading)
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 8
        header.translatesAutoresizingMaskIntoConstraints = false
        header.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        iconView.widthAnchor.constraint(equalToConstant: 18).isActive = true
        iconView.heightAnchor.constraint(equalToConstant: 18).isActive = true
        loadingIndicator.widthAnchor.constraint(equalToConstant: 18).isActive = true
        loadingIndicator.heightAnchor.constraint(equalToConstant: 18).isActive = true

        bodyField.isEditable = false
        bodyField.isSelectable = false
        bodyField.drawsBackground = false
        bodyField.isBezeled = false
        bodyField.maximumNumberOfLines = 0
        bodyField.lineBreakMode = .byWordWrapping
        bodyField.translatesAutoresizingMaskIntoConstraints = false
        bodyScrollView.drawsBackground = false
        bodyScrollView.hasVerticalScroller = true
        bodyScrollView.hasHorizontalScroller = false
        bodyScrollView.autohidesScrollers = true
        bodyScrollView.borderType = .noBorder
        bodyScrollView.translatesAutoresizingMaskIntoConstraints = false
        bodyScrollView.documentView = bodyField
        NSLayoutConstraint.activate([
            bodyField.leadingAnchor.constraint(equalTo: bodyScrollView.contentView.leadingAnchor),
            bodyField.trailingAnchor.constraint(equalTo: bodyScrollView.contentView.trailingAnchor),
            bodyField.topAnchor.constraint(equalTo: bodyScrollView.contentView.topAnchor),
            bodyField.widthAnchor.constraint(equalTo: bodyScrollView.contentView.widthAnchor),
        ])
        bodyHeightConstraint = bodyScrollView.heightAnchor.constraint(equalToConstant: 40)
        bodyHeightConstraint.isActive = true
        bodyStack.setViews([bodyScrollView], in: .leading)
        bodyStack.orientation = .horizontal
        bodyStack.alignment = .top
        bodyStack.spacing = 8
        bodyStack.translatesAutoresizingMaskIntoConstraints = false
        bodyScrollView.setContentHuggingPriority(.defaultLow, for: .horizontal)
        closeButton.setContentHuggingPriority(.required, for: .horizontal)
        closeButton.setContentCompressionResistancePriority(.required, for: .horizontal)

        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        separatorHeightConstraint = separator.heightAnchor.constraint(equalToConstant: 1)
        separatorHeightConstraint.isActive = true

        configureMetadata(metadataField)
        configureMetadata(fallbackField)
        configureMetadata(truncationField)
        // Orange is a non-text accent only; semantic label color preserves
        // readable contrast in both appearances and high-contrast mode.
        truncationField.textColor = .labelColor
        truncationField.setAccessibilityElement(false)
        truncationIcon.image = NSImage(
            systemSymbolName: "exclamationmark.triangle.fill",
            accessibilityDescription: nil
        )
        truncationIcon.symbolConfiguration = NSImage.SymbolConfiguration(
            pointSize: 10,
            weight: .semibold
        )
        truncationIcon.contentTintColor = .systemOrange
        truncationIcon.setAccessibilityElement(false)
        truncationIcon.translatesAutoresizingMaskIntoConstraints = false
        truncationIcon.widthAnchor.constraint(equalToConstant: 12).isActive = true
        truncationIcon.heightAnchor.constraint(equalToConstant: 12).isActive = true
        truncationBadgeView.setViews([truncationIcon, truncationField], in: .leading)
        truncationBadgeView.orientation = .horizontal
        truncationBadgeView.alignment = .centerY
        truncationBadgeView.spacing = 4
        truncationBadgeView.edgeInsets = NSEdgeInsets(top: 2, left: 7, bottom: 2, right: 7)
        truncationBadgeView.wantsLayer = true
        truncationBadgeView.layer?.cornerRadius = 9
        truncationBadgeView.layer?.cornerCurve = .continuous
        truncationBadgeView.setAccessibilityElement(true)
        truncationBadgeView.setAccessibilityRole(.staticText)
        metadataStack.setViews(
            [metadataField, fallbackField, truncationBadgeView],
            in: .leading
        )
        metadataStack.orientation = .vertical
        metadataStack.alignment = .leading
        metadataStack.spacing = 3

        actionsStack.setViews([ctaButton, copyButton], in: .leading)
        actionsStack.orientation = .horizontal
        actionsStack.alignment = .centerY
        actionsStack.spacing = 8
        actionsStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true

        footerStack.setViews([metadataStack, NSView(), actionsStack], in: .leading)
        footerStack.orientation = .horizontal
        footerStack.alignment = .centerY
        footerStack.spacing = 8
        footerStack.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true

        let root = NSStackView(views: [header, bodyStack, separator, footerStack])
        root.orientation = .vertical
        root.alignment = .leading
        root.spacing = 8
        root.translatesAutoresizingMaskIntoConstraints = false
        addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 14),
            root.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -14),
            root.topAnchor.constraint(equalTo: topAnchor, constant: 14),
            root.bottomAnchor.constraint(lessThanOrEqualTo: bottomAnchor, constant: -14),
            header.widthAnchor.constraint(equalTo: root.widthAnchor),
            bodyStack.widthAnchor.constraint(equalTo: root.widthAnchor),
            separator.widthAnchor.constraint(equalTo: root.widthAnchor),
            footerStack.widthAnchor.constraint(equalTo: root.widthAnchor),
        ])
        applyAccessibilityAppearance()
    }

    private func attributedBody(
        _ state: NativeTranslationOverlayState
    ) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = state.kind == .success ? 6 : 3
        let font = scaledSystemFont(
            ofSize: state.kind == .success ? 15 : 13,
            weight: .regular
        )
        return NSAttributedString(
            string: state.body,
            attributes: [
                .font: font,
                .foregroundColor: NSColor.labelColor,
                .paragraphStyle: paragraph,
            ]
        )
    }

    private func bodyViewportHeight(
        for state: NativeTranslationOverlayState,
        availablePanelHeight: CGFloat?
    ) -> CGFloat {
        let desired = desiredSize(for: state).height
        guard !state.body.isEmpty else { return 0 }
        let hasFooter = state.metadata != nil
            || state.fallbackNotice != nil
            || state.truncationBadge != nil
            || state.cta != nil
            || state.canCopy
        // 28pt outer insets + 28pt header + 8pt group gaps. A visible
        // footer also contributes separator, two further gaps and its height.
        let scale = accessibilityFontScale
        let headerHeight: CGFloat = state.kind == .success ? 0 : 28 * scale + 8
        let fixedHeight: CGFloat = 28 + headerHeight
            + (hasFooter ? 17 + footerHeight(for: state) : 0)
        let minimumBody: CGFloat = (state.kind == .success ? 23 : 12) * scale
        let baseline = max(minimumBody, desired - fixedHeight)
        guard let availablePanelHeight, availablePanelHeight.isFinite else {
            return baseline
        }
        let constrainedByPanel = baseline - max(0, desired - availablePanelHeight)
        return max(minimumBody, constrainedByPanel)
    }

    private func footerHeight(for state: NativeTranslationOverlayState) -> CGFloat {
        let simpleRows = [state.metadata, state.fallbackNotice].compactMap { $0 }.count
        let hasTruncationBadge = state.truncationBadge != nil
        let metadataRows = simpleRows + (hasTruncationBadge ? 1 : 0)
        let scale = accessibilityFontScale
        let metadataHeight = metadataRows == 0
            ? 0
            : (CGFloat(simpleRows * 14) * scale)
                + (hasTruncationBadge ? 20 * scale : 0)
                + CGFloat((metadataRows - 1) * 3)
        let hasAction = state.cta != nil || state.canCopy
        return max(metadataHeight, hasAction ? 28 * scale : 0)
    }

    private func configureButton(
        _ button: NativeTranslationOverlayButton,
        title: String,
        imageName: String? = nil
    ) {
        button.title = title
        button.font = scaledSystemFont(ofSize: 12, weight: .medium)
        button.controlSize = .small
        button.bezelStyle = .rounded
        button.refusesFirstResponder = true
        button.translatesAutoresizingMaskIntoConstraints = false
        button.heightAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        button.widthAnchor.constraint(greaterThanOrEqualToConstant: 28).isActive = true
        if let imageName {
            button.image = NSImage(systemSymbolName: imageName, accessibilityDescription: nil)
            button.imagePosition = .imageOnly
        }
    }

    private func configureMetadata(_ field: NSTextField) {
        field.font = scaledSystemFont(ofSize: 11, weight: .regular)
        field.textColor = .secondaryLabelColor
        field.maximumNumberOfLines = 2
        field.lineBreakMode = .byWordWrapping
    }

    private func icon(
        for kind: NativeTranslationOverlayState.Kind
    ) -> NSImage? {
        let name: String
        switch kind {
        case .hidden: name = "character.bubble"
        case .loading: name = "ellipsis.bubble"
        case .notice: name = "info.circle"
        case .error: name = "exclamationmark.triangle"
        case .success: name = "character.bubble.fill"
        }
        return NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    private func tint(
        for kind: NativeTranslationOverlayState.Kind
    ) -> NSColor {
        switch kind {
        case .error: return .systemOrange
        case .notice: return .secondaryLabelColor
        default: return .controlAccentColor
        }
    }

    private var accessibilityFontScale: CGFloat {
        let preferred = NSFont.preferredFont(forTextStyle: .body, options: [:])
        return min(2.5, max(1, preferred.pointSize / 13))
    }

    private func scaledSystemFont(
        ofSize size: CGFloat,
        weight: NSFont.Weight
    ) -> NSFont {
        .systemFont(ofSize: size * accessibilityFontScale, weight: weight)
    }

    private func updateAccessibilityOrder(
        _ state: NativeTranslationOverlayState
    ) {
        var children: [Any] = headerStack.isHidden ? [] : [titleField]
        if !bodyScrollView.isHidden { children.append(bodyField) }
        if !metadataField.isHidden { children.append(metadataField) }
        if !fallbackField.isHidden { children.append(fallbackField) }
        if !truncationBadgeView.isHidden { children.append(truncationBadgeView) }
        if !ctaButton.isHidden { children.append(ctaButton) }
        if !copyButton.isHidden { children.append(copyButton) }
        children.append(closeButton)
        setAccessibilityChildren(children)
    }

    @objc private func closePressed() { closeHandler?() }
    @objc private func copyPressed() { copyHandler?() }
    @objc private func ctaPressed() { ctaHandler?() }
}

private struct NativeTranslationOverlayPasteboardWriter {
    func write(_ fullTranslation: String) -> Bool {
        NativeTranslationOverlayPasteboardReplacePolicy.replace(
            text: fullTranslation,
            makeItem: { text in
                let item = NSPasteboardItem()
                guard item.setString(text, forType: .string) else { return nil }
                return item
            },
            clearExistingContents: {
                _ = NSPasteboard.general.clearContents()
            },
            writeSingleItem: { item in
                NSPasteboard.general.writeObjects([item])
            }
        )
    }
}

private typealias NativeTranslationOverlayPendingLifecycle =
    NativeTranslationOverlayPendingPresentationLifecycle<
        NativeTranslationOverlayState,
        NativeTranslationOverlayCopyPresentation
    >
private typealias NativeTranslationOverlayPendingPresentation =
    NativeTranslationOverlayPendingLifecycle.Entry

@MainActor
final class NativeTranslationOverlayController: NSObject {
    static let shared = NativeTranslationOverlayController()

    private let panel: NativeTranslationOverlayPanel
    private let overlayView: NativeTranslationOverlayContentView
    private let clock = NativeTranslationOverlayClock.main
    private let pasteboardWriter = NativeTranslationOverlayPasteboardWriter()
    private lazy var session = NativeTranslationOverlaySession(clock: clock) {
        [weak self] generation, state in
        MainActor.assumeIsolated {
            self?.apply(state: state, generation: generation)
        }
    }
    private lazy var monitorOwner = NativeTranslationOverlayScopedMonitorOwner(
        installGlobal: { [weak self] in self?.installGlobalMonitor() },
        installLocal: { [weak self] in self?.installLocalMonitor() },
        remove: { NSEvent.removeMonitor($0) }
    )

    private var observerTokens: [(NotificationCenter, NSObjectProtocol)] = []
    private var currentState: NativeTranslationOverlayState = .hidden
    private var currentGeneration = 0
    private var anchorMousePoint = CGPoint.zero
    private var anchorVisibleFrame: CGRect?
    private var anchorDirection: NativeTranslationOverlayAnchorDirection?
    private var anchorDisplayIdentifier: CGDirectDisplayID?
    private var sourceApplication: NSRunningApplication?
    private var keyboardMode = false
    private var isPaused = false
    private var copyPresentation: NativeTranslationOverlayCopyPresentation = .idle
    private var pendingPresentationLifecycle = NativeTranslationOverlayPendingLifecycle()
    private var fixtureCopyPresentationLifecycle =
        NativeTranslationOverlayFixtureCopyPresentationLifecycle()
    private var copyResetTask: NativeTranslationOverlayScheduledTask?
    private var announcedTerminalGeneration: Int?
    private var presentationLifecycle = NativeTranslationOverlayPresentationLifecycle()
    private var contentTransitionLifecycle = NativeTranslationOverlayContentTransitionLifecycle()
    private(set) var layoutRevision = 0
    private var navigationHandler: ((NativeTranslationOverlayCTA) -> Void)?
    private var pendingDismissReason: NativeTranslationOverlayDismissReason?
    private var preservesVisibleContentForNextSessionBegin = false
    #if DEBUG && JUYI_NATIVE_TRANSLATION_OVERLAY && !JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
    private var nextFixtureIndex = 0
    #endif
    private var nativeDismissHandler: ((NativeTranslationOverlayDismissReason) -> Void)?
    #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB
    private let externalPresentationRegistry =
        NativeTranslationOverlayExternalPresentationRegistry()
    private var resultLabIdentity: NativeTranslationOverlayExternalIdentity?
    #if JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
    private var realAppleResultLabLease: NativeTranslationOverlayExternalPresentationLease?
    private var realAppleLoadingAnnouncementLifecycle =
        NativeTranslationAppleResultLabLoadingAnnouncementLifecycle()
    #endif
    private var isResultLabPresentation: Bool { resultLabIdentity != nil }
    private var resultLabEngine: NativeTranslationEngine? {
        resultLabIdentity?.engine
    }
    #endif

    private override init() {
        overlayView = NativeTranslationOverlayContentView(
            frame: CGRect(x: 0, y: 0, width: 360, height: 132)
        )
        panel = NativeTranslationOverlayPanel(
            contentRect: overlayView.frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        super.init()
        configurePanel()
        configureActions()
        installLifecycleObservers()
    }

    func configureNavigation(
        _ handler: @escaping (NativeTranslationOverlayCTA) -> Void
    ) {
        navigationHandler = handler
    }

    #if DEBUG && JUYI_NATIVE_TRANSLATION_OVERLAY && !JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
    var nextFixturePreviewTitle: String {
        let fixtures = NativeTranslationOverlayFixture.allCases
        let fixture = fixtures[nextFixtureIndex % fixtures.count]
        return "开发：预览下一状态：\(fixture.displayName)"
    }

    /// The only preview entry. Repeated explicit invocations cycle a fixed,
    /// non-sensitive fixture matrix; no content comes from selection or I/O.
    func showFixturePreview() {
        guard !isPaused else { return }
        let fixtures = NativeTranslationOverlayFixture.allCases
        let fixture = fixtures[nextFixtureIndex % fixtures.count]
        sourceApplication = externalFrontmostApplication()
        anchorMousePoint = NSEvent.mouseLocation
        guard prepareAnchor() else { return }
        nextFixtureIndex = (nextFixtureIndex + 1) % fixtures.count
        fixtureCopyPresentationLifecycle.queue(fixture.initialCopyPresentation)
        pendingPresentationLifecycle.cancel()
        preservesVisibleContentForNextSessionBegin =
            NativeTranslationOverlayVisibleReplacementPolicy.preservesCurrentContent(
                panelIsVisible: panel.isVisible,
                presentationPhase: presentationLifecycle.phase
            )
        #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB
        let replacedExternalPresentation = externalPresentationRegistry.currentLease
        #if JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
        if realAppleResultLabLease == replacedExternalPresentation {
            realAppleResultLabLease = nil
        }
        #endif
        resultLabIdentity = nil
        overlayView.setResultLabPresentation(nil)
        resetPanelAccessibilityIdentity()
        #endif
        let generation = session.begin()
        if let event = fixture.event { session.resolve(event, for: generation) }
        #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB
        if let replacedExternalPresentation {
            // The legacy session is fully installed before notifying the old
            // external owner. A callback that starts a new external session
            // therefore wins and cannot be overwritten by this call.
            _ = externalPresentationRegistry.invalidate(
                replacedExternalPresentation,
                reason: .stop
            )
        }
        #endif
    }
    #endif

    /// Starts the real user translation presentation. The caller owns AX,
    /// Apple Translation and cancellation; this controller owns only the one
    /// passive panel session and reports every user/lifecycle dismissal.
    @discardableResult
    func beginNativeTranslation(
        sourceApplication: NSRunningApplication?,
        anchorPoint: CGPoint?,
        onDismiss: @escaping (NativeTranslationOverlayDismissReason) -> Void
    ) -> Int? {
        guard !isPaused else { return nil }
        if nativeDismissHandler != nil { dismiss(.stop) }
        self.sourceApplication = sourceApplication
        anchorMousePoint = anchorPoint ?? NSEvent.mouseLocation
        guard prepareAnchor() else { return nil }
        fixtureCopyPresentationLifecycle.queue(.idle)
        pendingPresentationLifecycle.cancel()
        preservesVisibleContentForNextSessionBegin =
            NativeTranslationOverlayVisibleReplacementPolicy.preservesCurrentContent(
                panelIsVisible: panel.isVisible,
                presentationPhase: presentationLifecycle.phase
            )
        nativeDismissHandler = onDismiss
        return session.begin()
    }

    func resolveNativeTranslation(
        _ event: NativeTranslationOverlayEvent,
        generation: Int
    ) {
        session.resolve(event, for: generation)
    }

    func cancelNativeTranslation(
        generation: Int,
        reason: NativeTranslationOverlayDismissReason
    ) {
        guard session.generation == generation else { return }
        dismiss(reason)
    }

    #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB
    #if !JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
    /// Creates the only panel session that an external Result Lab request may
    /// resolve. It is called before simulated domain work begins.
    func beginExternal(
        requestedEngine: NativeTranslationEngine,
        onDismiss: @escaping (NativeTranslationOverlayDismissReason) -> Void
    ) -> NativeTranslationOverlayExternalPresentationLease? {
        guard !isPaused else { return nil }
        sourceApplication = externalFrontmostApplication()
        anchorMousePoint = NSEvent.mouseLocation
        guard prepareAnchor() else { return nil }
        fixtureCopyPresentationLifecycle.queue(.idle)
        pendingPresentationLifecycle.cancel()
        preservesVisibleContentForNextSessionBegin =
            NativeTranslationOverlayVisibleReplacementPolicy.preservesCurrentContent(
                panelIsVisible: panel.isVisible,
                presentationPhase: presentationLifecycle.phase
            )
        let identity = NativeTranslationOverlayExternalIdentity.simulated(requestedEngine)
        resultLabIdentity = identity
        overlayView.setResultLabPresentation(identity)
        let engineLabel = requestedEngine == .apple ? "Apple" : "火山"
        panel.title = "句译 Debug 固定样例 \(engineLabel) 模拟结果"
        panel.setAccessibilityTitle("句译 Debug 固定样例 \(engineLabel) 模拟结果")
        let generation = session.beginResultLabPresentation(
            engine: requestedEngine,
            loading: .loading(engine: requestedEngine, isExtended: false),
            extendedLoading: .loading(engine: requestedEngine, isExtended: true)
        )
        let lease = externalPresentationRegistry.begin(
            sessionGeneration: generation,
            onDismiss: onDismiss
        )
        guard session.generation == generation,
              externalPresentationRegistry.isCurrent(
            lease,
            sessionGeneration: generation
        ) else {
            _ = externalPresentationRegistry.invalidate(lease, reason: .stop)
            return nil
        }
        return lease
    }

    @discardableResult
    func resolve(
        presentation: NativeTranslationResultLabValidatedPresentation,
        lease: NativeTranslationOverlayExternalPresentationLease
    ) -> Bool {
        guard presentation.overlayState.isTerminal,
              externalPresentationRegistry.acceptTerminal(
                  lease,
                  sessionGeneration: session.generation
              ) else { return false }
        session.resolveResultLabPresentation(
            presentation,
            for: session.generation
        )
        return true
    }
    #endif

    #if JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
    /// Reserves an opaque owner capability without reading an anchor, creating
    /// a panel session, scheduling visual work or posting accessibility output.
    /// Fresh availability and exact host claim must both succeed before the
    /// same lease can be activated.
    func reserveRealAppleExternal(
        onDismiss: @escaping (NativeTranslationOverlayDismissReason) -> Void
    ) -> NativeTranslationOverlayExternalPresentationLease? {
        guard !isPaused,
              !externalPresentationRegistry.hasActiveLease,
              realAppleResultLabLease == nil else { return nil }
        let anticipatedGeneration = session.generation + 1
        let lease = externalPresentationRegistry.begin(
            sessionGeneration: anticipatedGeneration,
            onDismiss: onDismiss
        )
        guard externalPresentationRegistry.isCurrent(
            lease,
            sessionGeneration: anticipatedGeneration
        ) else {
            _ = externalPresentationRegistry.invalidate(lease, reason: .stop)
            return nil
        }
        realAppleResultLabLease = lease
        return lease
    }

    @discardableResult
    func activateRealAppleExternal(
        loading: NativeTranslationAppleResultLabValidatedPresentation,
        lease: NativeTranslationOverlayExternalPresentationLease
    ) -> Bool {
        let anticipatedGeneration = session.generation + 1
        guard !isPaused,
              loading.category == .loading,
              realAppleResultLabLease == lease,
              externalPresentationRegistry.matches(
                  lease,
                  sessionGeneration: anticipatedGeneration
              ) else { return false }
        sourceApplication = externalFrontmostApplication()
        anchorMousePoint = NSEvent.mouseLocation
        guard prepareAnchor() else {
            realAppleResultLabLease = nil
            _ = externalPresentationRegistry.invalidate(lease, reason: .displayRemoved)
            return false
        }
        fixtureCopyPresentationLifecycle.queue(.idle)
        pendingPresentationLifecycle.cancel()
        preservesVisibleContentForNextSessionBegin =
            NativeTranslationOverlayVisibleReplacementPolicy.preservesCurrentContent(
                panelIsVisible: panel.isVisible,
                presentationPhase: presentationLifecycle.phase
            )
        resultLabIdentity = .realAppleFixed
        overlayView.setResultLabPresentation(.realAppleFixed)
        panel.title = "句译 Debug 固定样例 Apple Translation 真实结果"
        panel.setAccessibilityTitle("句译 Debug 固定样例 Apple Translation 真实结果")
        let generation = session.beginAppleResultLabPresentation(loading: loading)
        guard generation == anticipatedGeneration,
              externalPresentationRegistry.matches(
                  lease,
                  sessionGeneration: generation
              ) else {
            session.invalidate()
            resultLabIdentity = nil
            overlayView.setResultLabPresentation(nil)
            resetPanelAccessibilityIdentity()
            realAppleResultLabLease = nil
            _ = externalPresentationRegistry.invalidate(lease, reason: .stop)
            return false
        }
        announceRealAppleLoading(
            stage: .initial,
            generation: generation,
            lease: lease
        )
        return true
    }

    @discardableResult
    func updateRealAppleLoading(
        _ loading: NativeTranslationAppleResultLabValidatedPresentation,
        lease: NativeTranslationOverlayExternalPresentationLease
    ) -> Bool {
        guard loading.category == .loading,
              resultLabIdentity == .realAppleFixed,
              realAppleResultLabLease == lease,
              externalPresentationRegistry.isCurrent(
                  lease,
                  sessionGeneration: session.generation
              ) else { return false }
        let generation = session.generation
        session.updateAppleResultLabLoading(loading, for: generation)
        let isCurrent = externalPresentationRegistry.isCurrent(
            lease,
            sessionGeneration: generation
        )
        if isCurrent, loading == .loading(isExtended: true) {
            announceRealAppleLoading(
                stage: .extended,
                generation: generation,
                lease: lease
            )
        }
        return isCurrent
    }

    @discardableResult
    func resolveRealAppleExternal(
        presentation: NativeTranslationAppleResultLabValidatedPresentation,
        lease: NativeTranslationOverlayExternalPresentationLease
    ) -> Bool {
        guard presentation.overlayState.isTerminal,
              resultLabIdentity == .realAppleFixed,
              realAppleResultLabLease == lease,
              externalPresentationRegistry.acceptTerminal(
                  lease,
                  sessionGeneration: session.generation
              ) else { return false }
        session.resolveAppleResultLabPresentation(
            presentation,
            for: session.generation
        )
        return externalPresentationRegistry.matches(
            lease,
            sessionGeneration: session.generation
        )
    }

    private func announceRealAppleLoading(
        stage: NativeTranslationAppleResultLabLoadingAnnouncementStage,
        generation: Int,
        lease: NativeTranslationOverlayExternalPresentationLease
    ) {
        let isCurrent = resultLabIdentity == .realAppleFixed
            && realAppleResultLabLease == lease
            && externalPresentationRegistry.isCurrent(
                lease,
                sessionGeneration: generation
            )
        guard let announcement = realAppleLoadingAnnouncementLifecycle.consume(
            stage: stage,
            generation: generation,
            isCurrent: isCurrent
        ) else { return }
        postAnnouncement(announcement)
    }
    #endif

    func invalidate(
        lease: NativeTranslationOverlayExternalPresentationLease,
        reason: NativeTranslationOverlayDismissReason
    ) {
        #if JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
        if realAppleResultLabLease == lease,
           resultLabIdentity == nil {
            realAppleResultLabLease = nil
            _ = externalPresentationRegistry.invalidate(lease, reason: reason)
            return
        }
        #endif
        guard externalPresentationRegistry.matches(
            lease,
            sessionGeneration: session.generation
        ) else { return }
        pendingDismissReason = reason
        session.invalidate()
        pendingDismissReason = nil
        resultLabIdentity = nil
        #if JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
        realAppleResultLabLease = nil
        #endif
        overlayView.setResultLabPresentation(nil)
        resetPanelAccessibilityIdentity()
        _ = externalPresentationRegistry.invalidate(lease, reason: reason)
    }
    #endif

    func focusCurrentOverlay() {
        guard panel.isVisible else { return }
        enterKeyboardMode()
    }

    #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB
    @discardableResult
    func focusCurrentOverlay(
        lease: NativeTranslationOverlayExternalPresentationLease
    ) -> Bool {
        guard isResultLabPresentation,
              panel.isVisible,
              externalPresentationRegistry.matches(
                  lease,
                  sessionGeneration: session.generation
              ) else { return false }
        enterKeyboardMode()
        return true
    }
    #endif

    func setPaused(_ paused: Bool) {
        guard isPaused != paused else { return }
        isPaused = paused
        if paused { dismiss(.pause) }
    }

    func stop() { dismiss(.stop) }
    func accessibilityWasRevoked() { dismiss(.revoke) }
    func close() { dismiss(.close) }

    func shutdown() {
        dismiss(.terminate)
        for (center, token) in observerTokens { center.removeObserver(token) }
        observerTokens.removeAll()
    }

    private func configurePanel() {
        panel.contentView = overlayView
        #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
        panel.identifier = NSUserInterfaceItemIdentifier(
            nativeTranslationAppleResultLabBindingBuildSentinel
        )
        #elseif DEBUG && JUYI_NATIVE_TRANSLATION_OVERLAY
        panel.identifier = NSUserInterfaceItemIdentifier(
            NativeTranslationOverlayFixture.buildSentinel
        )
        #else
        panel.identifier = NSUserInterfaceItemIdentifier(
            "io.github.Eim-aa.Juyi.native-translation-overlay"
        )
        #endif
        panel.title = "句译译文"
        panel.titleVisibility = .hidden
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.transient, .ignoresCycle, .fullScreenAuxiliary]
        panel.setAccessibilityTitle("句译译文")
        panel.setAccessibilityRole(.window)
        panel.setAccessibilitySubrole(.floatingWindow)
    }

    private func configureActions() {
        overlayView.closeHandler = { [weak self] in self?.dismiss(.close) }
        overlayView.copyHandler = { [weak self] in self?.copyCurrentTranslation() }
        overlayView.ctaHandler = { [weak self] in self?.performCurrentCTA() }
        panel.scrollKeyHandler = { [weak self] keyCode, flags in
            self?.handlePanelScrollKey(keyCode: keyCode, flags: flags) ?? false
        }
    }

    private func installLifecycleObservers() {
        observe(
            center: .default,
            name: NSApplication.didChangeScreenParametersNotification
        ) { [weak self] in self?.screenConfigurationChanged() }
        let workspaceCenter = NSWorkspace.shared.notificationCenter
        observe(center: workspaceCenter, name: NSWorkspace.activeSpaceDidChangeNotification) {
            [weak self] in self?.dismiss(.space)
        }
        observe(center: workspaceCenter, name: NSWorkspace.sessionDidResignActiveNotification) {
            [weak self] in self?.dismiss(.session)
        }
        observe(center: workspaceCenter, name: NSWorkspace.willSleepNotification) {
            [weak self] in self?.dismiss(.sleep)
        }
        observe(
            center: workspaceCenter,
            name: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification
        ) { [weak self] in
            self?.overlayView.applyAccessibilityAppearance()
            self?.relayoutForCurrentScreen()
        }
    }

    private func observe(
        center: NotificationCenter,
        name: Notification.Name,
        action: @escaping @MainActor () -> Void
    ) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { action() }
        }
        observerTokens.append((center, token))
    }

    private func apply(
        state: NativeTranslationOverlayState,
        generation: Int
    ) {
        copyResetTask?.cancel()
        copyResetTask = nil
        if !state.isVisible,
           preservesVisibleContentForNextSessionBegin,
           NativeTranslationOverlayVisibleReplacementPolicy.preservesCurrentContent(
               panelIsVisible: panel.isVisible,
               presentationPhase: presentationLifecycle.phase
           ) {
            preservesVisibleContentForNextSessionBegin = false
            pendingPresentationLifecycle.cancel()
            contentTransitionLifecycle.invalidate()
            overlayView.layer?.removeAllAnimations()
            overlayView.alphaValue = 1
            overlayView.setStatefulActionsEnabled(false)
            return
        }
        preservesVisibleContentForNextSessionBegin = false
        if !state.isVisible {
            pendingPresentationLifecycle.cancel()
            commitDisplayedState(
                state: state,
                generation: generation,
                copyPresentation: .idle
            )
            hidePanel(reason: pendingDismissReason)
            return
        }
        let targetCopyPresentation =
            fixtureCopyPresentationLifecycle.consumeForVisibleState()
        renderVisibleState(
            state: state,
            generation: generation,
            targetCopyPresentation: targetCopyPresentation,
            announceTerminal: true,
            animateLayout: true
        )
    }

    private func renderVisibleState(
        state: NativeTranslationOverlayState,
        generation: Int,
        targetCopyPresentation: NativeTranslationOverlayCopyPresentation,
        announceTerminal: Bool,
        animateLayout: Bool
    ) {
        guard state.isVisible,
              let placement = placement(for: state) else {
            dismiss(.displayRemoved)
            return
        }
        // NSWindow remains isVisible while an order-out animation is pending.
        // Treat that phase as not presented so a newer generation restarts the
        // scoped monitors and revokes the old hide completion.
        let wasVisible = panel.isVisible && presentationLifecycle.phase == .visible
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        if wasVisible, !reduceMotion, animateLayout {
            pendingPresentationLifecycle.stage(
                state: state,
                generation: generation,
                copyPresentation: targetCopyPresentation
            )
            overlayView.setStatefulActionsEnabled(false)
            crossfadeAndResize(
                to: placement.frame,
                announceTerminal: announceTerminal,
                generation: generation
            )
            return
        } else {
            contentTransitionLifecycle.invalidate()
            pendingPresentationLifecycle.cancel()
            commitDisplayedState(
                state: state,
                generation: generation,
                copyPresentation: targetCopyPresentation
            )
            overlayView.render(
                currentState,
                copyPresentation: copyPresentation,
                availablePanelHeight: placement.frame.height,
                statefulActionsEnabled: statefulActionBindingIsCurrent
            )
            refreshKeyboardFocusTopologyAfterRender()
            layoutRevision += 1
            panel.setFrame(placement.frame, display: true)
            overlayView.alphaValue = 1
        }
        if !wasVisible {
            showPanelPassively()
        }
        announceTerminalIfEligible(
            requested: announceTerminal,
            expectedGeneration: generation
        )
    }

    private func commitDisplayedState(
        state: NativeTranslationOverlayState,
        generation: Int,
        copyPresentation: NativeTranslationOverlayCopyPresentation
    ) {
        currentState = state
        currentGeneration = generation
        self.copyPresentation = copyPresentation
        if pendingPresentationLifecycle.validEntry(for: generation) != nil {
            pendingPresentationLifecycle.cancel()
        }
    }

    private var statefulActionBindingIsCurrent: Bool {
        NativeTranslationOverlayStatefulActionPolicy.bindingIsCurrent(
            displayedGeneration: currentGeneration,
            sessionGeneration: session.generation
        )
    }

    private var statefulActionsArePermitted: Bool {
        NativeTranslationOverlayStatefulActionPolicy.permitsAction(
            displayedGeneration: currentGeneration,
            sessionGeneration: session.generation,
            panelIsVisible: panel.isVisible
        )
    }

    private func announceTerminalIfEligible(
        requested: Bool,
        expectedGeneration: Int
    ) {
        guard requested,
           currentGeneration == expectedGeneration,
           NativeTranslationOverlayAnnouncementPolicy.shouldAnnounceTerminal(
               state: currentState,
               stateGeneration: currentGeneration,
               currentGeneration: session.generation,
               panelIsVisible: panel.isVisible,
               announcedGeneration: announcedTerminalGeneration
           ),
           let announcement = currentState.terminalAnnouncement else {
            return
        }
        announcedTerminalGeneration = currentGeneration
        postAnnouncement(announcement)
    }

    private func showPanelPassively() {
        let revision = presentationLifecycle.beginShow()
        monitorOwner.start()
        _ = overlayView.setKeyboardFocusEnabled(false)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.08 : 0.14
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = 1
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard self?.presentationLifecycle.acceptsVisibleCompletion(revision) == true else {
                    return
                }
            }
        }
    }

    private func crossfadeAndResize(
        to frame: CGRect,
        announceTerminal: Bool,
        generation: Int
    ) {
        layoutRevision += 1
        let revision = contentTransitionLifecycle.begin()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.10
            overlayView.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.session.generation == generation,
                      let pending = self.pendingPresentationLifecycle.validEntry(
                          for: generation
                      ),
                      self.contentTransitionLifecycle.beginSwap(revision) else { return }
                self.commitDisplayedState(
                    state: pending.state,
                    generation: pending.generation,
                    copyPresentation: pending.copyPresentation
                )
                self.overlayView.render(
                    self.currentState,
                    copyPresentation: self.copyPresentation,
                    availablePanelHeight: frame.height,
                    statefulActionsEnabled: self.statefulActionBindingIsCurrent
                )
                self.refreshKeyboardFocusTopologyAfterRender()
                guard self.contentTransitionLifecycle.beginFadeIn(revision) else { return }
                NSAnimationContext.runAnimationGroup { context in
                    context.duration = 0.14
                    self.panel.animator().setFrame(frame, display: true)
                    self.overlayView.animator().alphaValue = 1
                } completionHandler: { [weak self] in
                    MainActor.assumeIsolated {
                        guard let self,
                              self.session.generation == generation,
                              self.contentTransitionLifecycle.complete(revision) else { return }
                        self.announceTerminalIfEligible(
                            requested: announceTerminal,
                            expectedGeneration: generation
                        )
                    }
                }
            }
        }
    }

    private func hidePanel(reason: NativeTranslationOverlayDismissReason?) {
        let revision = presentationLifecycle.beginHide()
        layoutRevision += 1
        contentTransitionLifecycle.invalidate()
        pendingPresentationLifecycle.cancel()
        monitorOwner.stop()
        overlayView.setStatefulActionsEnabled(false)
        copyResetTask?.cancel()
        copyResetTask = nil
        copyPresentation = .idle
        announcedTerminalGeneration = nil
        #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
        realAppleLoadingAnnouncementLifecycle.invalidate()
        #endif
        let hadExplicitKeyboardFocus = keyboardMode
        let sourceToRestore = sourceApplication
        keyboardMode = false
        sourceApplication = nil
        _ = overlayView.setKeyboardFocusEnabled(false)
        guard panel.isVisible else {
            _ = presentationLifecycle.completeHide(revision)
            restoreSourceApplicationIfEligible(
                sourceToRestore,
                reason: reason,
                hadExplicitKeyboardFocus: hadExplicitKeyboardFocus
            )
            return
        }
        let duration = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion ? 0.08 : 0.10
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            panel.animator().alphaValue = 0
        } completionHandler: { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.presentationLifecycle.completeHide(revision) else { return }
                self.panel.orderOut(nil)
                self.panel.alphaValue = 1
                self.restoreSourceApplicationIfEligible(
                    sourceToRestore,
                    reason: reason,
                    hadExplicitKeyboardFocus: hadExplicitKeyboardFocus
                )
            }
        }
    }

    private func dismiss(_ reason: NativeTranslationOverlayDismissReason) {
        pendingDismissReason = reason
        defer { pendingDismissReason = nil }
        let nativeHandler = nativeDismissHandler
        nativeDismissHandler = nil
        defer { nativeHandler?(reason) }
        #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB
        let hadExternalPresentation = externalPresentationRegistry.hasActiveLease
        #endif
        guard currentState.isVisible || session.state.isVisible else {
            // Explicit lifecycle invalidations still advance generation.
            session.invalidate()
            #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB
            if hadExternalPresentation {
                resultLabIdentity = nil
                #if JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
                realAppleResultLabLease = nil
                #endif
                overlayView.setResultLabPresentation(nil)
                resetPanelAccessibilityIdentity()
                externalPresentationRegistry.invalidateActive(reason: reason)
            }
            #endif
            return
        }
        session.invalidate()
        #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB
        if hadExternalPresentation {
            resultLabIdentity = nil
            #if JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
            realAppleResultLabLease = nil
            #endif
            overlayView.setResultLabPresentation(nil)
            resetPanelAccessibilityIdentity()
            externalPresentationRegistry.invalidateActive(reason: reason)
        }
        #endif
    }

    private func enterKeyboardMode() {
        guard panel.isVisible, !keyboardMode else { return }
        if sourceApplication == nil { sourceApplication = externalFrontmostApplication() }
        keyboardMode = true
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
        if let first = overlayView.setKeyboardFocusEnabled(
            true,
            currentFirstResponder: panel.firstResponder
        ) {
            panel.makeFirstResponder(first)
        }
    }

    private func refreshKeyboardFocusTopologyAfterRender() {
        let replacement = overlayView.setKeyboardFocusEnabled(
            keyboardMode,
            currentFirstResponder: panel.firstResponder
        )
        if keyboardMode, let replacement {
            panel.makeFirstResponder(replacement)
        }
    }

    private func copyCurrentTranslation() {
        guard statefulActionsArePermitted else { return }
        let result = NativeTranslationOverlayCopyPolicy.copy(
            state: currentState,
            stateGeneration: currentGeneration,
            currentGeneration: session.generation,
            isVisible: panel.isVisible,
            writer: { [pasteboardWriter] in pasteboardWriter.write($0) }
        )
        copyResetTask?.cancel()
        copyResetTask = nil
        let shouldResetPresentation: Bool
        switch result {
        case .copied:
            copyPresentation = .copied
            #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB
            #if JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
            postAnnouncement(
                resultLabIdentity == .realAppleFixed
                    ? NativeTranslationAppleResultLabCopyAnnouncementPolicy.message(
                        for: .copied
                    )
                    : "句译，已复制译文"
            )
            #else
            postAnnouncement(
                isResultLabPresentation
                    ? "句译，已复制 Debug 固定样例 \(resultLabEngine == .volc ? "火山" : "Apple") 模拟译文"
                    : "句译，已复制译文"
            )
            #endif
            #else
            postAnnouncement("句译，已复制译文")
            #endif
            shouldResetPresentation = true
        case .failed:
            copyPresentation = .failed
            #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB && JUYI_NATIVE_APPLE_TRANSLATION_ADAPTER && JUYI_NATIVE_APPLE_RESULT_LAB_BINDING
            if resultLabIdentity == .realAppleFixed {
                postAnnouncement(
                    NativeTranslationAppleResultLabCopyAnnouncementPolicy.message(
                        for: .failed
                    )
                )
            }
            #endif
            shouldResetPresentation = false
        case .unavailable:
            return
        }
        overlayView.render(
            currentState,
            copyPresentation: copyPresentation,
            availablePanelHeight: panel.frame.height
        )
        guard shouldResetPresentation else { return }
        let generation = currentGeneration
        copyResetTask = clock.schedule(2.0) { [weak self] in
            MainActor.assumeIsolated {
                guard let self,
                      self.panel.isVisible,
                      self.currentGeneration == generation,
                      self.session.generation == generation else { return }
                self.copyPresentation = .idle
                self.overlayView.render(
                    self.currentState,
                    copyPresentation: .idle,
                    availablePanelHeight: self.panel.frame.height
                )
            }
        }
    }

    private func performCurrentCTA() {
        guard statefulActionsArePermitted,
              let cta = currentState.cta else { return }
        keyboardMode = false
        dismiss(.stop)
        NSApp.activate(ignoringOtherApps: true)
        navigationHandler?(cta)
    }

    #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB
    private func resetPanelAccessibilityIdentity() {
        panel.title = "句译译文"
        panel.setAccessibilityTitle("句译译文")
    }
    #endif

    private func postAnnouncement(_ text: String) {
        NSAccessibility.post(
            element: NSApplication.shared,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }

    private func installGlobalMonitor() -> Any? {
        NSEvent.addGlobalMonitorForEvents(matching: monitorMask) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleScopedEvent(event, source: .global)
            }
        }
    }

    private func installLocalMonitor() -> Any? {
        NSEvent.addLocalMonitorForEvents(matching: monitorMask) { [weak self] event in
            MainActor.assumeIsolated {
                self?.handleScopedEvent(event, source: .local)
            }
            return event
        }
    }

    private var monitorMask: NSEvent.EventTypeMask {
        [.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]
    }

    private func handleScopedEvent(
        _ event: NSEvent,
        source: NativeTranslationOverlayScopedEventSource
    ) {
        guard panel.isVisible else { return }
        let interaction: NativeTranslationOverlayInteractionEvent
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            interaction = .mouseDown(globalPoint: NSEvent.mouseLocation)
        case .keyDown:
            interaction = .keyDown(
                keyCode: event.keyCode,
                modifiers: modifiers(for: event.modifierFlags)
            )
        default:
            return
        }
        switch NativeTranslationOverlayInteractionPolicy.action(
            for: interaction,
            panelFrame: panel.frame,
            panelIsKey: panel.isKeyWindow,
            canCopy: currentState.canCopy && statefulActionsArePermitted
        ) {
        case .none:
            break
        case .dismiss:
            #if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_TRANSLATION_OVERLAY && JUYI_NATIVE_TRANSLATION_RESULT_LAB
            if isResultLabPresentation,
               NativeTranslationResultLabOwnerSurfacePolicy
                   .suppressesDismiss(
                       from: source,
                       eventIsKeyDown: event.type == .keyDown,
                       panelIsKey: panel.isKeyWindow
                   ) {
                break
            }
            #endif
            dismiss(event.type == .keyDown ? .escape : .outside)
        case .enterKeyboardMode:
            enterKeyboardMode()
        case .copy:
            copyCurrentTranslation()
        case .scroll:
            // The local monitor returns the original event. The key panel
            // consumes a routed scroll exactly once in NSPanel.sendEvent.
            break
        }
    }

    private func handlePanelScrollKey(
        keyCode: UInt16,
        flags: NSEvent.ModifierFlags
    ) -> Bool {
        let action = NativeTranslationOverlayInteractionPolicy.action(
            for: .keyDown(keyCode: keyCode, modifiers: modifiers(for: flags)),
            panelFrame: panel.frame,
            panelIsKey: panel.isKeyWindow,
            canCopy: currentState.canCopy && statefulActionsArePermitted
        )
        guard let command = NativeTranslationOverlayPanelKeyRoutingPolicy.scrollCommand(
            for: action
        ) else { return false }
        overlayView.scrollBody(command)
        return true
    }

    private func modifiers(
        for eventFlags: NSEvent.ModifierFlags
    ) -> NativeTranslationOverlayInteractionModifiers {
        let flags = eventFlags.intersection(.deviceIndependentFlagsMask)
        var modifiers: NativeTranslationOverlayInteractionModifiers = []
        if flags.contains(.control) { modifiers.insert(.control) }
        if flags.contains(.command) { modifiers.insert(.command) }
        if flags.contains(.shift) { modifiers.insert(.shift) }
        if flags.contains(.option) { modifiers.insert(.option) }
        if flags.contains(.function) { modifiers.insert(.function) }
        return modifiers
    }

    private func prepareAnchor() -> Bool {
        let screens = NSScreen.screens
        guard !screens.isEmpty else { return false }
        let mouseScreen = screens.first(where: { $0.visibleFrame.contains(anchorMousePoint) })
        let input = NativeTranslationOverlayAnchorInput(
            contentSize: overlayView.maximumSuccessSize(),
            maximumSuccessSize: overlayView.maximumSuccessSize(),
            selectionRect: nil,
            mousePoint: anchorMousePoint,
            visibleFrames: screens.map(\.visibleFrame),
            sourceVisibleFrame: mouseScreen?.visibleFrame,
            mainVisibleFrame: NSScreen.main?.visibleFrame
        )
        guard let output = NativeTranslationOverlayAnchorPolicy.place(input),
              let screen = screen(matching: output.visibleFrame) else { return false }
        anchorVisibleFrame = output.visibleFrame
        anchorDirection = output.direction
        anchorDisplayIdentifier = displayIdentifier(for: screen)
        return true
    }

    private func placement(
        for state: NativeTranslationOverlayState
    ) -> NativeTranslationOverlayAnchorOutput? {
        guard let anchorVisibleFrame, let anchorDirection else { return nil }
        let screens = NSScreen.screens
        return NativeTranslationOverlayAnchorPolicy.place(
            NativeTranslationOverlayAnchorInput(
                contentSize: overlayView.desiredSize(for: state),
                maximumSuccessSize: overlayView.maximumSuccessSize(),
                selectionRect: nil,
                mousePoint: anchorMousePoint,
                visibleFrames: screens.map(\.visibleFrame),
                sourceVisibleFrame: screen(for: anchorDisplayIdentifier)?.visibleFrame,
                mainVisibleFrame: NSScreen.main?.visibleFrame,
                lockedVisibleFrame: anchorVisibleFrame,
                lockedDirection: anchorDirection
            )
        )
    }

    private func screenConfigurationChanged() {
        guard panel.isVisible else { return }
        guard let anchorDisplayIdentifier,
              let currentScreen = screen(for: anchorDisplayIdentifier) else {
            dismiss(.displayRemoved)
            return
        }
        anchorVisibleFrame = currentScreen.visibleFrame
        layoutRevision += 1
        let presentation = presentationForRelayout()
        renderVisibleState(
            state: presentation.state,
            generation: presentation.generation,
            targetCopyPresentation: presentation.copyPresentation,
            announceTerminal: NativeTranslationOverlayRelayoutPolicy
                .requestsTerminalAnnouncement,
            animateLayout: false
        )
    }

    private func relayoutForCurrentScreen() {
        guard panel.isVisible else { return }
        layoutRevision += 1
        let presentation = presentationForRelayout()
        renderVisibleState(
            state: presentation.state,
            generation: presentation.generation,
            targetCopyPresentation: presentation.copyPresentation,
            announceTerminal: NativeTranslationOverlayRelayoutPolicy
                .requestsTerminalAnnouncement,
            animateLayout: false
        )
    }

    private func presentationForRelayout() -> NativeTranslationOverlayPendingPresentation {
        if let pending = pendingPresentationLifecycle.validEntry(
            for: session.generation
        ) {
            return pending
        }
        pendingPresentationLifecycle.cancel()
        return NativeTranslationOverlayPendingPresentation(
            state: currentState,
            generation: currentGeneration,
            copyPresentation: copyPresentation
        )
    }

    private func screen(matching visibleFrame: CGRect) -> NSScreen? {
        NSScreen.screens.first(where: { $0.visibleFrame == visibleFrame })
            ?? NSScreen.screens.max(by: {
                intersectionArea($0.visibleFrame, visibleFrame)
                    < intersectionArea($1.visibleFrame, visibleFrame)
            })
    }

    private func screen(for identifier: CGDirectDisplayID?) -> NSScreen? {
        guard let identifier else { return nil }
        return NSScreen.screens.first { displayIdentifier(for: $0) == identifier }
    }

    private func displayIdentifier(for screen: NSScreen) -> CGDirectDisplayID? {
        let key = NSDeviceDescriptionKey("NSScreenNumber")
        return (screen.deviceDescription[key] as? NSNumber).map { CGDirectDisplayID($0.uint32Value) }
    }

    private func intersectionArea(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull, intersection.width > 0, intersection.height > 0 else {
            return 0
        }
        return intersection.width * intersection.height
    }

    private func externalFrontmostApplication() -> NSRunningApplication? {
        guard let application = NSWorkspace.shared.frontmostApplication,
              application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return nil
        }
        return application
    }

    private func restoreSourceApplicationIfEligible(
        _ application: NSRunningApplication?,
        reason: NativeTranslationOverlayDismissReason?,
        hadExplicitKeyboardFocus: Bool
    ) {
        let ownerPID = ProcessInfo.processInfo.processIdentifier
        let ownerIsStillFrontmost = NSWorkspace.shared.frontmostApplication?
            .processIdentifier == ownerPID
        guard NativeTranslationOverlayFocusRestorePolicy.shouldRestoreSourceApplication(
            reason: reason,
            hadExplicitKeyboardFocus: hadExplicitKeyboardFocus,
            ownerIsStillFrontmost: ownerIsStillFrontmost
        ), let application, !application.isTerminated else { return }
        application.activate(options: [])
    }
}
