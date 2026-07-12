#!/usr/bin/env bash
# Uninstall the launchd service, runtime, logs, and the Hammerspoon hook.
# The config dir (~/.config/argos-translator, holds the Volcengine API keys)
# is only removed after an explicit confirmation. Safe to re-run.
set -euo pipefail

ROOT="$HOME/.local/share/argos-translator"
LABEL="io.github.Eim-aa.argos-translator"
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONFIG_DIR="$HOME/.config/argos-translator"
HS_DIR="$HOME/.hammerspoon"
LOGS="$HOME/Library/Logs"

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
rm -rf "$ROOT/venv" "$ROOT/bin" "$ROOT/packages"
if [[ -L "$ROOT/logs" ]]; then
    rm -f "$ROOT/logs"
fi
echo "removed venv, helper binary, legacy packages dir, logs symlink"

echo
echo "== logs =="
rm -f "$LOGS/argos-translator.out.log" \
      "$LOGS/argos-translator.err.log" \
      "$LOGS/argos-translator.log" \
      "$LOGS/argos-translator.log".* \
      "$LOGS/argos-translator-hs.log" \
      "$LOGS/argos-translator-hs.log".* \
      "$LOGS/argos-translator-helper.log"
echo "removed argos-translator logs"

echo
echo "== hammerspoon hook =="
rm -f "$HS_DIR/argos-translator.lua"
INIT="$HS_DIR/init.lua"
if [[ -f "$INIT" ]] && grep -Fxq 'require("argos-translator")' "$INIT"; then
    tmp="$(mktemp)"
    grep -Fxv 'require("argos-translator")' "$INIT" > "$tmp" || true
    mv "$tmp" "$INIT"
    echo "removed require line from $INIT"
fi

echo
echo "== config (API keys) =="
if [[ -d "$CONFIG_DIR" ]]; then
    read -r -p "Delete $CONFIG_DIR (holds your Volcengine API keys and engine state)? [y/N] " answer || answer="N"
    case "${answer:-N}" in
        y|Y|yes|YES)
            rm -rf "$CONFIG_DIR"
            echo "removed $CONFIG_DIR"
            ;;
        *)
            echo "kept $CONFIG_DIR"
            ;;
    esac
fi

echo
echo "done. Remaining manual steps for a full wipe:"
echo "  rm -rf \"$ROOT\"                      # this checkout"
echo "  brew uninstall --cask hammerspoon    # only if nothing else uses it"
