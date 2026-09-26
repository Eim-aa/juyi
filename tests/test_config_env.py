"""Credential configuration parsers and legacy fallback behavior."""
import importlib.util
import subprocess
import sys
from pathlib import Path

import config as production_config

from config import (
    KeychainCredentialRead,
    VOLC_KEYCHAIN_ACCOUNT,
    VOLC_KEYCHAIN_SERVICE,
    _load_auth_token,
    _read_cloud_removal_marker,
    _load_env_file,
    _load_keychain_credentials,
    _parse_keychain_credentials,
    _resolve_volc_credentials,
    cloud_removal_blocks_volc,
)


def test_missing_file_returns_empty(tmp_path):
    assert _load_env_file(tmp_path / "nope.env") == {}


def test_basic_parsing(tmp_path):
    p = tmp_path / "volc.env"
    p.write_text(
        "# comment\n"
        "\n"
        "NOEQUALS\n"
        "A=plain\n"
        "  B  =  spaced  \n"
        "C=a=b\n",
        encoding="utf-8",
    )
    out = _load_env_file(p)
    assert out == {"A": "plain", "B": "spaced", "C": "a=b"}


def test_quoted_values_are_unwrapped(tmp_path):
    p = tmp_path / "volc.env"
    p.write_text(
        'A="abc"\n'
        "B='xyz'\n"
        'D="unmatched\n'
        'E=in"side"quotes\n'
        'F=""\n',
        encoding="utf-8",
    )
    out = _load_env_file(p)
    assert out["A"] == "abc"
    assert out["B"] == "xyz"
    assert out["D"] == '"unmatched'      # unmatched quote left alone
    assert out["E"] == 'in"side"quotes'  # inner quotes left alone
    assert out["F"] == ""


def test_auth_token_accepts_only_installer_shaped_value(tmp_path):
    token = tmp_path / "auth-token"
    assert _load_auth_token(token) == ""
    token.write_text("  " + "a" * 64 + "\n", encoding="utf-8")
    token.chmod(0o600)
    assert _load_auth_token(token) == "a" * 64
    for invalid in ("", "short", "A" * 64, "g" * 64, "a" * 63, "a" * 65):
        token.write_text(invalid, encoding="utf-8")
        token.chmod(0o600)
        assert _load_auth_token(token) == ""

    token.write_text("a" * 64, encoding="utf-8")
    token.chmod(0o644)
    assert _load_auth_token(token) == ""


def test_auth_token_rejects_symlink(tmp_path):
    target = tmp_path / "real-token"
    target.write_text("a" * 64, encoding="utf-8")
    target.chmod(0o600)
    link = tmp_path / "auth-token"
    link.symlink_to(target)
    assert _load_auth_token(link) == ""


def test_cloud_removal_marker_only_allows_cloud_when_confirmed_absent(tmp_path):
    marker = tmp_path / "cloud-removal-pending"
    assert _read_cloud_removal_marker(marker) == "not_found"
    assert cloud_removal_blocks_volc(marker) is False

    marker.write_bytes(b"1\n")
    marker.chmod(0o600)
    assert _read_cloud_removal_marker(marker) == "present"
    assert cloud_removal_blocks_volc(marker) is True

    marker.chmod(0o644)
    assert _read_cloud_removal_marker(marker) == "unavailable"
    assert cloud_removal_blocks_volc(marker) is True

    marker.chmod(0o600)
    marker.write_bytes(b"invalid\n")
    assert _read_cloud_removal_marker(marker) == "unavailable"
    assert cloud_removal_blocks_volc(marker) is True


def test_cloud_removal_marker_rejects_symlinks(tmp_path):
    target = tmp_path / "marker-target"
    target.write_bytes(b"1\n")
    target.chmod(0o600)
    marker = tmp_path / "cloud-removal-pending"
    marker.symlink_to(target)
    assert _read_cloud_removal_marker(marker) == "unavailable"
    assert cloud_removal_blocks_volc(marker) is True


