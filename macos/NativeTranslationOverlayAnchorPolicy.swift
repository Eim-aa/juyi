import CoreGraphics
import Foundation

enum NativeTranslationOverlayAnchorDirection: String, Equatable {
    case selectionBelow
    case selectionAbove
    case selectionRight
    case selectionLeft
    case mouseRightDown
    case mouseRightUp
    case mouseLeftDown
    case mouseLeftUp
}

enum NativeTranslationOverlayAnchorReason: String, Equatable {
    case selection
    case mouseNoSelection
    case mouseInvalidSelection
    case locked
}

struct NativeTranslationOverlayAnchorInput: Equatable {
    let contentSize: CGSize
    let maximumSuccessSize: CGSize
    let selectionRect: CGRect?
    let mousePoint: CGPoint
    let visibleFrames: [CGRect]
    let sourceVisibleFrame: CGRect?
    let mainVisibleFrame: CGRect?
    let lockedVisibleFrame: CGRect?
    let lockedDirection: NativeTranslationOverlayAnchorDirection?

    init(
        contentSize: CGSize,
        maximumSuccessSize: CGSize,
        selectionRect: CGRect?,
        mousePoint: CGPoint,
        visibleFrames: [CGRect],
        sourceVisibleFrame: CGRect?,
        mainVisibleFrame: CGRect?,
        lockedVisibleFrame: CGRect? = nil,
        lockedDirection: NativeTranslationOverlayAnchorDirection? = nil
    ) {
        self.contentSize = contentSize
        self.maximumSuccessSize = maximumSuccessSize
        self.selectionRect = selectionRect
        self.mousePoint = mousePoint
        self.visibleFrames = visibleFrames
        self.sourceVisibleFrame = sourceVisibleFrame
        self.mainVisibleFrame = mainVisibleFrame
        self.lockedVisibleFrame = lockedVisibleFrame
        self.lockedDirection = lockedDirection
    }
}

struct NativeTranslationOverlayAnchorOutput: Equatable {
    let frame: CGRect
    let visibleFrame: CGRect
    let direction: NativeTranslationOverlayAnchorDirection
    let reason: NativeTranslationOverlayAnchorReason
    let bodyViewportWasReduced: Bool
}

/// Pure AppKit-global-point placement. It never reads AX, NSScreen or backing
/// scale. Callers pass visible frames that already exclude menu bar, Dock and
/// notch-reserved areas.
enum NativeTranslationOverlayAnchorPolicy {
    private static let safeInset: CGFloat = 12
    private static let selectionGap: CGFloat = 10
    private static let mouseGap: CGFloat = 12
    private static let minimumWidth: CGFloat = 280
    private static let regularMinimumWidth: CGFloat = 320
    private static let regularMaximumWidth: CGFloat = 460
    private static let narrowHorizontalMargin: CGFloat = 32

    static func place(
        _ input: NativeTranslationOverlayAnchorInput
    ) -> NativeTranslationOverlayAnchorOutput? {
        let screens = input.visibleFrames.filter(isUsableRect)
        guard !screens.isEmpty else { return nil }

        if let lockedVisibleFrame = input.lockedVisibleFrame,
           let lockedDirection = input.lockedDirection {
            guard let screen = matchingScreen(for: lockedVisibleFrame, in: screens) else {
                return nil
            }
            return output(
                input: input,
                screen: screen,
                direction: lockedDirection,
                reason: .locked,
                useSelection: input.selectionRect.map(isFinitePositiveRect) == true
            )
        }

        if let selection = input.selectionRect,
           isFinitePositiveRect(selection),
           let selectionScreen = screenForSelection(
               selection,
               mousePoint: input.mousePoint,
               screens: screens,
               sourceVisibleFrame: input.sourceVisibleFrame,
               mainVisibleFrame: input.mainVisibleFrame
           ),
           selection.intersects(selectionScreen),
           selection.width <= selectionScreen.width * 0.60,
           selection.height <= selectionScreen.height * 0.60 {
            let direction = firstFittingSelectionDirection(
                selection: selection,
                screen: selectionScreen,
                maximumSize: constrainedSize(
                    input.maximumSuccessSize,
                    in: selectionScreen
                )
            )
            return output(
                input: input,
                screen: selectionScreen,
                direction: direction,
                reason: .selection,
                useSelection: true
            )
        }

        guard let mouseScreen = screenForMouseFallback(input, screens: screens) else {
            return nil
        }
        let reason: NativeTranslationOverlayAnchorReason = input.selectionRect == nil
            ? .mouseNoSelection
            : .mouseInvalidSelection
        let direction = firstFittingMouseDirection(
            mousePoint: finitePoint(input.mousePoint)
                ? input.mousePoint
                : CGPoint(x: mouseScreen.midX, y: mouseScreen.midY),
            screen: mouseScreen,
            maximumSize: constrainedSize(input.maximumSuccessSize, in: mouseScreen)
        )
        return output(
            input: input,
            screen: mouseScreen,
            direction: direction,
            reason: reason,
            useSelection: false
        )
    }

