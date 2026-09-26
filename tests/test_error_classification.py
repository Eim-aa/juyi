"""Engine failures expose stable codes, never raw upstream error text."""

import asyncio
import functools

import translator


def test_error_classifier_returns_only_stable_codes():
    secret = "AKFAKE1234567890 SKFAKE1234567890"
    cases = [
        ("volc", RuntimeError(f"signature denied {secret}"), "volc_credentials_or_permission"),
        ("volc", RuntimeError(f"network connection failed {secret}"), "volc_network"),
        ("apple", RuntimeError(f"helper timeout {secret}"), "apple_timeout_or_language_pack"),
        ("apple", RuntimeError(f"helper died {secret}"), "apple_helper_error"),
    ]
    for engine, error, expected in cases:
        result = translator.classify_engine_error(engine, error)
        assert result == expected
        assert "AKFAKE" not in result
        assert "SKFAKE" not in result


def test_run_engine_never_places_raw_exception_in_warnings(monkeypatch):
    secret = "VOLC_SECRET_KEY=SK-should-never-leak"

    @functools.lru_cache(maxsize=1)
    def fail(_text):
        raise RuntimeError(f"volc api failure {secret}")

    monkeypatch.setitem(translator._ENGINE_FNS, "volc", fail)
    instance = translator.Translator()
    result = translator.Result(engine="volc")
    asyncio.run(instance._run_engine("volc", "hello", result))

    assert result.error == "volc_error"
    assert result.warnings == ["volc_api_error"]
    assert secret not in repr(result)
