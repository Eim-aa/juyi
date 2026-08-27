"""Contracts for the native app's install location and login-item UX."""

import os
from pathlib import Path


ROOT = Path(__file__).parents[1]
INSTALLER_PATH = ROOT / "scripts" / "install_macos_app.sh"
INSTALLER = INSTALLER_PATH.read_text(encoding="utf-8")
INSTALL_ALL = (ROOT / "scripts" / "install.sh").read_text(encoding="utf-8")
BOOTSTRAP = (ROOT / "scripts" / "bootstrap.sh").read_text(encoding="utf-8")
BUILD = (ROOT / "scripts" / "build_macos_app.sh").read_text(encoding="utf-8")
SWIFT = (ROOT / "macos" / "JuyiMenuBar.swift").read_text(encoding="utf-8")
FRAME_POLICY = (ROOT / "macos" / "WindowFramePolicy.swift").read_text(encoding="utf-8")
CI = (ROOT / ".github" / "workflows" / "ci.yml").read_text(encoding="utf-8")


def test_all_install_entries_reject_pre_macos_15_before_any_state_change():
    bootstrap_guard = BOOTSTRAP.index("\nrequire_macos_15\n")
    for operation in (
        'command -v git',
        'git -C "$DEST" fetch',
        'git -C "$DEST" checkout',
        'git -C "$DEST" merge',
        'mkdir -p "$(dirname "$DEST")"',
        'git clone --depth=1',
        'exec "$DEST/scripts/install.sh"',
    ):
        assert bootstrap_guard < BOOTSTRAP.index(operation, bootstrap_guard)
    assert "未更新源码、服务、Hammerspoon 或 App；现有安装已保留" in BOOTSTRAP

    full_guard = INSTALL_ALL.index("\nrequire_macos_15\n")
    for operation in (
        '"$ROOT/scripts/hammerspoon_hook.sh" check',
        '"$ROOT/scripts/ensure_auth_token.sh"',
        'mkdir -p "$ROOT"',
        '"$PYTHON" -m venv',
        '"$ROOT/scripts/launchd_install.sh"',
        '"$ROOT/scripts/hammerspoon_hook.sh" install',
        '"$ROOT/scripts/build_apple_helper.sh"',
        '"$ROOT/scripts/install_macos_app.sh"',
    ):
        assert full_guard < INSTALL_ALL.index(operation)
    assert "现有安装已保留" in INSTALL_ALL
    assert "configure the Volcengine cloud option" not in INSTALL_ALL

    app_guard = INSTALLER.index("\nrequire_macos_15\n")
    for operation in (
        'if [[ "${1:-}" == "--install-helper" ]]',
        '"$ROOT/scripts/build_macos_app.sh"',
        "STAGING_ROOT=",
        "quit_running_app",
        'install_verified_app "$STAGED_APP"',
    ):
        assert app_guard < INSTALLER.index(operation, app_guard)
    assert "现有 App 与服务已保留" in INSTALLER


def test_native_installer_targets_system_applications_and_is_executable():
    assert 'DEST="/Applications/句译.app"' in INSTALLER
    assert not any(
        line.startswith('DEST="$HOME/Applications/')
        for line in INSTALLER.splitlines()
    )
    assert os.access(INSTALLER_PATH, os.X_OK)


def test_privileged_install_validates_before_and_after_replacement():
    assert "with administrator privileges" in INSTALLER
    assert "/usr/bin/codesign --verify --deep --strict" in INSTALLER
    assert "CFBundleShortVersionString" in INSTALLER
    assert "CFBundleVersion" in INSTALLER
    assert "CFBundleIdentifier" in INSTALLER
    assert 'APP_BUNDLE_ID="io.github.Eim-aa.Juyi"' in INSTALLER
    assert 'validate_app "$STAGED_APP"' in INSTALLER
    assert 'validate_app "$DEST"' in INSTALLER
    helper = INSTALLER.split('if [[ "${1:-}" == "--install-helper" ]]', 1)[0]
    assert helper.index('require_owned_or_absent "$destination"') < helper.index(
        '/bin/mv "$destination" "$previous"'
    )
    assert '[[ "$had_previous" -eq 1 ]] && /bin/rm -rf "$previous"' not in INSTALLER


def test_legacy_copy_is_unregistered_then_moved_only_after_validation():
    validation = INSTALLER.index('validate_app "$DEST"')
    migration = INSTALLER.index('if [[ -e "$LEGACY_DEST" || -L "$LEGACY_DEST" ]]')
    ownership = INSTALLER.index('app_is_owned "$LEGACY_DEST"', migration)
    unregister = INSTALLER.index('"$LSREGISTER" -u "$LEGACY_DEST"')
    register_new = INSTALLER.index('"$LSREGISTER" -f "$DEST"', unregister)
    move = INSTALLER.index('/bin/mv "$LEGACY_DEST" "$legacy_backup"')
    assert validation < migration < ownership < unregister < register_new < move
    assert '/bin/rm -rf "$LEGACY_DEST"' not in INSTALLER
    assert "$HOME/.Trash/句译-旧版-" in INSTALLER


