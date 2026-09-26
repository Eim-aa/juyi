import CoreGraphics
import Foundation

@main
enum NativeTranslationOverlayInteractionPolicyTests {
    private final class Token {}
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

    private static func testDismissFocusAndCopyPolicy() {
        let frame = CGRect(x: 100, y: 100, width: 360, height: 200)
        expect(
            NativeTranslationOverlayInteractionPolicy.action(
                for: .mouseDown(globalPoint: CGPoint(x: 200, y: 200)),
                panelFrame: frame,
                panelIsKey: false,
                canCopy: true
            ) == .none,
            "inside body/button/scroll clicks stay open"
        )
        expect(
            NativeTranslationOverlayInteractionPolicy.action(
                for: .mouseDown(globalPoint: CGPoint(x: 20, y: 20)),
                panelFrame: frame,
                panelIsKey: false,
                canCopy: true
            ) == .dismiss,
            "outside click dismisses"
        )
        expect(
            NativeTranslationOverlayInteractionPolicy.action(
                for: .mouseDown(globalPoint: CGPoint(x: CGFloat.nan, y: 20)),
                panelFrame: frame,
                panelIsKey: false,
                canCopy: true
            ) == .dismiss,
            "invalid global point fails closed"
        )
        expect(
            NativeTranslationOverlayInteractionPolicy.action(
                for: .keyDown(keyCode: 53, modifiers: []),
                panelFrame: frame,
                panelIsKey: false,
                canCopy: false
            ) == .dismiss,
            "Escape dismisses without activation"
        )
        expect(
            NativeTranslationOverlayInteractionPolicy.action(
                for: .keyDown(keyCode: 97, modifiers: [.control]),
                panelFrame: frame,
                panelIsKey: false,
                canCopy: false
            ) == .enterKeyboardMode,
            "Control-F6 is the only explicit focus shortcut"
        )
        expect(
            NativeTranslationOverlayInteractionPolicy.action(
                for: .keyDown(keyCode: 8, modifiers: [.command]),
                panelFrame: frame,
                panelIsKey: true,
                canCopy: true
            ) == .copy,
            "Cmd-C works only in focused success"
        )
        for (isKey, canCopy) in [(false, true), (true, false), (false, false)] {
            expect(
                NativeTranslationOverlayInteractionPolicy.action(
                    for: .keyDown(keyCode: 8, modifiers: [.command]),
                    panelFrame: frame,
                    panelIsKey: isKey,
                    canCopy: canCopy
                ) == .none,
                "Cmd-C cannot copy from passive/non-success panel"
            )
        }

        let scrollingKeys: [(UInt16, NativeTranslationOverlayScrollCommand)] = [
            (116, .pageUp),
            (121, .pageDown),
            (115, .beginning),
            (119, .end),
            (126, .lineUp),
            (125, .lineDown),
        ]
        for (keyCode, command) in scrollingKeys {
            expect(
                NativeTranslationOverlayInteractionPolicy.action(
                    for: .keyDown(keyCode: keyCode, modifiers: []),
                    panelFrame: frame,
                    panelIsKey: true,
                    canCopy: true
                ) == .scroll(command),
                "focused panel routes long-body scroll command \(command)"
            )
            expect(
                NativeTranslationOverlayInteractionPolicy.action(
                    for: .keyDown(keyCode: keyCode, modifiers: []),
                    panelFrame: frame,
                    panelIsKey: false,
                    canCopy: true
                ) == .none,
                "passive panel never handles body scrolling"
            )
        }
        for modifier in [
            NativeTranslationOverlayInteractionModifiers.command,
            .control, .shift, .option, .function,
        ] {
            expect(
                NativeTranslationOverlayInteractionPolicy.action(
                    for: .keyDown(keyCode: 121, modifiers: modifier),
                    panelFrame: frame,
                    panelIsKey: true,
                    canCopy: true
                ) == .none,
                "modified navigation keys remain available to AppKit"
            )
        }
        expect(
            NativeTranslationOverlayPanelKeyRoutingPolicy.scrollCommand(
                for: .scroll(.pageDown)
            ) == .pageDown,
            "key panel consumes one recognized scroll command"
        )
        expect(
            NativeTranslationOverlayPanelKeyRoutingPolicy.scrollCommand(for: .copy) == nil,
            "key panel leaves non-scroll actions on their existing route"
        )
    }

