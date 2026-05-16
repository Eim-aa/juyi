"""Configuration constants for argos-translator service.

Flat module of constants — no env-time magic, no I/O. Anything that depends on
the user's HOME is computed at import time via pathlib.
"""
import os
from pathlib import Path

# ---- Paths ----
ROOT = Path.home() / ".local" / "share" / "argos-translator"
VENV = ROOT / "venv"
PACKAGES_DIR = ROOT / "packages"
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

# argostranslate reads this env var to locate installed model packages.
# We set it eagerly so any import of argostranslate.* picks it up.
os.environ.setdefault("ARGOS_PACKAGES_DIR", str(PACKAGES_DIR))
