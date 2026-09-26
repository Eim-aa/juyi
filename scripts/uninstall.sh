#!/usr/bin/env bash
# Uninstall the launchd service, runtime, logs, and the Hammerspoon hook.
# Local settings and Juyi's Volcengine Keychain items are removed only after
# explicit confirmation. Safe to re-run.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
LABEL="io.github.Eim-aa.argos-translator"
DOMAIN="gui/$(id -u)"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
CONFIG_DIR="$HOME/.config/argos-translator"
LOGS="$HOME/Library/Logs"
APP_BUNDLE_ID="io.github.Eim-aa.Juyi"
APP_PATH="/Applications/句译.app"
LEGACY_APP_PATH="$HOME/Applications/句译.app"
LOGIN_LABEL="io.github.Eim-aa.Juyi.login-item"
LOGIN_PLIST="$HOME/Library/LaunchAgents/$LOGIN_LABEL.plist"
LOGIN_EXECUTABLE="$APP_PATH/Contents/MacOS/Juyi"
KEYCHAIN_SERVICE="io.github.Eim-aa.juyi.volc"
KEYCHAIN_ACCOUNT="volc"
PENDING_KEYCHAIN_SERVICE="io.github.Eim-aa.juyi.volc.pending"
PENDING_KEYCHAIN_ACCOUNT="pending"
credential_cleanup_failed=0

warn() {
    echo "WARN: $*" >&2
}

fallback_login_item_is_owned() {
    [[ -f "$LOGIN_PLIST" && ! -L "$LOGIN_PLIST" ]] || return 1
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :Label' "$LOGIN_PLIST" 2>/dev/null)" == "$LOGIN_LABEL" ]] || return 1
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:0' "$LOGIN_PLIST" 2>/dev/null)" == "$LOGIN_EXECUTABLE" ]] || return 1
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :ProgramArguments:1' "$LOGIN_PLIST" 2>/dev/null)" == "--login-item" ]] || return 1
    if /usr/libexec/PlistBuddy -c 'Print :ProgramArguments:2' "$LOGIN_PLIST" >/dev/null 2>&1; then
        return 1
    fi
}

remove_fallback_login_item() {
    local target="$DOMAIN/$LOGIN_LABEL"
    if fallback_login_item_is_owned; then
        if launchctl print "$target" >/dev/null 2>&1; then
            if ! launchctl bootout "$target"; then
                warn "could not stop the Juyi fallback login item; kept $LOGIN_PLIST"
                return 1
            fi
            for _ in $(seq 1 20); do
                launchctl print "$target" >/dev/null 2>&1 || break
                sleep 0.2
            done
            if launchctl print "$target" >/dev/null 2>&1; then
                warn "the Juyi fallback login item is still loaded; kept $LOGIN_PLIST"
                return 1
            fi
        fi
        rm -f "$LOGIN_PLIST"
        echo "removed owned fallback login item $LOGIN_PLIST"
    elif [[ -L "$LOGIN_PLIST" || -e "$LOGIN_PLIST" ]]; then
        warn "kept $LOGIN_PLIST because its contents do not match Juyi's login item"
    elif launchctl print "$target" >/dev/null 2>&1; then
        warn "a login item named $LOGIN_LABEL is loaded without an owned plist; it was left unchanged"
        return 1
    fi
}

app_is_owned() {
    local app="$1"
    [[ -d "$app" && ! -L "$app" ]] || return 1
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null)" == "$APP_BUNDLE_ID" ]]
}

running_app_count() {
    /usr/bin/osascript -l JavaScript - "$APP_BUNDLE_ID" <<'JXA'
ObjC.import('AppKit')
function run(argv) {
    const apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(argv[0])
    return Number(apps.count)
}
JXA
}

request_app_quit() {
    /usr/bin/osascript -l JavaScript - "$APP_BUNDLE_ID" <<'JXA'
ObjC.import('AppKit')
function run(argv) {
    const apps = $.NSRunningApplication.runningApplicationsWithBundleIdentifier(argv[0])
    for (let index = 0; index < Number(apps.count); index += 1) {
        apps.objectAtIndex(index).terminate
    }
}
JXA
}

