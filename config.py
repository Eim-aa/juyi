"""Configuration constants for argos-translator service.

Flat module of constants — no env-time magic, no I/O. Anything that depends on
the user's HOME is computed at import time via pathlib.
"""
from pathlib import Path

# ---- Paths ----
ROOT = Path.home() / ".local" / "share" / "argos-translator"
VENV = ROOT / "venv"
LOG_DIR = Path.home() / "Library" / "Logs"
LOG_FILE = LOG_DIR / "argos-translator.log"

# ---- HTTP transport (decision: HTTP loopback per IPC bench §6.1) ----
HOST = "127.0.0.1"
PORT = 54321

# ---- Translation language pair ----
SRC_LANG = "en"
TGT_LANG = "zh"

# ---- Input policy (§6.6) ----
MAX_INPUT_CHARS = 5000
LONG_INPUT_CHARS = 1500
LONG_INPUT_WORDS = 200
CJK_THRESHOLD = 0.5

# ---- Cache (§6.5) ----
CACHE_SIZE = 2000

# ---- Stats ring buffer for p50/p95 ----
LATENCY_RING_SIZE = 1000

# ---- Log rotation (§8) ----
LOG_MAX_BYTES = 10 * 1024 * 1024
LOG_BACKUP_COUNT = 3

# ---- Engine selection + Volcengine credentials ----
# Creds live in a local, gitignored file. The committed repo ships no creds, so
# ENGINE defaults to the fully-offline "apple". A local volc.env with valid keys
# and ENGINE=volc switches this machine's startup default to the cloud engine.
def _load_env_file(path: Path) -> dict:
    out: dict[str, str] = {}
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            out[k.strip()] = v.strip()
    except OSError:
        pass
    return out


_VOLC_ENV_FILE = Path.home() / ".config" / "argos-translator" / "volc.env"
_volc_cfg = _load_env_file(_VOLC_ENV_FILE)
VOLC_ACCESS_KEY = _volc_cfg.get("VOLC_ACCESS_KEY", "")
VOLC_SECRET_KEY = _volc_cfg.get("VOLC_SECRET_KEY", "")

# "apple" (default; macOS 15+ system on-device translation via
# bin/apple-translation-helper) or "volc" (Volcengine cloud). The legacy
# "argos" value from older configs maps to apple.
ENGINE = _volc_cfg.get("ENGINE", "apple")
if ENGINE not in ("apple", "volc"):
    ENGINE = "apple"
if ENGINE == "volc" and not (VOLC_ACCESS_KEY and VOLC_SECRET_KEY):
    ENGINE = "apple"

# Helper binary for the apple engine; built by scripts/install.sh on macOS 15+
# from apple/TranslationHelper.swift. Missing file = engine unavailable.
APPLE_HELPER_PATH = ROOT / "bin" / "apple-translation-helper"
