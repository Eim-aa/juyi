"""build_signed_request(): pin the AK/SK V4 signing algorithm.

Golden values were produced by the implementation at the time this test was
written; any change to the canonical request, key derivation, or header set
breaks the pin and must be a deliberate decision.
"""
import datetime
import hashlib

from volc_engine import build_signed_request

FIXED_NOW = datetime.datetime(2026, 1, 2, 3, 4, 5, tzinfo=datetime.timezone.utc)


def build():
    return build_signed_request(
        "Hello, world.", "AKTEST", "SKTEST", "en", "zh", FIXED_NOW
    )


def test_url_and_body():
    url, _, body = build()
    assert url == (
        "https://translate.volcengineapi.com/?Action=TranslateText&Version=2020-06-01"
    )
    assert body == (
        b'{"TargetLanguage": "zh", "TextList": ["Hello, world."],'
        b' "SourceLanguage": "en"}'
    )


def test_payload_hash_matches_body():
    _, headers, body = build()
    assert headers["X-Content-Sha256"] == hashlib.sha256(body).hexdigest()
    assert headers["X-Date"] == "20260102T030405Z"
    assert headers["Content-Type"] == "application/json; charset=utf-8"
    assert headers["Host"] == "translate.volcengineapi.com"


def test_signature_golden_pin():
    _, headers, _ = build()
    assert headers["Authorization"] == (
        "HMAC-SHA256 Credential=AKTEST/20260102/cn-north-1/translate/request, "
        "SignedHeaders=content-type;host;x-content-sha256;x-date, "
        "Signature=7265ac5fe98b6ff62155737ef2dd0ec68d07dbb472c0aba1b527b7e9715302a7"
    )


def test_empty_source_omits_source_language():
    _, _, body = build_signed_request("hi", "AKTEST", "SKTEST", "", "zh", FIXED_NOW)
    assert body == b'{"TargetLanguage": "zh", "TextList": ["hi"]}'
