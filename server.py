"""FastAPI HTTP service for argos-translator.

Lifespan constructs the Translator BEFORE uvicorn starts serving requests.
Logging is JSONL on both stderr and a rotating file.
"""
from __future__ import annotations

import asyncio
import hmac
import json
import logging
import logging.handlers
import uuid
from contextlib import asynccontextmanager
from typing import Optional

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse, PlainTextResponse
from pydantic import BaseModel

import apple_engine
import config
import volc_engine
from translator import Translator, classify_engine_error


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
    suppress third-party INFO/DEBUG spam on the root logger so the
    structured JSONL stream stays clean."""

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


# ---- Lifespan: construct the Translator before serving ------------------------
@asynccontextmanager
async def lifespan(_app: FastAPI):
    log.info("startup_begin")
    loop = asyncio.get_running_loop()
    # Construct in an executor so the asyncio loop stays responsive for the
    # lifespan protocol.
    await loop.run_in_executor(None, Translator.get_instance)
    log.info("startup_complete")
    yield
    log.info("shutdown")


app = FastAPI(lifespan=lifespan)


class TranslateRequest(BaseModel):
    text: Optional[str] = ""
    engine: Optional[str] = None


_PROTECTED_PATHS = frozenset({"/translate", "/validate/volc-pending", "/metrics"})
_ALLOWED_HOSTS = frozenset(
    {f"127.0.0.1:{config.PORT}", f"localhost:{config.PORT}"}
)


def _has_valid_auth_header(header: Optional[str], token: str) -> bool:
    """Compare the complete bearer value without logging either operand."""
    if not token or header is None:
        return False
    try:
        return hmac.compare_digest(header, f"Bearer {token}")
    except TypeError:
        # compare_digest rejects non-ASCII str input. Treat a malformed local
        # header as unauthorized instead of turning it into a 500 response.
        return False


# JSON only, checked BEFORE body parsing. A non-JSON content type would make
# /translate reachable from any web page as a CORS "simple request" (no
# preflight), letting a malicious page fire translations (and burn cloud
# quota) blind. FastAPI alone would 422 text/plain but happily parses a
# missing content type as JSON; the middleware closes both with a proper 415.
@app.middleware("http")
async def require_json(request: Request, call_next):
    # Reject DNS-rebinding and browser-originated requests before routing. The
    # native app, Hammerspoon and diagnostics all address 127.0.0.1 directly
    # and do not send an Origin header.
    host = (request.headers.get("host") or "").lower()
    if host not in _ALLOWED_HOSTS:
        return JSONResponse({"error": "invalid_host"}, status_code=421)
    if request.headers.get("origin") is not None:
        return JSONResponse({"error": "browser_origin_not_allowed"}, status_code=403)

    if request.url.path in _PROTECTED_PATHS:
        if not config.AUTH_TOKEN and not config.ALLOW_UNAUTHENTICATED:
            return JSONResponse(
                {"error": "local_auth_not_configured"}, status_code=503
            )
        if config.AUTH_TOKEN and not _has_valid_auth_header(
            request.headers.get("authorization"), config.AUTH_TOKEN
        ):
            return JSONResponse(
                {"error": "unauthorized"},
                status_code=401,
                headers={"WWW-Authenticate": "Bearer"},
            )
    if request.method == "POST" and request.url.path == "/translate":
        ctype = (request.headers.get("content-type") or "").lower()
        if "application/json" not in ctype:
            return JSONResponse(
                {"error": "unsupported_media_type"}, status_code=415
            )
    return await call_next(request)


@app.post("/translate")
async def translate(req: TranslateRequest):
    rid = uuid.uuid4().hex[:8]
    requested_engine = req.engine or config.ENGINE
    if requested_engine == "volc" and config.cloud_removal_blocks_volc():
        log.warning(
            "cloud_translation_blocked",
            extra={"request_id": rid, "error": "cloud_removal_pending"},
        )
        return JSONResponse(
            {
                "error": "cloud_removal_pending",
                "engine": "volc",
                "warnings": ["cloud_removal_pending"],
            },
            status_code=409,
        )
    t = Translator.get_instance()
    result = await t.translate(req.text or "", engine=req.engine)
    log.info(
        "translate_done",
        extra={
            "request_id": rid,
            "input_len": len(req.text or ""),
            "engine": result.engine,
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
        "engine": result.engine,
        "elapsed_ms": result.elapsed_ms,
        "cached": result.cached,
        "truncated": result.truncated,
        "skipped": result.skipped,
        "warnings": result.warnings,
    }
    if result.error:
        body["error"] = result.error
    return body


@app.post("/validate/volc-pending")
async def validate_pending_volc():
    """Validate the separate pending Keychain item without receiving secrets."""
    if config.cloud_removal_blocks_volc():
        return JSONResponse(
            {
                "error": "cloud_removal_pending",
                "engine": "volc",
                "warnings": ["cloud_removal_pending"],
            },
            status_code=409,
        )
    pending = config._load_keychain_credentials(
        service=config.VOLC_PENDING_KEYCHAIN_SERVICE,
        account=config.VOLC_PENDING_KEYCHAIN_ACCOUNT,
    )
    if pending.status != "found" or pending.credentials is None:
        return JSONResponse(
            {"error": "pending_credentials_unavailable", "engine": "volc"},
            status_code=400,
        )
    access_key, secret_key = pending.credentials
    loop = asyncio.get_running_loop()
    try:
        result = await loop.run_in_executor(
            None,
            lambda: volc_engine.translate_text(
                "Good tools should feel effortless.",
                access_key,
                secret_key,
                source=config.SRC_LANG,
                target=config.TGT_LANG,
            ),
        )
        return {"result": result, "engine": "volc", "elapsed_ms": 0}
    except Exception as exc:  # noqa: BLE001
        diagnostic = classify_engine_error("volc", exc)
        log.warning("volc_pending_validation_failed", extra={"error": diagnostic})
        return JSONResponse(
            {"error": "volc_error", "engine": "volc", "warnings": [diagnostic]},
            status_code=400,
        )


@app.get("/health")
async def health():
    auth_ready = bool(config.AUTH_TOKEN) or config.ALLOW_UNAUTHENTICATED
    cloud_removal_pending = config.cloud_removal_blocks_volc()
    return {
        "ok": auth_ready,
        "auth_required": bool(config.AUTH_TOKEN) or not config.ALLOW_UNAUTHENTICATED,
        "auth_configured": bool(config.AUTH_TOKEN),
        "cloud_removal_pending": cloud_removal_pending,
        "default_engine": config.ENGINE,
        "engines": {
            "apple": apple_engine.available(),
            # This reports whether credentials are resident in this process,
            # even while the removal kill switch blocks their use. The native
            # app relies on the raw state to avoid clearing the transaction
            # marker before an old credential-bearing process is gone.
            "volc": bool(config.VOLC_ACCESS_KEY and config.VOLC_SECRET_KEY),
        },
    }


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
