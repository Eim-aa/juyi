#!/usr/bin/env bash
# Render the launchd plist template, install it, and bootstrap the service.
# Safe to re-run: bootout the existing service first if present.
set -euo pipefail

UID_NUM="$(id -u)"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
LABEL="io.github.Eim-aa.argos-translator"
TEMPLATE="$ROOT/launchd/$LABEL.plist.template"
TARGET="$HOME/Library/LaunchAgents/$LABEL.plist"
DOMAIN="gui/$UID_NUM"
LEGACY_LABEL="com.local.argos-translator"
LEGACY_PLIST="$HOME/Library/LaunchAgents/$LEGACY_LABEL.plist"

[[ -f "$TEMPLATE" ]] || { echo "missing template: $TEMPLATE" >&2; exit 1; }

mkdir -p "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"

# Record legacy state without changing it. Migration is committed only after
# the replacement service has bootstrapped successfully.
legacy_was_loaded=0
if launchctl print "$DOMAIN/$LEGACY_LABEL" >/dev/null 2>&1; then
    legacy_was_loaded=1
fi

# Render the checkout root and home directory without assuming bootstrap's
# default DEST. Use literal replacement in awk so '&' in an escaped path is
# never interpreted as a replacement metacharacter.
xml_escape() {
    printf '%s' "$1" | sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g'
}

ESCAPED_ROOT="$(xml_escape "$ROOT")"
ESCAPED_HOME="$(xml_escape "$HOME")"
tmp="$(mktemp "$TARGET.XXXXXX")"
if ! awk -v root="$ESCAPED_ROOT" -v home="$ESCAPED_HOME" '
    function replace_literal(value, needle, replacement, at) {
        while ((at = index(value, needle)) != 0) {
            value = substr(value, 1, at - 1) replacement substr(value, at + length(needle))
        }
        return value
    }
    {
        line = replace_literal($0, "__ROOT__", root)
        line = replace_literal(line, "__HOME__", home)
        print line
    }
' "$TEMPLATE" > "$tmp"; then
    rm -f "$tmp"
    echo "failed to render launchd plist" >&2
    exit 1
fi

# Lint the staged file so a rendering problem never replaces a working plist.
if ! plutil -lint "$tmp"; then
    rm -f "$tmp"
    exit 1
fi

previous_target=""
if [[ -f "$TARGET" ]]; then
    previous_target="$(mktemp "$TARGET.previous.XXXXXX")"
    if ! cp -p "$TARGET" "$previous_target"; then
        rm -f "$tmp"
        if [[ -n "$previous_target" ]]; then
            rm -f "$previous_target"
        fi
        echo "failed to back up existing launchd plist" >&2
        exit 1
    fi
fi

legacy_previous=""
if [[ -f "$LEGACY_PLIST" ]]; then
    legacy_previous="$(mktemp "$LEGACY_PLIST.previous.XXXXXX")"
    if ! cp -p "$LEGACY_PLIST" "$legacy_previous"; then
        rm -f "$tmp" "$legacy_previous"
        if [[ -n "$previous_target" ]]; then
            rm -f "$previous_target"
        fi
        echo "failed to back up legacy launchd plist" >&2
        exit 1
    fi
fi

was_loaded=0
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    was_loaded=1
fi

restore_legacy() {
    if [[ ! -f "$LEGACY_PLIST" && -n "$legacy_previous" ]]; then
        mv "$legacy_previous" "$LEGACY_PLIST"
        legacy_previous=""
        echo "[restored legacy plist after launchd failure]" >&2
    elif [[ -n "$legacy_previous" ]]; then
        rm -f "$legacy_previous"
        legacy_previous=""
    fi

    if [[ "$legacy_was_loaded" -eq 1 ]] \
        && ! launchctl print "$DOMAIN/$LEGACY_LABEL" >/dev/null 2>&1; then
        if [[ -f "$LEGACY_PLIST" ]]; then
            if launchctl bootstrap "$DOMAIN" "$LEGACY_PLIST"; then
                echo "[restored previous legacy service]" >&2
            else
                echo "ERROR: legacy plist was preserved, but its service could not be restarted" >&2
            fi
        else
            echo "ERROR: legacy service was loaded without an on-disk plist and could not be restored" >&2
        fi
    fi
}

