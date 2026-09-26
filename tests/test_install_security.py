"""Behavioral contracts for the installer-owned local security files."""

import os
from pathlib import Path
import stat
import subprocess


ROOT = Path(__file__).parents[1]
HOOK = ROOT / "scripts" / "hammerspoon_hook.sh"
TOKEN_HELPER = ROOT / "scripts" / "ensure_auth_token.sh"
INSTALL = (ROOT / "scripts" / "install.sh").read_text(encoding="utf-8")
UNINSTALL = (ROOT / "scripts" / "uninstall.sh").read_text(encoding="utf-8")
LAUNCHD_UNINSTALL = (ROOT / "scripts" / "launchd_uninstall.sh").read_text(
    encoding="utf-8"
)
LAUNCHD_INSTALL = (ROOT / "scripts" / "launchd_install.sh").read_text(
    encoding="utf-8"
)
PLIST_TEMPLATE = (
    ROOT / "launchd" / "io.github.Eim-aa.argos-translator.plist.template"
).read_text(encoding="utf-8")
CONFIG = (ROOT / "config.py").read_text(encoding="utf-8")
SWIFT = (ROOT / "macos" / "JuyiMenuBar.swift").read_text(encoding="utf-8")
TEST_SCRIPT = (ROOT / "scripts" / "test.sh").read_text(encoding="utf-8")
BENCH_SCRIPT = (ROOT / "scripts" / "bench.sh").read_text(encoding="utf-8")

BEGIN = "-- BEGIN argos-translator managed block"
END = "-- END argos-translator managed block"
REQUIRE = 'require("argos-translator")'


def run(script: Path, home: Path, *args: str) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env["HOME"] = str(home)
    return subprocess.run(
        ["bash", str(script), *args],
        check=False,
        capture_output=True,
        text=True,
        env=env,
    )


def test_installer_roots_follow_the_checkout_and_launchd_accepts_custom_dest():
    root_expression = 'ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"'
    assert root_expression in INSTALL
    assert root_expression in LAUNCHD_INSTALL
    assert 'ROOT="$HOME/.local/share/argos-translator"' not in INSTALL
    assert "__ROOT__/venv/bin/python" in PLIST_TEMPLATE
    assert "__ROOT__/server.py" in PLIST_TEMPLATE
    assert "<key>JUYI_ROOT</key>" in PLIST_TEMPLATE
    assert "__ROOT__" in LAUNCHD_INSTALL
    assert 'os.environ.get("JUYI_ROOT"' in CONFIG
    assert 'dictionary["WorkingDirectory"]' in SWIFT
    assert 'ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"' in TEST_SCRIPT
    assert 'ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"' in BENCH_SCRIPT
    assert "__HOME__/Library/Logs/argos-translator.out.log" in PLIST_TEMPLATE
    assert "__HOME__/Library/Logs/argos-translator.err.log" in PLIST_TEMPLATE
    assert "__HOME__" in LAUNCHD_INSTALL
    assert "/Users/__USER__" not in PLIST_TEMPLATE


def test_regular_hammerspoon_module_is_never_overwritten(tmp_path):
    hs_dir = tmp_path / ".hammerspoon"
    hs_dir.mkdir()
    module = hs_dir / "argos-translator.lua"
    module.write_text("-- my custom module\n", encoding="utf-8")

    result = run(HOOK, tmp_path, "install")

    assert result.returncode != 0
    assert module.read_text(encoding="utf-8") == "-- my custom module\n"
    assert "refusing to replace" in result.stderr
    assert "backup" in result.stderr


def test_non_target_hammerspoon_symlink_is_never_repointed(tmp_path):
    hs_dir = tmp_path / ".hammerspoon"
    hs_dir.mkdir()
    other = tmp_path / "other.lua"
    other.write_text("-- other\n", encoding="utf-8")
    module = hs_dir / "argos-translator.lua"
    module.symlink_to(other)

    result = run(HOOK, tmp_path, "install")

    assert result.returncode != 0
    assert module.is_symlink()
    assert module.resolve() == other.resolve()
    assert "refusing to replace" in result.stderr


