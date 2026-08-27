#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 2 ]]; then
    echo "usage: $0 <Mach-O binary> <minimum macOS version>" >&2
    exit 2
fi

BINARY_PATH="$1"
EXPECTED_MINIMUM="$2"

[[ -f "$BINARY_PATH" ]] || { echo "missing binary: $BINARY_PATH" >&2; exit 1; }
[[ "$EXPECTED_MINIMUM" =~ ^[0-9]+([.][0-9]+){1,2}$ ]] || {
    echo "invalid minimum macOS version: $EXPECTED_MINIMUM" >&2
    exit 2
}

lipo "$BINARY_PATH" -verify_arch arm64 x86_64
for arch in arm64 x86_64; do
    if ! xcrun vtool -arch "$arch" -show-build "$BINARY_PATH" | \
        /usr/bin/grep -Eq "minos[[:space:]]+$EXPECTED_MINIMUM([.]0)?$"; then
        echo "unexpected deployment target for $arch slice in $BINARY_PATH" >&2
        exit 1
    fi
done

echo "Verified $BINARY_PATH (Universal 2, macOS $EXPECTED_MINIMUM+)"
