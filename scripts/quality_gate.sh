#!/usr/bin/env bash
# Mechanical guard rails for the unattended quality loop described in
# docs/dev/quality-loop/README.md. The loop agent must never edit this file;
# it is not on the editable allowlist below, so the gate itself rejects that.
#
# Usage:
#   scripts/quality_gate.sh --check-worktree           worktree/branch checks only (runs anywhere)
#   scripts/quality_gate.sh --preflight                worktree + toolchain checks; records the base commit
#   scripts/quality_gate.sh --static [--max-lines N]   scope and secret checks on the uncommitted diff
#   scripts/quality_gate.sh --full   [--max-lines N]   --static, then builds, Swift tests, Python contracts
#   scripts/quality_gate.sh --audit                    re-check every commit made since the recorded base
#
# Exit codes: 0 pass | 10 scope violation | 11 credential-like text | 12 wrong checkout
#             20 build failed | 21 Swift tests failed | 22 Python contracts failed
#             30 toolchain or environment missing | 64 usage
#
# Written for the bash 3.2 that ships with macOS: no associative arrays,
# mapfile, or case-conversion expansions.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT"

die() {
    printf 'GATE: FAIL (exit %s) %s\n' "$1" "$2"
    exit "$1"
}

usage() {
    # Print the leading comment block (stops at the first non-comment line).
    awk 'NR == 1 { next } /^#/ { sub(/^# ?/, ""); print; next } { exit }' "${BASH_SOURCE[0]}"
}

MODE=""
if [ $# -gt 0 ]; then
    MODE="$1"
    shift
fi
MAX_LINES=60
while [ $# -gt 0 ]; do
    case "$1" in
        --max-lines)
            [ $# -ge 2 ] || die 64 "--max-lines needs a number"
            MAX_LINES="$2"
            shift 2
            ;;
        *) die 64 "unknown argument: $1" ;;
    esac
done
case "$MAX_LINES" in
    '' | *[!0-9]*) die 64 "--max-lines must be a number" ;;
esac

GIT_DIR_ABS="$(cd "$(git rev-parse --git-dir)" && pwd -P)"
COMMON_DIR_ABS="$(cd "$(git rev-parse --git-common-dir)" && pwd -P)"
BASE_FILE="$GIT_DIR_ABS/quality-loop-base"
AUDIT_BASE=""