def test_exact_broken_legacy_symlink_is_migrated_without_claiming_other_links(tmp_path):
    hs_dir = tmp_path / ".hammerspoon"
    hs_dir.mkdir()
    init = hs_dir / "init.lua"
    init.write_text(f"{REQUIRE}\n", encoding="utf-8")
    legacy = tmp_path / ".local/share/argos-translator/hammerspoon/argos-translator.lua"
    module = hs_dir / "argos-translator.lua"
    module.symlink_to(legacy)
    assert module.is_symlink() and not module.exists()

    result = run(HOOK, tmp_path, "install")

    assert result.returncode == 0, result.stderr
    assert module.resolve() == ROOT / "hammerspoon" / "argos-translator.lua"


def test_arbitrary_broken_hammerspoon_symlink_is_never_repointed(tmp_path):
    hs_dir = tmp_path / ".hammerspoon"
    hs_dir.mkdir()
    module = hs_dir / "argos-translator.lua"
    target = tmp_path / "missing-custom.lua"
    module.symlink_to(target)

    result = run(HOOK, tmp_path, "install")

    assert result.returncode != 0
    assert module.is_symlink()
    assert os.readlink(module) == str(target)
    assert "refusing to replace" in result.stderr


def test_legacy_module_migration_never_follows_a_directory_symlink(tmp_path):
    hs_dir = tmp_path / ".hammerspoon"
    hs_dir.mkdir()
    init = hs_dir / "init.lua"
    init.write_text(f"{REQUIRE}\n", encoding="utf-8")
    legacy = tmp_path / ".local/share/argos-translator/hammerspoon/argos-translator.lua"
    legacy.mkdir(parents=True)
    sentinel = legacy / "keep.txt"
    sentinel.write_text("user-owned contents\n", encoding="utf-8")
    module = hs_dir / "argos-translator.lua"
    module.symlink_to(legacy, target_is_directory=True)

    result = run(HOOK, tmp_path, "install")

    assert result.returncode == 0, result.stderr
    assert module.is_symlink()
    assert module.resolve() == ROOT / "hammerspoon" / "argos-translator.lua"
    assert list(legacy.iterdir()) == [sentinel]
    assert sentinel.read_text(encoding="utf-8") == "user-owned contents\n"
    assert init.read_text(encoding="utf-8").count(REQUIRE) == 1
    assert not list(hs_dir.glob(".juyi-module-link.*"))


def test_install_migrates_legacy_require_and_is_idempotent(tmp_path):
    hs_dir = tmp_path / ".hammerspoon"
    hs_dir.mkdir()
    init = hs_dir / "init.lua"
    init.write_text(
        "local before = true\n"
        f"{REQUIRE}\n"
        "local after = true\n",
        encoding="utf-8",
    )

    first = run(HOOK, tmp_path, "install")
    assert first.returncode == 0, first.stderr
    module = hs_dir / "argos-translator.lua"
    assert module.is_symlink()
    assert module.resolve() == ROOT / "hammerspoon" / "argos-translator.lua"
    installed = init.read_text(encoding="utf-8")
    assert "local before = true" in installed
    assert "local after = true" in installed
    assert installed.count(BEGIN) == 1
    assert installed.count(END) == 1
    assert installed.count(REQUIRE) == 1

    second = run(HOOK, tmp_path, "install")
    assert second.returncode == 0, second.stderr
    assert init.read_text(encoding="utf-8") == installed


def test_uninstall_removes_only_owned_symlink_and_managed_block(tmp_path):
    hs_dir = tmp_path / ".hammerspoon"
    hs_dir.mkdir()
    init = hs_dir / "init.lua"
    init.write_text("local user_setting = true\n", encoding="utf-8")
    assert run(HOOK, tmp_path, "install").returncode == 0

    result = run(HOOK, tmp_path, "uninstall")

    assert result.returncode == 0, result.stderr
    assert not (hs_dir / "argos-translator.lua").exists()
    remaining = init.read_text(encoding="utf-8")
    assert "local user_setting = true" in remaining
    assert BEGIN not in remaining
    assert END not in remaining
    assert REQUIRE not in remaining


