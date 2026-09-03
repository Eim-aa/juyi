"""Contracts for the production overlay and its gated Debug preview."""

from pathlib import Path


ROOT = Path(__file__).parents[1]
APP = (ROOT / "macos" / "JuyiMenuBar.swift").read_text(encoding="utf-8")
MODEL = (ROOT / "macos" / "NativeTranslationOverlayModel.swift").read_text(
    encoding="utf-8"
)
ANCHOR = (
    ROOT / "macos" / "NativeTranslationOverlayAnchorPolicy.swift"
).read_text(encoding="utf-8")
INTERACTION = (
    ROOT / "macos" / "NativeTranslationOverlayInteractionPolicy.swift"
).read_text(encoding="utf-8")
CONTROLLER = (
    ROOT / "macos" / "NativeTranslationOverlayController.swift"
).read_text(encoding="utf-8")
PROJECT = (ROOT / "Juyi.xcodeproj" / "project.pbxproj").read_text(encoding="utf-8")
LEGACY = (ROOT / "scripts" / "build_macos_app.sh").read_text(encoding="utf-8")
CI = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")
DEBUG_CONFIG = (ROOT / "Config" / "Debug.xcconfig").read_text(encoding="utf-8")
RELEASE_CONFIG = (ROOT / "Config" / "Release.xcconfig").read_text(encoding="utf-8")
DOC = (ROOT / "docs" / "NATIVE_TRANSLATION_OVERLAY.md").read_text(
    encoding="utf-8"
)

GATE = "#if DEBUG && JUYI_NATIVE_TRANSLATION_OVERLAY"


def test_debug_preview_is_gated_but_the_production_panel_is_not():
    assert CONTROLLER.count(GATE) >= 1
    assert not CONTROLLER.rstrip().endswith("#endif")
    assert "final class NativeTranslationOverlayController" in CONTROLLER
    assert "func beginNativeTranslation(" in CONTROLLER
    assert "io.github.Eim-aa.Juyi.native-translation-overlay" in CONTROLLER
    assert APP.count(GATE) >= 2
    assert CONTROLLER.count("开发：预览下一状态：") == 1
    assert APP.count("showFixturePreview()") == 1
    assert "JUYI_NATIVE_TRANSLATION_OVERLAY" not in DEBUG_CONFIG
    assert "JUYI_NATIVE_TRANSLATION_OVERLAY" not in RELEASE_CONFIG
    assert 'if [[ "$CONFIGURATION" == "Debug" ]]; then' in LEGACY
    debug_forwarding = LEGACY.split(
        'if [[ "$CONFIGURATION" == "Debug" ]]; then', 1
    )[1].split("\nfi\n", 1)[0]
    assert 'SWIFT_FLAGS+=(-D JUYI_NATIVE_TRANSLATION_OVERLAY)' in debug_forwarding
    assert "HAS_NATIVE_OVERLAY=true" in debug_forwarding
    assert "HAS_NATIVE_DOMAIN" in debug_forwarding
    assert "JUYI_NATIVE_TRANSLATION_RESULT_LAB" in debug_forwarding
    app_overlay_references = "\n".join(
        line
        for line in APP.splitlines()
        if "NativeTranslationOverlay" in line
        or "JUYI_NATIVE_TRANSLATION_OVERLAY" in line
    )
    for source in (CONTROLLER, app_overlay_references):
        for forbidden in ("UserDefaults", "ProcessInfo.processInfo.environment", "remoteConfig"):
            assert forbidden not in source


