#!/usr/bin/env python3
"""Compare frozen Swift 4A policy output with the current pure Python policy.

The translator module is loaded only after pure in-memory config and engine
stubs are installed. This prevents its import from consulting HOME, Keychain,
environment-derived config, marker files, helper processes, or a network.
"""
from __future__ import annotations

import argparse
import asyncio
import datetime as dt
import hashlib
import importlib.util
import inspect
import json
import logging
import sys
import types
from pathlib import Path
from typing import Any


def _load_python_policy(root: Path):
    config = types.ModuleType("config")
    config.MAX_INPUT_CHARS = 5000
    config.CJK_THRESHOLD = 0.5
    config.CACHE_SIZE = 2000
    config.LATENCY_RING_SIZE = 1000
    config.ENGINE = "apple"
    config.VOLC_ACCESS_KEY = ""
    config.VOLC_SECRET_KEY = ""
    config.SRC_LANG = "en"
    config.TGT_LANG = "zh"
    config.cloud_removal_blocks_volc = lambda: False

    apple = types.ModuleType("apple_engine")
    apple.available = lambda: True
    apple.translate_text = lambda _text: "fixed-stub-result"

    signer_spec = importlib.util.spec_from_file_location(
        "native_translation_parity_signer", root / "volc_engine.py"
    )
    if signer_spec is None or signer_spec.loader is None:
        raise AssertionError("cannot load pure signer module")
    signer = importlib.util.module_from_spec(signer_spec)
    signer_spec.loader.exec_module(signer)

    volc_proxy = types.ModuleType("volc_engine")
    volc_calls = {"count": 0}

    def forbidden_volc_effect(*_args, **_kwargs):
        volc_calls["count"] += 1
        raise AssertionError("parity adapter attempted a Volc effect")

    volc_proxy.translate_text = forbidden_volc_effect

    old_config = sys.modules.get("config")
    old_apple = sys.modules.get("apple_engine")
    old_volc = sys.modules.get("volc_engine")
    sys.modules["config"] = config
    sys.modules["apple_engine"] = apple
    sys.modules["volc_engine"] = volc_proxy
    try:
        spec = importlib.util.spec_from_file_location(
            "native_translation_parity_translator", root / "translator.py"
        )
        if spec is None or spec.loader is None:
            raise AssertionError("cannot load translator policy")
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
    finally:
        if old_config is None:
            sys.modules.pop("config", None)
        else:
            sys.modules["config"] = old_config
        if old_apple is None:
            sys.modules.pop("apple_engine", None)
        else:
            sys.modules["apple_engine"] = old_apple
        if old_volc is None:
            sys.modules.pop("volc_engine", None)
        else:
            sys.modules["volc_engine"] = old_volc
    return module, signer, volc_calls


def _materialize(spec: dict[str, Any]) -> str | None:
    kind = spec["kind"]
    if kind == "null":
        return None
    if kind == "literal":
        return spec["value"]
    if kind == "repeated":
        scalar = spec["scalar"]
        assert len(scalar) == 1
        return scalar * spec["count"] + spec.get("suffix", "")
    raise AssertionError(f"unknown input spec: {kind}")


def _input_record(policy, item: dict[str, Any]) -> dict[str, str]:
    normalized = policy.normalize_input(_materialize(item["input"]))
    if not normalized:
        return {"classification": "must_match", "decision": "failure:empty_input"}
    limited, truncated = policy.truncate_input(normalized)
    if policy._cjk_ratio(limited) > 0.5:
        return {
            "classification": "must_match",
            "decision": "failure:source_language_mismatch",
        }
    if policy._letter_count(limited) < 2:
        return {"classification": "must_match", "decision": "skipped:too_short"}
    return {
        "classification": "must_match",
        "decision": "ready",
        "scalar_count": str(len(limited)),
        "truncated": str(truncated).lower(),
        "utf8_sha256": hashlib.sha256(limited.encode("utf-8")).hexdigest(),
    }


def _route_record(policy, item: dict[str, Any]) -> dict[str, str]:
    engine, _warnings = policy.resolve_engine(
        item["requestedEngine"],
        "apple",
        item["volcAvailable"],
        item["appleAvailable"],
    )
    return {"classification": "must_match", "decision": f"execute:{engine}"}


def _signer_record(volc_engine, item: dict[str, Any]) -> dict[str, str]:
    instant = dt.datetime.fromisoformat(item["instant"].replace("Z", "+00:00"))
    _url, headers, body = volc_engine.build_signed_request(
        item["text"],
        item["accessKey"],
        item["secretKey"],
        item["sourceLanguage"],
        item["targetLanguage"],
        instant,
    )
    signature = headers["Authorization"].split("Signature=", 1)[1]
    return {
        "classification": "must_match",
        "body_sha256": hashlib.sha256(body).hexdigest(),
        "signature": signature,
    }