# --------------------------------------------------------------------------
# Scope: the loop may edit only these paths (everything else is read-only).
# New files are allowed only below the run-log directory.
# --------------------------------------------------------------------------
is_editable() {
    case "$1" in
        macos/JuyiMenuBar.swift) return 0 ;;
        macos/NativeTranslationOverlayController.swift) return 0 ;;
        macos/NativeTranslationOverlayModel.swift) return 0 ;;
        tests/NativeTranslationOverlayModelTests.swift) return 0 ;; # additive only
        docs/dev/quality-loop/runs/*) return 0 ;;
    esac
    return 1
}

check_worktree() {
    [ "$GIT_DIR_ABS" != "$COMMON_DIR_ABS" ] ||
        die 12 "this is the main checkout; run the loop in a linked worktree (docs/dev/quality-loop/README.md)"
    local branch
    branch="$(git symbolic-ref --quiet --short HEAD || true)"
    case "$branch" in
        quality-loop/*) ;;
        *) die 12 "current branch '${branch:-detached}' is not quality-loop/*" ;;
    esac
}

# Prints "<status><TAB><path>" for the uncommitted diff (or base..HEAD in audit).
changed_name_status() {
    if [ "$MODE" = "--audit" ]; then
        git -c core.quotepath=off diff --name-status --no-renames "$AUDIT_BASE" HEAD
    else
        git -c core.quotepath=off diff --name-status --no-renames HEAD
        git -c core.quotepath=off ls-files --others --exclude-standard | while IFS= read -r p; do
            case "$p" in
                */xcuserdata/* | *.DS_Store) continue ;;
            esac
            printf 'A\t%s\n' "$p"
        done
    fi
}

check_scope() {
    local bad=0 status path
    while IFS=$'\t' read -r status path; do
        [ -n "$path" ] || continue
        if ! is_editable "$path"; then
            echo "  not editable: $path ($status)"
            bad=1
            continue
        fi
        case "$status" in
            D)
                echo "  deletion not allowed: $path"
                bad=1
                ;;
            A)
                case "$path" in
                    docs/dev/quality-loop/runs/*) ;;
                    *)
                        echo "  new file not allowed: $path"
                        bad=1
                        ;;
                esac
                ;;
        esac
    done
    return "$bad"
}

check_sizes() {
    local numstat added deleted path total=0 files=0 bad=0
    if [ "$MODE" = "--audit" ]; then
        numstat="$(git -c core.quotepath=off diff --numstat --no-renames "$AUDIT_BASE" HEAD || true)"
    else
        numstat="$(git -c core.quotepath=off diff --numstat --no-renames HEAD || true)"
    fi
    while IFS=$'\t' read -r added deleted path; do
        [ -n "$path" ] || continue
        case "$path" in
            macos/*)
                if [ "$added" = "-" ]; then
                    echo "  binary change in $path"
                    bad=1
                    continue
                fi
                files=$((files + 1))
                total=$((total + added + deleted))
                ;;
            tests/*)
                if [ "$added" = "-" ] || [ "$deleted" != "0" ]; then
                    echo "  tests may only gain lines; $path deletes ${deleted} line(s)"
                    bad=1
                fi
                ;;
        esac
    done <<<"$numstat"
    if [ "$MODE" != "--audit" ]; then
        if [ "$files" -gt 2 ]; then
            echo "  $files macos/ files changed in one round (limit 2)"
            bad=1
        fi
        if [ "$total" -gt "$MAX_LINES" ]; then
            echo "  $total changed macos/ lines in one round (limit $MAX_LINES)"
            bad=1
        fi
    fi
    return "$bad"
}

# Credential-looking text in added lines. Matches are never printed.
SECRET_RE='AKLT[A-Za-z0-9+/=]{12,}|AKIA[0-9A-Z]{16}|-----BEGIN [A-Z ]*PRIVATE KEY-----|ghp_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{30,}|(^|[^A-Za-z0-9])sk-[A-Za-z0-9_-]{24,}|xox[baprs]-[A-Za-z0-9-]{10,}|[Ss]ecret[A-Za-z_ ]{0,16}[:=][[:space:]]*"[A-Za-z0-9+/=]{20,}"'

check_secrets() {
    local added path
    if [ "$MODE" = "--audit" ]; then
        added="$(git diff -U0 --no-renames "$AUDIT_BASE" HEAD | grep -E '^\+' | grep -v -E '^\+\+\+ ' || true)"
    else
        added="$(git diff -U0 --no-renames HEAD | grep -E '^\+' | grep -v -E '^\+\+\+ ' || true)"
        while IFS= read -r path; do
            [ -f "$path" ] || continue
            case "$path" in
                docs/dev/quality-loop/runs/*) added="$added"$'\n'"$(cat "$path")" ;;
            esac
        done < <(git -c core.quotepath=off ls-files --others --exclude-standard)
    fi
    if printf '%s\n' "$added" | grep -E -q "$SECRET_RE"; then
        die 11 "text that looks like a credential was added (content not shown). Remove it, do not commit, stop the loop."
    fi
}

run_static_checks() {
    local status_lines
    check_secrets
    status_lines="$(changed_name_status)"
    if [ -z "$status_lines" ]; then
        echo "no changes in the working tree"
        return 0
    fi
    local report violations=0
    if ! report="$(printf '%s\n' "$status_lines" | check_scope)"; then
        echo "scope violations:"
        echo "$report"
        violations=1
    fi
    if ! report="$(check_sizes)"; then
        echo "size/test-integrity violations:"
        echo "$report"
        violations=1
    fi
    if [ "$violations" -ne 0 ]; then
        die 10 "change set is outside the allowed scope. Tracked paths: git restore --source=HEAD --staged --worktree -- <path>. Stray untracked files: rm <that one file> (no -r)."
    fi
}

# --------------------------------------------------------------------------
# Preflight (toolchain) — runs on the Mac before the loop starts.
# --------------------------------------------------------------------------
PY=""

# Always use a private venv with the versions pinned in requirements-dev.txt.
# A system ruff of a different version reports unrelated errors and would make
# every round look like a failure.
venv_ready() { # venv_ready <venv-dir> <wanted-ruff-version-or-empty>
    local have
    [ -x "$1/bin/python" ] || return 1
    "$1/bin/python" -m pytest --version >/dev/null 2>&1 || return 1
    have="$("$1/bin/python" -m ruff --version 2>/dev/null | awk '{print $2}')"
    [ -n "$have" ] || return 1
    [ -z "$2" ] || [ "$have" = "$2" ]
}

resolve_python() {
    local venv="${TMPDIR:-/tmp}/juyi-quality-gate-venv" want
    want="$(sed -n 's/^ruff==\([0-9][0-9.]*\).*/\1/p' "$ROOT/requirements-dev.txt" | head -n 1)"
    if venv_ready "$venv" "$want"; then
        PY="$venv/bin/python"
        return 0
    fi
    if [ "$MODE" != "--preflight" ]; then
        die 30 "pinned pytest/ruff venv is missing; run scripts/quality_gate.sh --preflight while online"
    fi
    echo "creating $venv with the pinned test tools (needs network, one time)"
    python3 -m venv "$venv" || die 30 "cannot create a Python virtual environment"
    "$venv/bin/python" -m pip install -q -r "$ROOT/requirements-dev.txt" >/dev/null 2>&1 ||
        die 30 "cannot install pinned pytest/ruff (network?)"
    venv_ready "$venv" "$want" || die 30 "venv was created but pytest/ruff $want are not usable"
    PY="$venv/bin/python"
}