def test_fixture_preview_has_no_live_selection_network_or_hotkey_owner():
    joined = "\n".join((MODEL, ANCHOR, INTERACTION, CONTROLLER))
    for forbidden in (
        "URLSession",
        "127.0.0.1",
        "localhost",
        "auth-token",
        "NativeOptionDevelopmentHarness",
        "NativeSelectionReader",
        "NativeSelectionResult",
        "NativeOptionMonitor",
        "AXUIElement",
        "CGEvent",
        "charactersIgnoringModifiers",
        ".characters",
    ):
        assert forbidden not in joined
    assert "NativeTranslationOverlayFixture.allCases" in CONTROLLER
    for fixture in (
        "case loading",
        "case appleSuccess",
        "case volcSuccess",
        "case volcAppleFallback",
        "case volcNetwork",
        "case copyFailure",
        "case longTruncated",
        "case noSelection",
        "case secure",
        "case unsupported",
        "case accessibility",
        "case serviceError",
        "case applePackage",
        "case volcCredential",
        "case privacyRefusal",
    ):
        assert fixture in CONTROLLER
    assert "warning: .usedAppleFallback" in CONTROLLER
    assert "error: .volcNetwork" in CONTROLLER
    assert "initialCopyPresentation" in CONTROLLER
    assert "case .copyFailure: return .failed" in CONTROLLER
    assert "fixtureCopyPresentationLifecycle.queue(fixture.initialCopyPresentation)" in CONTROLLER
    assert "fixtureCopyPresentationLifecycle.consumeForVisibleState()" in CONTROLLER
    apply_state = CONTROLLER.split("private func apply(", 1)[1].split(
        "private func renderVisibleState", 1
    )[0]
    assert "preservesVisibleContentForNextSessionBegin" in apply_state
    assert "overlayView.setStatefulActionsEnabled(false)" in apply_state
    assert "pendingPresentationLifecycle.cancel()" in apply_state
    assert "currentState = state" not in apply_state
    assert "currentGeneration = generation" not in apply_state
    assert "commitDisplayedState(" in apply_state
    assert "NSEvent.mouseLocation" in CONTROLLER
    assert "selectionRect: nil" in CONTROLLER
    assert "hammerspoon/argos-translator.lua" not in joined

    cta_handler = APP.split("private func handleNativeOverlayCTA", 1)[1].split(
        "#endif", 1
    )[0]
    assert "model.prepareApple()" not in cta_handler
    assert "model.chooseCloud()" not in cta_handler


def test_clipboard_is_write_only_exact_and_user_initiated():
    assert CONTROLLER.count("NSPasteboard.general.writeObjects") == 1
    assert CONTROLLER.count("NSPasteboard.general.clearContents") == 1
    assert "NSPasteboardItem()" in CONTROLLER
    writer = CONTROLLER.split(
        "private struct NativeTranslationOverlayPasteboardWriter", 1
    )[1].split("@MainActor", 1)[0]
    assert "NativeTranslationOverlayPasteboardReplacePolicy.replace" in writer
    assert writer.index("NSPasteboard.general.clearContents") < writer.index(
        "NSPasteboard.general.writeObjects"
    )
    assert "writeObjects([item])" in writer
    for forbidden in (
        "string(forType",
        "readObjects",
        "pasteboardItems",
        "general.string",
    ):
        assert forbidden not in CONTROLLER
    assert "copyPressed" in CONTROLLER
    assert "case .copy:" in CONTROLLER
    assert "NativeTranslationOverlayCopyPolicy.copy" in CONTROLLER
    assert "state.kind == .success" in MODEL
    assert "stateGeneration == currentGeneration" in MODEL


def test_panel_is_singleton_passive_reused_and_focus_is_explicit():
    assert "static let shared = NativeTranslationOverlayController()" in CONTROLLER
    assert "styleMask: [.borderless, .nonactivatingPanel]" in CONTROLLER
    assert "override var canBecomeMain: Bool { false }" in CONTROLLER
    assert "override var canBecomeKey: Bool { true }" in CONTROLLER
    assert "panel.becomesKeyOnlyIfNeeded = true" in CONTROLLER
    assert "panel.level = .floating" in CONTROLLER
    assert "panel.hidesOnDeactivate = false" in CONTROLLER
    assert "[.transient, .ignoresCycle, .fullScreenAuxiliary]" in CONTROLLER
    assert "canJoinAllSpaces" not in CONTROLLER
    assert "panel.orderFrontRegardless()" in CONTROLLER
    assert "panel.orderOut(nil)" in CONTROLLER
    assert "panel.close()" not in CONTROLLER

    show = CONTROLLER.split("func showFixturePreview()", 1)[1].split(
        "\n    }\n    #endif", 1
    )[0]
    assert "activate" not in show
    assert "makeKey" not in show
    focus = CONTROLLER.split("private func enterKeyboardMode()", 1)[1].split(
        "private func copyCurrentTranslation", 1
    )[0]
    assert "activate" in focus
    assert "makeKeyAndOrderFront" in focus


