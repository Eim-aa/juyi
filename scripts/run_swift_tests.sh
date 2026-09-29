#!/usr/bin/env bash
# Compile and run every production Swift test executable. Used by CI and for
# local verification. Each suite is a small `@main` program built with swiftc
# from exactly the production sources it exercises.
#
# Usage: scripts/run_swift_tests.sh [output-directory]
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
OUT="${1:-${RUNNER_TEMP:-${TMPDIR:-/tmp}}/juyi-swift-tests}"
mkdir -p "$OUT"
cd "$ROOT"

BASE_FLAGS=(-swift-version 5 -warnings-as-errors -parse-as-library)
STRICT_FLAGS=("${BASE_FLAGS[@]}" -strict-concurrency=complete)
AX_FRAMEWORKS=(-framework AppKit -framework ApplicationServices)

passed=0

# run_suite <name> <flags-array-name> <source>... -- the test file is
# tests/<name>.swift and is appended automatically.
run_suite() {
    local name="$1" flags_name="$2"
    shift 2
    local flags_ref="${flags_name}[@]"
    local binary="$OUT/$name"
    echo "==> $name"
    swiftc "${!flags_ref}" "$@" "tests/$name.swift" -o "$binary"
    "$binary"
    passed=$((passed + 1))
}

PLAIN=("${BASE_FLAGS[@]}")
AX=("${BASE_FLAGS[@]}" "${AX_FRAMEWORKS[@]}")
STRICT=("${STRICT_FLAGS[@]}")

run_suite OnboardingPolicyTests PLAIN macos/OnboardingPolicy.swift
run_suite WindowFramePolicyTests PLAIN macos/WindowFramePolicy.swift
run_suite AppRefreshPolicyTests PLAIN macos/AppRefreshPolicy.swift
run_suite NativeTriggerPreflightTests PLAIN macos/NativeTriggerPreflight.swift
run_suite DoubleOptionStateMachineTests PLAIN macos/DoubleOptionStateMachine.swift
run_suite NativeOptionEventAdapterTests PLAIN \
    macos/DoubleOptionStateMachine.swift macos/NativeOptionEventAdapter.swift
run_suite NativeSelectionReaderTests AX \
    macos/AccessibilityController.swift macos/NativeSelectionReader.swift
run_suite NativeSelectionCaptureCoordinatorTests AX \
    macos/AccessibilityController.swift macos/NativeSelectionReader.swift \
    macos/NativeSelectionCaptureCoordinator.swift
run_suite NativeOptionMonitorTests AX \
    macos/AccessibilityController.swift macos/DoubleOptionStateMachine.swift \
    macos/NativeOptionEventAdapter.swift macos/NativeSelectionReader.swift \
    macos/NativeSelectionCaptureCoordinator.swift macos/NativeOptionMonitor.swift
run_suite NativeOwnerHandoffProtocolTests PLAIN macos/NativeOwnerHandoffProtocol.swift
run_suite NativeOwnerHandoffStoreTests STRICT \
    macos/NativeOwnerHandoffProtocol.swift macos/NativeOwnerHandoffStore.swift
run_suite NativeOwnerHandoffWorkflowTests STRICT \
    macos/NativeOwnerHandoffProtocol.swift macos/NativeOwnerHandoffStore.swift \
    macos/NativeOwnerHandoffWorkflow.swift
run_suite NativeOwnerHandoffStatusReaderTests STRICT \
    macos/NativeOwnerHandoffProtocol.swift macos/NativeOwnerHandoffStatusReader.swift
run_suite NativeOwnerActivationCoordinatorTests STRICT \
    macos/NativeOwnerHandoffProtocol.swift macos/NativeOwnerHandoffStore.swift \
    macos/NativeOwnerHandoffWorkflow.swift macos/NativeOwnerActivationCoordinator.swift
run_suite NativeTranslationOverlayModelTests PLAIN macos/NativeTranslationOverlayModel.swift
run_suite NativeTranslationOverlayAnchorPolicyTests PLAIN \
    macos/NativeTranslationOverlayAnchorPolicy.swift
run_suite NativeTranslationOverlayInteractionPolicyTests PLAIN \
    macos/NativeTranslationOverlayInteractionPolicy.swift

echo "All $passed Swift test suites passed."