quit_running_app() {
    local count
    if ! count="$(running_app_count)" || [[ ! "$count" =~ ^[0-9]+$ ]]; then
        warn "unable to determine whether $APP_BUNDLE_ID is running; nothing was removed"
        return 1
    fi
    [[ "$count" -eq 0 ]] && return 0
    if ! request_app_quit; then
        warn "unable to ask $APP_BUNDLE_ID to quit; nothing was removed"
        return 1
    fi
    for _ in $(seq 1 40); do
        if ! count="$(running_app_count)" || [[ ! "$count" =~ ^[0-9]+$ ]]; then
            warn "unable to confirm that $APP_BUNDLE_ID quit; nothing was removed"
            return 1
        fi
        [[ "$count" -eq 0 ]] && return 0
        sleep 0.25
    done
    warn "$APP_BUNDLE_ID is still running; quit 句译 and run the uninstaller again"
    return 1
}

unregister_service_management_login_item() {
    local app executable="" helper_pid helper_status
    for app in "$APP_PATH" "$LEGACY_APP_PATH"; do
        [[ -e "$app" || -L "$app" ]] || continue
        if ! app_is_owned "$app"; then
            warn "did not run the login-item cleanup helper in unowned app $app"
            continue
        fi
        executable="$app/Contents/MacOS/Juyi"
        break
    done

    [[ -n "$executable" ]] || return 0
    if [[ ! -x "$executable" ]]; then
        warn "owned app has no executable login-item cleanup helper; nothing was removed"
        return 1
    fi
    if ! /usr/bin/grep -aFq -- "--unregister-login-item" "$executable"; then
        warn "installed Juyi app is too old to remove its Service Management login item; reinstall the current app, then retry"
        return 1
    fi

    "$executable" --unregister-login-item &
    helper_pid=$!
    for _ in $(seq 1 40); do
        if ! kill -0 "$helper_pid" 2>/dev/null; then
            helper_status=0
            wait "$helper_pid" || helper_status=$?
            if [[ "$helper_status" -eq 0 ]]; then
                echo "unregistered Juyi Service Management login item"
                return 0
            fi
            warn "could not unregister the Service Management login item; nothing was removed"
            return 1
        fi
        sleep 0.25
    done
    # This is only the exact cleanup subprocess started above, never an app
    # name-wide signal that could affect another process.
    kill "$helper_pid" 2>/dev/null || true
    wait "$helper_pid" 2>/dev/null || true
    warn "login-item cleanup did not finish; nothing was removed"
    return 1
}

keychain_item_state() {
    local service="$1"
    local account="$2"
    local status
    if /usr/bin/security find-generic-password -s "$service" -a "$account" >/dev/null 2>&1; then
        printf 'present\n'
        return 0
    else
        status=$?
    fi
    if [[ "$status" -eq 44 ]]; then
        printf 'absent\n'
    else
        printf 'unknown\n'
    fi
}

delete_keychain_item() {
    local service="$1"
    local account="$2"
    local description="$3"
    local status
    if /usr/bin/security delete-generic-password -s "$service" -a "$account" >/dev/null 2>&1; then
        :
    else
        status=$?
        if [[ "$status" -eq 44 ]]; then
            echo "$description Juyi Volcengine credential was already absent from Keychain"
            return 0
        fi
        warn "could not remove $description Juyi Volcengine credential from Keychain"
        return 1
    fi
    if /usr/bin/security find-generic-password -s "$service" -a "$account" >/dev/null 2>&1; then
        warn "$description Juyi Volcengine credential is still present in Keychain"
        return 1
    else
        status=$?
    fi
    if [[ "$status" -ne 44 ]]; then
        warn "could not verify removal of $description Juyi Volcengine credential from Keychain"
        return 1
    fi
    echo "removed $description Juyi Volcengine credential from Keychain"
}

