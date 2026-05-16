#!/usr/bin/env python3
"""Automated diagnostics for the local argos-translator service."""
from __future__ import annotations

import json
import os
import statistics
import subprocess
import sys
import time
import urllib.error
import urllib.request

URL = os.environ.get("ARGOS_URL", "http://127.0.0.1:54321")
LABEL = "io.github.Eim-aa.argos-translator"
DOMAIN = f"gui/{os.getuid()}"


def request(method: str, path: str, body: dict | None = None, timeout: float = 30.0):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    headers = {"Content-Type": "application/json"} if data is not None else {}
    req = urllib.request.Request(URL + path, data=data, method=method, headers=headers)
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            return resp.status, raw, (time.perf_counter() - t0) * 1000
    except urllib.error.HTTPError as exc:
        return exc.code, exc.read(), (time.perf_counter() - t0) * 1000


def get_json(path: str):
    code, raw, rtt = request("GET", path)
    return code, json.loads(raw), rtt


def post_json(text: str):
    code, raw, rtt = request("POST", "/translate", {"text": text})
    try:
        parsed = json.loads(raw)
    except json.JSONDecodeError:
        parsed = {"raw": raw.decode("utf-8", errors="replace")}
    return code, parsed, rtt


def report(name: str, ok: bool, detail: str) -> bool:
    mark = "PASS" if ok else "FAIL"
    print(f"[{mark}] {name:24s} {detail}")
    return ok


def percentile(samples: list[int], q: float) -> int:
    if not samples:
        return 0
    s = sorted(samples)
    return s[min(len(s) - 1, int(len(s) * q))]


def service_pid() -> int | None:
    try:
        out = subprocess.check_output(
            ["launchctl", "print", f"{DOMAIN}/{LABEL}"],
            text=True,
            stderr=subprocess.DEVNULL,
        )
    except subprocess.CalledProcessError:
        return None
    for line in out.splitlines():
        line = line.strip()
        if line.startswith("pid ="):
            try:
                return int(line.split("=", 1)[1].strip())
            except ValueError:
                return None
    return None


def wait_for_health(timeout_s: float = 45.0) -> bool:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        try:
            code, body, _ = get_json("/health")
            if code == 200 and body.get("ok") and body.get("model_loaded"):
                return True
        except Exception:
            pass
        time.sleep(0.5)
    return False


def rss_kb(pid: int) -> int | None:
    try:
        out = subprocess.check_output(["ps", "-o", "rss=", "-p", str(pid)], text=True)
        return int(out.strip())
    except Exception:
        return None


def run() -> int:
    failed: list[str] = []

    def check(name: str, ok: bool, detail: str) -> None:
        if not report(name, ok, detail):
            failed.append(name)

    print("== health ==")
    code, health, rtt = get_json("/health")
    check("GET /health", code == 200 and health.get("ok") and health.get("model_loaded"),
          f"code={code} rtt={rtt:.1f}ms body={health}")

    print("\n== latency and behavior matrix ==")
    short_latencies: list[int] = []
    for _ in range(20):
        code, body, _ = post_json("Hello world.")
        if code == 200:
            short_latencies.append(int(body.get("elapsed_ms", 999999)))
    short_p95 = percentile(short_latencies, 0.95)
    first_short = short_latencies[0] if short_latencies else 999999
    check("short x20", len(short_latencies) == 20 and first_short < 200 and short_p95 < 300,
          f"first={first_short}ms p95={short_p95}ms samples={short_latencies}")

    e2e_samples: list[int] = []
    for _ in range(50):
        code, body, rtt = post_json("The local translator stays offline.")
        if code == 200:
            e2e_samples.append(int(round(rtt)))
    e2e_p50 = percentile(e2e_samples, 0.50)
    e2e_p95 = percentile(e2e_samples, 0.95)
    check("short e2e x50", len(e2e_samples) == 50 and e2e_p50 < 500 and e2e_p95 < 800,
          f"p50={e2e_p50}ms p95={e2e_p95}ms")

    long_text = ("Local offline translation keeps private text on the Mac. " * 62).strip()
    code, body, _ = post_json(long_text)
    long_ms = int(body.get("elapsed_ms", 999999)) if isinstance(body, dict) else 999999
    check("long paragraph", code == 200 and long_ms < 2000,
          f"code={code} elapsed={long_ms}ms warnings={body.get('warnings') if isinstance(body, dict) else None}")

    code1, body1, _ = post_json("Cache probe unique phrase 1778469531910.")
    code2, body2, _ = post_json("Cache probe unique phrase 1778469531910.")
    cache_ms = int(body2.get("elapsed_ms", 999999)) if isinstance(body2, dict) else 999999
    check("cache repeat", code1 == 200 and code2 == 200 and body2.get("cached") is True and cache_ms < 5,
          f"cached={body2.get('cached')} elapsed={cache_ms}ms")

    code, body, _ = post_json("")
    check("empty input", code == 400 and body.get("error") == "empty_input", f"code={code} body={body}")

    code, body, _ = post_json("Hello " * 1000)
    check("6000+ chars", code == 200 and body.get("truncated") is True,
          f"code={code} truncated={body.get('truncated')}")

    code, body, _ = post_json("你好世界")
    check("CJK mismatch", code == 200 and body.get("error") == "src_lang_mismatch",
          f"code={code} error={body.get('error')}")

    code, body, _ = post_json("Hello 🌍 world")
    check("emoji input", code == 200 and "result" in body, f"code={code} result={body.get('result')!r}")

    print("\n== restart and memory ==")
    before_pid = service_pid()
    if before_pid is None:
        check("launchd pid", False, "could not resolve service pid")
    else:
        os.kill(before_pid, 9)
        print(f"killed pid {before_pid}; waiting 35s for launchd throttle window")
        time.sleep(35)
        healthy = wait_for_health(20)
        after_pid = service_pid()
        check("kill -9 restart", healthy and after_pid is not None and after_pid != before_pid,
              f"before={before_pid} after={after_pid}")

        for _ in range(100):
            post_json("RSS stability probe.")
        pid = service_pid()
        rss = rss_kb(pid) if pid else None
        check("RSS < 1.2GB", rss is not None and rss < 1_228_800,
              f"pid={pid} rss_kb={rss}")

    print("\n== summary ==")
    if failed:
        print("FAILED:", ", ".join(failed))
        return 1
    print("all automated checks passed")
    return 0


if __name__ == "__main__":
    sys.exit(run())
