"""
Microbenchmark: HTTP loopback vs Unix Domain Socket RTT.

Closed-loop, single-process client; matches Hammerspoon's serial async call pattern.
Each iteration opens a fresh connection (Connection: close) to mirror hs.http.asyncPost.
"""
import os
import socket
import statistics
import sys
import time

PORT = 54399
SOCK = "/tmp/argos-bench.sock"
N = 110  # 100 measured + 10 warmup


async def app(scope, receive, send):
    if scope["type"] != "http":
        return
    while True:
        msg = await receive()
        if not msg.get("more_body"):
            break
    body = b'{"ok":true}'
    await send(
        {
            "type": "http.response.start",
            "status": 200,
            "headers": [
                (b"content-type", b"application/json"),
                (b"content-length", str(len(body)).encode()),
            ],
        }
    )
    await send({"type": "http.response.body", "body": body})


def run_server(mode: str) -> None:
    import uvicorn

    if mode == "http":
        uvicorn.run(app, host="127.0.0.1", port=PORT, log_level="error", access_log=False)
    else:
        if os.path.exists(SOCK):
            os.unlink(SOCK)
        uvicorn.run(app, uds=SOCK, log_level="error", access_log=False)


def bench(family: int, target) -> list[float]:
    req = (
        b"POST /noop HTTP/1.1\r\n"
        b"Host: x\r\n"
        b"Content-Type: application/json\r\n"
        b"Content-Length: 12\r\n"
        b"Connection: close\r\n\r\n"
        b'{"text":"x"}'
    )
    out = []
    for _ in range(N):
        t0 = time.perf_counter_ns()
        s = socket.socket(family, socket.SOCK_STREAM)
        s.connect(target)
        s.sendall(req)
        while s.recv(4096):
            pass
        s.close()
        out.append((time.perf_counter_ns() - t0) / 1e6)
    return out


def report(name: str, samples: list[float]) -> float:
    s = sorted(samples)
    n = len(s)
    p50 = s[n // 2]
    p95 = s[int(n * 0.95)]
    p99 = s[int(n * 0.99)]
    print(
        f"{name:5s}  n={n:3d}  min={min(s):5.2f}  p50={p50:5.2f}  "
        f"p95={p95:5.2f}  p99={p99:5.2f}  max={max(s):5.2f}  "
        f"mean={statistics.mean(s):5.2f}  (ms)"
    )
    return p50


def main() -> None:
    cmd = sys.argv[1]
    if cmd == "server":
        run_server(sys.argv[2])
    elif cmd == "client":
        mode = sys.argv[2]
        if mode == "http":
            samples = bench(socket.AF_INET, ("127.0.0.1", PORT))
        else:
            samples = bench(socket.AF_UNIX, SOCK)
        report(mode, samples[10:])


if __name__ == "__main__":
    main()
