#!/usr/bin/env bash
# Uninstall the launchd service and local runtime. Model deletion is optional.
set -euo pipefail

ROOT="$HOME/.local/share/argos-translator"
VENV="$ROOT/venv"
PACKAGES_DIR="$ROOT/packages"
LABEL="io.github.Eim-aa.argos-translator"
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

echo "== launchd =="
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    launchctl bootout "$DOMAIN/$LABEL" || true
    echo "booted out $DOMAIN/$LABEL"
else
    echo "service not loaded"
fi

if [[ -f "$PLIST" ]]; then
    rm -f "$PLIST"
    echo "removed $PLIST"
fi

echo
echo "== runtime =="
if [[ -d "$VENV" ]]; then
    rm -rf "$VENV"
    echo "removed $VENV"
fi

rm -f "$HOME/Library/Logs/argos-translator.out.log" \
      "$HOME/Library/Logs/argos-translator.err.log" \
      "$HOME/Library/Logs/argos-translator.log" \
      "$HOME/Library/Logs/argos-translator.log".*
echo "removed argos-translator logs"

echo
read -r -p "Delete installed model package at $PACKAGES_DIR? [y/N] " answer
case "${answer:-N}" in
    y|Y|yes|YES)
        rm -rf "$PACKAGES_DIR"
        echo "removed $PACKAGES_DIR"
        ;;
    *)
        echo "kept model package"
        ;;
esac

echo "done"
