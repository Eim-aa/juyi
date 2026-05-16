#!/usr/bin/env bash
# Render the launchd plist template, install it, and bootstrap the service.
# Safe to re-run: bootout the existing service first if present.
set -euo pipefail

USER_NAME="$(id -un)"
UID_NUM="$(id -u)"
ROOT="$HOME/.local/share/argos-translator"
LABEL="io.github.Eim-aa.argos-translator"
TEMPLATE="$ROOT/launchd/$LABEL.plist.template"
TARGET="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$UID_NUM"
LEGACY_LABEL="com.local.argos-translator"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"

[[ -f "$TEMPLATE" ]] || { echo "missing template: $TEMPLATE" >&2; exit 1; }

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

# Migrate from the legacy "com.local.*" label if present so the old service
# doesn't keep competing for port 54321.
if launchctl print "$DOMAIN/$LEGACY_LABEL" >/dev/null 2>&1; then
    echo "[bootout legacy $LEGACY_LABEL]"
    launchctl bootout "$DOMAIN/$LEGACY_LABEL" || true
fi
if [[ -f "$LEGACY_PLIST" ]]; then
    rm -f "$LEGACY_PLIST"
    echo "[removed legacy plist $LEGACY_PLIST]"
fi

# Render: substitute __USER__ placeholder
sed "s|__USER__|$USER_NAME|g" "$TEMPLATE" > "$TARGET"

# Lint before loading
plutil -lint "$TARGET"

# Idempotent bootstrap: bootout if currently loaded
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    echo "[bootout existing $LABEL]"
    launchctl bootout "$DOMAIN/$LABEL" || true
    # bootout can lag; wait briefly
    for i in $(seq 1 20); do
        launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
        sleep 0.2
    done
fi

launchctl bootstrap "$DOMAIN" "$TARGET"
echo "[bootstrap done: $DOMAIN/$LABEL]"
echo "  plist: $TARGET"
echo "  logs:  $HOME/Library/Logs/argos-translator.{out,err}.log"