def test_import_with_removal_marker_does_not_load_cloud_secrets(tmp_path, monkeypatch):
    config_dir = tmp_path / ".config" / "argos-translator"
    config_dir.mkdir(parents=True, mode=0o700)
    marker = config_dir / "cloud-removal-pending"
    marker.write_bytes(b"1\n")
    marker.chmod(0o600)
    (config_dir / "volc.env").write_text(
        "VOLC_ACCESS_KEY=legacy-ak\nVOLC_SECRET_KEY=legacy-sk\nENGINE=volc\n",
        encoding="utf-8",
    )
    monkeypatch.setenv("HOME", str(tmp_path))

    def reject_keychain(*_args, **_kwargs):
        raise AssertionError("removal startup must not read Keychain")

    monkeypatch.setattr(subprocess, "run", reject_keychain)
    module_name = "_juyi_config_removal_startup_test"
    spec = importlib.util.spec_from_file_location(module_name, Path(production_config.__file__))
    assert spec is not None and spec.loader is not None
    isolated = importlib.util.module_from_spec(spec)
    sys.modules[module_name] = isolated
    try:
        spec.loader.exec_module(isolated)
    finally:
        sys.modules.pop(module_name, None)

    assert isolated.VOLC_ACCESS_KEY == ""
    assert isolated.VOLC_SECRET_KEY == ""
    assert isolated.ENGINE == "apple"


def test_keychain_json_parser_accepts_only_complete_string_credentials():
    assert _parse_keychain_credentials(
        '{"access_key":"  AKTEST  ","secret_key":" SKTEST "}'
    ) == ("AKTEST", "SKTEST")
    assert _parse_keychain_credentials("not json") is None
    assert _parse_keychain_credentials("[]") is None
    assert _parse_keychain_credentials('{"access_key":"AKTEST"}') is None
    assert _parse_keychain_credentials(
        '{"access_key":"AKTEST","secret_key":42}'
    ) is None


def test_keychain_reader_uses_security_without_credentials_in_argv():
    calls = []

    def fake_runner(args, **kwargs):
        calls.append((args, kwargs))
        return subprocess.CompletedProcess(
            args, 0, stdout='{"access_key":"AKTEST","secret_key":"SKTEST"}'
        )

    assert _load_keychain_credentials(fake_runner) == KeychainCredentialRead(
        "found", ("AKTEST", "SKTEST")
    )
    args, kwargs = calls[0]
    assert args == [
        "/usr/bin/security",
        "find-generic-password",
        "-s",
        VOLC_KEYCHAIN_SERVICE,
        "-a",
        VOLC_KEYCHAIN_ACCOUNT,
        "-w",
    ]
    assert "AKTEST" not in args and "SKTEST" not in args
    assert kwargs["stderr"] is subprocess.DEVNULL
    assert kwargs["check"] is False


def test_only_explicit_keychain_not_found_falls_back_to_legacy_env():
    def missing_item(args, **kwargs):
        return subprocess.CompletedProcess(args, 44, stdout="")

    def malformed_item(args, **kwargs):
        return subprocess.CompletedProcess(args, 0, stdout="not json")

    legacy = {"VOLC_ACCESS_KEY": "legacy-ak", "VOLC_SECRET_KEY": "legacy-sk"}
    not_found = _load_keychain_credentials(missing_item)
    assert not_found == KeychainCredentialRead("not_found")
    assert _resolve_volc_credentials(not_found, legacy) == ("legacy-ak", "legacy-sk")

    invalid = _load_keychain_credentials(malformed_item)
    assert invalid == KeychainCredentialRead("invalid")
    assert _resolve_volc_credentials(invalid, legacy) == ("", "")

    def unavailable(args, **kwargs):
        return subprocess.CompletedProcess(args, 36, stdout="")

    unavailable_read = _load_keychain_credentials(unavailable)
    assert unavailable_read == KeychainCredentialRead("unavailable")
    assert _resolve_volc_credentials(unavailable_read, legacy) == ("", "")


def test_keychain_credentials_take_precedence_over_legacy_env():
    assert _resolve_volc_credentials(
        KeychainCredentialRead("found", ("keychain-ak", "keychain-sk")),
        {"VOLC_ACCESS_KEY": "legacy-ak", "VOLC_SECRET_KEY": "legacy-sk"},
    ) == ("keychain-ak", "keychain-sk")
