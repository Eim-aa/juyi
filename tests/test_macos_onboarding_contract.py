"""Static contract checks for the dependency-free native macOS shell.

The policy has executable Swift tests, while these checks protect the complete
product flow from accidental removal in both Xcode and legacy-script builds.
"""

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
    assert "切换到另一个 App，选中一段英文" in SWIFT
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
    assert "切换到 Apple 离线并启用" in SWIFT
    assert 'if hasCloudConfiguration { return "volc" }' not in POLICY
    assert "onboardingEngineReady" not in POLICY.split("firstIncompleteScreen", 1)[1].split("}", 1)[0]


def test_accessible_scroll_layout_and_window_policy_are_wired():
    assert "@AccessibilityFocusState" in SWIFT
    assert "permissionTroubleshooting" in SWIFT
    assert "practiceTroubleshooting" in SWIFT
    assert "onboardingFooter.padding" in SWIFT
    assert "window.titleVisibility = .hidden" in SWIFT
    assert "guard lastOnboardingMode != mode" in SWIFT
    assert "max(current.width, target.width)" in SWIFT


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
