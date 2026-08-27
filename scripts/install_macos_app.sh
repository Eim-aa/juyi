#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT/scripts/install_macos_app.sh"
BUILD="$ROOT/build/Juyi.app"
DEST="/Applications/句译.app"
LEGACY_DEST="$HOME/Applications/句译.app"
APP_BUNDLE_ID="io.github.Eim-aa.Juyi"
LSREGISTER="/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"

require_macos_15() {
    local platform product_version major
    platform="$(/usr/bin/uname -s 2>/dev/null || true)"
    if [[ "$platform" != "Darwin" ]]; then
        echo "ERROR: 句译公开版只能安装在 macOS 15.0 或更高版本。未构建、退出或替换任何 App。" >&2
        exit 1
    fi
    product_version="$(/usr/bin/sw_vers -productVersion 2>/dev/null || true)"
    major="${product_version%%.*}"
    if [[ ! "$major" =~ ^[0-9]+$ || "$major" -lt 15 ]]; then
        echo "ERROR: 句译公开版需要 macOS 15.0 或更高版本（当前：${product_version:-未知}）。未构建、退出或替换任何 App；现有 App 与服务已保留。" >&2
        exit 1
    fi
}

# Also protects the privileged --install-helper entry. Keep this before every
# build, quit request, staging write, registration, or replacement operation.
require_macos_15

app_is_owned() {
    local app="$1"
    [[ -d "$app" && ! -L "$app" ]] || return 1
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$app/Contents/Info.plist" 2>/dev/null)" == "$APP_BUNDLE_ID" ]]
}

require_owned_or_absent() {
    local app="$1"
    [[ -e "$app" || -L "$app" ]] || return 0
    if ! app_is_owned "$app"; then
        echo "ERROR: refusing to replace $app because its bundle identifier does not match $APP_BUNDLE_ID." >&2
        echo "Back it up or move it aside yourself, then run the installer again." >&2
        return 1
    fi
}

validate_app() {
    local app="$1"
    local expected_short="$2"
    local expected_build="$3"
    app_is_owned "$app" || return 1
    [[ -x "$app/Contents/MacOS/Juyi" ]] || return 1
    /usr/bin/plutil -lint "$app/Contents/Info.plist" >/dev/null
    /usr/bin/codesign --verify --deep --strict "$app"
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")" == "$expected_short" ]]
    [[ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$app/Contents/Info.plist")" == "$expected_build" ]]
}

install_verified_app() {
    local staged="$1"
    local destination="$2"
    local expected_short="$3"
    local expected_build="$4"
    [[ "$destination" == "/Applications/句译.app" ]] || {
        echo "ERROR: refusing unexpected install destination: $destination" >&2
        return 1
    }
    validate_app "$staged" "$expected_short" "$expected_build" || {
        echo "ERROR: staged app failed validation" >&2
        return 1
    }
    # This check must also run inside the privileged helper. A check made by
    # the unprivileged caller alone would leave a race before replacement.
    require_owned_or_absent "$destination" || return 1

    local candidate="/Applications/.juyi-install-$$.app"
    local previous="/Applications/.juyi-previous-$$.app"
    if [[ -e "$candidate" || -L "$candidate" || -e "$previous" || -L "$previous" ]]; then
        echo "ERROR: refusing to reuse an existing installer staging path" >&2
        return 1
    fi
    /usr/bin/ditto "$staged" "$candidate"
    if ! validate_app "$candidate" "$expected_short" "$expected_build"; then
        /bin/rm -rf "$candidate"
        echo "ERROR: copied app failed validation" >&2
        return 1
    fi

    local had_previous=0
    if [[ -e "$destination" ]]; then
        /bin/mv "$destination" "$previous"
        had_previous=1
    fi
    if ! /bin/mv "$candidate" "$destination"; then
        [[ "$had_previous" -eq 1 ]] && /bin/mv "$previous" "$destination"
        echo "ERROR: unable to place app in /Applications" >&2
        return 1
    fi
    if ! validate_app "$destination" "$expected_short" "$expected_build"; then
        /bin/rm -rf "$destination"
        [[ "$had_previous" -eq 1 ]] && /bin/mv "$previous" "$destination"
        echo "ERROR: installed app failed validation; previous app restored" >&2
        return 1
    fi
    if [[ "$had_previous" -eq 1 ]]; then
        /bin/rm -rf "$previous"
    fi
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
        // NSRunningApplication.terminate is a graceful, bundle-scoped request.
        apps.objectAtIndex(index).terminate
    }
}
JXA
}