    private static func testCopyFailureFixtureFeedbackIsConsumedOnce() {
        var lifecycle = NativeTranslationOverlayFixtureCopyPresentationLifecycle()
        lifecycle.queue(.failed)
        expect(
            lifecycle.consumeForVisibleState() == .failed,
            "copy-failure fixture reaches the next visible panel state"
        )
        expect(
            lifecycle.consumeForVisibleState() == .idle,
            "fixture feedback is one-shot and later states return to idle"
        )
        lifecycle.queue(.copied)
        lifecycle.queue(.failed)
        expect(
            lifecycle.consumeForVisibleState() == .failed,
            "latest explicitly selected fixture feedback supersedes stale feedback"
        )
    }

    private static func testPasteboardReplacementIsOrderedAndSingleItem() {
        var operations: [String] = []
        var writtenItems: [String] = []
        let copied = NativeTranslationOverlayPasteboardReplacePolicy.replace(
            text: "完整译文\n第二行 😀",
            makeItem: { text in
                operations.append("materialize")
                return text
            },
            clearExistingContents: {
                operations.append("clear")
            },
            writeSingleItem: { item in
                operations.append("write")
                writtenItems.append(item)
                return true
            }
        )
        expect(copied, "explicit Copy reports a successful replacement")
        expect(
            operations == ["materialize", "clear", "write"],
            "copy materializes before clearing and writes only after clearing"
        )
        expect(
            writtenItems == ["完整译文\n第二行 😀"],
            "copy writes exactly one complete translation item"
        )

        operations.removeAll()
        let couldNotMaterialize = NativeTranslationOverlayPasteboardReplacePolicy.replace(
            text: "fixture",
            makeItem: { _ -> String? in
                operations.append("materialize")
                return nil
            },
            clearExistingContents: {
                operations.append("clear")
            },
            writeSingleItem: { _ in
                operations.append("write")
                return true
            }
        )
        expect(!couldNotMaterialize, "materialization failure reports Copy failure")
        expect(
            operations == ["materialize"],
            "materialization failure leaves the existing pasteboard untouched"
        )

        operations.removeAll()
        let writeFailed = NativeTranslationOverlayPasteboardReplacePolicy.replace(
            text: "fixture",
            makeItem: { $0 },
            clearExistingContents: {
                operations.append("clear")
            },
            writeSingleItem: { _ in
                operations.append("write")
                return false
            }
        )
        expect(!writeFailed, "system write failure is surfaced to the panel")
        expect(
            operations == ["clear", "write"],
            "a failed system write is not retried or followed by another mutation"
        )
    }

    private static func testScopedMonitorTokenCleanup() {
        var globalInstallCount = 0
        var localInstallCount = 0
        var removed: [ObjectIdentifier] = []
        let global = Token()
        let local = Token()
        let owner = NativeTranslationOverlayScopedMonitorOwner(
            installGlobal: {
                globalInstallCount += 1
                return global
            },
            installLocal: {
                localInstallCount += 1
                return local
            },
            remove: { token in
                removed.append(ObjectIdentifier(token as AnyObject))
            }
        )

        owner.start()
        owner.start()
        expect(globalInstallCount == 1, "visible scope installs one global token")
        expect(localInstallCount == 1, "visible scope installs one local token")
        expect(owner.isActive, "owner reports active while either token exists")
        owner.stop()
        owner.stop()
        expect(removed.count == 2, "every token is removed exactly once")
        expect(Set(removed) == Set([ObjectIdentifier(global), ObjectIdentifier(local)]), "both tokens removed")
        expect(!owner.isActive, "all dismissal paths leave no scoped token")

        let partial = NativeTranslationOverlayScopedMonitorOwner(
            installGlobal: { nil },
            installLocal: { local },
            remove: { _ in localInstallCount += 1 }
        )
        partial.start()
        expect(partial.isActive, "one successful token still counts as active")
        let before = localInstallCount
        partial.stop()
        expect(localInstallCount == before + 1, "partial install still cleans its token")
    }