def test_native_installer_quits_only_the_expected_bundle_and_never_killalls():
    assert "runningApplicationsWithBundleIdentifier" in INSTALLER
    assert '"$APP_BUNDLE_ID"' in INSTALLER
    assert "killall Juyi" not in INSTALLER
    assert "request_app_quit" in INSTALLER
    assert "still running" in INSTALLER


def test_installer_registers_and_opens_verified_system_app():
    assert '"$LSREGISTER" -f "$DEST"' in INSTALLER
    assert '/usr/bin/open "$DEST"' in INSTALLER


def test_full_installer_reuses_native_installer_without_home_copy():
    assert '"$ROOT/scripts/install_macos_app.sh"' in INSTALL_ALL
    assert '"$HOME/Applications/句译.app"' not in INSTALL_ALL
    assert 'Open 句译 from Applications or Launchpad.' in INSTALL_ALL


def test_service_management_login_item_contract_is_visible_and_non_blocking():
    assert "import ServiceManagement" in SWIFT
    assert "SMAppService.mainApp" in SWIFT
    assert "try SMAppService.mainApp.register()" in SWIFT
    assert "try service.unregister()" in SWIFT
    for state in (".enabled", ".notRegistered", ".requiresApproval", ".notFound"):
        assert state in SWIFT
    assert "登录时自动打开句译" in SWIFT
    assert "SMAppService.openSystemSettingsLoginItems()" in SWIFT
    assert "这不会影响现在使用翻译" in SWIFT


def test_native_app_exposes_login_item_unregistration_for_uninstall():
    main = SWIFT.split("@main enum JuyiMain", 1)[1]
    assert 'contains("--unregister-login-item")' in main
    assert "try service.unregister()" in main
    assert main.index("--unregister-login-item") < main.index("NSApplication.shared")
    assert "runningApplications(withBundleIdentifier: appBundleIdentifier)" in main
    assert "first { $0.processIdentifier != getpid() }" in main
    assert main.index("if let duplicate") < main.index("NSApplication.shared")


def test_not_found_uses_validated_launch_agent_fallback_only_from_applications():
    body = SWIFT.split("private func configureDefaultLoginItemIfNeeded()", 1)[1]
    body = body.split("func setLoginItemEnabled", 1)[0]
    assert "loginItemBackend == .launchAgent" in body
    assert "SMAppService.mainApp.status != .notFound" in body
    assert 'fallbackLoginItemLabel = "io.github.Eim-aa.Juyi.login-item"' in SWIFT
    assert 'fallbackLoginItemExecutable = "/Applications/句译.app/Contents/MacOS/Juyi"' in SWIFT
    assert 'URL(fileURLWithPath: "/Applications/句译.app"' in SWIFT
    assert "fallbackLoginItemCanBeInstalled" in SWIFT
    assert "isExecutableFile(atPath: fallbackLoginItemExecutable)" in SWIFT


def test_fallback_plist_is_atomic_exact_and_has_no_keepalive():
    fallback = SWIFT.split("nonisolated private static func setFallbackLoginItem", 1)[1]
    fallback = fallback.split("private func readLocalState", 1)[0]
    assert '"ProgramArguments": [fallbackLoginItemExecutable, "--login-item"]' in fallback
    assert '"RunAtLoad": true' in fallback
    assert '"KeepAlive": false' in fallback
    assert "/usr/bin/open" not in fallback
    assert "data.write(to: temporary, options: .atomic)" in fallback
    assert "fallbackLoginItemIsValid(at: temporary)" in fallback
    assert "replaceItemAt" in fallback
    assert "fallbackLoginItemIsValid(at: plistURL)" in fallback
    assert 'launchctl(["bootstrap", domain, plistURL.path])' in fallback
    assert 'launchctl(["bootout", target])' in fallback


def test_fallback_disable_cannot_bootout_its_own_process():
    disable = SWIFT.split("if !enabled {", 1)[1].split("guard fallbackLoginItemCanBeInstalled", 1)[0]
    remove = disable.index("fileManager.removeItem(at: plistURL)")
    bootout = disable.index('launchctl(["bootout", target])')
    assert remove < bootout
    assert "if !launchedByFallback" in disable


