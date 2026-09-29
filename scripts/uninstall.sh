#!/usr/bin/env bash
# Uninstall 句译: quit the app, remove its login item, optionally delete its
# Volcengine Keychain credential, clean up components left by pre-native
# (build <= 17) installations, and move the app to the Trash. Safe to re-run.
set -euo pipefail

DOMAIN="gui/$(id -u)"
CONFIG_DIR="$HOME/.config/argos-translator"
LAUNCH_AGENTS="$HOME/Library/LaunchAgents"
HS_DIR="$HOME/.hammerspoon"
HS_MODULE="$HS_DIR/argos-translator.lua"
HS_INIT="$HS_DIR/init.lua"
BEGIN_MARKER="-- BEGIN argos-translator managed block"
END_MARKER="-- END argos-translator managed block"
REQUIRE_LINE='require("argos-translator")'
APP_BUNDLE_ID="io.github.Eim-aa.Juyi"
APP_PATH="/Applications/句译.app"
LEGACY_APP_PATH="$HOME/Applications/句译.app"
LOGIN_LABEL="io.github.Eim-aa.Juyi.login-item"
LOGIN_PLIST="$LAUNCH_AGENTS/$LOGIN_LABEL.plist"
LOGIN_EXECUTABLE="$APP_PATH/Contents/MacOS/Juyi"
KEYCHAIN_SERVICE="io.github.Eim-aa.juyi.volc"
KEYCHAIN_ACCOUNT="volc"
# Written only by pre-4A builds; removed together with the active item.
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

# bootout_label <label>: stop a loaded LaunchAgent and confirm it is gone.
bootout_label() {
    local target="$DOMAIN/$1"
    launchctl print "$target" >/dev/null 2>&1 || return 0
    launchctl bootout "$target" || return 1
    for _ in $(seq 1 20); do
        launchctl print "$target" >/dev/null 2>&1 || return 0
        sleep 0.2
    done
    return 1
}

