"""Static contract checks for the dependency-free native macOS shell.

The policy has executable Swift tests, while these checks protect the complete
product flow from accidental removal in both Xcode and legacy-script builds.
"""

import re
from pathlib import Path


SOURCE = Path(__file__).parents[1] / "macos" / "JuyiMenuBar.swift"
SWIFT = SOURCE.read_text(encoding="utf-8")
POLICY = (SOURCE.parent / "OnboardingPolicy.swift").read_text(encoding="utf-8")


def test_versioned_disposition_and_legacy_migration_exist():
    assert "case neverStarted, inProgress, deferred, completed" in POLICY
    assert "currentVersion = 1" in POLICY
    assert 'defaults.bool(forKey: "onboardingConfirmed")' in SWIFT
    assert 'defaults.removeObject(forKey: "onboardingConfirmed")' in SWIFT


def test_completion_requires_active_native_hotkey_and_explicit_confirmation():
    body = SWIFT.split("func confirmHotkeyWorked()", 1)[1].split("func togglePause()", 1)[0]
    assert "guard NativeProductionTranslationCoordinator.shared.isEnabled else" in body
    assert "onboardingDisposition = .completed" in body
    assert "last_translation_at" not in SWIFT


def test_practice_uses_an_external_app_and_separate_root_is_present():
    assert "SelectablePracticeText" not in SWIFT
    assert "打开示例文稿，选中英文，再连按两次 Option。" in SWIFT
    assert "句译不会读取自身窗口中的文字" in SWIFT
    assert "struct OnboardingView: View" in SWIFT
    assert "struct RootView: View" in SWIFT


def test_close_defers_and_help_can_rerun_without_reset_path():
    assert "func windowWillClose" in SWIFT
    assert "model.deferOnboarding()" in SWIFT
    assert "重新运行完整设置" in SWIFT
    assert "removeCloud()" not in SWIFT.split('Button("重新运行完整设置…")', 1)[1][:200]


def test_engine_choice_uses_policy_and_native_routing_is_explicit():
    assert "OnboardingPolicy.preferredEngine" in SWIFT
    assert "NativeProductionTranslationCoordinator.shared.isEnabled ? .practice : .permission" in SWIFT
    # Enabling the shortcut never switches the engine: both engines use the
    # native chain, and a missing cloud key leads to the cloud settings.
    assert "切换到 Apple 离线并启用" not in SWIFT
    enable = SWIFT.split("func enableNativeShortcut()", 1)[1].split("func applicationBecameActive()", 1)[0]
    assert "setEngine(" not in enable
    assert 'footer(primary: "设置火山云端"' in SWIFT
    assert "case .unavailable where nativeTranslation.cloudCredentialRequired:" in SWIFT
    assert 'if hasCloudConfiguration { return "volc" }' not in POLICY
    # The unreachable engine-self-test screen was removed; routing only
    # depends on the live native hotkey state.
    assert "case welcome, permission, practice, complete" in POLICY
    assert "firstIncompleteScreen" not in POLICY
    assert "onboardingEngineReady" not in SWIFT
    assert "verifyOnboardingEngine" not in SWIFT
    assert re.search(r"\.prepare\b", SWIFT) is None


def test_accessible_scroll_layout_and_window_policy_are_wired():
    assert "@AccessibilityFocusState" in SWIFT
    assert "permissionTroubleshooting" in SWIFT
    assert "practiceTroubleshooting" in SWIFT
    assert "onboardingFooter.padding" in SWIFT
    assert "window.titleVisibility = .hidden" in SWIFT
    assert "guard lastOnboardingMode != mode" in SWIFT
    assert "NSSize(width: 520, height: 520)" in SWIFT


def test_initialization_never_persists_an_implicit_engine_choice():
    init_body = SWIFT.split("init() {", 1)[1].split("private var refreshContext", 1)[0]
    assert "OnboardingPolicy.preferredEngine" in init_body
    assert "setEngine(" not in init_body


def test_service_and_hammerspoon_management_are_gone():
    for removed in (
        "func repairService",
        "func stopService",
        "func openLogs",
        "func openInstallationGuide",
        "func openHammerspoon",
        "installBundledShortcut",
        "restartHammerspoonAfterInstall",
        "runHammerspoonHook",
        "bundledShortcutIsCurrent",
        "hammerspoon_hook",
        "HotkeyProblem",
        "hotkeyProblem",
        "nativeNeedsLegacyHandoff",
        "nativeOwnerBridgeReady",
        "shortcutRepairBusy",
        "waitingForHammerspoon",
        "修复云端组件",
        "停止云端翻译组件",
        "打开安装说明",
        "检查已有 Hammerspoon 组件",
        "打开技术日志",
        "argos-translator.err.log",
    ):
        assert removed not in SWIFT, removed


def _between(text, start, end):
    return text.split(start, 1)[1].split(end, 1)[0]


ONBOARDING = _between(SWIFT, "private struct OnboardingView: View", "private struct CloudSetupView")
DIAGNOSTICS = _between(SWIFT, "private struct DiagnosticsView: View", "private struct SupportInfoView")
SUPPORT = _between(SWIFT, "private struct SupportInfoView: View", "private struct AppView")
APP_VIEW = _between(SWIFT, "private struct AppView: View", "private struct RootView")


