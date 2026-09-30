"""Contracts for phase 4B: the Python/Hammerspoon transport is gone, and what
early installations left behind is detected fail-closed and removed only by
an explicit user action (or by scripts/uninstall.sh)."""

import re
from pathlib import Path


ROOT = Path(__file__).parents[1]
CLEANUP = (ROOT / "macos" / "LegacyComponentCleanup.swift").read_text(encoding="utf-8")
APP = (ROOT / "macos" / "JuyiMenuBar.swift").read_text(encoding="utf-8")
FEATURE = (ROOT / "macos" / "NativeOptionFeature.swift").read_text(encoding="utf-8")
PROJECT = (ROOT / "Juyi.xcodeproj" / "project.pbxproj").read_text(encoding="utf-8")
BUILD = (ROOT / "scripts" / "build_macos_app.sh").read_text(encoding="utf-8")
RUNNER = (ROOT / "scripts" / "run_swift_tests.sh").read_text(encoding="utf-8")
UNINSTALL = (ROOT / "scripts" / "uninstall.sh").read_text(encoding="utf-8")

# Spelled in pieces so repository-wide greps for these tokens stay empty.
TRANSPORT_TOKENS = ("5432" + "1", "argos-translator" + ".lua", "hs-status" + ".json", "owner-request" + ".json")
SKIPPED_DIRS = {".git", "docs", "tmp", "build", "bin", "venv", ".venv", "logs", "__pycache__", "packages"}
SKIPPED_FILES = {"start_service.command"}
ALLOWED = {"scripts/uninstall.sh", "macos/LegacyComponentCleanup.swift"}


def _repository_files():
    for path in ROOT.rglob("*"):
        relative = path.relative_to(ROOT)
        if not path.is_file() or path.name in SKIPPED_FILES:
            continue
        if any(part in SKIPPED_DIRS for part in relative.parts):
            continue
        yield relative.as_posix(), path


def test_transport_and_handoff_stack_is_deleted():
    for removed in (
        "server.py", "translator.py", "config.py", "apple_engine.py", "volc_engine.py",
        "requirements.txt", "eval", "launchd", "hammerspoon", "apple",
        "scripts/install.sh", "scripts/bootstrap.sh", "scripts/launchd_install.sh",
        "scripts/launchd_uninstall.sh", "scripts/ensure_auth_token.sh",
        "scripts/hammerspoon_hook.sh", "scripts/build_apple_helper.sh", "scripts/smoke.py",
        "scripts/test_matrix.py", "scripts/test.sh", "tests/hammerspoon_runtime_test.lua",
        "macos/NativeOwnerHandoffProtocol.swift", "macos/NativeOwnerHandoffStore.swift",
        "macos/NativeOwnerHandoffWorkflow.swift", "macos/NativeOwnerHandoffStatusReader.swift",
        "macos/NativeOwnerActivationCoordinator.swift",
    ):
        assert not (ROOT / removed).exists(), removed
    requirements = (ROOT / "requirements-dev.txt").read_text(encoding="utf-8")
    assert "-r requirements.txt" not in requirements
    assert "httpx" not in requirements
    assert "pytest" in requirements and "ruff" in requirements


def test_transport_tokens_live_only_in_the_cleanup_paths():
    hits = set()
    checked = 0
    for relative, path in _repository_files():
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        checked += 1
        if any(token in text for token in TRANSPORT_TOKENS):
            hits.add(relative)
    assert checked > 50
    assert hits <= ALLOWED, sorted(hits - ALLOWED)
    assert "hs-status" + ".json" in CLEANUP
    assert "argos-translator" + ".lua" in UNINSTALL


def test_hammerspoon_is_named_only_by_the_cleanup_and_ui_strings():
    for path in (ROOT / "macos").rglob("*"):
        if not path.is_file() or path.name == "LegacyComponentCleanup.swift":
            continue
        try:
            text = path.read_text(encoding="utf-8")
        except UnicodeDecodeError:
            continue
        for line in text.splitlines():
            if "Hammerspoon" not in line:
                continue
            assert path.suffix == ".swift", path
            literals = "".join(re.findall(r'"(?:[^"\\]|\\.)*"', line))
            assert line.count("Hammerspoon") == literals.count("Hammerspoon"), line
    assert "org.hammerspoon.Hammerspoon" in CLEANUP
    assert "org.hammerspoon" not in APP + FEATURE


