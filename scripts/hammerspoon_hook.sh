#!/usr/bin/env bash
# Safely install, remove, or reload the Juyi Hammerspoon hook.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
HS_DIR="$HOME/.hammerspoon"
MODULE="$HS_DIR/argos-translator.lua"
MODULE_TARGET="$ROOT/hammerspoon/argos-translator.lua"
INIT="$HS_DIR/init.lua"
BEGIN_MARKER="-- BEGIN argos-translator managed block"
END_MARKER="-- END argos-translator managed block"
REQUIRE_LINE='require("argos-translator")'

fail() {
    echo "ERROR: $*" >&2
    exit 1
}

warn() {
    echo "WARN: $*" >&2
}

# Resolve symlinks without relying on GNU readlink -f, which macOS does not
# provide. The final path need not exist, but its parent directory must.
resolve_path() {
    local path="$1"
    local target
    local depth=0
    while [[ -L "$path" ]]; do
        target="$(readlink "$path")" || return 1
        if [[ "$target" = /* ]]; then
            path="$target"
        else
            path="$(dirname "$path")/$target"
        fi
        depth=$((depth + 1))
        [[ "$depth" -le 40 ]] || return 1
    done

    local parent
    parent="$(cd "$(dirname "$path")" 2>/dev/null && pwd -P)" || return 1
    printf '%s/%s\n' "$parent" "$(basename "$path")"
}

module_is_managed() {
    [[ -L "$MODULE" ]] || return 1

    local raw_target
    raw_target="$(readlink "$MODULE")" || return 1
    if [[ "$raw_target" == "$MODULE_TARGET" ]]; then
        return 0
    fi

    local actual expected
    actual="$(resolve_path "$MODULE")" || return 1
    expected="$(resolve_path "$MODULE_TARGET")" || return 1
    [[ "$actual" == "$expected" ]]
}

module_conflict() {
    cat >&2 <<EOF
ERROR: refusing to replace $MODULE because it is not a symlink managed by this Juyi checkout.

Your existing Hammerspoon module was left unchanged. If it is no longer needed,
move it to an unused backup path yourself, for example:
  mv "$MODULE" "$MODULE.before-juyi"
Then rerun the installer. If you still use that module, keep it and load Juyi
under a different module name instead of overwriting it.
EOF
    exit 1
}

check_module_path() {
    [[ -f "$MODULE_TARGET" ]] || fail "missing Hammerspoon source module: $MODULE_TARGET"
    if [[ -L "$MODULE" ]]; then
        module_is_managed || module_conflict
    elif [[ -e "$MODULE" ]]; then
        module_conflict
    fi
}

init_storage_path() {
    if [[ -L "$INIT" ]]; then
        local resolved
        resolved="$(resolve_path "$INIT")" || fail "cannot resolve Hammerspoon init symlink: $INIT"
        [[ -f "$resolved" ]] || fail "Hammerspoon init symlink does not point to a regular file: $INIT"
        printf '%s\n' "$resolved"
    elif [[ -e "$INIT" ]]; then
        [[ -f "$INIT" ]] || fail "Hammerspoon init path is not a regular file: $INIT"
        printf '%s\n' "$INIT"
    else
        printf '%s\n' "$INIT"
    fi
}

marker_count() {
    local file="$1"
    local marker="$2"
    awk -v marker="$marker" '$0 == marker { count++ } END { print count + 0 }' "$file"
}

managed_block_is_well_formed() {
    local file="$1"
    awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
        $0 == begin {
            if (inside || seen_begin) exit 2
            inside = 1
            seen_begin = 1
            next
        }
        $0 == end {
            if (!inside || seen_end) exit 2
            inside = 0
            seen_end = 1
            next
        }
        END {
            if (inside || seen_begin != seen_end) exit 2
        }
    ' "$file" >/dev/null
}

check_init_path() {
    local file
    file="$(init_storage_path)"
    [[ -e "$file" ]] || return 0

    local begin_count end_count
    begin_count="$(marker_count "$file" "$BEGIN_MARKER")"
    end_count="$(marker_count "$file" "$END_MARKER")"
    if [[ "$begin_count" -gt 1 || "$end_count" -gt 1 || "$begin_count" -ne "$end_count" ]]; then
        fail "managed block markers in $INIT are malformed; repair or remove that block before reinstalling"
    fi
    if [[ "$begin_count" -eq 1 ]] && ! managed_block_is_well_formed "$file"; then
        fail "managed block markers in $INIT are out of order; repair or remove that block before reinstalling"
    fi
}

rewrite_init_for_install() {
    local file
    file="$(init_storage_path)"
    if [[ ! -e "$file" ]]; then
        printf '%s\n%s\n%s\n' "$BEGIN_MARKER" "$REQUIRE_LINE" "$END_MARKER" > "$file"
        echo "[created managed block in $INIT]"
        return
    fi

    local begin_count
    begin_count="$(marker_count "$file" "$BEGIN_MARKER")"
    local tmp
    tmp="$(mktemp "$(dirname "$file")/.juyi-init.XXXXXX")"
    if ! cp -p "$file" "$tmp"; then
        rm -f "$tmp"
        fail "could not stage an update for $INIT"
    fi

    if [[ "$begin_count" -eq 1 ]]; then
        if ! awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" -v require="$REQUIRE_LINE" '
            $0 == begin {
                print begin
                print require
                inside = 1
                next
            }
            $0 == end {
                print end
                inside = 0
                next
            }
            inside { next }
            { print }
        ' "$file" > "$tmp"; then
            rm -f "$tmp"
            fail "could not update the managed block in $INIT"
        fi
    else
        if ! awk -v require="$REQUIRE_LINE" '
            $0 == require && !removed_legacy { removed_legacy = 1; next }
            { print }
        ' "$file" > "$tmp"; then
            rm -f "$tmp"
            fail "could not migrate the legacy require line in $INIT"
        fi
        if [[ -s "$tmp" ]]; then
            printf '\n' >> "$tmp"
        fi
        printf '%s\n%s\n%s\n' "$BEGIN_MARKER" "$REQUIRE_LINE" "$END_MARKER" >> "$tmp"
    fi

    if ! mv "$tmp" "$file"; then
        rm -f "$tmp"
        fail "could not atomically update $INIT"
    fi
    echo "[installed managed block in $INIT]"
}

rewrite_init_for_uninstall() {
    local remove_legacy="$1"
    local file
    file="$(init_storage_path)"
    [[ -e "$file" ]] || return 0

    local begin_count end_count
    begin_count="$(marker_count "$file" "$BEGIN_MARKER")"
    end_count="$(marker_count "$file" "$END_MARKER")"
    if [[ "$begin_count" -gt 1 || "$end_count" -gt 1 || "$begin_count" -ne "$end_count" ]]; then
        warn "kept malformed managed block in $INIT; remove it manually after inspection"
        return 0
    fi
    if [[ "$begin_count" -eq 1 ]] && ! managed_block_is_well_formed "$file"; then
        warn "kept out-of-order managed block in $INIT; remove it manually after inspection"
        return 0
    fi
    if [[ "$begin_count" -eq 0 && "$remove_legacy" -ne 1 ]]; then
        return 0
    fi
    if [[ "$begin_count" -eq 1 ]]; then
        # Marker ownership applies only inside the marker. An identical require
        # outside it may have been added intentionally by the user.
        remove_legacy=0
    fi

    local tmp
    tmp="$(mktemp "$(dirname "$file")/.juyi-init.XXXXXX")"
    if ! cp -p "$file" "$tmp"; then
        rm -f "$tmp"
        warn "could not stage an update for $INIT; it was left unchanged"
        return 0
    fi
    if ! awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" \
        -v require="$REQUIRE_LINE" -v remove_legacy="$remove_legacy" '
        $0 == begin { inside = 1; next }
        $0 == end { inside = 0; next }
        inside { next }
        remove_legacy == 1 && $0 == require && !removed_legacy {
            removed_legacy = 1
            next
        }
        { print }
    ' "$file" > "$tmp"; then
        rm -f "$tmp"
        warn "could not update $INIT; it was left unchanged"
        return 0
    fi
    if ! mv "$tmp" "$file"; then
        rm -f "$tmp"
        warn "could not atomically update $INIT; it was left unchanged"
        return 0
    fi
    echo "[removed Juyi-managed Hammerspoon config from $INIT]"
}

install_hook() {
    check_module_path
    check_init_path
    mkdir -p "$HS_DIR"
    if [[ ! -L "$MODULE" ]]; then
        ln -s "$MODULE_TARGET" "$MODULE"
        echo "[linked $MODULE -> $MODULE_TARGET]"
    else
        echo "[kept managed symlink $MODULE]"
    fi
    rewrite_init_for_install
}

uninstall_hook() {
    local owned_module=0
    if [[ -L "$MODULE" ]] && module_is_managed; then
        rm -f "$MODULE"
        owned_module=1
        echo "[removed managed symlink $MODULE]"
    elif [[ -L "$MODULE" || -e "$MODULE" ]]; then
        warn "kept $MODULE because it is not a symlink managed by this Juyi checkout"
    fi
    rewrite_init_for_uninstall "$owned_module"
}

reload_hammerspoon() {
    if ! command -v pgrep >/dev/null 2>&1 || ! pgrep -x Hammerspoon >/dev/null 2>&1; then
        if [[ -d /Applications/Hammerspoon.app || -d "$HOME/Applications/Hammerspoon.app" ]]; then
            echo "[starting Hammerspoon]"
            /usr/bin/open -a Hammerspoon || warn "could not open Hammerspoon; start it manually"
        else
            warn "Hammerspoon is not running; install and open it, then reload its config"
        fi
        return 0
    fi

    local hs_cli=""
    if command -v hs >/dev/null 2>&1; then
        hs_cli="$(command -v hs)"
    elif [[ -x /Applications/Hammerspoon.app/Contents/Frameworks/hs/hs ]]; then
        hs_cli="/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs"
    elif [[ -x "$HOME/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs" ]]; then
        hs_cli="$HOME/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs"
    fi
    if [[ -n "$hs_cli" ]] && "$hs_cli" -c 'hs.reload()' >/dev/null 2>&1; then
        echo "[reloaded the running Hammerspoon config]"
    else
        warn "Hammerspoon is running. Choose Hammerspoon > Reload Config to activate Juyi."
    fi
}

case "${1:-}" in
    check)
        check_module_path
        check_init_path
        ;;
    install)
        install_hook
        ;;
    uninstall)
        uninstall_hook
        ;;
    reload)
        reload_hammerspoon
        ;;
    *)
        echo "usage: $0 {check|install|uninstall|reload}" >&2
        exit 2
        ;;
esac
