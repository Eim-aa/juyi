"""Volcengine machine translation (TranslateText) engine.

Self-contained AK/SK V4 signed call to translate.volcengineapi.com.
Stdlib only (no extra deps). Used when config.ENGINE == "volc".
"""
from __future__ import annotations

import datetime
import hashlib
import hmac
import json
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

_SERVICE = "translate"
_REGION = "cn-north-1"
_HOST = "translate.volcengineapi.com"
_CONTENT_TYPE = "application/json; charset=utf-8"
_QUERY = urlencode([("Action", "TranslateText"), ("Version", "2020-06-01")])
_SIGNED_HEADERS = "content-type;host;x-content-sha256;x-date"


def _sha256_hex(s: str) -> str:
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def _hmac(key: bytes, msg: str) -> bytes:
    return hmac.new(key, msg.encode("utf-8"), hashlib.sha256).digest()


def translate_text(
    text: str,
    ak: str,
    sk: str,
    source: str = "en",
    target: str = "zh",
    timeout: int = 30,
) -> str:
    """Translate `text` via Volcengine. Returns the translated string.

    Raises RuntimeError on credential/transport/API error.
    """
    if not ak or not sk:
        raise RuntimeError("volc credentials missing")

    body_obj = {"TargetLanguage": target, "TextList": [text]}
    if source:
        body_obj["SourceLanguage"] = source
    body = json.dumps(body_obj, ensure_ascii=False)

    now = datetime.datetime.now(datetime.timezone.utc)
    x_date = now.strftime("%Y%m%dT%H%M%SZ")
    short_date = now.strftime("%Y%m%d")
    payload_hash = _sha256_hex(body)

    canonical_headers = (
        f"content-type:{_CONTENT_TYPE}\n"
        f"host:{_HOST}\n"
        f"x-content-sha256:{payload_hash}\n"
        f"x-date:{x_date}\n"
    )
    canonical_request = "\n".join(
        ["POST", "/", _QUERY, canonical_headers, _SIGNED_HEADERS, payload_hash]
    )
    credential_scope = f"{short_date}/{_REGION}/{_SERVICE}/request"
    string_to_sign = "\n".join(
        ["HMAC-SHA256", x_date, credential_scope, _sha256_hex(canonical_request)]
    )

    k_date = _hmac(sk.encode("utf-8"), short_date)
    k_region = _hmac(k_date, _REGION)
    k_service = _hmac(k_region, _SERVICE)
    k_signing = _hmac(k_service, "request")
    signature = hmac.new(
        k_signing, string_to_sign.encode("utf-8"), hashlib.sha256
    ).hexdigest()

    authorization = (
        f"HMAC-SHA256 Credential={ak}/{credential_scope}, "
        f"SignedHeaders={_SIGNED_HEADERS}, Signature={signature}"
    )
    headers = {
        "Content-Type": _CONTENT_TYPE,
        "Host": _HOST,
        "X-Date": x_date,
        "X-Content-Sha256": payload_hash,
        "Authorization": authorization,
    }
    url = f"https://{_HOST}/?{_QUERY}"

    try:
        req = Request(url, data=body.encode("utf-8"), headers=headers, method="POST")
        with urlopen(req, timeout=timeout) as resp:
            payload = json.loads(resp.read().decode("utf-8"))
    except HTTPError as e:
        detail = e.read().decode("utf-8", "replace")[:200]
        raise RuntimeError(f"volc http {e.code}: {detail}") from e
    except URLError as e:
        raise RuntimeError(f"volc network error: {e}") from e

    meta = payload.get("ResponseMetadata", {})
    if isinstance(meta, dict) and meta.get("Error"):
        err = meta["Error"]
        raise RuntimeError(f"volc api {err.get('Code')}: {err.get('Message')}")

    lst = payload.get("TranslationList") or []
    if not lst or "Translation" not in lst[0]:
        raise RuntimeError(f"volc unexpected response: {str(payload)[:200]}")
    return lst[0]["Translation"]