def test_uninstall_preserves_custom_module_and_its_legacy_require(tmp_path):
    hs_dir = tmp_path / ".hammerspoon"
    hs_dir.mkdir()
    module = hs_dir / "argos-translator.lua"
    module.write_text("-- custom\n", encoding="utf-8")
    init = hs_dir / "init.lua"
    init.write_text(f"{REQUIRE}\nlocal keep = true\n", encoding="utf-8")

    result = run(HOOK, tmp_path, "uninstall")

    assert result.returncode == 0
    assert module.read_text(encoding="utf-8") == "-- custom\n"
    assert init.read_text(encoding="utf-8") == f"{REQUIRE}\nlocal keep = true\n"
    assert "kept" in result.stderr


def test_managed_block_never_claims_identical_require_outside_markers(tmp_path):
    hs_dir = tmp_path / ".hammerspoon"
    hs_dir.mkdir()
    init = hs_dir / "init.lua"
    init.write_text(
        f"{REQUIRE}\n{BEGIN}\n{REQUIRE}\n{END}\nlocal keep = true\n",
        encoding="utf-8",
    )

    installed = run(HOOK, tmp_path, "install")
    assert installed.returncode == 0, installed.stderr
    assert init.read_text(encoding="utf-8").count(REQUIRE) == 2

    removed = run(HOOK, tmp_path, "uninstall")
    assert removed.returncode == 0, removed.stderr
    remaining = init.read_text(encoding="utf-8")
    assert remaining.count(REQUIRE) == 1
    assert "local keep = true" in remaining


def test_existing_auth_token_is_preserved_and_permissions_are_repaired(tmp_path):
    first = run(TOKEN_HELPER, tmp_path)
    assert first.returncode == 0, first.stderr
    config = tmp_path / ".config" / "argos-translator"
    token = config / "auth-token"
    generated = token.read_text(encoding="utf-8")
    assert len(generated.strip()) == 64
    assert stat.S_IMODE(config.stat().st_mode) == 0o700
    assert stat.S_IMODE(token.stat().st_mode) == 0o600
    assert generated.strip() not in first.stdout
    assert generated.strip() not in first.stderr

    preserved = "ab" * 32 + "\n"
    token.write_text(preserved, encoding="utf-8")
    token.chmod(0o644)
    second = run(TOKEN_HELPER, tmp_path)
    assert second.returncode == 0, second.stderr
    assert token.read_text(encoding="utf-8") == preserved
    assert stat.S_IMODE(token.stat().st_mode) == 0o600
    assert preserved.strip() not in second.stdout
    assert preserved.strip() not in second.stderr


def test_invalid_existing_auth_token_fails_without_overwriting(tmp_path):
    config = tmp_path / ".config" / "argos-translator"
    config.mkdir(parents=True)
    token = config / "auth-token"
    token.write_text("too-short\n", encoding="utf-8")

    result = run(TOKEN_HELPER, tmp_path)

    assert result.returncode != 0
    assert token.read_text(encoding="utf-8") == "too-short\n"
    assert "expected exactly 64 lowercase hexadecimal" in result.stderr
    assert "too-short" not in result.stdout

    multiple = "ab" * 32 + "\n" + "cd" * 32 + "\n"
    token.write_text(multiple, encoding="utf-8")
    second = run(TOKEN_HELPER, tmp_path)
    assert second.returncode != 0
    assert token.read_text(encoding="utf-8") == multiple


def test_auth_token_helper_rejects_symlink_without_touching_target(tmp_path):
    config = tmp_path / ".config" / "argos-translator"
    config.mkdir(parents=True)
    target = tmp_path / "do-not-touch"
    target.write_text("private\n", encoding="utf-8")
    (config / "auth-token").symlink_to(target)

    result = run(TOKEN_HELPER, tmp_path)

    assert result.returncode != 0
    assert target.read_text(encoding="utf-8") == "private\n"
    assert "regular, non-symlink file" in result.stderr


def test_hammerspoon_reload_never_uses_killall():
    hook = HOOK.read_text(encoding="utf-8")
    assert "killall Hammerspoon" not in hook
    assert "killall Hammerspoon" not in INSTALL
    assert "hs.reload()" in hook
    assert "Reload Config" in hook
    assert "command -v hs" not in hook


