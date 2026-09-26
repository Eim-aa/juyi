"""resolve_engine(): the per-request mapping and two-way fallback chain."""
import asyncio
import functools

import translator
from translator import resolve_engine


def test_default_used_when_no_request():
    assert resolve_engine(None, "apple", True, True) == ("apple", [])
    assert resolve_engine(None, "volc", True, True) == ("volc", [])


def test_request_overrides_default():
    assert resolve_engine("volc", "apple", True, True) == ("volc", [])
    assert resolve_engine("apple", "volc", True, True) == ("apple", [])


def test_legacy_argos_maps_to_apple_with_warning():
    eng, warnings = resolve_engine("argos", "volc", True, True)
    assert eng == "apple"
    assert warnings == ["argos_engine_removed_using_apple"]


def test_unknown_engine_falls_back_to_apple_silently():
    assert resolve_engine("deepl", "volc", True, True) == ("apple", [])


def test_volc_without_creds_falls_back_to_apple():
    eng, warnings = resolve_engine("volc", "apple", False, True)
    assert eng == "apple"
    assert warnings == ["volc_unavailable_fallback_apple"]


def test_apple_without_helper_never_falls_back_to_cloud():
    eng, warnings = resolve_engine("apple", "apple", True, False)
    assert eng == "apple"
    assert warnings == []


def test_both_unavailable_stays_apple_without_warnings():
    # The no_engine_available error is raised downstream; resolution itself
    # keeps apple and stays quiet.
    assert resolve_engine("apple", "apple", False, False) == ("apple", [])


def test_argos_maps_to_apple_without_cloud_fallback():
    eng, warnings = resolve_engine("argos", "apple", True, False)
    assert eng == "apple"
    assert warnings == ["argos_engine_removed_using_apple"]


def test_volc_fallback_does_not_flip_back_when_apple_also_missing():
    eng, warnings = resolve_engine("volc", "apple", False, False)
    assert eng == "apple"
    assert warnings == ["volc_unavailable_fallback_apple"]


def test_durable_removal_marker_blocks_cloud_before_engine_dispatch(monkeypatch):
    @functools.lru_cache(maxsize=1)
    def should_not_run(_text):
        raise AssertionError("Volcengine must not run while removal is pending")

    monkeypatch.setattr(translator.config, "VOLC_ACCESS_KEY", "AK")
    monkeypatch.setattr(translator.config, "VOLC_SECRET_KEY", "SK")
    monkeypatch.setattr(translator.config, "cloud_removal_blocks_volc", lambda: True)
    monkeypatch.setitem(translator._ENGINE_FNS, "volc", should_not_run)

    result = asyncio.run(translator.Translator().translate("hello", engine="volc"))

    assert result.error == "cloud_removal_pending"
    assert result.engine == "volc"
    assert result.warnings == ["cloud_removal_pending"]
    assert should_not_run.cache_info().misses == 0
