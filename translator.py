"""Translator: caching, length handling, language sanity, async serialization.

A single Translator instance per process. For the offline engine it loads
ctranslate2 + stanza in __init__ and runs one warmup translation so subsequent
requests skip cold start. For the "volc" cloud engine no local model is loaded.

Inference is serialized via asyncio.Lock; the cache (functools.lru_cache on the
SHA-1 of preprocessed text) makes exact repeats free.
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

# 100% offline guarantee. argostranslate doesn't pass download_method= to
# stanza.Pipeline, so stanza defaults to fetching resources_<ver>.json from
# raw.githubusercontent.com. Force REUSE_RESOURCES so it uses the bundled
# resources.json without any network call.
import stanza.pipeline.core as _spc

_orig_pipeline_init = _spc.Pipeline.__init__


def _offline_pipeline_init(self, *args, **kwargs):
    kwargs.setdefault("download_method", _spc.DownloadMethod.REUSE_RESOURCES)
    return _orig_pipeline_init(self, *args, **kwargs)


_spc.Pipeline.__init__ = _offline_pipeline_init

import config  # noqa: E402
import volc_engine  # noqa: E402
import stanza  # noqa: E402
import argostranslate.translate as AT  # noqa: E402

log = logging.getLogger(__name__)

_CJK_RE = re.compile("[一-鿿　-〿＀-￯]")
_WORD_RE = re.compile(r"\S+")


def _cjk_ratio(text: str) -> float:
    non_space = [c for c in text if not c.isspace()]
    if not non_space:
        return 0.0
    return sum(1 for c in non_space if _CJK_RE.match(c)) / len(non_space)


def _letter_count(text: str) -> int:
    return sum(1 for c in text if c.isalpha())


def _word_count(text: str) -> int:
    return len(_WORD_RE.findall(text))


@dataclass
class Result:
    result: str = ""
    elapsed_ms: int = 0
    cached: bool = False
    truncated: bool = False
    skipped: bool = False
    warnings: list[str] = field(default_factory=list)
    error: Optional[str] = None


@functools.lru_cache(maxsize=config.CACHE_SIZE)
def _translate_cached(text: str) -> str:
    return AT.translate(text, config.SRC_LANG, config.TGT_LANG)


@functools.lru_cache(maxsize=config.CACHE_SIZE)
def _translate_cached_volc(text: str) -> str:
    return volc_engine.translate_text(
        text,
        config.VOLC_ACCESS_KEY,
        config.VOLC_SECRET_KEY,
        source=config.SRC_LANG,
        target=config.TGT_LANG,
    )


class Translator:
    _instance: Optional["Translator"] = None

    @classmethod
    def get_instance(cls) -> "Translator":
        if cls._instance is None:
            cls._instance = cls()
        return cls._instance

    def __init__(self) -> None:
        self._lock = asyncio.Lock()
        self._latencies: deque[int] = deque(maxlen=config.LATENCY_RING_SIZE)
        self._started_at = time.time()
        self._count = 0
        self._sbd_pipeline = None
        self.warmup_ms = 0

        if config.ENGINE == "volc":
            # Cloud engine: no local model or sentence splitter to load.
            log.info("engine_selected", extra={"engine": "volc"})
            return

        self._sbd_pipeline = stanza.Pipeline(
            lang=config.SRC_LANG,
            dir=str(config.PACKAGES_DIR / "translate-en_zh-1_9" / "stanza"),
            processors="tokenize",
            use_gpu=False,
            logging_level="WARNING",
            download_method=_spc.DownloadMethod.REUSE_RESOURCES,
        )

        t0 = time.perf_counter()
        AT.translate("warmup", config.SRC_LANG, config.TGT_LANG)
        self.warmup_ms = int((time.perf_counter() - t0) * 1000)
        log.info(
            "model_warmup_done",
            extra={"warmup_ms": self.warmup_ms, "engine": "argos"},
        )

    async def _infer(self, text: str) -> str:
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(None, _translate_cached, text)

    async def _infer_volc(self, text: str) -> str:
        loop = asyncio.get_running_loop()
        return await loop.run_in_executor(None, _translate_cached_volc, text)

    def _split_sentences(self, text: str) -> list[str]:
        doc = self._sbd_pipeline(text)
        return [sent.text.strip() for sent in doc.sentences if sent.text.strip()]

    async def translate(self, text: str) -> Result:
        t0 = time.perf_counter()
        r = Result()

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

        chars = len(text)
        words = _word_count(text)
        long_input = words > config.LONG_INPUT_WORDS or chars > config.LONG_INPUT_CHARS

        # ---- Cloud engine: one signed API call, no sentence splitting ----
        if config.ENGINE == "volc":
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

        # ---- Offline engine: sentence-split long inputs, per-sentence cache ----
        info_before = _translate_cached.cache_info()
        async with self._lock:
            if long_input:
                paragraphs = text.split("\n\n")
                translated: list[str] = []
                memo: dict[str, str] = {}
                for p in paragraphs:
                    p_stripped = p.strip()
                    if not p_stripped:
                        translated.append("")
                        continue
                    sentences = self._split_sentences(p_stripped)
                    if not sentences:
                        translated.append(await self._infer(p_stripped))
                        continue
                    out_sentences: list[str] = []
                    for sentence in sentences:
                        if sentence not in memo:
                            memo[sentence] = await self._infer(sentence)
                        out_sentences.append(memo[sentence])
                    translated.append(" ".join(out_sentences))
                r.result = "\n\n".join(translated)
            else:
                r.result = await self._infer(text)
        info_after = _translate_cached.cache_info()
        r.cached = info_after.misses == info_before.misses and info_after.hits > info_before.hits

        r.elapsed_ms = int((time.perf_counter() - t0) * 1000)

        self._count += 1
        self._latencies.append(r.elapsed_ms)
        return r

    def stats(self) -> dict:
        cache = _translate_cached_volc if config.ENGINE == "volc" else _translate_cached
        info = cache.cache_info()
        s = sorted(self._latencies)
        n = len(s)
        return {
            "translations_total": self._count,
            "cache_hits": info.hits,
            "cache_misses": info.misses,
            "cache_size": info.currsize,
            "uptime_s": round(time.time() - self._started_at, 1),
            "warmup_ms": self.warmup_ms,
            "p50_ms": s[n // 2] if n else 0,
            "p95_ms": s[int(n * 0.95)] if n else 0,
        }
