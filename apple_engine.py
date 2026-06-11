"""Apple on-device translation engine (macOS 15+ Translation framework).

The Translation framework is Swift-only and bound to SwiftUI views, so this
module bridges to a small helper binary (bin/apple-translation-helper, source
in apple/TranslationHelper.swift) that hosts the session inside an invisible
window. Protocol: one JSON object per line over stdin/stdout —
    request:  {"id": "...", "text": "..."}
    response: {"id": "...", "result": "...", "error": null}
An empty "text" is a liveness ping; "__ready__" is emitted once at startup.

This module owns the helper's lifecycle, mirroring the offline engine's lazy
philosophy: nothing is spawned until the first apple-engine request. A reader
thread feeds stdout lines into a queue; requests are serialized with a lock,
carry a hard timeout, and a dead or wedged helper is killed and respawned on
the next call. All failures raise RuntimeError — the caller (translator.py)
maps them to error="apple_error" and falls back to returning the input text.
"""
from __future__ import annotations

import json
import platform
import queue
import subprocess
import threading
import time
import uuid
from typing import Optional

import config

READY_ID = "__ready__"
STARTUP_TIMEOUT_S = 20.0
REQUEST_TIMEOUT_S = 10.0

_lock = threading.Lock()
_proc: Optional[subprocess.Popen] = None
_lines: Optional[queue.Queue] = None

_EOF = object()


def available() -> bool:
    """True when the helper binary exists and the OS has the framework (15+)."""
    try:
        major = int((platform.mac_ver()[0] or "0").split(".")[0])
    except ValueError:
        major = 0
    return major >= 15 and config.APPLE_HELPER_PATH.is_file()


def _reader(proc: subprocess.Popen, q: queue.Queue) -> None:
    try:
        for line in proc.stdout:
            q.put(line)
    finally:
        q.put(_EOF)


def _kill_locked() -> None:
    global _proc, _lines
    if _proc is not None:
        try:
            _proc.kill()
            _proc.wait(timeout=2)
        except (OSError, subprocess.TimeoutExpired):
            pass
    _proc = None
    _lines = None


def _spawn_locked() -> None:
    """Start the helper and wait for its ready handshake. Caller holds _lock."""
    global _proc, _lines
    _kill_locked()
    if not available():
        raise RuntimeError("apple engine unavailable (needs macOS 15+ and a built helper)")
    proc = subprocess.Popen(
        [str(config.APPLE_HELPER_PATH)],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        text=True,
        encoding="utf-8",
        bufsize=1,
    )
    q: queue.Queue = queue.Queue()
    threading.Thread(
        target=_reader, args=(proc, q), daemon=True, name="apple-helper-reader"
    ).start()
    deadline = time.monotonic() + STARTUP_TIMEOUT_S
    while True:
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            proc.kill()
            raise RuntimeError("apple helper did not become ready in time")
        try:
            line = q.get(timeout=remaining)
        except queue.Empty:
            continue
        if line is _EOF:
            raise RuntimeError("apple helper exited during startup")
        try:
            msg = json.loads(line)
        except ValueError:
            continue
        if msg.get("id") == READY_ID:
            break
    _proc = proc
    _lines = q


def translate_text(text: str, timeout: float = REQUEST_TIMEOUT_S) -> str:
    """Translate en -> zh-Hans via the system framework.

    Raises RuntimeError on helper death, timeout, or a framework error
    (e.g. the language pack is not installed yet).
    """
    with _lock:
        if _proc is None or _proc.poll() is not None:
            _spawn_locked()
        rid = uuid.uuid4().hex
        payload = json.dumps({"id": rid, "text": text}, ensure_ascii=False)
        try:
            _proc.stdin.write(payload + "\n")
            _proc.stdin.flush()
        except (OSError, ValueError) as e:
            _kill_locked()
            raise RuntimeError(f"apple helper write failed: {e}") from e
        deadline = time.monotonic() + timeout
        while True:
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                # Wedged (e.g. system dialog pending). Kill it; the next
                # request gets a fresh helper.
                _kill_locked()
                raise RuntimeError("apple helper timeout")
            try:
                line = _lines.get(timeout=remaining)
            except queue.Empty:
                continue
            if line is _EOF:
                _kill_locked()
                raise RuntimeError("apple helper died mid-request")
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if msg.get("id") != rid:
                continue  # stale line from a timed-out predecessor
            if msg.get("error"):
                raise RuntimeError(f"apple translate error: {str(msg['error'])[:200]}")
            result = msg.get("result")
            if not isinstance(result, str):
                raise RuntimeError("apple helper returned no result")
            return result


def ping(timeout: float = 3.0) -> bool:
    """Round-trip an empty request through the live helper without translating."""
    try:
        return translate_text("", timeout=timeout) == ""
    except RuntimeError:
        return False