def test_scoped_dismiss_monitors_are_passthrough_and_cleanup_owned():
    assert "NativeTranslationOverlayScopedMonitorOwner" in CONTROLLER
    assert "NSEvent.addGlobalMonitorForEvents" in CONTROLLER
    assert "NSEvent.addLocalMonitorForEvents" in CONTROLLER
    assert "return event" in CONTROLLER
    assert "[.leftMouseDown, .rightMouseDown, .otherMouseDown, .keyDown]" in CONTROLLER
    assert "NSEvent.removeMonitor" in CONTROLLER
    assert "monitorOwner.start()" in CONTROLLER
    assert "monitorOwner.stop()" in CONTROLLER
    assert "NativeTranslationOverlayPresentationLifecycle" in CONTROLLER
    assert "presentationLifecycle.phase == .visible" in CONTROLLER
    assert "presentationLifecycle.completeHide(revision)" in CONTROLLER
    assert "panelFrame.contains(globalPoint) ? .none : .dismiss" in INTERACTION
    assert "keyCode == escapeKeyCode" in INTERACTION
    assert "keyCode == f6KeyCode" in INTERACTION
    assert "case pageUpKeyCode: return .scroll(.pageUp)" in INTERACTION
    assert "case pageDownKeyCode: return .scroll(.pageDown)" in INTERACTION
    assert "case homeKeyCode: return .scroll(.beginning)" in INTERACTION
    assert "case endKeyCode: return .scroll(.end)" in INTERACTION
    assert "case upArrowKeyCode: return .scroll(.lineUp)" in INTERACTION
    assert "case downArrowKeyCode: return .scroll(.lineDown)" in INTERACTION
    assert "override func sendEvent(_ event: NSEvent)" in CONTROLLER
    assert "scrollKeyHandler?(event.keyCode, event.modifierFlags) == true" in CONTROLLER
    assert "case .scroll:" in CONTROLLER
    assert "NativeTranslationOverlayPanelKeyRoutingPolicy.scrollCommand" in CONTROLLER
    assert "overlayView.scrollBody(command)" in CONTROLLER
    for modifier in (".shift", ".option", ".function"):
        assert f"flags.contains({modifier})" in CONTROLLER
    assert "bodyField.isSelectable = false" in CONTROLLER
    assert "NativeTranslationOverlayStatefulActionPolicy" in CONTROLLER
    assert "guard statefulActionsArePermitted else { return }" in CONTROLLER
    assert "guard statefulActionsArePermitted," in CONTROLLER
    assert "NativeTranslationOverlayFocusTopologyPolicy.orderedControls" in CONTROLLER
    assert "refreshKeyboardFocusTopologyAfterRender()" in CONTROLLER
    assert "button.nextKeyView = nil" in CONTROLLER
    assert "NativeTranslationOverlayFocusRestorePolicy" in INTERACTION
    assert "reason == .close || reason == .escape" in INTERACTION
    assert "ownerIsStillFrontmost" in INTERACTION


def test_state_generation_privacy_and_anchor_are_pure():
    assert "final class NativeTranslationOverlaySession" in MODEL
    assert "let requestGeneration = generation" in MODEL
    assert "terminalGeneration != expectedGeneration" in MODEL
    assert "schedule(after: 0.15" in MODEL
    assert "schedule(after: 2.0" in MODEL
    assert "schedule(after: 12.0" in MODEL
    assert MODEL.index("if let error = response.error") < MODEL.index(
        "let result = response.result"
    )
    assert "case (.volc, .apple, .usedAppleFallback)" in MODEL
    assert "case let (requested, actual, nil) where requested == actual" in MODEL
    assert "advanceGenerationPreservingState" not in MODEL
    assert "NativeTranslationOverlayAnnouncementPolicy" in MODEL
    assert "stateGeneration == currentGeneration" in MODEL

    for forbidden in (
        "import AppKit",
        "NSScreen.",
        "AXUIElementCreate",
        "backingScaleFactor",
        "NSEvent.",
    ):
        assert forbidden not in ANCHOR
    assert "private static let safeInset: CGFloat = 12" in ANCHOR
    assert "private static let selectionGap: CGFloat = 10" in ANCHOR
    assert "private static let mouseGap: CGFloat = 12" in ANCHOR
    screen_change = CONTROLLER.split("private func screenConfigurationChanged()", 1)[
        1
    ].split("private func relayoutForCurrentScreen", 1)[0]
    assert "layoutRevision += 1" in screen_change
    assert "session.generation" not in screen_change
    assert "requestsTerminalAnnouncement" in screen_change
    assert "animateLayout: false" in screen_change


