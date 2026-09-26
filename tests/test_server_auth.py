"""Bearer-token policy for the loopback HTTP service."""
import asyncio
import json
from types import SimpleNamespace

import server
from config import KeychainCredentialRead


class _Request:
    def __init__(self, path, method="GET", headers=None):
        self.url = SimpleNamespace(path=path)
        self.method = method
        self.headers = {"host": "127.0.0.1:54321", **(headers or {})}


async def _next(_request):
    return "allowed"


def test_bearer_header_comparison_is_exact_and_empty_token_is_never_valid():
    assert server._has_valid_auth_header("Bearer install-token", "install-token")
    assert not server._has_valid_auth_header("install-token", "install-token")
    assert not server._has_valid_auth_header("Bearer wrong", "install-token")
    assert not server._has_valid_auth_header("Bearer 密钥", "install-token")
    assert not server._has_valid_auth_header(None, "install-token")
    assert not server._has_valid_auth_header(None, "")


def test_token_protects_translate_pending_validation_and_metrics(monkeypatch):
    monkeypatch.setattr(server.config, "AUTH_TOKEN", "install-token")
    for path, method in (
        ("/translate", "POST"),
        ("/validate/volc-pending", "POST"),
        ("/metrics", "GET"),
    ):
        response = asyncio.run(
            server.require_json(_Request(path, method=method), _next)
        )
        assert response.status_code == 401
        assert response.headers["www-authenticate"] == "Bearer"
        assert json.loads(response.body) == {"error": "unauthorized"}


def test_valid_token_and_open_health_pass_request_policy(monkeypatch):
    monkeypatch.setattr(server.config, "AUTH_TOKEN", "install-token")
    authorized = _Request(
        "/translate",
        method="POST",
        headers={
            "authorization": "Bearer install-token",
            "content-type": "application/json",
        },
    )
    assert asyncio.run(server.require_json(authorized, _next)) == "allowed"
    assert asyncio.run(server.require_json(_Request("/health"), _next)) == "allowed"


def test_missing_install_token_fails_closed_by_default(monkeypatch):
    monkeypatch.setattr(server.config, "AUTH_TOKEN", "")
    monkeypatch.setattr(server.config, "ALLOW_UNAUTHENTICATED", False)
    request = _Request(
        "/translate", method="POST", headers={"content-type": "application/json"}
    )
    response = asyncio.run(server.require_json(request, _next))
    assert response.status_code == 503
    assert json.loads(response.body) == {"error": "local_auth_not_configured"}


def test_source_tree_development_requires_explicit_unauthenticated_opt_in(monkeypatch):
    monkeypatch.setattr(server.config, "AUTH_TOKEN", "")
    monkeypatch.setattr(server.config, "ALLOW_UNAUTHENTICATED", True)
    request = _Request(
        "/translate", method="POST", headers={"content-type": "application/json"}
    )
    assert asyncio.run(server.require_json(request, _next)) == "allowed"


def test_dns_rebinding_host_and_browser_origin_are_rejected(monkeypatch):
    monkeypatch.setattr(server.config, "AUTH_TOKEN", "install-token")
    bad_host = _Request("/health", headers={"host": "attacker.example:54321"})
    response = asyncio.run(server.require_json(bad_host, _next))
    assert response.status_code == 421
    assert json.loads(response.body) == {"error": "invalid_host"}

    browser = _Request(
        "/health",
        headers={"origin": "http://127.0.0.1:54321"},
    )
    response = asyncio.run(server.require_json(browser, _next))
    assert response.status_code == 403
    assert json.loads(response.body) == {"error": "browser_origin_not_allowed"}


