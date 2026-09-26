#!/usr/bin/env bash
# Bootout the launchd service and remove the plist file.
set -euo pipefail

UID_NUM="$(id -u)"
LABEL="io.github.Eim-aa.argos-translator"
TARGET="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$UID_NUM"

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    echo "[bootout $LABEL]"
    if ! launchctl bootout "$DOMAIN/$LABEL"; then
        echo "ERROR: could not stop $DOMAIN/$LABEL; kept $TARGET" >&2
        exit 1
    fi
    for i in $(seq 1 20); do
        launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
        sleep 0.2
    done
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
        echo "ERROR: $DOMAIN/$LABEL is still loaded; kept $TARGET" >&2
        exit 1
    fi
fi

if [[ -f "$TARGET" ]]; then
    rm -f "$TARGET"
    echo "[removed $TARGET]"
fi

echo "[done]"