    private static func testNewShowRevokesInFlightHideCompletion() {
        var lifecycle = NativeTranslationOverlayPresentationLifecycle()
        let firstShow = lifecycle.beginShow()
        expect(lifecycle.phase == .visible, "first fixture enters visible presentation")
        expect(lifecycle.monitorsShouldBeActive, "visible presentation requires scoped monitors")
        expect(
            lifecycle.acceptsVisibleCompletion(firstShow),
            "current show completion remains valid"
        )

        let oldHide = lifecycle.beginHide()
        expect(lifecycle.phase == .hiding, "hidden session update begins one hide")
        expect(!lifecycle.monitorsShouldBeActive, "hide stops scoped monitors")

        let replacementShow = lifecycle.beginShow()
        expect(
            replacementShow > oldHide,
            "replacement fixture owns a newer presentation revision"
        )
        expect(lifecycle.phase == .visible, "replacement fixture is visible")
        expect(
            lifecycle.monitorsShouldBeActive,
            "replacement fixture restores scoped monitors"
        )
        expect(
            !lifecycle.completeHide(oldHide),
            "stale hide completion cannot order out replacement fixture"
        )
        expect(
            lifecycle.acceptsVisibleCompletion(replacementShow),
            "replacement show completion remains authoritative"
        )
        expect(lifecycle.phase == .visible, "stale completion leaves replacement visible")
    }

    private static func testCrossfadeOrdersOldOutSwapNewIn() {
        var transition = NativeTranslationOverlayContentTransitionLifecycle()
        let first = transition.begin()
        expect(transition.phase == .fadingOut, "crossfade begins with old content fade-out")
        expect(!transition.beginFadeIn(first), "new content cannot fade in before a swap")
        expect(transition.beginSwap(first), "current fade-out completion may swap content")
        expect(transition.phase == .swapping, "content owns an explicit swap boundary")
        expect(transition.beginFadeIn(first), "new content fades in only after the swap")
        expect(transition.complete(first), "current fade-in completion ends transition")
        expect(transition.phase == .idle, "completed crossfade becomes idle")

        let stale = transition.begin()
        transition.invalidate()
        expect(!transition.beginSwap(stale), "invalidated fade-out cannot swap stale content")
        let latest = transition.begin()
        expect(transition.beginSwap(latest), "latest content may swap")
        expect(transition.beginFadeIn(latest), "latest content may fade in")
        expect(!transition.complete(stale), "stale completion cannot finish latest transition")
        expect(transition.complete(latest), "latest transition remains authoritative")
    }

    private static func testVisibleFixtureReplacementPreservesOldContentForFadeOut() {
        expect(
            NativeTranslationOverlayVisibleReplacementPolicy.preservesCurrentContent(
                panelIsVisible: true,
                presentationPhase: .visible
            ),
            "visible terminal stays rendered until replacement fade-out swaps content"
        )
        for phase in [
            NativeTranslationOverlayPresentationLifecycle.Phase.hidden,
            .hiding,
        ] {
            expect(
                !NativeTranslationOverlayVisibleReplacementPolicy.preservesCurrentContent(
                    panelIsVisible: true,
                    presentationPhase: phase
                ),
                "hidden/hiding panel does not masquerade as a visible replacement"
            )
        }
        expect(
            !NativeTranslationOverlayVisibleReplacementPolicy.preservesCurrentContent(
                panelIsVisible: false,
                presentationPhase: .visible
            ),
            "ordered-out panel has no old content to preserve"
        )
    }

    private static func testDisplayedGenerationBindsCopyAndCTA() {
        expect(
            !NativeTranslationOverlayStatefulActionPolicy.bindingIsCurrent(
                displayedGeneration: 7,
                sessionGeneration: 8
            ),
            "loading replacement leaves old visual unbound from the new generation"
        )
        expect(
            !NativeTranslationOverlayStatefulActionPolicy.permitsAction(
                displayedGeneration: 7,
                sessionGeneration: 8,
                panelIsVisible: true
            ),
            "old visual cannot Copy or invoke CTA while new content is pending/fading"
        )
        expect(
            NativeTranslationOverlayStatefulActionPolicy.permitsAction(
                displayedGeneration: 8,
                sessionGeneration: 8,
                panelIsVisible: true
            ),
            "Copy and CTA become available at the atomic visual swap"
        )
        expect(
            !NativeTranslationOverlayStatefulActionPolicy.permitsAction(
                displayedGeneration: 8,
                sessionGeneration: 8,
                panelIsVisible: false
            ),
            "ordered-out content cannot perform stateful actions"
        )
    }