def test_health_reports_whether_authentication_is_required(monkeypatch):
    class _Translator:
        def stats(self):
            return {"translations_total": 0}

    monkeypatch.setattr(server.Translator, "get_instance", lambda: _Translator())
    monkeypatch.setattr(server.apple_engine, "available", lambda: True)
    monkeypatch.setattr(server.config, "AUTH_TOKEN", "install-token")
    monkeypatch.setattr(server.config, "ALLOW_UNAUTHENTICATED", False)
    body = asyncio.run(server.health())
    assert body["ok"] is True
    assert body["auth_required"] is True
    assert body["auth_configured"] is True
    assert "translations_total" not in body

    monkeypatch.setattr(server.config, "AUTH_TOKEN", "")
    body = asyncio.run(server.health())
    assert body["ok"] is False
    assert body["auth_required"] is True
    assert body["auth_configured"] is False

    monkeypatch.setattr(server.config, "ALLOW_UNAUTHENTICATED", True)
    body = asyncio.run(server.health())
    assert body["ok"] is True
    assert body["auth_required"] is False
    assert body["auth_configured"] is False

    monkeypatch.setattr(server.config, "AUTH_TOKEN", "install-token")
    body = asyncio.run(server.health())
    assert body["auth_required"] is True


def test_health_keeps_resident_cloud_state_visible_during_removal(monkeypatch):
    monkeypatch.setattr(server.config, "VOLC_ACCESS_KEY", "resident-ak")
    monkeypatch.setattr(server.config, "VOLC_SECRET_KEY", "resident-sk")
    monkeypatch.setattr(server.config, "cloud_removal_blocks_volc", lambda: True)

    body = asyncio.run(server.health())

    assert body["cloud_removal_pending"] is True
    assert body["engines"]["volc"] is True


def test_pending_cloud_validation_reads_keychain_and_never_echoes_secrets(monkeypatch):
    credentials = ("AK-should-not-echo", "SK-should-not-echo")
    monkeypatch.setattr(
        server.config,
        "_load_keychain_credentials",
        lambda **_kwargs: KeychainCredentialRead("found", credentials),
    )
    monkeypatch.setattr(server.volc_engine, "translate_text", lambda *_args, **_kwargs: "好工具应该很轻松。")

    body = asyncio.run(server.validate_pending_volc())
    assert body["engine"] == "volc"
    assert body["result"]
    assert "AK-should-not-echo" not in repr(body)
    assert "SK-should-not-echo" not in repr(body)


def test_removal_marker_blocks_translate_and_pending_validation(monkeypatch):
    monkeypatch.setattr(server.config, "cloud_removal_blocks_volc", lambda: True)
    monkeypatch.setattr(
        server.config,
        "_load_keychain_credentials",
        lambda **_kwargs: (_ for _ in ()).throw(
            AssertionError("Keychain must not be read while removal is pending")
        ),
    )
    monkeypatch.setattr(
        server.Translator,
        "get_instance",
        lambda: (_ for _ in ()).throw(
            AssertionError("translator must not run for a blocked cloud request")
        ),
    )

    translated = asyncio.run(server.translate(server.TranslateRequest(text="hello", engine="volc")))
    validated = asyncio.run(server.validate_pending_volc())

    for response in (translated, validated):
        assert response.status_code == 409
        assert json.loads(response.body) == {
            "error": "cloud_removal_pending",
            "engine": "volc",
            "warnings": ["cloud_removal_pending"],
        }


def test_pending_cloud_validation_returns_stable_error_only(monkeypatch):
    secret = "SK-secret-in-upstream-error"
    monkeypatch.setattr(
        server.config,
        "_load_keychain_credentials",
        lambda **_kwargs: KeychainCredentialRead("found", ("AK", "SK")),
    )

    def fail(*_args, **_kwargs):
        raise RuntimeError(f"signature permission denied {secret}")

    monkeypatch.setattr(server.volc_engine, "translate_text", fail)
    response = asyncio.run(server.validate_pending_volc())
    decoded = json.loads(response.body)
    assert response.status_code == 400
    assert decoded["warnings"] == ["volc_credentials_or_permission"]
    assert secret not in response.body.decode("utf-8")
