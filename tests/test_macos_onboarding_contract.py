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
    enable = SWIFT.split("func enableNativeShortcut()", 1)[1].split("private func installBundledShortcut", 1)[0]
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
    init_body = SWIFT.split("init() {", 1)[1].split("var hammerspoonInstalled", 1)[0]
    assert "OnboardingPolicy.preferredEngine" in init_body
    assert "setEngine(" not in init_body


def test_service_repair_is_non_destructive_and_kickstart_first():
    body = SWIFT.split("func repairService()", 1)[1].split("func chooseApple()", 1)[0]
    assert '"bootout"' not in body
    assert '["kickstart", "-k", serviceTarget]' in body
    assert '["bootstrap", domain, target]' in body
    assert body.index('["kickstart", "-k"') < body.index('["bootstrap"')


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


def test_onboarding_mentions_hammerspoon_only_in_legacy_branches():
    status = _between(ONBOARDING, "private var shortcutStatus: ShortcutState", "private var legacyHandoffPending")
    native, legacy = status.split("guard legacyHandoffPending else { return canEnable }", 1)
    assert "Hammerspoon" not in native.replace("case .waitingForHammerspoon", "")
    assert "先安装 Hammerspoon" in legacy
    assert "legacyHandoffPending: Bool { model.nativeNeedsLegacyHandoff && !model.nativeOwnerBridgeReady }" in ONBOARDING

    footer = _between(ONBOARDING, "@ViewBuilder private var shortcutFooter", "private var practice: some View")
    native_footer, legacy_footer = footer.split("case .disabled where !legacyHandoffPending:", 1)
    assert "Hammerspoon" not in native_footer.replace("case .waitingForHammerspoon", "")
    assert "前往下载 Hammerspoon" in legacy_footer

    card = _between(ONBOARDING, "private var shortcutStatusCard", "private func preparationRow")
    assert card.index("if model.nativeNeedsLegacyHandoff {") < card.index("全新安装不需要 Hammerspoon")
    # Every hotkey problem state still has a status and a footer branch.
    for case in (".notInstalled", ".notRunning", ".heartbeatExpired", ".needsUpdate",
                 ".notAuthorized", ".notLoaded", ".paused", ".ready"):
        assert case in legacy and case in legacy_footer


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
    for action in ('"重新检查"', '"辅助功能设置"', '"准备 Apple 语言包"', '"停止云端翻译组件"', '"打开技术日志"'):
        assert repair < DIAGNOSTICS.index(action) < settings
    for block in ('"登录时自动打开句译"', '"测试当前翻译方式"', '"重新运行完整设置…"'):
        assert settings < DIAGNOSTICS.index(block)
    # Support info stacks on the diagnostics sheet instead of competing with
    # RootView's sheet presentation.
    assert 'Button("支持范围与隐私") { showSupportInfo = true }' in DIAGNOSTICS
    assert ".sheet(isPresented: $showSupportInfo) { SupportInfoView() }" in DIAGNOSTICS
    assert "@Environment(\\.dismiss) private var dismiss" in SUPPORT
    assert "model" not in SUPPORT


def test_home_compatibility_caveat_requires_legacy_components():
    caveat = APP_VIEW.index("兼容快捷键可能仍在运行")
    assert "&& model.nativeNeedsLegacyHandoff {" in APP_VIEW[caveat - 200:caveat]


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