async def _skip_echo_probe(policy) -> str:
    result = await policy.Translator().translate("A", engine="apple")
    return "echoes_source" if result.skipped and result.result == "A" else "changed"


def _python_delta_value(policy, volc_engine, item: dict[str, Any]) -> str:
    delta_id = item["id"]
    if delta_id == "legacy_argos_engine":
        return f"execute:{policy.resolve_engine('argos', 'apple', True, True)[0]}"
    if delta_id == "unknown_engine":
        return f"execute:{policy.resolve_engine('deepl', 'volc', True, True)[0]}"
    if delta_id == "volc_unavailable":
        return f"execute:{policy.resolve_engine('volc', 'apple', False, True)[0]}"
    if delta_id == "body_cache":
        return f"lru:{policy._translate_cached_apple.cache_info().maxsize}"
    if delta_id == "failure_and_skip_body":
        return asyncio.run(_skip_echo_probe(policy))
    if delta_id == "error_classification":
        timeout = policy.classify_engine_error("volc", RuntimeError("timed out"))
        credential = policy.classify_engine_error("volc", RuntimeError("unauthorized"))
        assert timeout != credential
        return "message_substring"
    if delta_id == "response_parser":
        source = inspect.getsource(volc_engine.translate_text)
        assert 'payload.get("TranslationList")' in source and "lst[0]" in source
        return "legacy_top_level_first_item"
    if delta_id == "network_timeout":
        timeout = inspect.signature(volc_engine.translate_text).parameters["timeout"].default
        return f"transport_{timeout}s"
    raise AssertionError(f"unclassified intentional delta: {delta_id}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--corpus", required=True, type=Path)
    parser.add_argument("--swift-output", required=True, type=Path)
    args = parser.parse_args()

    root = Path(__file__).resolve().parents[1]
    corpus = json.loads(args.corpus.read_text(encoding="utf-8"))
    swift_output = json.loads(args.swift_output.read_text(encoding="utf-8"))
    assert corpus["schema"] == "juyi.native_translation.input_parity"
    assert corpus["version"] == 1
    assert swift_output["schema"] == corpus["schema"]
    assert swift_output["version"] == corpus["version"]

    logging.disable(logging.CRITICAL)
    policy, volc_engine, volc_calls = _load_python_policy(root)
    swift_records = {item["id"]: item["fields"] for item in swift_output["records"]}
    assert len(swift_records) == len(swift_output["records"]), "duplicate Swift record id"

    matched = 0
    expected_ids: set[str] = set()
    for item in corpus["inputCases"]:
        expected_ids.add(item["id"])
        python_record = _input_record(policy, item)
        assert python_record["decision"] == item["expectedDecision"]
        assert swift_records[item["id"]] == python_record, item["id"]
        matched += 1
    for item in corpus["routeCases"]:
        expected_ids.add(item["id"])
        python_record = _route_record(policy, item)
        assert python_record["decision"] == item["expectedDecision"]
        assert swift_records[item["id"]] == python_record, item["id"]
        matched += 1
    for item in corpus["signerCases"]:
        expected_ids.add(item["id"])
        python_record = _signer_record(volc_engine, item)
        assert python_record["body_sha256"] == item["expectedBodySHA256"]
        assert python_record["signature"] == item["expectedSignature"]
        assert swift_records[item["id"]] == python_record, item["id"]
        matched += 1

    allowed_reasons = {
        "python_legacy_engine_alias",
        "python_unknown_engine_defaults_apple",
        "python_volc_unavailable_falls_back_apple",
        "python_lru_cache_2000",
        "python_echoes_source_on_non_success",
        "python_string_error_classification",
        "python_parser_is_legacy_loose",
        "python_transport_timeout_30s",
    }
    deltas = corpus["intentionalDeltas"]
    assert {item["reason"] for item in deltas} == allowed_reasons
    for item in deltas:
        expected_ids.add(item["id"])
        actual_python = _python_delta_value(policy, volc_engine, item)
        assert actual_python == item["python"], item["id"]
        assert item["swift"] != actual_python, item["id"]
        assert swift_records[item["id"]] == {
            "classification": "intentional_delta",
            "reason": item["reason"],
            "decision": item["swift"],
        }

    assert set(swift_records) == expected_ids, "unclassified parity record"
    assert volc_calls["count"] == 0, "Python parity adapter invoked a Volc effect"
    print(
        f"NativeTranslationParity: {matched} must-match, "
        f"{len(deltas)} intentional deltas"
    )


if __name__ == "__main__":
    main()
