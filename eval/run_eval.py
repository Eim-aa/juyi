#!/usr/bin/env python3
"""Run the 20-sentence translation quality set and print TSV output."""
from __future__ import annotations

import json
import pathlib
import sys
import time
import urllib.request

URL = "http://127.0.0.1:54321/translate"
HERE = pathlib.Path(__file__).resolve().parent
SENTENCES = HERE / "benchmark_sentences.txt"


def translate(text: str) -> dict:
    data = json.dumps({"text": text}).encode("utf-8")
    req = urllib.request.Request(
        URL,
        data=data,
        method="POST",
        headers={"Content-Type": "application/json"},
    )
    t0 = time.perf_counter()
    with urllib.request.urlopen(req, timeout=30) as resp:
        body = json.loads(resp.read())
    body["rtt_ms"] = round((time.perf_counter() - t0) * 1000)
    return body


def main() -> int:
    if not SENTENCES.exists():
        print(f"missing {SENTENCES}", file=sys.stderr)
        return 1
    lines = [line.strip() for line in SENTENCES.read_text(encoding="utf-8").splitlines() if line.strip()]
    print("idx\tsource\ttranslation\telapsed_ms\trtt_ms\tcached")
    for idx, line in enumerate(lines, 1):
        body = translate(line)
        result = body.get("result", "").replace("\t", " ").replace("\n", " ")
        print(f"{idx}\t{line}\t{result}\t{body.get('elapsed_ms')}\t{body.get('rtt_ms')}\t{body.get('cached')}")
    print("\nManual scoring: rate each translation 1-5; acceptance target average >= 3.5.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
