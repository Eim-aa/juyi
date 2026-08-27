import CoreGraphics
import Foundation

@main
enum NativeTranslationOverlayAnchorPolicyTests {
    private static let mainFrame = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private static let left = CGRect(x: -1280, y: 0, width: 1280, height: 800)
    private static let upper = CGRect(x: 0, y: 900, width: 1200, height: 800)
    private static var passed = 0

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        guard condition() else {
            FileHandle.standardError.write(Data(("FAIL: " + message + "\n").utf8))
            exit(1)
        }
        passed += 1
    }

    private static func input(
        contentSize: CGSize = CGSize(width: 360, height: 132),
        maximumSize: CGSize = CGSize(width: 360, height: 320),
        selection: CGRect? = nil,
        mouse: CGPoint = CGPoint(x: 700, y: 450),
        screens: [CGRect] = [mainFrame],
        source: CGRect? = mainFrame,
        mainScreen: CGRect? = mainFrame,
        lockedScreen: CGRect? = nil,
        lockedDirection: NativeTranslationOverlayAnchorDirection? = nil
    ) -> NativeTranslationOverlayAnchorInput {
        NativeTranslationOverlayAnchorInput(
            contentSize: contentSize,
            maximumSuccessSize: maximumSize,
            selectionRect: selection,
            mousePoint: mouse,
            visibleFrames: screens,
            sourceVisibleFrame: source,
            mainVisibleFrame: mainScreen,
            lockedVisibleFrame: lockedScreen,
            lockedDirection: lockedDirection
        )
    }

    private static func safe(_ screen: CGRect) -> CGRect {
        screen.insetBy(dx: 12, dy: 12)
    }

    private static func isFinite(_ rect: CGRect) -> Bool {
        rect.minX.isFinite && rect.minY.isFinite
            && rect.width.isFinite && rect.height.isFinite
    }

    private static func testSelectionValidationAndDirectionOrder() {
        let selection = CGRect(x: 500, y: 600, width: 100, height: 20)
        let below = NativeTranslationOverlayAnchorPolicy.place(
            input(selection: selection)
        )!
        expect(below.reason == .selection, "valid selection is preferred")
        expect(below.direction == .selectionBelow, "selection tries below first")
        expect(abs(below.frame.maxY - (selection.minY - 10)) < 0.001, "selection gap is 10")

        let nearBottom = NativeTranslationOverlayAnchorPolicy.place(
            input(selection: CGRect(x: 500, y: 20, width: 100, height: 20))
        )!
        expect(nearBottom.direction == .selectionAbove, "selection flips above second")

        let shortScreen = CGRect(x: 0, y: 0, width: 900, height: 400)
        let centerLeft = CGRect(x: 80, y: 190, width: 80, height: 20)
        let right = NativeTranslationOverlayAnchorPolicy.place(
            input(
                maximumSize: CGSize(width: 320, height: 320),
                selection: centerLeft,
                mouse: CGPoint(x: 100, y: 200),
                screens: [shortScreen],
                source: shortScreen,
                mainScreen: shortScreen
            )
        )!
        expect(right.direction == .selectionRight, "right is third selection direction")

        let centerRight = CGRect(x: 740, y: 190, width: 80, height: 20)
        let leftPlacement = NativeTranslationOverlayAnchorPolicy.place(
            input(
                maximumSize: CGSize(width: 320, height: 320),
                selection: centerRight,
                mouse: CGPoint(x: 780, y: 200),
                screens: [shortScreen],
                source: shortScreen,
                mainScreen: shortScreen
            )
        )!
        expect(leftPlacement.direction == .selectionLeft, "left is fourth selection direction")

        let exactlySixty = CGRect(
            x: 10,
            y: 100,
            width: mainFrame.width * 0.60,
            height: mainFrame.height * 0.60
        )
        let boundary = NativeTranslationOverlayAnchorPolicy.place(
            input(selection: exactlySixty)
        )!
        expect(boundary.reason == .selection, "60 percent selection remains valid")

        let invalidSelections: [CGRect] = [
            CGRect(x: 10, y: 10, width: 0, height: 20),
            CGRect(x: 10, y: 10, width: -2, height: 20),
            CGRect(x: CGFloat.nan, y: 10, width: 20, height: 20),
            CGRect(x: 10, y: 10, width: CGFloat.infinity, height: 20),
            CGRect(x: 10, y: 10, width: mainFrame.width * 0.61, height: 20),
            CGRect(x: 2000, y: 10, width: 20, height: 20),
        ]
        for invalid in invalidSelections {
            let output = NativeTranslationOverlayAnchorPolicy.place(
                input(selection: invalid)
            )!
            expect(
                output.reason == .mouseInvalidSelection,
                "invalid selection falls back to mouse: \(invalid)"
            )
        }
    }

    private static func testSelectionScreenIntersectionAndTie() {
        let a = CGRect(x: 0, y: 0, width: 1000, height: 800)
        let b = CGRect(x: 1000, y: 0, width: 1000, height: 800)
        let mostlyB = CGRect(x: 950, y: 500, width: 200, height: 20)
        let outputB = NativeTranslationOverlayAnchorPolicy.place(
            input(selection: mostlyB, mouse: CGPoint(x: 900, y: 500), screens: [a, b])
        )!
        expect(outputB.visibleFrame == b, "selection uses greatest screen intersection")

        let tied = CGRect(x: 950, y: 500, width: 100, height: 20)
        let tieMouseB = NativeTranslationOverlayAnchorPolicy.place(
            input(selection: tied, mouse: CGPoint(x: 1020, y: 500), screens: [a, b])
        )!
        expect(tieMouseB.visibleFrame == b, "intersection tie follows mouse screen")

        let tieSourceA = NativeTranslationOverlayAnchorPolicy.place(
            input(
                selection: tied,
                mouse: CGPoint(x: 3000, y: 3000),
                screens: [a, b],
                source: a,
                mainScreen: b
            )
        )!
        expect(tieSourceA.visibleFrame == a, "tie falls back to source then main")
    }

    private static func testMouseOrderAndFallbackScreen() {
        let rightDown = NativeTranslationOverlayAnchorPolicy.place(
            input(mouse: CGPoint(x: 500, y: 500))
        )!
        expect(rightDown.direction == .mouseRightDown, "mouse tries right-down first")
        expect(abs(rightDown.frame.minX - 512) < 0.001, "mouse horizontal gap is 12")
        expect(abs(rightDown.frame.maxY - 488) < 0.001, "mouse vertical gap is 12")

        let bottom = NativeTranslationOverlayAnchorPolicy.place(
            input(mouse: CGPoint(x: 500, y: 40))
        )!
        expect(bottom.direction == .mouseRightUp, "mouse tries right-up second")

        let rightEdge = NativeTranslationOverlayAnchorPolicy.place(
            input(mouse: CGPoint(x: 1420, y: 500))
        )!
        expect(rightEdge.direction == .mouseLeftDown, "mouse tries left-down third")

        let bottomRight = NativeTranslationOverlayAnchorPolicy.place(
            input(mouse: CGPoint(x: 1420, y: 40))
        )!
        expect(bottomRight.direction == .mouseLeftUp, "mouse tries left-up fourth")

        let sourceFallback = NativeTranslationOverlayAnchorPolicy.place(
            input(
                mouse: CGPoint(x: CGFloat.nan, y: CGFloat.nan),
                screens: [left, mainFrame],
                source: left,
                mainScreen: mainFrame
            )
        )!
        expect(sourceFallback.visibleFrame == left, "invalid mouse falls back to source screen")

        let mainFallback = NativeTranslationOverlayAnchorPolicy.place(
            input(
                mouse: CGPoint(x: 4000, y: 4000),
                screens: [left, mainFrame],
                source: nil,
                mainScreen: mainFrame
            )
        )!
        expect(mainFallback.visibleFrame == mainFrame, "missing source falls back to main")
        expect(
            NativeTranslationOverlayAnchorPolicy.place(
                input(screens: [], source: nil, mainScreen: nil)
            ) == nil,
            "no screen fails closed"
        )
    }

    private static func testMultiScreenSafeFramesAndViewportReduction() {
        let negative = NativeTranslationOverlayAnchorPolicy.place(
            input(mouse: CGPoint(x: -50, y: 400), screens: [left, mainFrame], source: left)
        )!
        expect(negative.visibleFrame == left, "negative-origin display is selected")
        expect(safe(left).contains(negative.frame), "negative-origin frame stays in visible inset")

        let vertical = NativeTranslationOverlayAnchorPolicy.place(
            input(mouse: CGPoint(x: 500, y: 1200), screens: [mainFrame, upper], source: upper)
        )!
        expect(vertical.visibleFrame == upper, "vertical display arrangement is supported")
        expect(safe(upper).contains(vertical.frame), "vertical display frame is contained")

        let dockReduced = CGRect(x: 0, y: 70, width: 1440, height: 800)
        let dockOutput = NativeTranslationOverlayAnchorPolicy.place(
            input(
                contentSize: CGSize(width: 700, height: 1000),
                maximumSize: CGSize(width: 700, height: 1000),
                mouse: CGPoint(x: 720, y: 470),
                screens: [dockReduced],
                source: dockReduced,
                mainScreen: dockReduced
            )
        )!
        expect(dockOutput.bodyViewportWasReduced, "oversize body viewport is reduced first")
        expect(dockOutput.frame.width <= 460, "regular width never exceeds 460")
        expect(dockOutput.frame.width >= 280, "panel never narrows below 280")
        expect(safe(dockReduced).contains(dockOutput.frame), "Dock/menu visibleFrame inset is obeyed")
        expect(isFinite(dockOutput.frame), "output coordinates stay finite")

        let narrow = CGRect(x: 0, y: 0, width: 340, height: 500)
        let narrowOutput = NativeTranslationOverlayAnchorPolicy.place(
            input(
                mouse: CGPoint(x: 170, y: 250),
                screens: [narrow],
                source: narrow,
                mainScreen: narrow
            )
        )!
        expect(narrowOutput.frame.width == 308, "narrow display uses visible width minus 32")
        expect(safe(narrow).contains(narrowOutput.frame), "narrow panel remains in safe frame")
    }

    private static func testLockedEdgeAndReconfiguration() {
        let selection = CGRect(x: 500, y: 600, width: 100, height: 20)
        let loading = NativeTranslationOverlayAnchorPolicy.place(
            input(
                contentSize: CGSize(width: 360, height: 76),
                selection: selection
            )
        )!
        let terminal = NativeTranslationOverlayAnchorPolicy.place(
            input(
                contentSize: CGSize(width: 360, height: 300),
                selection: selection,
                lockedScreen: loading.visibleFrame,
                lockedDirection: loading.direction
            )
        )!
        expect(terminal.reason == .locked, "terminal reuses the preselected anchor")
        expect(terminal.direction == loading.direction, "loading→terminal never flips edge")
        expect(abs(terminal.frame.maxY - loading.frame.maxY) < 0.001, "below anchor edge stays fixed")

        let changedVisibleFrame = CGRect(x: 0, y: 60, width: 1440, height: 820)
        let reclamped = NativeTranslationOverlayAnchorPolicy.place(
            input(
                contentSize: CGSize(width: 360, height: 300),
                selection: selection,
                screens: [changedVisibleFrame],
                source: changedVisibleFrame,
                mainScreen: changedVisibleFrame,
                lockedScreen: loading.visibleFrame,
                lockedDirection: loading.direction
            )
        )!
        expect(safe(changedVisibleFrame).contains(reclamped.frame), "visibleFrame change reclamps")
        expect(reclamped.direction == loading.direction, "reconfigure preserves locked direction")

        let removed = NativeTranslationOverlayAnchorPolicy.place(
            input(
                selection: selection,
                screens: [left],
                source: left,
                mainScreen: left,
                lockedScreen: mainFrame,
                lockedDirection: .selectionBelow
            )
        )
        expect(removed == nil, "removed anchor display fails closed for controller dismissal")
    }

    static func main() {
        testSelectionValidationAndDirectionOrder()
        testSelectionScreenIntersectionAndTie()
        testMouseOrderAndFallbackScreen()
        testMultiScreenSafeFramesAndViewportReduction()
        testLockedEdgeAndReconfiguration()
        print("NativeTranslationOverlayAnchorPolicyTests: \(passed) passed")
    }
}
