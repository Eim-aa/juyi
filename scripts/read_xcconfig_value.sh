#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
    echo "usage: $0 <xcconfig> <key>" >&2
    exit 2
fi

CONFIG_FILE="$1"
SETTING_KEY="$2"
[[ -f "$CONFIG_FILE" ]] || { echo "missing xcconfig: $CONFIG_FILE" >&2; exit 1; }
[[ "$SETTING_KEY" =~ ^[A-Z0-9_]+$ ]] || { echo "invalid xcconfig key: $SETTING_KEY" >&2; exit 2; }

VALUE="$(/usr/bin/awk -v key="$SETTING_KEY" '
    $0 ~ "^[[:space:]]*" key "[[:space:]]*=" {
        line = $0
        sub("^[[:space:]]*" key "[[:space:]]*=[[:space:]]*", "", line)
        sub("[[:space:]]*//.*$", "", line)
        gsub("^[[:space:]]+|[[:space:]]+$", "", line)
        print line
        exit
    }
' "$CONFIG_FILE")"

[[ -n "$VALUE" ]] || { echo "missing setting $SETTING_KEY in $CONFIG_FILE" >&2; exit 1; }
printf '%s\n' "$VALUE"