    private static func output(
        input: NativeTranslationOverlayAnchorInput,
        screen: CGRect,
        direction: NativeTranslationOverlayAnchorDirection,
        reason: NativeTranslationOverlayAnchorReason,
        useSelection: Bool
    ) -> NativeTranslationOverlayAnchorOutput {
        let requestedSize = normalizedSize(input.contentSize)
        let size = constrainedSize(requestedSize, in: screen)
        let anchorPoint = finitePoint(input.mousePoint)
            ? input.mousePoint
            : CGPoint(x: screen.midX, y: screen.midY)
        let selection = useSelection && input.selectionRect.map(isFinitePositiveRect) == true
            ? input.selectionRect
            : nil
        let proposed = proposedFrame(
            size: size,
            selection: selection,
            mousePoint: anchorPoint,
            direction: direction
        )
        let safe = safeFrame(screen)
        let clamped = CGRect(
            origin: CGPoint(
                x: clamp(proposed.minX, minimum: safe.minX, maximum: safe.maxX - size.width),
                y: clamp(proposed.minY, minimum: safe.minY, maximum: safe.maxY - size.height)
            ),
            size: size
        )
        return NativeTranslationOverlayAnchorOutput(
            frame: clamped,
            visibleFrame: screen,
            direction: direction,
            reason: reason,
            bodyViewportWasReduced: size.width < requestedSize.width
                || size.height < requestedSize.height
        )
    }

    private static func firstFittingSelectionDirection(
        selection: CGRect,
        screen: CGRect,
        maximumSize: CGSize
    ) -> NativeTranslationOverlayAnchorDirection {
        let safe = safeFrame(screen)
        let order: [NativeTranslationOverlayAnchorDirection] = [
            .selectionBelow, .selectionAbove, .selectionRight, .selectionLeft,
        ]
        return order.first {
            safe.contains(
                proposedFrame(
                    size: maximumSize,
                    selection: selection,
                    mousePoint: .zero,
                    direction: $0
                )
            )
        } ?? .selectionBelow
    }

    private static func firstFittingMouseDirection(
        mousePoint: CGPoint,
        screen: CGRect,
        maximumSize: CGSize
    ) -> NativeTranslationOverlayAnchorDirection {
        let safe = safeFrame(screen)
        let order: [NativeTranslationOverlayAnchorDirection] = [
            .mouseRightDown, .mouseRightUp, .mouseLeftDown, .mouseLeftUp,
        ]
        return order.first {
            safe.contains(
                proposedFrame(
                    size: maximumSize,
                    selection: nil,
                    mousePoint: mousePoint,
                    direction: $0
                )
            )
        } ?? .mouseRightDown
    }

    private static func proposedFrame(
        size: CGSize,
        selection: CGRect?,
        mousePoint: CGPoint,
        direction: NativeTranslationOverlayAnchorDirection
    ) -> CGRect {
        if let selection {
            switch direction {
            case .selectionBelow:
                return CGRect(
                    x: selection.midX - size.width / 2,
                    y: selection.minY - selectionGap - size.height,
                    width: size.width,
                    height: size.height
                )
            case .selectionAbove:
                return CGRect(
                    x: selection.midX - size.width / 2,
                    y: selection.maxY + selectionGap,
                    width: size.width,
                    height: size.height
                )
            case .selectionRight:
                return CGRect(
                    x: selection.maxX + selectionGap,
                    y: selection.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                )
            case .selectionLeft:
                return CGRect(
                    x: selection.minX - selectionGap - size.width,
                    y: selection.midY - size.height / 2,
                    width: size.width,
                    height: size.height
                )
            default:
                break
            }
        }

        switch direction {
        case .mouseRightDown, .selectionBelow:
            return CGRect(
                x: mousePoint.x + mouseGap,
                y: mousePoint.y - mouseGap - size.height,
                width: size.width,
                height: size.height
            )
        case .mouseRightUp, .selectionAbove:
            return CGRect(
                x: mousePoint.x + mouseGap,
                y: mousePoint.y + mouseGap,
                width: size.width,
                height: size.height
            )
        case .mouseLeftDown, .selectionRight:
            return CGRect(
                x: mousePoint.x - mouseGap - size.width,
                y: mousePoint.y - mouseGap - size.height,
                width: size.width,
                height: size.height
            )
        case .mouseLeftUp, .selectionLeft:
            return CGRect(
                x: mousePoint.x - mouseGap - size.width,
                y: mousePoint.y + mouseGap,
                width: size.width,
                height: size.height
            )
        }
    }

