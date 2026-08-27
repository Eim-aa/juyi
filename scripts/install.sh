#!/usr/bin/env bash
# Install or refresh the local argos-translator service.
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
VENV="$ROOT/venv"
REQ="$ROOT/requirements.txt"
BREW_BIN="${BREW_BIN:-}"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

hint() {
    echo "FIX: $*" >&2
}

require_macos_15() {
    local platform product_version major
    platform="$(/usr/bin/uname -s 2>/dev/null || true)"
    [[ "$platform" == "Darwin" ]] || fail "句译公开版只能安装在 macOS 15.0 或更高版本。未做任何更改。"
    product_version="$(/usr/bin/sw_vers -productVersion 2>/dev/null || true)"
    major="${product_version%%.*}"
    if [[ ! "$major" =~ ^[0-9]+$ || "$major" -lt 15 ]]; then
        fail "句译公开版需要 macOS 15.0 或更高版本（当前：${product_version:-未知}）。未修改服务、Hammerspoon 或 App；现有安装已保留。"
    fi
    echo "macOS: $product_version"
}

find_brew() {
    if [[ -n "$BREW_BIN" && -x "$BREW_BIN" ]]; then
        echo "$BREW_BIN"
        return 0
    fi
    if command -v brew >/dev/null 2>&1; then
        command -v brew
        return 0
    fi
    if [[ -x /opt/homebrew/bin/brew ]]; then
        echo /opt/homebrew/bin/brew
        return 0
    fi
    if [[ -x /usr/local/bin/brew ]]; then
        echo /usr/local/bin/brew
        return 0
    fi
    return 1
}

version_ge_310() {
    "$1" - "$1" <<'PY'
import subprocess
import sys
py = sys.argv[1]
out = subprocess.check_output([py, "-c", "import sys; print('%d.%d' % sys.version_info[:2])"], text=True).strip()
maj, minor = map(int, out.split("."))
raise SystemExit(0 if (maj, minor) >= (3, 10) else 1)
PY
}

find_python() {
    local candidates=(
        /opt/homebrew/bin/python3.12
        /opt/homebrew/bin/python3.11
        /opt/homebrew/bin/python3.10
        /usr/local/bin/python3.12
        /usr/local/bin/python3.11
        /usr/local/bin/python3.10
        python3.12
        python3.11
        python3.10
        python3
    )
    local py
    for py in "${candidates[@]}"; do
        if command -v "$py" >/dev/null 2>&1; then
            py="$(command -v "$py")"
            if version_ge_310 "$py"; then
                echo "$py"
                return 0
            fi
        elif [[ -x "$py" ]]; then
            if version_ge_310 "$py"; then
                echo "$py"
                return 0
            fi
        fi
    done
    return 1
}

echo "== preflight =="

# This must remain the first preflight action. A rejected macOS version must
# not create a token/venv, touch launchd or Hammerspoon, build, or replace App.
require_macos_15

# Refuse a conflicting Hammerspoon module before installing dependencies or
# changing launchd state. The helper also validates any existing managed block.
"$ROOT/scripts/hammerspoon_hook.sh" check

BREW="$(find_brew)" || {
    hint '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'
    fail "Homebrew not found"
}
echo "brew: $BREW"
"$BREW" --version | head -1

PYTHON="$(find_python)" || {
    hint "brew install python@3.12"
    fail "python >= 3.10 not found; /usr/bin/python3 on macOS is often 3.9"
}
echo "python: $PYTHON"
"$PYTHON" --version

avail_kb="$(df -k "$HOME" | awk 'NR==2 {print $4}')"
if [[ "${avail_kb:-0}" -lt 204800 ]]; then
    hint "Free at least 200MB on the system volume, then rerun this script"
    fail "not enough disk space"
fi
echo "disk: $((avail_kb / 1024)) MB available"

[[ -f "$REQ" ]] || fail "missing requirements.txt at $REQ"

echo
echo "== local authentication =="
PYTHON_BIN="$PYTHON" "$ROOT/scripts/ensure_auth_token.sh"

echo
echo "== directories =="
mkdir -p "$ROOT" "$ROOT/scripts" "$ROOT/launchd" "$ROOT/hammerspoon" "$HOME/Library/Logs"
ln -sfn "$HOME/Library/Logs" "$ROOT/logs"
echo "root: $ROOT"

echo
echo "== venv =="
if [[ ! -x "$VENV/bin/python" ]]; then
    "$PYTHON" -m venv "$VENV"
fi
"$VENV/bin/python" -m pip install --upgrade pip
"$VENV/bin/pip" install --no-cache-dir -r "$REQ"

echo
echo "== launchd =="
"$ROOT/scripts/launchd_install.sh"

echo
echo "== hammerspoon files =="
if [[ ! -d "/Applications/Hammerspoon.app" && ! -d "$HOME/Applications/Hammerspoon.app" ]]; then
    echo "[installing the shortcut helper]"
    "$BREW" install --cask hammerspoon
fi
"$ROOT/scripts/hammerspoon_hook.sh" install
"$ROOT/scripts/hammerspoon_hook.sh" reload

# Compile the system-translation helper on the supported macOS baseline.
if command -v swiftc >/dev/null 2>&1; then
    echo "[building apple-translation-helper (macOS on-device translation engine)]"
    mkdir -p "$ROOT/bin"
    if "$ROOT/scripts/build_apple_helper.sh" "$ROOT/bin/apple-translation-helper"; then
        echo "apple engine ready: $ROOT/bin/apple-translation-helper"
    else
        echo "WARN: apple helper build failed; offline engine unavailable (volc cloud unaffected)" >&2
    fi
else
    echo "WARN: apple engine helper was not built because swiftc is unavailable; install Xcode Command Line Tools and rerun this installer" >&2
fi

echo
echo "== native app =="
if command -v swiftc >/dev/null 2>&1; then
    "$ROOT/scripts/install_macos_app.sh"
else
    echo "WARN: swiftc not found; native app was not built. Install Xcode Command Line Tools and run scripts/install_macos_app.sh" >&2
fi

echo
echo "== required next steps =="
echo "1. Open 句译 from Applications or Launchpad."
echo "2. Follow its guide to install Hammerspoon and grant Accessibility permission."
echo "3. Ensure ~/.hammerspoon/init.lua contains the argos-translator managed block."
echo "4. Reload Hammerspoon config, select English text, double-tap Option."
echo
echo "Run diagnostics any time with:"
echo "  $ROOT/scripts/test.sh"