def test_accessibility_semantic_appearance_and_fixed_content_contract():
    for required in (
        'panel.title = "句译译文"',
        "setAccessibilitySubrole(.floatingWindow)",
        "accessibilityDisplayShouldReduceTransparency",
        "accessibilityDisplayShouldIncreaseContrast",
        "accessibilityDisplayShouldReduceMotion",
        "material = .popover",
        "layer?.cornerCurve = .continuous",
        "bodyField.isSelectable = false",
        "hasVerticalScroller = true",
        "NSProgressIndicator()",
        "loadingIndicator.startAnimation(nil)",
        "loadingIndicator.stopAnimation(nil)",
        "layer?.borderWidth = workspace.accessibilityDisplayShouldIncreaseContrast ? 2 : 1",
        "layer?.borderColor = NSColor.separatorColor.cgColor",
        'systemSymbolName: "exclamationmark.triangle.fill"',
        "truncationBadgeView.layer?.cornerRadius = 9",
        "truncationBadgeView.setAccessibilityHelp(state.truncationAccessibilityHelp)",
        "truncationField.textColor = .labelColor",
        "preferredFont(forTextStyle: .body",
        "availablePanelHeight: placement.frame.height",
        "terminalAnnouncement",
        ".announcementRequested",
    ):
        assert required in CONTROLLER
    assert "setAccessibilityChildren(children)" in CONTROLLER
    assert "if !bodyScrollView.isHidden { children.append(bodyField) }" in CONTROLLER
    assert "children.append(closeButton)" in CONTROLLER
    announcement = CONTROLLER.split("private func announceTerminalIfEligible", 1)[1].split(
        "private func showPanelPassively", 1
    )[0]
    assert "panelIsVisible: panel.isVisible" in announcement
    assert announcement.index("announcedTerminalGeneration = currentGeneration") < announcement.index(
        "postAnnouncement(announcement)"
    )
    assert "fullTranslation" not in CONTROLLER.split("postAnnouncement", 1)[1]

    crossfade = CONTROLLER.split("private func crossfadeAndResize", 1)[1].split(
        "private func hidePanel", 1
    )[0]
    assert crossfade.index("overlayView.animator().alphaValue = 0") < crossfade.index(
        "contentTransitionLifecycle.beginSwap(revision)"
    )
    assert crossfade.index("contentTransitionLifecycle.beginSwap(revision)") < crossfade.index(
        "overlayView.render("
    )
    assert crossfade.index("overlayView.render(") < crossfade.index(
        "contentTransitionLifecycle.beginFadeIn(revision)"
    )
    assert crossfade.index("contentTransitionLifecycle.beginFadeIn(revision)") < crossfade.index(
        "overlayView.animator().alphaValue = 1"
    )
    assert "NativeTranslationOverlayContentTransitionLifecycle" in INTERACTION
    assert "NativeTranslationOverlayVisibleReplacementPolicy" in INTERACTION
    assert "NativeTranslationOverlayPendingPresentationLifecycle" in INTERACTION
    assert "pendingPresentationLifecycle.validEntry" in crossfade
    assert crossfade.index("contentTransitionLifecycle.beginSwap(revision)") < crossfade.index(
        "commitDisplayedState("
    )
    assert crossfade.index("commitDisplayedState(") < crossfade.index(
        "overlayView.render("
    )
    relayout = CONTROLLER.split("private func screenConfigurationChanged", 1)[1].split(
        "private func screen(matching", 1
    )[0]
    assert "presentationForRelayout()" in relayout
    assert "requestsTerminalAnnouncement" in relayout
    presentation_for_relayout = CONTROLLER.split(
        "private func presentationForRelayout", 1
    )[1].split("private func screen(matching", 1)[0]
    assert "validEntry(" in presentation_for_relayout
    assert "for: session.generation" in presentation_for_relayout


def test_all_build_paths_tests_and_docs_include_overlay_without_user_script():
    for source in (
        "NativeTranslationOverlayModel.swift",
        "NativeTranslationOverlayAnchorPolicy.swift",
        "NativeTranslationOverlayInteractionPolicy.swift",
        "NativeTranslationOverlayController.swift",
    ):
        assert f"{source} in Sources" in PROJECT
        assert f'"$ROOT/macos/{source}"' in LEGACY
    assert "QuartzCore.framework in Frameworks" in PROJECT
    assert "-framework QuartzCore" in LEGACY
    for test in (
        "NativeTranslationOverlayModelTests.swift",
        "NativeTranslationOverlayAnchorPolicyTests.swift",
        "NativeTranslationOverlayInteractionPolicyTests.swift",
    ):
        assert f"tests/{test}" in CI
    assert "JuyiOverlayPreview" in CI
    assert "JuyiReleaseOverlayFlag" in CI
    assert "SWIFT_ACTIVE_COMPILATION_CONDITIONS='DEBUG JUYI_NATIVE_TRANSLATION_OVERLAY'" in CI
    assert "SWIFT_ACTIVE_COMPILATION_CONDITIONS='JUYI_NATIVE_TRANSLATION_OVERLAY'" in CI
    assert "scripts/start_service.command" not in PROJECT
    assert "scripts/start_service.command" not in CI
    assert "默认未启用" in DOC
    assert "Hammerspoon" in DOC
    assert "真机验证" in DOC