    private static func screenForSelection(
        _ selection: CGRect,
        mousePoint: CGPoint,
        screens: [CGRect],
        sourceVisibleFrame: CGRect?,
        mainVisibleFrame: CGRect?
    ) -> CGRect? {
        let intersections = screens.map { (screen: $0, area: area(selection.intersection($0))) }
        guard let maximum = intersections.map(\.area).max(), maximum > 0 else {
            return nil
        }
        let tied = intersections
            .filter { abs($0.area - maximum) < 0.001 }
            .map(\.screen)
        if finitePoint(mousePoint), let mouse = tied.first(where: { $0.contains(mousePoint) }) {
            return mouse
        }
        if let source = preferredScreen(sourceVisibleFrame, among: tied) { return source }
        if let main = preferredScreen(mainVisibleFrame, among: tied) { return main }
        return tied.first
    }

    private static func screenForMouseFallback(
        _ input: NativeTranslationOverlayAnchorInput,
        screens: [CGRect]
    ) -> CGRect? {
        if finitePoint(input.mousePoint),
           let mouse = screens.first(where: { $0.contains(input.mousePoint) }) {
            return mouse
        }
        if let source = preferredScreen(input.sourceVisibleFrame, among: screens) {
            return source
        }
        if let main = preferredScreen(input.mainVisibleFrame, among: screens) {
            return main
        }
        return screens.first
    }

    private static func preferredScreen(
        _ preferred: CGRect?,
        among screens: [CGRect]
    ) -> CGRect? {
        guard let preferred, isUsableRect(preferred) else { return nil }
        return screens.max {
            area($0.intersection(preferred)) < area($1.intersection(preferred))
        }.flatMap { area($0.intersection(preferred)) > 0 ? $0 : nil }
    }

    private static func matchingScreen(
        for locked: CGRect,
        in screens: [CGRect]
    ) -> CGRect? {
        if let exact = screens.first(where: { $0.equalTo(locked) }) { return exact }
        guard let best = screens.max(by: {
            area($0.intersection(locked)) < area($1.intersection(locked))
        }), area(best.intersection(locked)) > 0 else { return nil }
        return best
    }

    private static func constrainedSize(_ raw: CGSize, in screen: CGRect) -> CGSize {
        let normalized = normalizedSize(raw)
        let safe = safeFrame(screen)
        let screenWidthLimit = max(0, screen.width - narrowHorizontalMargin)
        let regularWidth = min(regularMaximumWidth, max(regularMinimumWidth, normalized.width))
        let width = min(regularWidth, screenWidthLimit, safe.width)
        return CGSize(
            width: max(minimumWidth, width),
            height: min(normalized.height, safe.height)
        )
    }

    private static func normalizedSize(_ raw: CGSize) -> CGSize {
        CGSize(
            width: raw.width.isFinite && raw.width > 0 ? raw.width : 360,
            height: raw.height.isFinite && raw.height > 0 ? raw.height : 132
        )
    }

    private static func safeFrame(_ screen: CGRect) -> CGRect {
        screen.insetBy(dx: safeInset, dy: safeInset)
    }

    private static func clamp(
        _ value: CGFloat,
        minimum: CGFloat,
        maximum: CGFloat
    ) -> CGFloat {
        guard maximum >= minimum else { return minimum }
        return min(max(value, minimum), maximum)
    }

    private static func area(_ rect: CGRect) -> CGFloat {
        guard !rect.isNull, !rect.isInfinite, rect.width > 0, rect.height > 0 else {
            return 0
        }
        return rect.width * rect.height
    }

    private static func finitePoint(_ point: CGPoint) -> Bool {
        point.x.isFinite && point.y.isFinite
    }

    private static func isFinitePositiveRect(_ rect: CGRect) -> Bool {
        rect.origin.x.isFinite
            && rect.origin.y.isFinite
            && rect.size.width.isFinite
            && rect.size.height.isFinite
            && rect.size.width > 0
            && rect.size.height > 0
    }

    private static func isUsableRect(_ rect: CGRect) -> Bool {
        isFinitePositiveRect(rect)
            && rect.width >= minimumWidth + safeInset * 2
            && rect.height > safeInset * 2
    }
}