remove_fallback_login_item() {
    if fallback_login_item_is_owned; then
        if ! bootout_label "$LOGIN_LABEL"; then
            warn "could not stop the Juyi fallback login item; kept $LOGIN_PLIST"
            return 1
        fi
        rm -f "$LOGIN_PLIST"
        echo "removed owned fallback login item $LOGIN_PLIST"
    elif [[ -L "$LOGIN_PLIST" || -e "$LOGIN_PLIST" ]]; then
        warn "kept $LOGIN_PLIST because its contents do not match Juyi's login item"
    elif launchctl print "$DOMAIN/$LOGIN_LABEL" >/dev/null 2>&1; then
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

# The early service LaunchAgent (io.github.<user>.argos-translator).
remove_legacy_launch_agents() {
    local plist label
    shopt -s nullglob
    for plist in "$LAUNCH_AGENTS"/io.github.*.argos-translator.plist; do
        label="$(basename "$plist" .plist)"
        if ! bootout_label "$label"; then
            warn "could not stop $DOMAIN/$label; kept $plist"
            continue
        fi
        rm -f "$plist"
        echo "removed early service LaunchAgent $plist"
    done
    shopt -u nullglob
}

# Only a symlink whose target is named argos-translator.lua is Juyi's; any
# other module file or link is left for the user.
remove_owned_hammerspoon_module() {
    if [[ -L "$HS_MODULE" ]]; then
        if [[ "$(basename "$(readlink "$HS_MODULE")")" == "argos-translator.lua" ]]; then
            rm -f "$HS_MODULE"
            echo "removed early Hammerspoon module symlink $HS_MODULE"
            return 0
        fi
        warn "kept $HS_MODULE because it does not point to Juyi's early module"
    elif [[ -e "$HS_MODULE" ]]; then
        warn "kept $HS_MODULE because it is not a symlink created by Juyi"
    fi
    return 1
}

# Removes exactly one well-formed managed block. A bare legacy require is
# removed only together with the owned module and only when no block exists;
# the user's other Hammerspoon configuration is never changed.
remove_hammerspoon_managed_block() {
    local remove_bare_require="$1"
    local file="$HS_INIT"
    if [[ -L "$HS_INIT" ]]; then
        # Like the old hook, a symlinked init.lua is edited at its target.
        file="$(readlink "$HS_INIT")"
        [[ "$file" = /* ]] || file="$HS_DIR/$file"
        if [[ -L "$file" ]]; then
            warn "kept $HS_INIT because it is a chain of symlinks; remove Juyi's block manually"
            return 0
        fi
    fi
    [[ -f "$file" ]] || return 0

    local begin_count end_count
    begin_count="$(awk -v m="$BEGIN_MARKER" '$0 == m { n++ } END { print n + 0 }' "$file")"
    end_count="$(awk -v m="$END_MARKER" '$0 == m { n++ } END { print n + 0 }' "$file")"
    if [[ "$begin_count" -eq 0 && "$end_count" -eq 0 ]]; then
        [[ "$remove_bare_require" -eq 1 ]] || return 0
        grep -qxF "$REQUIRE_LINE" "$file" || return 0
    elif [[ "$begin_count" -ne 1 || "$end_count" -ne 1 ]] || ! awk -v b="$BEGIN_MARKER" -v e="$END_MARKER" '
            $0 == b { begin = NR } $0 == e { end = NR } END { exit !(begin < end) }' "$file"; then
        warn "kept the malformed managed block in $HS_INIT; remove it manually after inspection"
        return 0
    else
        remove_bare_require=0
    fi

    local tmp
    tmp="$(mktemp "$(dirname "$file")/.juyi-init.XXXXXX")"
    if ! cp -p "$file" "$tmp" || ! awk -v b="$BEGIN_MARKER" -v e="$END_MARKER" \
            -v r="$REQUIRE_LINE" -v bare="$remove_bare_require" '
            $0 == b { inside = 1; next }
            $0 == e { inside = 0; next }
            inside { next }
            bare == 1 && $0 == r && !done { done = 1; next }
            { print }' "$file" > "$tmp" || ! mv "$tmp" "$file"; then
        rm -f "$tmp"
        warn "could not update $HS_INIT; it was left unchanged"
        return 0
    fi
    echo "removed Juyi's early Hammerspoon configuration from $HS_INIT"
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

echo "== app and login item =="
quit_running_app
unregister_service_management_login_item
remove_fallback_login_item

echo
echo "== Volcengine credential =="
active_keychain_state="$(keychain_item_state "$KEYCHAIN_SERVICE" "$KEYCHAIN_ACCOUNT")"
pending_keychain_state="$(keychain_item_state "$PENDING_KEYCHAIN_SERVICE" "$PENDING_KEYCHAIN_ACCOUNT")"
if [[ "$active_keychain_state" != "absent" || "$pending_keychain_state" != "absent" ]]; then
    read -r -p "Delete Juyi's Volcengine access key from Keychain? [y/N] " answer || answer="N"
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
            ;;
        *)
            echo "kept Juyi's Volcengine credential in Keychain"
            ;;
    esac
else
    echo "no Juyi Volcengine credential in Keychain"
fi

echo
echo "== early components =="
remove_legacy_launch_agents
owned_module=0
if remove_owned_hammerspoon_module; then owned_module=1; fi
remove_hammerspoon_managed_block "$owned_module"
if [[ -d "$CONFIG_DIR" && ! -L "$CONFIG_DIR" ]]; then
    rm -rf "$CONFIG_DIR"
    echo "removed $CONFIG_DIR"
fi
if [[ "$owned_module" -eq 1 ]] && /usr/bin/pgrep -x Hammerspoon >/dev/null 2>&1; then
    echo "Hammerspoon is running: quit and reopen it so it forgets the removed module."
fi

echo
echo "== native app =="
move_owned_app_to_trash "$APP_PATH"
move_owned_app_to_trash "$LEGACY_APP_PATH"

echo
echo "done. App preferences (UserDefaults domain $APP_BUNDLE_ID) can be removed with:"
echo "  defaults delete $APP_BUNDLE_ID"
if [[ "$credential_cleanup_failed" -ne 0 ]]; then
    warn "uninstall finished, but the requested Keychain credential could not be confirmed removed"
    exit 1
fi
