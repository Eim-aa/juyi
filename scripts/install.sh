#!/usr/bin/env bash
# Install or refresh the local argos-translator service.
set -euo pipefail

ROOT="$HOME/.local/share/argos-translator"
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
if [[ "${avail_kb:-0}" -lt 1048576 ]]; then
    hint "Free at least 1GB on the system volume, then rerun this script"
    fail "not enough disk space"
fi
echo "disk: $((avail_kb / 1024)) MB available"

[[ -f "$REQ" ]] || fail "missing requirements.txt at $REQ"

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
mkdir -p "$HOME/.hammerspoon"
ln -sfn "$ROOT/hammerspoon/argos-translator.lua" "$HOME/.hammerspoon/argos-translator.lua"
if [[ ! -f "$HOME/.hammerspoon/init.lua" ]]; then
    printf '%s\n' 'require("argos-translator")' > "$HOME/.hammerspoon/init.lua"
elif ! grep -Fq 'require("argos-translator")' "$HOME/.hammerspoon/init.lua"; then
    printf '\n%s\n' 'require("argos-translator")' >> "$HOME/.hammerspoon/init.lua"
fi

# Optional apple engine: compile the system-translation helper on macOS 15+.
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
if [[ "$MACOS_MAJOR" -ge 15 ]] && command -v swiftc >/dev/null 2>&1; then
    echo "[building apple-translation-helper (macOS on-device translation engine)]"
    mkdir -p "$ROOT/bin"
    if swiftc -O -o "$ROOT/bin/apple-translation-helper" "$ROOT/apple/TranslationHelper.swift"; then
        echo "apple engine ready: $ROOT/bin/apple-translation-helper"
    else
        echo "WARN: apple helper build failed; offline engine unavailable (volc cloud unaffected)" >&2
    fi
else
    echo "[skipping apple engine helper: needs macOS 15+ and swiftc; configure volc.env to use the cloud engine]"
fi

echo
echo "== required next steps =="
echo "1. Install Hammerspoon if needed: brew install --cask hammerspoon"
echo "2. Open Hammerspoon and grant Accessibility permission in System Settings."
echo "3. Ensure ~/.hammerspoon/init.lua contains: require(\"argos-translator\")"
echo "4. Reload Hammerspoon config, select English text, double-tap Option."
echo
echo "Run diagnostics any time with:"
echo "  $ROOT/scripts/test.sh"