def test_cleanup_is_built_tested_and_wired():
    assert "LegacyComponentCleanup.swift in Sources" in PROJECT
    assert BUILD.count('"$ROOT/macos/LegacyComponentCleanup.swift"') == 1
    assert "run_suite LegacyComponentCleanupTests STRICT macos/LegacyComponentCleanup.swift" in RUNNER
    assert (ROOT / "tests" / "LegacyComponentCleanupTests.swift").is_file()
    assert "LegacyComponentCleanup.inventory(home: home)" in APP
    assert "LegacyComponentCleanup.perform(" in APP
    assert "NativeProductionTranslationCoordinator.shared.setLegacyComponentsDetected(" in APP


def test_cleanup_removes_only_owned_items():
    # The module symlink is owned only when it points at our module name;
    # a regular file or a foreign link is reported for manual handling.
    assert "destinationOfSymbolicLink(atPath: module)" in CLEANUP
    assert "(target as NSString).lastPathComponent == moduleName" in CLEANUP
    assert "result.manualItems.append(module)" in CLEANUP
    # Exactly one well-formed marker block; malformed blocks are left alone.
    assert 'beginMarker = "-- BEGIN argos-translator managed block"' in CLEANUP
    assert 'endMarker = "-- END argos-translator managed block"' in CLEANUP
    assert "begins.count == 1, ends.count == 1, begins[0] < ends[0]" in CLEANUP
    assert "guard effects.readFile(path) == original else" in CLEANUP
    # Only the early service LaunchAgent label family; the login item stays.
    assert 'name.hasPrefix("io.github.") && name.hasSuffix(".argos-translator.plist")' in CLEANUP
    # The private directory goes only once empty (rmdir never recurses).
    assert "removeDirectoryIfEmpty: { path in _ = rmdir(path) }" in CLEANUP
    assert "effects.removeDirectoryIfEmpty(inventory.configDirectory)" in CLEANUP
    for forbidden in ('".hammerspoon")', "Library/Logs", "UserDefaults", "/usr/bin/security", "SecItem"):
        assert forbidden not in CLEANUP, forbidden


def test_detection_is_cheap_and_never_on_the_trigger_path():
    inventory = CLEANUP.split("static func inventory(home: URL", 1)[1].split("static func state(of", 1)[0]
    for forbidden in ("Process(", "launchctl", "NSRunningApplication", "Task", "await"):
        assert forbidden not in inventory, forbidden
    pipeline = FEATURE.split("private func beginPipeline(target:", 1)[1].split(
        "private func suspendForAppleFailure", 1
    )[0]
    assert "LegacyComponentCleanup" not in pipeline
    assert "LegacyComponentCleanup" not in FEATURE


def test_uninstall_script_has_exactly_the_4b_scope():
    order = [
        UNINSTALL.index("\nquit_running_app\n"),
        UNINSTALL.index("\nunregister_service_management_login_item\n"),
        UNINSTALL.index("\nremove_fallback_login_item\n"),
        UNINSTALL.index('read -r -p "Delete Juyi\'s Volcengine access key from Keychain? [y/N] "'),
        UNINSTALL.index("\nremove_legacy_launch_agents\n"),
        UNINSTALL.index("if remove_owned_hammerspoon_module; then owned_module=1; fi"),
        UNINSTALL.index('remove_hammerspoon_managed_block "$owned_module"'),
        UNINSTALL.index('rm -rf "$CONFIG_DIR"'),
        UNINSTALL.index('move_owned_app_to_trash "$APP_PATH"'),
    ]
    assert order == sorted(order)
    assert 'KEYCHAIN_SERVICE="io.github.Eim-aa.juyi.volc"' in UNINSTALL
    assert 'LOGIN_LABEL="io.github.Eim-aa.Juyi.login-item"' in UNINSTALL
    assert '"$LAUNCH_AGENTS"/io.github.*.argos-translator.plist' in UNINSTALL
    assert '[[ "$(basename "$(readlink "$HS_MODULE")")" == "' + TRANSPORT_TOKENS[1] + '" ]]' in UNINSTALL
    assert "kept the malformed managed block" in UNINSTALL
    # The Keychain item is deleted only after an explicit "y".
    ask = UNINSTALL.split('read -r -p "Delete Juyi', 1)[1].split("esac", 1)[0]
    assert ask.index("y|Y|yes|YES)") < ask.index("delete_keychain_item")
    for removed in ("ROOT=", "venv", "hammerspoon_hook.sh", "brew ", "Library/Logs", "killall", "sudo "):
        assert removed not in UNINSTALL, removed