def test_onboarding_progress_matches_two_steps_and_completion():
    for label in ("第 1 步 · 准备", "第 2 步 · 练习", '"完成"', "第 1 步，共 2 步", "第 2 步，共 2 步"):
        assert label in ONBOARDING
    assert "共 4 步" not in ONBOARDING
    assert "第 3 步" not in ONBOARDING


def test_early_components_are_fail_closed_on_home_onboarding_and_diagnostics():
    # One state source (AppModel.legacyState) drives every surface.
    for state in ('"检测到早期组件"', '"早期组件需要手动处理"', '"请重新启动 Hammerspoon"'):
        assert state in SWIFT
    for action in ('"移除早期组件"', '"重新检查"', '"重新启动 Hammerspoon"', '"正在移除早期组件…"'):
        assert action in SWIFT
    assert "if legacyComponentsPresent { return legacyActionTitle }" in SWIFT
    assert "if legacyComponentsPresent { performLegacyComponentAction() }" in SWIFT

    status = _between(ONBOARDING, "private var shortcutStatus: ShortcutState", "@ViewBuilder private var shortcutFooter")
    assert "if model.legacyComponentsPresent {" in status
    assert "model.legacyTitle, model.legacyMessage" in status
    footer = _between(ONBOARDING, "@ViewBuilder private var shortcutFooter", "private var practice: some View")
    assert "} else if model.legacyComponentsPresent {" in footer
    assert "model.performLegacyComponentAction()" in footer
    assert "Hammerspoon" not in status + footer
    card = _between(ONBOARDING, "private var shortcutStatusCard", "private func preparationRow")
    assert "if model.legacyComponentsPresent {" in card
    assert "移除早期版本留下的组件" in card

    assert "if model.legacyComponentsPresent {" in DIAGNOSTICS
    assert "Button(model.legacyActionTitle) { model.performLegacyComponentAction() }" in DIAGNOSTICS

    # Detection runs at launch, before an explicit enable, and on refresh.
    init = SWIFT.split("init() {", 1)[1].split("private var refreshContext", 1)[0]
    assert "refreshLegacyComponents()" in init
    enable = SWIFT.split("func enableNativeShortcut()", 1)[1].split("func applicationBecameActive()", 1)[0]
    assert enable.index("refreshLegacyComponents()") < enable.index("native.enableByUser()\n    }")
    assert "guard !legacyComponentsPresent else { return }" in enable
    refresh = SWIFT.split("func refresh() async {", 1)[1].split("\n    }\n", 1)[0]
    assert "refreshLegacyComponents()" in refresh
    assert "setLegacyComponentsDetected(state != .clean)" in SWIFT


def test_explainers_and_scope_copy_live_once_in_support_info():
    assert "后台运行与停止" in SUPPORT
    assert "退出句译：停止翻译；重开后需要点击“恢复翻译”。" in SUPPORT
    assert "失败时不会自动改用云端" in SUPPORT
    assert "WPS PDF 的兼容取词会临时执行系统复制" in SUPPORT
    assert "关闭窗口：" not in ONBOARDING + DIAGNOSTICS
    assert 'Button("后台运行与停止…") { model.showSupportInfo = true }' in ONBOARDING
    # Practice keeps the WPS clipboard disclosure as one short sentence.
    assert "WPS PDF 兼容取词会临时使用剪贴板，剪贴板管理器可能保留原文；扫描图片型 PDF 暂不支持。" in ONBOARDING
    assert SWIFT.count("扫描") <= 2
    assert SWIFT.count("选中英文，连按两次 Option") <= 3
    assert SWIFT.count('"退出句译"') == 1


def test_diagnostics_groups_repairs_settings_and_links_support_info():
    assert "DisclosureGroup" not in DIAGNOSTICS
    repair = DIAGNOSTICS.index('sectionTitle("状态与修复")')
    settings = DIAGNOSTICS.index('sectionTitle("设置")')
    for action in ('"重新检查"', '"辅助功能设置"', '"准备 Apple 语言包"', "model.legacyActionTitle"):
        assert repair < DIAGNOSTICS.index(action) < settings
    for block in ('"登录时自动打开句译"', '"测试当前翻译方式"', '"重新运行完整设置…"'):
        assert settings < DIAGNOSTICS.index(block)
    # Support info stacks on the diagnostics sheet instead of competing with
    # RootView's sheet presentation.
    assert 'Button("支持范围与隐私") { showSupportInfo = true }' in DIAGNOSTICS
    assert ".sheet(isPresented: $showSupportInfo) { SupportInfoView() }" in DIAGNOSTICS
    assert "@Environment(\\.dismiss) private var dismiss" in SUPPORT
    assert "model" not in SUPPORT


def test_home_has_no_dual_path_caveat_any_more():
    assert "兼容快捷键可能仍在运行" not in APP_VIEW
    assert "Hammerspoon" not in APP_VIEW + SUPPORT


def test_status_menu_has_six_groups_without_double_separators():
    menu = _between(SWIFT, "private func updateMenu(", "private func updateChrome()")
    order = ['item("句译 · ', 'item("打开句译…"', 'item("翻译方式")', "snapshot.primaryActionTitle",
             'item("诊断与帮助…"', "item(quitMenuTitle"]
    positions = [menu.index(marker) for marker in order]
    assert positions == sorted(positions)
    lines = [line.strip() for line in menu.splitlines() if "menu.addItem" in line]
    separators = [i for i, line in enumerate(lines) if line == "menu.addItem(.separator())"]
    assert len(separators) == 5
    assert all(b - a > 1 for a, b in zip(separators, separators[1:]))
