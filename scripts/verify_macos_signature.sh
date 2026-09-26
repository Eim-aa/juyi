#!/usr/bin/env bash
set -euo pipefail

if [[ "$#" -ne 1 ]]; then
    echo "usage: $0 <signed Mach-O or app bundle>" >&2
    exit 2
fi

SIGNED_PATH="$1"
[[ -e "$SIGNED_PATH" ]] || { echo "missing signed artifact: $SIGNED_PATH" >&2; exit 1; }

VERIFY_ARGS=(--strict)
if [[ -d "$SIGNED_PATH" ]]; then VERIFY_ARGS+=(--deep); fi
codesign --verify "${VERIFY_ARGS[@]}" "$SIGNED_PATH"

SIGNATURE_DETAILS="$(codesign -d --verbose=4 "$SIGNED_PATH" 2>&1)"
if [[ ! "$SIGNATURE_DETAILS" =~ flags=.*runtime ]]; then
    echo "signature does not enable Hardened Runtime: $SIGNED_PATH" >&2
    exit 1
fi

echo "Verified code signature and Hardened Runtime: $SIGNED_PATH"