quit_running_app() {
    local count
    if ! count="$(running_app_count)" || [[ ! "$count" =~ ^[0-9]+$ ]]; then
        echo "ERROR: unable to determine whether $APP_BUNDLE_ID is running; no app was replaced." >&2
        return 1
    fi
    [[ "$count" -eq 0 ]] && return 0

    if ! request_app_quit; then
        echo "ERROR: unable to ask $APP_BUNDLE_ID to quit; no app was replaced." >&2
        return 1
    fi
    for _ in $(seq 1 40); do
        if ! count="$(running_app_count)" || [[ ! "$count" =~ ^[0-9]+$ ]]; then
            echo "ERROR: unable to confirm that $APP_BUNDLE_ID quit; no app was replaced." >&2
            return 1
        fi
        [[ "$count" -eq 0 ]] && return 0
        sleep 0.25
    done
    echo "ERROR: $APP_BUNDLE_ID is still running. Quit 句译 and run the installer again." >&2
    return 1
}

if [[ "${1:-}" == "--install-helper" ]]; then
    [[ "$#" -eq 5 ]] || exit 2
    install_verified_app "$2" "$3" "$4" "$5"
    exit
fi

"$ROOT/scripts/build_macos_app.sh"

EXPECTED_SHORT="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$BUILD/Contents/Info.plist")"
EXPECTED_BUILD="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$BUILD/Contents/Info.plist")"
validate_app "$BUILD" "$EXPECTED_SHORT" "$EXPECTED_BUILD" || {
    echo "ERROR: built app failed version or signature validation" >&2
    exit 1
}

STAGING_ROOT="$(mktemp -d /private/tmp/juyi-install.XXXXXX)"
trap '/bin/rm -rf "$STAGING_ROOT"' EXIT
STAGED_APP="$STAGING_ROOT/句译.app"
/usr/bin/ditto "$BUILD" "$STAGED_APP"
validate_app "$STAGED_APP" "$EXPECTED_SHORT" "$EXPECTED_BUILD"

require_owned_or_absent "$DEST"
quit_running_app
if [[ -w /Applications ]]; then
    install_verified_app "$STAGED_APP" "$DEST" "$EXPECTED_SHORT" "$EXPECTED_BUILD"
else
    /usr/bin/osascript - "$SCRIPT" "$STAGED_APP" "$DEST" "$EXPECTED_SHORT" "$EXPECTED_BUILD" <<'APPLESCRIPT'
on run argv
    set commandText to quoted form of item 1 of argv & " --install-helper " & quoted form of item 2 of argv & " " & quoted form of item 3 of argv & " " & quoted form of item 4 of argv & " " & quoted form of item 5 of argv
    do shell script commandText with administrator privileges
end run
APPLESCRIPT
fi

validate_app "$DEST" "$EXPECTED_SHORT" "$EXPECTED_BUILD" || {
    echo "ERROR: final app validation failed; legacy app was preserved" >&2
    exit 1
}

if [[ -e "$LEGACY_DEST" || -L "$LEGACY_DEST" ]]; then
    if ! app_is_owned "$LEGACY_DEST"; then
        echo "WARN: preserved $LEGACY_DEST because its bundle identifier does not match $APP_BUNDLE_ID" >&2
    else
        "$LSREGISTER" -u "$LEGACY_DEST" >/dev/null 2>&1 || \
            echo "WARN: unable to unregister the legacy app path" >&2
        "$LSREGISTER" -f "$DEST"
        /bin/mkdir -p "$HOME/.Trash"
        stamp="$(/bin/date +%Y%m%d-%H%M%S)"
        legacy_backup="$HOME/.Trash/句译-旧版-$stamp.app"
        suffix=1
        while [[ -e "$legacy_backup" ]]; do
            legacy_backup="$HOME/.Trash/句译-旧版-$stamp-$suffix.app"
            suffix=$((suffix + 1))
        done
        if /bin/mv "$LEGACY_DEST" "$legacy_backup"; then
            echo "Moved legacy app to Trash: $legacy_backup"
        else
            echo "WARN: the verified /Applications app is installed, but the legacy ~/Applications copy was preserved" >&2
        fi
    fi
fi

"$LSREGISTER" -f "$DEST"
echo "Installed and verified $DEST ($EXPECTED_SHORT, build $EXPECTED_BUILD)"
/usr/bin/open "$DEST"