preflight_clean() {
    local lines
    lines="$(changed_name_status)"
    [ -z "$lines" ] || die 12 "working tree is not clean; commit or restore first:"$'\n'"$lines"
}

preflight_toolchain() {
    [ "$(uname -s)" = "Darwin" ] || die 30 "macOS is required (xcodebuild exists only there)"
    local version major tool
    version="$(sw_vers -productVersion)"
    major="${version%%.*}"
    [ "$major" -ge 15 ] || die 30 "macOS 15 or newer is required, found $version"
    for tool in git xcodebuild swiftc python3; do
        command -v "$tool" >/dev/null 2>&1 || die 30 "missing tool: $tool"
    done
    xcodebuild -version >/dev/null 2>&1 ||
        die 30 "xcodebuild does not work (try: xcode-select -p, sudo xcodebuild -license accept)"
    if [ -z "$(git config user.name || true)" ] || [ -z "$(git config user.email || true)" ]; then
        die 30 "git user.name / user.email are not set; commits would fail overnight"
    fi
    local dir="${TMPDIR:-/tmp}" free_kb
    free_kb="$(df -Pk "$dir" | awk 'NR==2 {print $4}')"
    [ "${free_kb:-0}" -ge 6000000 ] || die 30 "less than 6 GB free in $dir (build products need it)"
    for tool in PROMPT.md RUBRIC.md TEMPLATES.md; do
        [ -f "docs/dev/quality-loop/$tool" ] || die 30 "missing docs/dev/quality-loop/$tool in this worktree"
    done
    resolve_python
    echo "macOS $version | $(xcodebuild -version | head -n 1) | python: $PY | free: $((free_kb / 1024)) MB"
}

run_logged() { # run_logged <exit-code> <label> <logfile> command...
    local code="$1" label="$2" log="$3"
    shift 3
    echo "==> $label"
    if ! "$@" >"$log" 2>&1; then
        echo "---- $label failed (full log: $log) ----"
        grep -E 'error:|warning:|FAIL|Assertion|assert ' "$log" | head -n 40 || true
        echo "---- last 25 lines ----"
        tail -n 25 "$log"
        die "$code" "$label failed"
    fi
}

mode_full() {
    check_worktree
    run_static_checks
    resolve_python
    local dd="${TMPDIR:-/tmp}/juyi-quality-gate"
    mkdir -p "$dd"
    run_logged 20 "Debug build" "$dd/debug-build.log" \
        xcodebuild -quiet -project Juyi.xcodeproj -scheme Juyi -configuration Debug \
        -derivedDataPath "$dd/debug" CODE_SIGNING_ALLOWED=NO SWIFT_TREAT_WARNINGS_AS_ERRORS=YES build
    run_logged 21 "Swift tests" "$dd/swift-tests.log" scripts/run_swift_tests.sh "$dd/swift-tests"
    run_logged 22 "Ruff" "$dd/ruff.log" "$PY" -m ruff check tests
    run_logged 22 "Contract tests" "$dd/pytest.log" "$PY" -m pytest -q tests
    run_logged 20 "Release build" "$dd/release-build.log" \
        xcodebuild -quiet -project Juyi.xcodeproj -scheme Juyi -configuration Release \
        -derivedDataPath "$dd/release" CODE_SIGNING_ALLOWED=NO build
    echo "GATE: PASS (full)"
}

mode_audit() {
    check_worktree
    [ -f "$BASE_FILE" ] || die 64 "no recorded base commit; was --preflight ever run in this worktree?"
    AUDIT_BASE="$(cat "$BASE_FILE")"
    git cat-file -e "$AUDIT_BASE^{commit}" 2>/dev/null || die 64 "recorded base commit $AUDIT_BASE not found"
    git merge-base --is-ancestor "$AUDIT_BASE" HEAD || die 10 "history was rewritten: base is no longer an ancestor of HEAD"
    echo "base: $AUDIT_BASE"
    echo "commits since base:"
    git log --oneline "$AUDIT_BASE"..HEAD | sed 's/^/  /'
    echo "files changed since base:"
    git -c core.quotepath=off diff --stat --no-renames "$AUDIT_BASE" HEAD | sed 's/^/  /'
    if [ -n "$(git status --porcelain --untracked-files=no)" ]; then
        echo "note: uncommitted changes exist in the working tree (not part of this audit)"
    fi
    run_static_checks
    echo "GATE: PASS (audit)"
}

case "$MODE" in
    --check-worktree)
        check_worktree
        echo "GATE: PASS (worktree)"
        ;;
    --preflight)
        check_worktree
        preflight_clean
        preflight_toolchain
        if [ ! -f "$BASE_FILE" ]; then
            git rev-parse HEAD >"$BASE_FILE"
        fi
        echo "base commit: $(cat "$BASE_FILE")"
        echo "GATE: PASS (preflight)"
        ;;
    --static)
        check_worktree
        run_static_checks
        echo "GATE: PASS (static)"
        ;;
    --full) mode_full ;;
    --audit) mode_audit ;;
    *)
        usage
        exit 64
        ;;
esac
