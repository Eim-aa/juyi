#!/usr/bin/env bash
# IPC microbench: compare HTTP loopback vs Unix Domain Socket RTT.
# Drives bench_ipc.py: spawns a minimal starlette/uvicorn server, runs 100
# closed-loop requests, prints p50/p95/p99, repeats for the other transport.
set -euo pipefail

ROOT="$HOME/.local/share/argos-translator"
PY="$ROOT/venv/bin/python"
SCRIPT="$ROOT/scripts/bench_ipc.py"

wait_for() {
  # wait_for <test-command> — polls every 50ms up to 5s
  local i
  for i in $(seq 1 100); do
    if eval "$1" >/dev/null 2>&1; then return 0; fi
    sleep 0.05
  done
  return 1
}

run_one() {
  local mode=$1
  "$PY" "$SCRIPT" server "$mode" >/dev/null 2>&1 &
  local pid=$!
  if [[ $mode == http ]]; then
    wait_for "curl -sf -X POST http://127.0.0.1:54399/noop -d '{}'"
  else
    wait_for "curl -sf --unix-socket /tmp/argos-bench.sock -X POST http://x/noop -d '{}'"
  fi
  "$PY" "$SCRIPT" client "$mode"
  kill "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

run_one http
run_one uds