def test_signed_build_migration_never_removes_working_fallback_early():
    migration = SWIFT.split("private func migrateFallbackToServiceManagementIfNeeded()", 1)[1]
    migration = migration.split("nonisolated private static func fallbackLoginItemCanBeInstalled", 1)[0]
    assert "SMAppService.mainApp.status == .notRegistered" in migration
    assert "SMAppService.mainApp.status == .enabled" in migration
    assert migration.index("status == .enabled") < migration.index("enabled: false")
    assert "if !removed" in migration
    assert "SMAppService.mainApp.unregister()" in migration
    assert "status == .notRegistered || status == .enabled" in migration
    became_active = SWIFT.split("func applicationBecameActive()", 1)[1]
    became_active = became_active.split("private func readLocalState", 1)[0]
    assert "migrateFallbackToServiceManagementIfNeeded()" in became_active


def test_login_item_launch_stays_quiet_but_manual_launch_opens_window():
    assert "keyAELaunchedAsLogInItem" in SWIFT
    assert 'ProcessInfo.processInfo.arguments.contains("--login-item")' in SWIFT
    assert "NSRunningApplication.runningApplications(withBundleIdentifier: appBundleIdentifier)" in SWIFT
    assert "$0.processIdentifier != getpid()" in SWIFT
    app_main = SWIFT.split("@main enum JuyiMain", 1)[1]
    assert app_main.index("if ProcessInfo.processInfo.arguments.contains") < app_main.index("NSApplication.shared")
    launch = SWIFT.split("func applicationDidFinishLaunching", 1)[1]
    launch = launch.split("func applicationShouldHandleReopen", 1)[0]
    assert "let isLoginLaunch = launchedFromLogin" in launch
    assert "if !isLoginLaunch { showWindow() }" in launch
    assert "func applicationShouldHandleReopen" in SWIFT
    assert "showWindow(); return true" in SWIFT
    show = SWIFT.split("@objc private func showWindow()", 1)[1].split("@objc private func onboarding", 1)[0]
    assert "window.isMiniaturized" in show
    assert "window.deminiaturize(nil)" in show
    assert show.index("deminiaturize") < show.index("makeKeyAndOrderFront")


def test_build_links_service_management_and_keeps_dock_and_menu_bar():
    assert BUILD.count("-framework ServiceManagement") == 1
    assert BUILD.count('"$ROOT/macos/WindowFramePolicy.swift"') == 1
    info = (ROOT / "macos" / "Info.plist").read_text(encoding="utf-8")
    assert "$(MARKETING_VERSION)" in info
    assert "$(CURRENT_PROJECT_VERSION)" in info
    assert "$(MACOSX_DEPLOYMENT_TARGET)" in info
    assert "LSUIElement" not in info
    assert "NSApp.setActivationPolicy(.regular)" in SWIFT
    assert "applicationShouldTerminateAfterLastWindowClosed" in SWIFT
    assert 'NSStatusBar.system.statusItem' in SWIFT


def test_ci_builds_the_native_app_and_apple_translation_helper():
    assert "runs-on: macos-15" in CI
    assert "xcodebuild -quiet -project Juyi.xcodeproj -scheme Juyi" in CI
    assert "-configuration Debug" in CI
    assert "-configuration Release" in CI
    assert "scripts/verify_macos_binary.sh" in CI
    assert "scripts/build_macos_app.sh" in CI
    assert "scripts/build_apple_helper.sh" in CI


def test_window_frame_policy_preserves_valid_positions_and_repairs_before_show():
    assert "usableFrames.contains(where: { $0.contains(frame) })" in FRAME_POLICY
    assert "intersectionArea" in FRAME_POLICY
    assert "intersection(frame)" in FRAME_POLICY
    assert "preferred ?? usableFrames[0]" in FRAME_POLICY
    assert "min(frame.width, target.width)" in FRAME_POLICY
    assert "min(frame.height, target.height)" in FRAME_POLICY
    assert "window.center()" not in SWIFT
    assert "let screens = NSScreen.screens" in SWIFT
    assert "window.screen ?? NSScreen.main ?? screens.first" in SWIFT
    assert "screens.map(\\.visibleFrame)" in SWIFT

    create = SWIFT.split("private func createWindow()", 1)[1].split("private func installMainMenu", 1)[0]
    assert "ensureWindowVisible(forceCenter: true)" in create

    show = SWIFT.split("@objc private func showWindow()", 1)[1].split("@objc private func onboarding", 1)[0]
    assert show.index("ensureWindowVisible()") < show.index("makeKeyAndOrderFront")


def test_completion_and_docs_name_the_discoverable_install_location():
    message = "句译会留在 Dock 和菜单栏，关闭窗口不会停止翻译。"
    assert message in SWIFT
    for relative in ("README.md", "README_EN.md", "docs/MENU_BAR_APP.md"):
        text = (ROOT / relative).read_text(encoding="utf-8")
        assert "~/Applications/句译.app" not in text
        assert "/Applications/句译.app" in text
