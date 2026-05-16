#!/usr/bin/env bash
# One-line installer entry point. Pipe to bash:
#   curl -fsSL https://raw.githubusercontent.com/Eim-aa/argos-translator/main/scripts/bootstrap.sh | bash
#
# Honors env overrides:
#   REPO_URL  override the git remote (e.g. fork URL)
#   DEST      override the checkout path (default: ~/.local/share/argos-translator)
#   BRANCH    override the branch (default: main)
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/Eim-aa/argos-translator.git}"
DEST="${DEST:-$HOME/.local/share/argos-translator}"
BRANCH="${BRANCH:-main}"

echo "== argos-translator bootstrap =="
echo "  repo:   $REPO_URL"
echo "  dest:   $DEST"
echo "  branch: $BRANCH"
echo

if ! command -v git >/dev/null 2>&1; then
    echo "git not found. install with: xcode-select --install" >&2
    exit 1
fi

if [[ -d "$DEST/.git" ]]; then
    echo "[$DEST is already a git checkout; fast-forwarding]"
    git -C "$DEST" fetch --depth=1 origin "$BRANCH"
    git -C "$DEST" checkout "$BRANCH"
    git -C "$DEST" merge --ff-only "origin/$BRANCH"
elif [[ -e "$DEST" ]]; then
    cat >&2 <<EOF
ERROR: $DEST exists and is not a git checkout.

Either:
  - move/remove it:        mv "$DEST" "$DEST.bak"
  - or pick a different path: DEST=/path/to/other bash <(curl -fsSL ...)
EOF
    exit 1
else
    mkdir -p "$(dirname "$DEST")"
    git clone --depth=1 --branch="$BRANCH" "$REPO_URL" "$DEST"
fi

exec "$DEST/scripts/install.sh"
