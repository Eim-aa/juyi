#!/usr/bin/env bash
# One-line installer entry point. Pipe to bash:
#   curl -fsSL https://raw.githubusercontent.com/Eim-aa/juyi/main/scripts/bootstrap.sh | bash
#
# Honors env overrides:
#   REPO_URL  override the git remote (e.g. fork URL)
#   DEST      override the checkout path (default: ~/.local/share/argos-translator)
#   BRANCH    override the branch (default: main)
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/Eim-aa/juyi.git}"
DEST="${DEST:-$HOME/.local/share/argos-translator}"
BRANCH="${BRANCH:-main}"

require_macos_15() {
    local platform product_version major
    platform="$(/usr/bin/uname -s 2>/dev/null || true)"
    if [[ "$platform" != "Darwin" ]]; then
        echo "ERROR: 句译公开版只能安装在 macOS 15.0 或更高版本。未下载或修改任何安装文件。" >&2
        exit 1
    fi
    product_version="$(/usr/bin/sw_vers -productVersion 2>/dev/null || true)"
    major="${product_version%%.*}"
    if [[ ! "$major" =~ ^[0-9]+$ || "$major" -lt 15 ]]; then
        echo "ERROR: 句译公开版需要 macOS 15.0 或更高版本（当前：${product_version:-未知}）。未更新源码、服务、Hammerspoon 或 App；现有安装已保留。" >&2
        exit 1
    fi
}

# Keep this before git discovery/fetch/checkout/clone and destination mkdir so
# an unsupported Mac cannot partially update a service's live checkout.
require_macos_15

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
