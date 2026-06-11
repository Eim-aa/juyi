"""Translator: caching, length handling, language sanity, async dispatch.

A single Translator instance per process, dispatching to one of two engines
per request:

  apple - macOS 15+ system on-device translation, bridged through
          bin/apple-translation-helper (see apple_engine.py). Default.
  volc  - Volcengine cloud API, AK/SK V4 signed (see volc_engine.py).

The legacy offline Argos engine (Argos Translate / CTranslate2 / Stanza) was
removed after the apple engine beat it on quality at equal latency with zero
model footprint; requests still asking for "argos" are served by apple.

Each engine sits behind a functools.lru_cache keyed on the preprocessed text,
so exact repeats are free.
"""
from __future__ import annotations

import asyncio
import functools
import logging
import re
import time
from collections import deque
from dataclasses import dataclass, field
from typing import Optional

import config
import volc_engine
import apple_engine

log = logging.getLogger(__name__)

_CJK_RE = re.compile("[一-鿿　-〿＀-￯]")


def _cjk_ratio(text: str) -> float:
    non_space = [c for c in text if not c.isspace()]
    if not non_space:
        return 0.0
    return sum(1 for c in non_space if _CJK_RE.match(c)) / len(non_space)


def _letter_count(text: str) -> int:
    return sum(1 for c in text if c.isalpha())


@dataclass
class Result:
    result: str = ""
    elapsed_ms: int = 0
    cached: bool = False
    truncated: bool = False
    skipped: bool = False
    engine: str = ""
    warnings: list[str] = field(default_factory=list)
    error: Optional[str] = None


@functools.lru_cache(maxsize=config.CACHE_SIZE)
def _translate_cached_volc(text: str) -> str:
    return volc_engine.translate_text(
        text,
        config.VOLC_ACCESS_KEY,
        config.VOLC_SECRET_KEY,
        source=config.SRC_LANG,
        target=config.TGT_LANG,
    )


@functools.lru_cache(maxsize=config.CACHE_SIZE)
def _translate_cached_apple(text: str) -> str:
    return apple_engine.translate_text(text)


class Translator:
    _instance: Optional["Translator"] = None

    @classmethod
    def get_instance(cls) -> "Translator":
        if cls._instance is None:
            cls._instance = cls()
        return cls._instance

    def __init__(self) -> None:
        self._latencies: deque[int] = deque(maxlen=config.LATENCY_RING_SIZE)
        self._started_at = time.time()
        self._count = 0
        # Legacy field from the Argos era; nothing local needs warming now.
        # The apple helper is spawned lazily by apple_engine on first use.
        self.warmup_ms = 0
        log.info(
            "engines_ready",
            extra={
                "default_engine": config.ENGINE,
                "apple_available": apple_engine.available(),
                "volc_available": bool(config.VOLC_ACCESS_KEY and config.VOLC_SECRET_KEY),
            },
        )

    async def _infer_volc(self, text: str) -> str:
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(None, _translate_cached_volc, text)

    async def _infer_apple(self, text: str) -> str:
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(None, _translate_cached_apple, text)

    async def translate(self, text: str, engine: Optional[str] = None) -> Result:
        t0 = time.perf_counter()
        r = Result()

        # Resolve the engine for THIS request. Clients may override the
        # process default per call. Legacy "argos" maps to apple, and each
        # engine falls back to the other when it cannot run.
        volc_ok = bool(config.VOLC_ACCESS_KEY and config.VOLC_SECRET_KEY)
        eng = engine or config.ENGINE
        if eng == "argos":
            eng = "apple"
            r.warnings.append("argos_engine_removed_using_apple")
        if eng not in ("apple", "volc"):
            eng = "apple"
        if eng == "volc" and not volc_ok:
            eng = "apple"
            r.warnings.append("volc_unavailable_fallback_apple")
        if eng == "apple" and not apple_engine.available() and volc_ok:
            eng = "volc"
            r.warnings.append("apple_unavailable_fallback_volc")
        r.engine = eng

        if text is None:
            text = ""
        text = text.replace("\r\n", "\n").replace("\r", "\n").strip()

        if not text:
            r.error = "empty_input"
            r.elapsed_ms = int((time.perf_counter() - t0) * 1000)
            return r

        if len(text) > config.MAX_INPUT_CHARS:
            text = text[: config.MAX_INPUT_CHARS] + "…[truncated]"
            r.truncated = True
            r.warnings.append("input_truncated")

        if _cjk_ratio(text) > config.CJK_THRESHOLD:
            r.error = "src_lang_mismatch"
            r.result = text
            r.elapsed_ms = int((time.perf_counter() - t0) * 1000)
            return r

        if _letter_count(text) < 2:
            r.result = text
            r.skipped = True
            r.elapsed_ms = int((time.perf_counter() - t0) * 1000)
            return r

        # Neither engine can run (no helper on this OS and no cloud keys).
        if eng == "apple" and not apple_engine.available():
            r.error = "no_engine_available"
            r.warnings.append("needs macOS 15+ helper or volc.env credentials")
            r.result = text
            r.elapsed_ms = int((time.perf_counter() - t0) * 1000)
            return r

        # ---- Apple engine: system on-device translation via the helper ----
        if eng == "apple":
            info_before = _translate_cached_apple.cache_info()
            try:
                r.result = await self._infer_apple(text)
            except Exception as e:  # noqa: BLE001
                r.error = "apple_error"
                r.warnings.append(str(e)[:200])
                r.result = text
            info_after = _translate_cached_apple.cache_info()
            r.cached = (
                info_after.misses == info_before.misses
                and info_after.hits > info_before.hits
            )
            r.elapsed_ms = int((time.perf_counter() - t0) * 1000)
            self._count += 1
            self._latencies.append(r.elapsed_ms)
            return r

        # ---- Cloud engine: one signed API call ----
        info_before = _translate_cached_volc.cache_info()
        try:
            r.result = await self._infer_volc(text)
        except Exception as e:  # noqa: BLE001
            r.error = "volc_error"
            r.warnings.append(str(e)[:200])
            r.result = text
        info_after = _translate_cached_volc.cache_info()
        r.cached = (
            info_after.misses == info_before.misses
            and info_after.hits > info_before.hits
        )
        r.elapsed_ms = int((time.perf_counter() - t0) * 1000)
        self._count += 1
        self._latencies.append(r.elapsed_ms)
        return r

    def stats(self) -> dict:
        # Both engines may be used at runtime; report combined cache counters.
        v = _translate_cached_volc.cache_info()
        ap = _translate_cached_apple.cache_info()
        s = sorted(self._latencies)
        n = len(s)
        return {
            "translations_total": self._count,
            "cache_hits": v.hits + ap.hits,
            "cache_misses": v.misses + ap.misses,
            "cache_size": v.currsize + ap.currsize,
            "uptime_s": round(time.time() - self._started_at, 1),
            "warmup_ms": self.warmup_ms,
            "p50_ms": s[n // 2] if n else 0,
            "p95_ms": s[int(n * 0.95)] if n else 0,
        }