unique_trash_path() {
    local stamp candidate suffix
    stamp="$(date +%Y%m%d-%H%M%S)"
    candidate="$HOME/.Trash/句译-已卸载-$stamp.app"
    suffix=1
    while [[ -e "$candidate" || -L "$candidate" ]]; do
        candidate="$HOME/.Trash/句译-已卸载-$stamp-$suffix.app"
        suffix=$((suffix + 1))
    done
    printf '%s\n' "$candidate"
}

move_owned_app_to_trash() {
    local app="$1"
    [[ -e "$app" || -L "$app" ]] || return 0
    if ! app_is_owned "$app"; then
        warn "kept $app because its bundle identifier does not match $APP_BUNDLE_ID"
        return 0
    fi

    mkdir -p "$HOME/.Trash"
    local destination
    destination="$(unique_trash_path)"
    if mv "$app" "$destination" 2>/dev/null; then
        echo "moved Juyi app to Trash: $destination"
        return 0
    fi

    if /usr/bin/osascript - "$app" "$destination" <<'APPLESCRIPT'
on run argv
    set sourcePath to item 1 of argv
    set destinationPath to item 2 of argv
    do shell script "/bin/mv " & quoted form of sourcePath & " " & quoted form of destinationPath with administrator privileges
end run
APPLESCRIPT
    then
        echo "moved Juyi app to Trash: $destination"
    else
        warn "could not move the verified Juyi app at $app to Trash"
    fi
}

echo "== native login item preflight =="
quit_running_app
unregister_service_management_login_item
remove_fallback_login_item

echo "== launchd =="
if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
    if ! launchctl bootout "$DOMAIN/$LABEL"; then
        warn "could not stop $DOMAIN/$LABEL; nothing was removed"
        exit 1
    fi
    for i in $(seq 1 20); do
        launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1 || break
        sleep 0.2
    done
    if launchctl print "$DOMAIN/$LABEL" >/dev/null 2>&1; then
        warn "$DOMAIN/$LABEL is still loaded; nothing was removed"
        exit 1
    fi
    echo "booted out $DOMAIN/$LABEL"
else
    echo "service not loaded"
fi

if [[ -f "$PLIST" ]]; then
    rm -f "$PLIST"
    echo "removed $PLIST"
fi

echo
echo "== hammerspoon hook =="
"$ROOT/scripts/hammerspoon_hook.sh" uninstall

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
echo "== local settings and cloud credentials =="
active_keychain_state="$(keychain_item_state "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT")"
pending_keychain_state="$(keychain_item_state "$PENDING_KEYCHAIN_SERVICE" "$PENDING_KEYCHAIN_ACCOUNT")"
if [[ -d "$CONFIG_DIR" || "$active_keychain_state" != "absent" || "$pending_keychain_state" != "absent" ]]; then
    read -r -p "Delete local settings and Juyi's active/pending Volcengine credentials from Keychain? [y/N] " answer || answer="N"
    case "${answer:-N}" in
        y|Y|yes|YES)
            if [[ "$active_keychain_state" != "absent" ]] && \
                    ! delete_keychain_item "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT" "active"; then
                credential_cleanup_failed=1
            fi
            if [[ "$pending_keychain_state" != "absent" ]] && \
                    ! delete_keychain_item "$PENDING_KEYCHAIN_SERVICE" "$PENDING_KEYCHAIN_ACCOUNT" "pending"; then
                credential_cleanup_failed=1
            fi
            if [[ -d "$CONFIG_DIR" ]]; then
                rm -rf "$CONFIG_DIR"
                echo "removed $CONFIG_DIR"
            fi
            ;;
        *)
            echo "kept local settings and Juyi's Keychain credentials"
            ;;
    esac
fi

echo
echo "== native app =="
move_owned_app_to_trash "$APP_PATH"
move_owned_app_to_trash "$LEGACY_APP_PATH"

echo
echo "done. Remaining manual steps for a full wipe:"
echo "  rm -rf \"$ROOT\"                      # this checkout"
echo "  brew uninstall --cask hammerspoon    # only if nothing else uses it"
if [[ "$credential_cleanup_failed" -ne 0 ]]; then
    warn "uninstall finished, but one or more requested Keychain credentials could not be confirmed removed"
    exit 1
fi
