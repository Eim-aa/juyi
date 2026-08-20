import CoreGraphics
import Foundation

/// Pure geometry used by the AppKit shell to keep the entire main window on
/// the current screen without disturbing a user-chosen position that is valid.
enum WindowFramePolicy {
    static func frameEnsuringVisibility(
        _ frame: CGRect,
        in visibleFrames: [CGRect],
        preferredVisibleFrame: CGRect?,
        forceCenter: Bool = false
    ) -> CGRect {
        guard frame.width > 0, frame.height > 0 else { return frame }
        let usableFrames = visibleFrames.filter { $0.width > 0 && $0.height > 0 }
        guard !usableFrames.isEmpty else { return frame }

        if !forceCenter && usableFrames.contains(where: { $0.contains(frame) }) { return frame }

        let preferred = preferredVisibleFrame.flatMap { candidate in
            usableFrames.first(where: { $0 == candidate })
        }
        let target: CGRect
        if forceCenter {
            target = preferred ?? usableFrames[0]
        } else {
            let intersections = usableFrames.map { visibleFrame in
                (visibleFrame, visibleFrame.intersection(frame))
            }
            let best = intersections.max { lhs, rhs in
                intersectionArea(lhs.1) < intersectionArea(rhs.1)
            }
            if let best, intersectionArea(best.1) > 0 {
                target = best.0
            } else {
                target = preferred ?? usableFrames[0]
            }
        }

        let fittedSize = CGSize(
            width: min(frame.width, target.width),
            height: min(frame.height, target.height)
        )
        return CGRect(
            x: target.midX - fittedSize.width / 2,
            y: target.midY - fittedSize.height / 2,
            width: fittedSize.width,
            height: fittedSize.height
        )
    }

    private static func intersectionArea(_ frame: CGRect) -> CGFloat {
        guard !frame.isNull, !frame.isInfinite else { return 0 }
        return max(0, frame.width) * max(0, frame.height)
    }
}