restore_previous() {
    if [[ -n "$previous_target" ]]; then
        mv "$previous_target" "$TARGET"
        previous_target=""
        echo "[restored previous plist after launchd failure]" >&2
    else
        rm -f "$TARGET"
    fi

    if [[ "$was_loaded" -eq 1 ]] && ! launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
        if [[ -f "$TARGET" ]]; then
            if launchctl bootstrap "$DOMAIN" "$TARGET"; then
                echo "[restored previous running service]" >&2
            else
                echo "ERROR: previous plist was restored, but its service could not be restarted" >&2
            fi
        else
            echo "ERROR: previous service was loaded without an on-disk plist and could not be restored" >&2
        fi
    fi
    restore_legacy
}

# Stop the legacy job only after every replacement file has rendered, linted,
# and been backed up. On any later failure restore_legacy restarts it.
if [[ "$legacy_was_loaded" -eq 1 ]]; then
    echo "[bootout legacy $LEGACY_LABEL]"
    if ! launchctl bootout "$DOMAIN/$LEGACY_LABEL"; then
        restore_legacy
        rm -f "$tmp"
        if [[ -n "$previous_target" ]]; then
            rm -f "$previous_target"
        fi
        exit 1
    fi
    for i in $(seq 1 20); do
        launchctl print "$DOMAIN/$LEGACY_LABEL" >/dev/null 2>&1 || break
        sleep 0.2
    done
    if launchctl print "$DOMAIN/$LEGACY_LABEL" >/dev/null 2>&1; then
        echo "ERROR: legacy service did not stop; leaving it unchanged" >&2
        restore_legacy
        rm -f "$tmp"
        if [[ -n "$previous_target" ]]; then
            rm -f "$previous_target"
        fi
        exit 1
    fi
fi

if ! mv "$tmp" "$TARGET"; then
    rm -f "$tmp"
    if [[ -n "$previous_target" ]]; then
        rm -f "$previous_target"
    fi
    restore_legacy
    echo "failed to install rendered launchd plist" >&2
    exit 1
fi

# Idempotent bootstrap: bootout if currently loaded
if [[ "$was_loaded" -eq 1 ]]; then
    echo "[bootout existing $LABEL]"
    if ! launchctl bootout "$DOMAIN/$LABEL"; then
        restore_previous
        exit 1
    fi
    # bootout can lag; wait briefly
    for i in $(seq 1 20); do
        launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
        sleep 0.2
    done
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
        echo "ERROR: existing service did not stop; preserving its previous configuration" >&2
        restore_previous
        exit 1
    fi
fi

if ! launchctl bootstrap "$DOMAIN" "$TARGET"; then
    # A failed bootstrap may still have registered a partial job. Remove it
    # before restoring the old plist and (when applicable) the old service.
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
        if ! launchctl bootout "$DOMAIN/$LABEL"; then
            echo "WARN: partially registered replacement reported a bootout failure; checking whether it stopped" >&2
        fi
        for i in $(seq 1 20); do
            launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
            sleep 0.2
        done
        if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
            echo "ERROR: partial replacement is still loaded; kept its matching plist and the rollback backups for manual recovery" >&2
            exit 1
        fi
    fi
    restore_previous
    exit 1
fi

health_is_ready() {
    "$ROOT/venv/bin/python" - <<'PY' >/dev/null 2>&1
import json
import urllib.request

with urllib.request.urlopen("http://127.0.0.1:54321/health", timeout=1.0) as response:
    if response.status != 200:
        raise SystemExit(1)
    body = json.load(response)
if body.get("ok") is not True or body.get("auth_configured") is not True:
    raise SystemExit(1)
PY
}

health_ready=0
for i in $(seq 1 30); do
    if health_is_ready; then
        health_ready=1
        break
    fi
    sleep 0.5
done
if [[ "$health_ready" -ne 1 ]]; then
    echo "ERROR: replacement service failed its authenticated health check; rolling back" >&2
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
        if ! launchctl bootout "$DOMAIN/$LABEL"; then
            echo "WARN: replacement job reported a bootout failure; checking whether it stopped" >&2
        fi
        for i in $(seq 1 20); do
            launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
            sleep 0.2
        done
        if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
            echo "ERROR: replacement job is still loaded; kept its matching plist and the rollback backups for manual recovery" >&2
            exit 1
        fi
    fi
    restore_previous
    exit 1
fi
if [[ -n "$previous_target" ]]; then
    rm -f "$previous_target"
fi
if [[ -f "$LEGACY_PLIST" ]]; then
    rm -f "$LEGACY_PLIST"
    echo "[removed legacy plist $LEGACY_PLIST]"
fi
if [[ -n "$legacy_previous" ]]; then
    rm -f "$legacy_previous"
fi
echo "[bootstrap done: $DOMAIN/$LABEL]"
echo "  plist: $TARGET"
echo "  logs:  $HOME/Library/Logs/argos-translator.{out,err}.log"
