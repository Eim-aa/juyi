#!/usr/bin/env bash
# Full automated diagnostic matrix for argos-translator.
set -euo pipefail

ROOT="$HOME/.local/share/argos-translator"
PY="$ROOT/venv/bin/python"
TEST="$ROOT/scripts/test_matrix.py"

[[ -x "$PY" ]] || { echo "missing venv python: $PY" >&2; exit 1; }
[[ -f "$TEST" ]] || { echo "missing test matrix: $TEST" >&2; exit 1; }

"$PY" "$TEST"
