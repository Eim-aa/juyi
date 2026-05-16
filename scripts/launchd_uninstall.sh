#!/usr/bin/env bash
# Bootout the launchd service and remove the plist file.
set -euo pipefail

UID_NUM="$(id -u)"
LABEL="io.github.Eim-aa.argos-translator"
TARGET="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$UID_NUM"

if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    echo "[bootout $LABEL]"
    launchctl bootout "$DOMAIN/$LABEL" || true
fi

if [[ -f "$TARGET" ]]; then
    rm -f "$TARGET"
    echo "[removed $TARGET]"
fi

echo "[done]"
