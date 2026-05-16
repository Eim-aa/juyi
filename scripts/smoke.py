"""Smoke test for /translate edge cases. Run after server is up."""
import json
import sys
import time
import urllib.error
import urllib.request

URL = "http://127.0.0.1:54321"


def _request(method: str, path: str, body=None, timeout: float = 30):
    data = json.dumps(body).encode("utf-8") if body is not None else None
    req = urllib.request.Request(
        URL + path, data=data, method=method,
        headers={"Content-Type": "application/json"} if data else {},
    )
    t0 = time.perf_counter()
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            raw = r.read()
            return r.status, raw, (time.perf_counter() - t0) * 1000
    except urllib.error.HTTPError as e:
        return e.code, e.read(), (time.perf_counter() - t0) * 1000


def post(path, body):
    code, raw, rtt = _request("POST", path, body)
    return code, json.loads(raw), rtt


def get(path):
    code, raw, rtt = _request("GET", path)
    return code, raw.decode("utf-8"), rtt


def short(s: str, n: int = 120) -> str:
    if len(s) <= n:
        return s
    return s[:n] + "…"


def show(name: str, code: int, resp: dict, rtt_ms: float, expect_status=200, **expect) -> bool:
    ok = code == expect_status
    for k, v in expect.items():
        if resp.get(k) != v:
            ok = False
    mark = "PASS" if ok else "FAIL"
    line = short(json.dumps(resp, ensure_ascii=False))
    print(f"[{mark}] [{code}] {rtt_ms:6.1f}ms  {name:18s}  {line}")
    return ok


def main() -> int:
    print("=== /health ===")
    code, body, rtt = get("/health")
    print(body)
    if code != 200:
        print("HEALTH FAILED")
        return 1

    print("\n=== /translate cases ===")
    failed = []

    cases = [
        # name, body, expectations
        ("short", {"text": "The quick brown fox jumps over the lazy dog."}, dict(cached=False)),
        ("short_cached", {"text": "The quick brown fox jumps over the lazy dog."}, dict(cached=True)),
        ("empty", {"text": ""}, dict(_status=400, error="empty_input")),
        ("cjk", {"text": "你好世界，这是一段中文。"}, dict(error="src_lang_mismatch")),
        ("emoji", {"text": "Hello 🌍 world"}, {}),
        ("punct", {"text": "...!!!"}, dict(skipped=True)),
        ("single_letter", {"text": "A"}, dict(skipped=True)),
        ("long_paragraph", {"text": "The cat sat on the mat. " * 80}, {}),  # 80*24=1920 chars, 80*6=480 words -> long path
        ("huge_6000", {"text": "Hello world. " * 600}, dict(truncated=True)),
        ("multiline", {"text": "Hello.\n\nGoodbye."}, {}),
    ]

    for name, body, expect in cases:
        expect_status = expect.pop("_status", 200)
        try:
            code, resp, rtt = post("/translate", body)
            ok = show(name, code, resp, rtt, expect_status=expect_status, **expect)
            if not ok:
                failed.append(name)
        except Exception as e:
            print(f"[FAIL] [---]   ----ms  {name:18s}  EXC: {e}")
            failed.append(name)

    print("\n=== /metrics (last 6 lines) ===")
    code, text, _ = get("/metrics")
    print("\n".join(text.strip().splitlines()[-6:]))

    print("\n=== summary ===")
    if failed:
        print(f"FAILED: {failed}")
        return 1
    print(f"all {len(cases)} cases passed")
    return 0


if __name__ == "__main__":
    sys.exit(main())