def test_launchd_install_restores_previous_plist_and_service_on_failure():
    assert 'previous_target="$(mktemp "$TARGET.previous.XXXXXX")"' in LAUNCHD_INSTALL
    assert 'cp -p "$TARGET" "$previous_target"' in LAUNCHD_INSTALL
    assert "restore_previous()" in LAUNCHD_INSTALL
    assert 'if ! launchctl bootstrap "$DOMAIN" "$TARGET"' in LAUNCHD_INSTALL
    assert 'mv "$previous_target" "$TARGET"' in LAUNCHD_INSTALL
    assert 'launchctl bootstrap "$DOMAIN" "$TARGET"' in LAUNCHD_INSTALL
    assert 'legacy_previous="$(mktemp "$LEGACY_PLIST.previous.XXXXXX")"' in LAUNCHD_INSTALL
    assert "restore_legacy()" in LAUNCHD_INSTALL
    assert 'launchctl bootstrap "$DOMAIN" "$LEGACY_PLIST"' in LAUNCHD_INSTALL
    assert 'response.status != 200' in LAUNCHD_INSTALL
    assert 'body.get("ok") is not True' in LAUNCHD_INSTALL
    assert 'body.get("auth_configured") is not True' in LAUNCHD_INSTALL
    assert 'if [[ "$health_ready" -ne 1 ]]' in LAUNCHD_INSTALL
    assert 'launchctl bootout "$DOMAIN/$LABEL" || true' not in LAUNCHD_INSTALL
    assert "partial replacement is still loaded; kept its matching plist" in LAUNCHD_INSTALL
    assert "replacement job is still loaded; kept its matching plist" in LAUNCHD_INSTALL
    assert LAUNCHD_INSTALL.index('if ! launchctl bootstrap "$DOMAIN" "$TARGET"') < (
        LAUNCHD_INSTALL.index('rm -f "$LEGACY_PLIST"')
    )


def test_uninstaller_removes_only_owned_native_artifacts_and_never_prints_keys():
    assert 'APP_BUNDLE_ID="io.github.Eim-aa.Juyi"' in UNINSTALL
    assert "CFBundleIdentifier" in UNINSTALL
    assert 'LOGIN_LABEL="io.github.Eim-aa.Juyi.login-item"' in UNINSTALL
    assert "fallback_login_item_is_owned" in UNINSTALL
    assert "ProgramArguments:0" in UNINSTALL
    assert "ProgramArguments:1" in UNINSTALL
    assert 'KEYCHAIN_SERVICE="io.github.Eim-aa.juyi.volc"' in UNINSTALL
    assert 'KEYCHAIN_ACCOUNT="volc"' in UNINSTALL
    assert 'PENDING_KEYCHAIN_SERVICE="io.github.Eim-aa.juyi.volc.pending"' in UNINSTALL
    assert 'PENDING_KEYCHAIN_ACCOUNT="pending"' in UNINSTALL
    assert "delete-generic-password" in UNINSTALL
    assert "find-generic-password" in UNINSTALL
    assert "find-generic-password -w" not in UNINSTALL
    assert '"$executable" --unregister-login-item' in UNINSTALL
    assert "runningApplicationsWithBundleIdentifier" in UNINSTALL
    assert "killall Juyi" not in UNINSTALL
    assert "$HOME/.Trash/句译-已卸载-" in UNINSTALL
    assert 'bundle identifier does not match $APP_BUNDLE_ID' in UNINSTALL
    assert UNINSTALL.index("unregister_service_management_login_item") < UNINSTALL.index(
        'rm -f "$PLIST"'
    )


def test_uninstallers_never_delete_files_while_service_remains_loaded():
    for script, removal in (
        (UNINSTALL, 'rm -f "$PLIST"'),
        (LAUNCHD_UNINSTALL, 'rm -f "$TARGET"'),
    ):
        assert 'if ! launchctl bootout "$DOMAIN/$LABEL"' in script
        assert 'launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then' in script
        assert script.index('if ! launchctl bootout "$DOMAIN/$LABEL"') < script.index(removal)
