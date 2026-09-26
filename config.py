"""Configuration constants for the argos-translator service."""
import json
import os
import re
import stat
import subprocess
from dataclasses import dataclass
from pathlib import Path
from typing import Callable, Optional

# ---- Paths ----
_default_root = Path.home() / ".local" / "share" / "argos-translator"
_root_override = os.environ.get("JUYI_ROOT", "")
ROOT = (
    Path(_root_override)
    if _root_override and Path(_root_override).is_absolute()
    else _default_root
)
LOG_DIR = Path.home() / "Library" / "Logs"
LOG_FILE = LOG_DIR / "argos-translator.log"
# The apple helper's stderr (Translation framework errors) lands here.
HELPER_LOG_FILE = LOG_DIR / "argos-translator-helper.log"

# ---- HTTP transport ----
# Loopback HTTP over a Unix socket: the RTT difference was negligible in
# scripts/bench_ipc.py, and Hammerspoon's hs.http only speaks TCP.
HOST = "127.0.0.1"
PORT = 54321

# Requests that can translate text or expose usage metrics require this
# installer-created bearer token. Missing or malformed token state fails closed.
AUTH_TOKEN_FILE = Path.home() / ".config" / "argos-translator" / "auth-token"
CLOUD_REMOVAL_MARKER_FILE = (
    Path.home() / ".config" / "argos-translator" / "cloud-removal-pending"
)


_AUTH_TOKEN_RE = re.compile(r"[0-9a-f]{64}")


def _load_auth_token(path: Path) -> str:
    """Load only installer-shaped tokens; malformed files fail closed later."""
    try:
        metadata = path.lstat()
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_mode & 0o077:
            return ""
        if hasattr(os, "getuid") and metadata.st_uid != os.getuid():
            return ""
        value = path.read_text(encoding="utf-8").strip()
    except OSError:
        return ""
    return value if _AUTH_TOKEN_RE.fullmatch(value) else ""


def _read_cloud_removal_marker(path: Path) -> str:
    """Return ``present``, ``not_found`` or ``unavailable`` for the kill switch.

    Only a confirmed absence permits cloud traffic.  An unreadable, malformed,
    symlinked, foreign-owned or overly broad marker fails closed.  The open-file
    metadata check also prevents a path swap between ``lstat`` and ``open``.
    """
    try:
        path_metadata = path.lstat()
    except FileNotFoundError:
        return "not_found"
    except OSError:
        return "unavailable"

    if not stat.S_ISREG(path_metadata.st_mode):
        return "unavailable"
    if stat.S_IMODE(path_metadata.st_mode) & 0o077:
        return "unavailable"
    if hasattr(os, "getuid") and path_metadata.st_uid != os.getuid():
        return "unavailable"

    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError:
        # The path was present when checked above.  A disappearance or any
        # other race is ambiguous, so this read must not enable cloud traffic.
        return "unavailable"

    try:
        opened_metadata = os.fstat(descriptor)
        if not stat.S_ISREG(opened_metadata.st_mode):
            return "unavailable"
        if stat.S_IMODE(opened_metadata.st_mode) & 0o077:
            return "unavailable"
        if hasattr(os, "getuid") and opened_metadata.st_uid != os.getuid():
            return "unavailable"
        if (
            opened_metadata.st_dev != path_metadata.st_dev
            or opened_metadata.st_ino != path_metadata.st_ino
        ):
            return "unavailable"
        return "present" if os.read(descriptor, 3) == b"1\n" else "unavailable"
    except OSError:
        return "unavailable"
    finally:
        try:
            os.close(descriptor)
        except OSError:
            pass


def cloud_removal_blocks_volc(path: Optional[Path] = None) -> bool:
    """Dynamically enforce the native app's durable cloud-removal marker."""
    marker = CLOUD_REMOVAL_MARKER_FILE if path is None else Path(path)
    return _read_cloud_removal_marker(marker) != "not_found"


AUTH_TOKEN = _load_auth_token(AUTH_TOKEN_FILE)
# Source-tree development can explicitly opt out. Production/default behavior
# is fail-closed when the installer token is missing, unreadable, or malformed.
ALLOW_UNAUTHENTICATED = os.environ.get("JUYI_ALLOW_UNAUTHENTICATED") == "1"

# ---- Translation language pair ----
SRC_LANG = "en"
TGT_LANG = "zh"

# ---- Input policy ----
MAX_INPUT_CHARS = 5000
CJK_THRESHOLD = 0.5

# ---- Cache ----
CACHE_SIZE = 2000

# ---- Stats ring buffer for p50/p95 ----
LATENCY_RING_SIZE = 1000

