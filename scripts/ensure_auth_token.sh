#!/usr/bin/env bash
# Create the local API authentication token without ever printing its value.
set -euo pipefail
umask 077

CONFIG_DIR="$HOME/.config/argos-translator"
AUTH_TOKEN="$CONFIG_DIR/auth-token"
PYTHON_BIN="${PYTHON_BIN:-python3}"

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

token_file_is_valid() {
    LC_ALL=C awk '
        NR == 1 && $0 ~ /^[0-9a-f]{64}$/ { valid = 1; next }
        { valid = 0 }
        END { exit !(NR == 1 && valid == 1) }
    ' "$1"
}

validate_existing_token() {
    if [[ -L "$AUTH_TOKEN" || ! -f "$AUTH_TOKEN" ]]; then
        fail "refusing unsafe auth token path (must be a regular, non-symlink file): $AUTH_TOKEN"
    fi
    if ! token_file_is_valid "$AUTH_TOKEN"; then
        fail "existing auth token is invalid; expected exactly 64 lowercase hexadecimal characters at $AUTH_TOKEN"
    fi
    chmod 600 "$AUTH_TOKEN"
    echo "[preserved existing auth token at $AUTH_TOKEN; contents hidden]"
}

if [[ -L "$CONFIG_DIR" ]]; then
    fail "refusing symlinked config directory: $CONFIG_DIR"
fi
mkdir -p "$CONFIG_DIR"
[[ -d "$CONFIG_DIR" ]] || fail "config path is not a directory: $CONFIG_DIR"
chmod 700 "$CONFIG_DIR"

if [[ -e "$AUTH_TOKEN" || -L "$AUTH_TOKEN" ]]; then
    validate_existing_token
    exit 0
fi

tmp="$(mktemp "$CONFIG_DIR/.auth-token.XXXXXX")"
if [[ -x /usr/bin/openssl ]]; then
    if ! /usr/bin/openssl rand -hex 32 > "$tmp"; then
        rm -f "$tmp"
        fail "could not generate auth token with /usr/bin/openssl"
    fi
elif command -v openssl >/dev/null 2>&1; then
    if ! openssl rand -hex 32 > "$tmp"; then
        rm -f "$tmp"
        fail "could not generate auth token with openssl"
    fi
elif command -v "$PYTHON_BIN" >/dev/null 2>&1 || [[ -x "$PYTHON_BIN" ]]; then
    if ! "$PYTHON_BIN" -c 'import secrets; print(secrets.token_hex(32))' > "$tmp"; then
        rm -f "$tmp"
        fail "could not generate auth token with Python secrets"
    fi
else
    rm -f "$tmp"
    fail "neither openssl nor a usable Python interpreter is available"
fi

if ! token_file_is_valid "$tmp"; then
    rm -f "$tmp"
    fail "generated auth token failed validation"
fi
chmod 600 "$tmp"

# A hard link provides an atomic no-clobber install on macOS. If another
# installer won the race, validate and preserve that file instead.
if ln "$tmp" "$AUTH_TOKEN" 2>/dev/null; then
    rm -f "$tmp"
    echo "[created auth token at $AUTH_TOKEN; contents hidden]"
else
    rm -f "$tmp"
    if [[ -e "$AUTH_TOKEN" || -L "$AUTH_TOKEN" ]]; then
        validate_existing_token
    else
        fail "could not install auth token at $AUTH_TOKEN"
    fi
fi
