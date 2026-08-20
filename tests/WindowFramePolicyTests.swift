import CoreGraphics
import Foundation

@main
enum WindowFramePolicyTests {
    private static var passed = 0

    private static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        guard condition() else {
            FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
            exit(1)
        }
        passed += 1
    }

    static func main() {
        let main = CGRect(x: 0, y: 25, width: 1470, height: 875)
        let secondary = CGRect(x: 1470, y: 40, width: 1920, height: 1040)
        let screens = [main, secondary]
        let valid = CGRect(x: 300, y: 120, width: 681, height: 650)
        expect(
            WindowFramePolicy.frameEnsuringVisibility(valid, in: screens, preferredVisibleFrame: main) == valid,
            "a fully visible main-screen position stays unchanged"
        )

        let validSecondary = CGRect(x: 1800, y: 160, width: 681, height: 650)
        expect(
            WindowFramePolicy.frameEnsuringVisibility(validSecondary, in: screens, preferredVisibleFrame: main) == validSecondary,
            "a fully visible secondary-screen position stays unchanged"
        )

        let rightOverflow = CGRect(x: 1244, y: 120, width: 681, height: 650)
        let repairedRight = WindowFramePolicy.frameEnsuringVisibility(rightOverflow, in: [main], preferredVisibleFrame: main)
        expect(main.contains(repairedRight), "X=1244 overflow is fully repaired")
        expect(repairedRight.midX == main.midX, "X=1244 overflow is centered")

        let leftOverflow = CGRect(x: -366, y: 120, width: 681, height: 650)
        let repairedLeft = WindowFramePolicy.frameEnsuringVisibility(leftOverflow, in: [main], preferredVisibleFrame: main)
        expect(main.contains(repairedLeft), "X=-366 overflow is fully repaired")
        expect(repairedLeft.midX == main.midX, "X=-366 overflow is centered")

        let mostlySecondary = CGRect(x: 1300, y: 120, width: 900, height: 650)
        let repairedOverlap = WindowFramePolicy.frameEnsuringVisibility(mostlySecondary, in: screens, preferredVisibleFrame: main)
        expect(repairedOverlap.midX == secondary.midX, "the screen with the largest intersection wins")

        let oversized = CGRect(x: -200, y: -100, width: 1800, height: 1000)
        let fitted = WindowFramePolicy.frameEnsuringVisibility(oversized, in: [main], preferredVisibleFrame: main)
        expect(fitted.size == main.size, "an oversized window is constrained to the visible frame")
        expect(fitted.origin == main.origin, "a constrained oversized window uses the visible origin")

        let disconnected = CGRect(x: 6000, y: 4000, width: 681, height: 650)
        let repairedDisconnected = WindowFramePolicy.frameEnsuringVisibility(
            disconnected,
            in: screens,
            preferredVisibleFrame: secondary
        )
        expect(secondary.contains(repairedDisconnected), "a disconnected window uses the preferred screen")
        expect(repairedDisconnected.midX == secondary.midX, "disconnected fallback is centered")

        let forced = WindowFramePolicy.frameEnsuringVisibility(
            validSecondary,
            in: screens,
            preferredVisibleFrame: main,
            forceCenter: true
        )
        expect(forced.midX == main.midX && forced.midY == main.midY, "creation centers on the active preferred screen")

        print("WindowFramePolicyTests: \(passed) passed")
    }
}