    private static func testPendingPresentationCannotCrossSessionBoundary() {
        var pending = NativeTranslationOverlayPendingPresentationLifecycle<String, String>()
        pending.stage(state: "B", generation: 2, copyPresentation: "failed")
        expect(
            pending.validEntry(for: 2)?.state == "B",
            "current session can consume its pending visual"
        )
        expect(
            pending.validEntry(for: 3) == nil,
            "relayout rejects pending content from an old session generation"
        )

        // Starting C cancels B before C's first visible state arrives. A screen
        // relayout in that interval must retain displayed A, never commit B.
        pending.cancel()
        expect(
            pending.validEntry(for: 3) == nil,
            "B pending → C begin leaves no stale presentation to relayout"
        )
        pending.stage(state: "C loading", generation: 3, copyPresentation: "idle")
        pending.stage(state: "C terminal", generation: 3, copyPresentation: "idle")
        expect(
            pending.validEntry(for: 3)?.state == "C terminal",
            "latest state in one generation supersedes its older pending state"
        )
        expect(
            NativeTranslationOverlayRelayoutPolicy.requestsTerminalAnnouncement,
            "every relayout asks the current/visible/terminal/once announcement gate"
        )
    }

    private static func testKeyboardFocusTopologyTracksVisibleControls() {
        let loading = NativeTranslationOverlayFocusTopologyPolicy.orderedControls(
            hasCTA: false,
            canCopy: false
        )
        let success = NativeTranslationOverlayFocusTopologyPolicy.orderedControls(
            hasCTA: false,
            canCopy: true
        )
        let errorCTA = NativeTranslationOverlayFocusTopologyPolicy.orderedControls(
            hasCTA: true,
            canCopy: false
        )
        expect(loading == [.close], "loading exposes only Close to the keyboard loop")
        expect(success == [.copy, .close], "loading→success rebuilds Copy→Close")
        expect(errorCTA == [.cta, .close], "success→CTA rebuilds CTA→Close")
        expect(
            NativeTranslationOverlayFocusTopologyPolicy.decision(
                current: .close,
                orderedControls: success
            ) == .preserveCurrent,
            "still-visible Close remains first responder after loading→success"
        )
        expect(
            NativeTranslationOverlayFocusTopologyPolicy.decision(
                current: .copy,
                orderedControls: errorCTA
            ) == .moveTo(.cta),
            "hidden old Copy moves focus to the first visible CTA"
        )
        expect(
            NativeTranslationOverlayFocusTopologyPolicy.decision(
                current: .cta,
                orderedControls: loading
            ) == .moveTo(.close),
            "CTA→noCTA moves focus to visible Close"
        )
    }

    private static func testFocusRestoreIsReasonAndFrontmostAware() {
        for reason in [
            NativeTranslationOverlayDismissReason.close,
            .escape,
        ] {
            expect(
                NativeTranslationOverlayFocusRestorePolicy.shouldRestoreSourceApplication(
                    reason: reason,
                    hadExplicitKeyboardFocus: true,
                    ownerIsStillFrontmost: true
                ),
                "explicit focus exit may restore its captured source"
            )
            expect(
                !NativeTranslationOverlayFocusRestorePolicy.shouldRestoreSourceApplication(
                    reason: reason,
                    hadExplicitKeyboardFocus: false,
                    ownerIsStillFrontmost: true
                ),
                "passive Close/Escape never activates another app"
            )
            expect(
                !NativeTranslationOverlayFocusRestorePolicy.shouldRestoreSourceApplication(
                    reason: reason,
                    hadExplicitKeyboardFocus: true,
                    ownerIsStillFrontmost: false
                ),
                "a third app chosen during hide animation is never stolen back"
            )
        }

        for reason in [
            NativeTranslationOverlayDismissReason.outside,
            .pause, .stop, .revoke, .displayRemoved,
            .space, .session, .sleep, .terminate,
        ] {
            expect(
                !NativeTranslationOverlayFocusRestorePolicy.shouldRestoreSourceApplication(
                    reason: reason,
                    hadExplicitKeyboardFocus: true,
                    ownerIsStillFrontmost: true
                ),
                "passive/lifecycle dismissal never restores an old app"
            )
        }
    }

    static func main() {
        testDismissFocusAndCopyPolicy()
        testCopyFailureFixtureFeedbackIsConsumedOnce()
        testPasteboardReplacementIsOrderedAndSingleItem()
        testScopedMonitorTokenCleanup()
        testNewShowRevokesInFlightHideCompletion()
        testCrossfadeOrdersOldOutSwapNewIn()
        testVisibleFixtureReplacementPreservesOldContentForFadeOut()
        testDisplayedGenerationBindsCopyAndCTA()
        testPendingPresentationCannotCrossSessionBoundary()
        testKeyboardFocusTopologyTracksVisibleControls()
        testFocusRestoreIsReasonAndFrontmostAware()
        print("NativeTranslationOverlayInteractionPolicyTests: \(passed) passed")
    }
}