# ---- Log rotation ----
LOG_MAX_BYTES = 10 * 1024 * 1024
LOG_BACKUP_COUNT = 3

# ---- Engine selection + Volcengine credentials ----
# New installs keep both Volcengine values in one Keychain generic-password
# item. volc.env remains the engine/non-secret settings file; legacy credentials
# in that file are read only when Keychain explicitly reports item-not-found.
VOLC_KEYCHAIN_SERVICE = "io.github.Eim-aa.juyi.volc"
VOLC_KEYCHAIN_ACCOUNT = "volc"
VOLC_PENDING_KEYCHAIN_SERVICE = "io.github.Eim-aa.juyi.volc.pending"
VOLC_PENDING_KEYCHAIN_ACCOUNT = "pending"


def _load_env_file(path: Path) -> dict:
    out: dict[str, str] = {}
    try:
        for line in path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            v = v.strip()
            # Tolerate shell-style quoting: VOLC_ACCESS_KEY="abc" == abc.
            if len(v) >= 2 and v[0] == v[-1] and v[0] in ("'", '"'):
                v = v[1:-1]
            out[k.strip()] = v
    except OSError:
        pass
    return out


def _parse_keychain_credentials(payload: str) -> Optional[tuple[str, str]]:
    """Parse the JSON stored in Keychain without ever including it in errors."""
    try:
        value = json.loads(payload)
    except (json.JSONDecodeError, TypeError):
        return None
    if not isinstance(value, dict):
        return None
    access_key = value.get("access_key")
    secret_key = value.get("secret_key")
    if not isinstance(access_key, str) or not isinstance(secret_key, str):
        return None
    access_key = access_key.strip()
    secret_key = secret_key.strip()
    if not access_key or not secret_key:
        return None
    return access_key, secret_key


@dataclass(frozen=True)
class KeychainCredentialRead:
    status: str
    credentials: Optional[tuple[str, str]] = None


def _load_keychain_credentials(
    runner: Optional[Callable[..., subprocess.CompletedProcess[str]]] = None,
    *,
    service: str = VOLC_KEYCHAIN_SERVICE,
    account: str = VOLC_KEYCHAIN_ACCOUNT,
) -> KeychainCredentialRead:
    """Read the Volcengine JSON item through macOS's ``security`` tool.

    ``runner`` is injectable so tests never touch the user's real Keychain.
    stderr is discarded because Keychain diagnostics are not useful service
    logs and must never accidentally include credential material.
    """
    if runner is None:
        runner = subprocess.run
    try:
        result = runner(
            [
                "/usr/bin/security",
                "find-generic-password",
                "-s",
                service,
                "-a",
                account,
                "-w",
            ],
            stdout=subprocess.PIPE,
            stderr=subprocess.DEVNULL,
            text=True,
            timeout=3,
            check=False,
        )
    except (OSError, subprocess.SubprocessError):
        return KeychainCredentialRead("unavailable")
    if result.returncode == 44:
        return KeychainCredentialRead("not_found")
    if result.returncode != 0:
        return KeychainCredentialRead("unavailable")
    credentials = _parse_keychain_credentials(result.stdout)
    if credentials is None:
        return KeychainCredentialRead("invalid")
    return KeychainCredentialRead("found", credentials)


def _resolve_volc_credentials(
    keychain: KeychainCredentialRead, env: dict[str, str]
) -> tuple[str, str]:
    """Use plaintext legacy keys only when Keychain explicitly has no item."""
    if keychain.status == "found" and keychain.credentials is not None:
        return keychain.credentials
    if keychain.status == "not_found":
        return env.get("VOLC_ACCESS_KEY", ""), env.get("VOLC_SECRET_KEY", "")
    # A locked, denied or malformed Keychain item is not the same as absence.
    # Fail closed instead of silently activating potentially stale plaintext.
    return "", ""


_VOLC_ENV_FILE = Path.home() / ".config" / "argos-translator" / "volc.env"
_volc_cfg = _load_env_file(_VOLC_ENV_FILE)
if cloud_removal_blocks_volc():
    # Do not even load cloud secrets into a newly started service while a
    # removal transaction exists or cannot be verified. The per-request check
    # remains necessary for a service that was already running when the marker
    # appeared.
    _keychain_read = KeychainCredentialRead("unavailable")
    VOLC_ACCESS_KEY, VOLC_SECRET_KEY = "", ""
else:
    _keychain_read = _load_keychain_credentials()
    VOLC_ACCESS_KEY, VOLC_SECRET_KEY = _resolve_volc_credentials(
        _keychain_read, _volc_cfg
    )

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
