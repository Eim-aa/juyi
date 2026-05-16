"""FastAPI HTTP service for argos-translator.

Lifespan loads the Translator (which warmups the model) BEFORE uvicorn starts
serving requests. Logging is JSONL on both stderr and a rotating file.
"""
from __future__ import annotations

import asyncio
import json
import logging
import logging.handlers
import uuid
from contextlib import asynccontextmanager
from typing import Optional

from fastapi import FastAPI
from fastapi.responses import JSONResponse, PlainTextResponse
from pydantic import BaseModel

import config
from translator import Translator


# ---- Structured JSONL logging --------------------------------------------------
class JsonFormatter(logging.Formatter):
    _RESERVED = {
        "name", "msg", "args", "levelname", "levelno", "pathname", "filename",
        "module", "exc_info", "exc_text", "stack_info", "lineno", "funcName",
        "created", "msecs", "relativeCreated", "thread", "threadName",
        "processName", "process", "getMessage", "message", "taskName",
    }

    def format(self, record: logging.LogRecord) -> str:
        d = {
            "ts": round(record.created, 3),
            "level": record.levelname.lower(),
            "logger": record.name,
            "event": record.getMessage(),
        }
        for k, v in record.__dict__.items():
            if k in self._RESERVED:
                continue
            try:
                json.dumps(v)
                d[k] = v
            except (TypeError, ValueError):
                d[k] = repr(v)
        return json.dumps(d, ensure_ascii=False)


class _AppLogsFilter(logging.Filter):
    """Allow our own loggers (any level) and uvicorn startup messages;
    suppress third-party INFO/DEBUG spam (argostranslate calls logging.info()
    on root with positional args, polluting structured logs)."""

    _OURS = {"server", "translator", "uvicorn", "uvicorn.error"}

    def filter(self, record: logging.LogRecord) -> bool:
        if record.name in self._OURS:
            return True
        return record.levelno >= logging.WARNING


def setup_logging() -> None:
    config.LOG_DIR.mkdir(parents=True, exist_ok=True)
    root = logging.getLogger()
    root.handlers.clear()
    root.setLevel(logging.INFO)
    flt = _AppLogsFilter()
    sh = logging.StreamHandler()
    sh.setFormatter(JsonFormatter())
    sh.addFilter(flt)
    root.addHandler(sh)
    fh = logging.handlers.RotatingFileHandler(
        str(config.LOG_FILE),
        maxBytes=config.LOG_MAX_BYTES,
        backupCount=config.LOG_BACKUP_COUNT,
        encoding="utf-8",
    )
    fh.setFormatter(JsonFormatter())
    fh.addFilter(flt)
    root.addHandler(fh)


log = logging.getLogger("server")


# ---- Lifespan: load model before serving --------------------------------------
@asynccontextmanager
async def lifespan(_app: FastAPI):
    log.info("startup_begin")
    loop = asyncio.get_running_loop()
    # Run blocking model load in executor so the asyncio loop stays responsive
    # for the lifespan protocol.
    await loop.run_in_executor(None, Translator.get_instance)
    log.info(
        "startup_complete",
        extra={"warmup_ms": Translator.get_instance().warmup_ms},
    )
    yield
    log.info("shutdown")


app = FastAPI(lifespan=lifespan)


class TranslateRequest(BaseModel):
    text: Optional[str] = ""


@app.post("/translate")
async def translate(req: TranslateRequest):
    rid = uuid.uuid4().hex[:8]
    t = Translator.get_instance()
    result = await t.translate(req.text or "")
    log.info(
        "translate_done",
        extra={
            "request_id": rid,
            "input_len": len(req.text or ""),
            "latency_ms": result.elapsed_ms,
            "cached": result.cached,
            "truncated": result.truncated,
            "skipped": result.skipped,
            "error": result.error,
        },
    )
    if result.error == "empty_input":
        return JSONResponse({"error": "empty_input"}, status_code=400)
    body = {
        "result": result.result,
        "elapsed_ms": result.elapsed_ms,
        "cached": result.cached,
        "truncated": result.truncated,
        "skipped": result.skipped,
        "warnings": result.warnings,
    }
    if result.error:
        body["error"] = result.error
    return body


@app.get("/health")
async def health():
    t = Translator.get_instance()
    return {"ok": True, "model_loaded": True, **t.stats()}


@app.get("/metrics")
async def metrics():
    t = Translator.get_instance()
    s = t.stats()
    out = [
        "# HELP argos_translations_total Total translations served",
        "# TYPE argos_translations_total counter",
        f"argos_translations_total {s['translations_total']}",
        "# HELP argos_cache_hits_total Cache hits",
        "# TYPE argos_cache_hits_total counter",
        f"argos_cache_hits_total {s['cache_hits']}",
        "# HELP argos_cache_misses_total Cache misses",
        "# TYPE argos_cache_misses_total counter",
        f"argos_cache_misses_total {s['cache_misses']}",
        "# HELP argos_uptime_seconds Process uptime",
        "# TYPE argos_uptime_seconds gauge",
        f"argos_uptime_seconds {s['uptime_s']}",
        "# HELP argos_latency_p50_ms p50 latency over recent ring",
        "# TYPE argos_latency_p50_ms gauge",
        f"argos_latency_p50_ms {s['p50_ms']}",
        "# HELP argos_latency_p95_ms p95 latency over recent ring",
        "# TYPE argos_latency_p95_ms gauge",
        f"argos_latency_p95_ms {s['p95_ms']}",
    ]
    return PlainTextResponse("\n".join(out) + "\n")


if __name__ == "__main__":
    import uvicorn

    setup_logging()
    uvicorn.run(
        app,
        host=config.HOST,
        port=config.PORT,
        log_config=None,
        access_log=False,
    )
