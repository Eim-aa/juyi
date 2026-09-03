"""Static contracts for the cooperative legacy/native trigger-owner protocol."""

from pathlib import Path


ROOT = Path(__file__).parents[1]
LUA = (ROOT / "hammerspoon/argos-translator.lua").read_text(encoding="utf-8")
RUNTIME = (ROOT / "tests/hammerspoon_runtime_test.lua").read_text(encoding="utf-8")
POLICY = (ROOT / "macos/NativeOwnerHandoffProtocol.swift").read_text(
    encoding="utf-8"
)
STORE = (ROOT / "macos/NativeOwnerHandoffStore.swift").read_text(encoding="utf-8")
STORE_TESTS = (ROOT / "tests/NativeOwnerHandoffStoreTests.swift").read_text(
    encoding="utf-8"
)
WORKFLOW = (ROOT / "macos/NativeOwnerHandoffWorkflow.swift").read_text(
    encoding="utf-8"
)
WORKFLOW_TESTS = (ROOT / "tests/NativeOwnerHandoffWorkflowTests.swift").read_text(
    encoding="utf-8"
)
STATUS_READER = (ROOT / "macos/NativeOwnerHandoffStatusReader.swift").read_text(
    encoding="utf-8"
)
STATUS_READER_TESTS = (
    ROOT / "tests/NativeOwnerHandoffStatusReaderTests.swift"
).read_text(encoding="utf-8")
LAB_MODEL = (ROOT / "macos/NativeOwnerHandoffLabModel.swift").read_text(
    encoding="utf-8"
)
LAB_HOST = (ROOT / "macos/NativeOwnerHandoffLabHost.swift").read_text(
    encoding="utf-8"
)
LAB_TESTS = (ROOT / "tests/NativeOwnerHandoffLabModelTests.swift").read_text(
    encoding="utf-8"
)
ACTIVATION = (ROOT / "macos/NativeOwnerActivationCoordinator.swift").read_text(
    encoding="utf-8"
)
ACTIVATION_TESTS = (
    ROOT / "tests/NativeOwnerActivationCoordinatorTests.swift"
).read_text(encoding="utf-8")
APP = (ROOT / "macos/JuyiMenuBar.swift").read_text(encoding="utf-8")
SWIFT_TESTS = (ROOT / "tests/NativeOwnerHandoffProtocolTests.swift").read_text(
    encoding="utf-8"
)
DOC = (ROOT / "docs/NATIVE_OWNER_HANDOFF_PROTOCOL.md").read_text(encoding="utf-8")
PROJECT = (ROOT / "Juyi.xcodeproj/project.pbxproj").read_text(encoding="utf-8")
LEGACY = (ROOT / "scripts/build_macos_app.sh").read_text(encoding="utf-8")
CI = (ROOT / ".github/workflows/ci.yml").read_text(encoding="utf-8")


def _between(source: str, start: str, end: str) -> str:
    return source.split(start, 1)[1].split(end, 1)[0]


def test_legacy_reads_one_exact_durable_request_fail_closed():
    reader = _between(LUA, "local function readOwnerRequest", "local function writeStatus")
    assert '"/.config/argos-translator/owner-request.json"' in LUA
    assert '#raw == 0 or #raw > 1024' in reader
    assert "keyCount ~= 4" in reader
    for key in ("version", "requested_owner", "epoch", "native_instance_id"):
        assert f"{key} = true" in reader
    assert 'decoded.requested_owner ~= "native"' in reader
    assert 'return { kind = "unavailable" }' in reader
    assert 'return { kind = "invalid" }' in reader
    assert 'if errno == 2 then return { kind = "absent" } end' in reader


def test_quiesce_tombstones_every_legacy_effect_before_yield():
    quiesce = _between(
        LUA,
        "local function quiesceLegacyOwner",
        "local function reconcileLegacyOwner",
    )
    for required in (
        "requestGeneration = requestGeneration + 1",
        "stopRequestTimers(activeRequest)",
        "activeRequest = nil",
        "tapWatcher:stop()",
        "optDown = false",
        "lastTapTime = 0",
        "dismiss()",
    ):
        assert required in quiesce

    reconcile = _between(
        LUA,
        "local function reconcileLegacyOwner",
        "local function beginRequest",
    )
    assert reconcile.index("quiesceLegacyOwner()") < reconcile.index(
        'legacyOwnerState = "yielded"'
    )
    assert 'legacyOwnerState = "blocked"' in reconcile
    assert 'legacyOwnerState = "paused"' in reconcile
    assert reconcile.index('request.kind ~= "absent"') < reconcile.index(
        "tapWatcher:start()"
    )


def test_hammerspoon_startup_reconciles_before_watcher_can_start():
    start = _between(LUA, "function M.start()", "function M.stop()")
    assert start.index("tapWatcher = hs.eventtap.new") < start.index(
        "reconcileLegacyOwner()"
    )
    assert start.index("reconcileLegacyOwner()") < start.index(
        "startExternalEngineWatcher()"
    )
    assert "tapWatcher:start()" not in start
    assert "valid-native-owner-request" in RUNTIME
    assert "startup briefly enabled yielded watcher" in RUNTIME
    assert "unavailable owner request enabled watcher" in RUNTIME


def test_status_ack_is_epoch_instance_effect_and_freshness_complete():
    status = _between(LUA, "local function writeStatus", "-- Truncate to at most")
    for field in (
        "owner_protocol_version",
        "legacy_instance_id",
        "owner_state",
        "owner_request_epoch",
        "owner_request_native_instance_id",
        "watcher_active",
        "active_request",
        "popup_visible",
        "status_sequence",
        "updated_at",
    ):
        assert field in status

    for field in (
        "ownerProtocolVersion",
        "legacyInstanceID",
        "ownerRequestEpoch",
        "ownerRequestNativeInstanceID",
        "watcherActive",
        "activeRequest",
        "popupVisible",
        "statusSequence",
        "updatedAt",
    ):
        assert field in POLICY
    assert 'status.ownerState == "yielded"' in POLICY
    assert "maximumStatusAge: TimeInterval = 2.5" in POLICY
    assert "maximumFutureClockSkew: TimeInterval = 1.0" in POLICY


def test_native_policy_is_pure_and_cannot_start_or_store_an_owner():
    for forbidden in (
        "FileManager",
        "Data(contentsOf:",
        "write(to:",
        "URLSession",
        "SecItem",
        "NSEvent",
        "AXUIElement",
        "NSPasteboard",
        "Process(",
        "UserDefaults",
    ):
        assert forbidden not in POLICY
    assert "starts no monitor" in POLICY
    assert "production activation layer" in POLICY
    assert "owner-request.json" not in POLICY


def test_store_is_production_durable_and_recovery_only():
    assert "#if DEBUG && JUYI_NATIVE_OWNER_HANDOFF_LAB" not in STORE
    for required in (
        "native-owner.lock",
        "owner-request.json",
        "O_NOFOLLOW",
        "O_EXCL",
        "RENAME_EXCL",
        "fsync(directory)",
        "LOCK_EX | LOCK_NB",
        "recoveryOnly",
        "releasePreservingRequest",
    ):
        assert required in STORE
    for forbidden in (
        "NSEvent",
        "AXUIElement",
        "NSPasteboard",
        "URLSession",
        "SecItem",
    ):
        assert forbidden not in STORE


def test_workflow_retains_lease_but_has_no_live_effects():
    assert "#if DEBUG && JUYI_NATIVE_OWNER_HANDOFF_LAB" not in WORKFLOW
    for required in (
        "acknowledgementDeadline: TimeInterval = 5",
        "waitingForLegacy",
        "legacyYielded",
        "recoverAndReturnToLegacy",
        "latestUnsafeReason",
        "ReturnReason",
        "returnActiveLeaseToLegacy",
        "if activeLease != nil",
    ):
        assert required in WORKFLOW
    for forbidden in (
        "Data(contentsOf:",
        "asyncAfter",
        "Timer",
        "NSEvent",
        "AXUIElement",
        "NSPasteboard",
        "URLSession",
        "TranslationSession",
    ):
        assert forbidden not in WORKFLOW


def test_status_reader_is_one_shot_bounded_and_nofollow():
    for required in (
        "hs-status.json",
        "O_NOFOLLOW",
        "AT_SYMLINK_NOFOLLOW",
        "maximumStatusBytes",
        "st_nlink == 1",
        "(value.st_mode & 0o022) == 0",
        "currentPath.st_ino == final.st_ino",
    ):
        assert required in STATUS_READER
    for forbidden in (
        "Timer",
        "asyncAfter",
        "write(",
        "URLSession",
        "NSEvent",
        "AXUIElement",
        "NSPasteboard",
    ):
        assert forbidden not in STATUS_READER


def test_disclosed_lab_is_explicit_monotonic_and_lifecycle_complete():
    for required in (
        "pollingInterval: TimeInterval = 0.2",
        "acknowledgementDeadline",
        "monotonicNow",
        "wallNow",
        "statusBecameUnavailable",
        "invalidatePolling()",
        "generation &+= 1",
    ):
        assert required in LAB_MODEL
    for required in (
        "打开本页为零 I/O",
        "开始安全交接测试",
        "原生 monitor 仍未启动",
        "安全归还给 Hammerspoon",
        "不会翻译、联网、读密钥",
    ):
        assert required in LAB_HOST
    for forbidden in (
        "NativeOptionMonitor",
        "AXUIElement",
        "NSPasteboard",
        "URLSession",
        "TranslationSession",
        "SecItem",
    ):
        assert forbidden not in LAB_MODEL + LAB_HOST
    for token in (
        "NativeOwnerHandoffLabLive.shared",
        "NativeOwnerHandoffLabHost()",
        "开发：双 Option owner 交接实验室…",
        "openNativeOwnerHandoffLab",
        "nativeOwnerHandoffWillSleep",
        "nativeOwnerHandoffSessionResigned",
    ):
        assert token in APP
    assert "#if DEBUG && JUYI_NATIVE_OWNER_HANDOFF_LAB" in APP
    assert "testOpenIsZeroIOAndExplicitStartYields" in LAB_TESTS
    assert "testCloseCancelsAndLatePollCannotReopen" in LAB_TESTS


def test_production_activation_orders_effect_stop_before_owner_return():
    assert "JUYI_NATIVE_OWNER_ACTIVATION_LAB" not in ACTIVATION
    for required in (
        "readyToActivate",
        "nativeActive",
        "revocationRequired",
        "effect.start()",
        "effect.stop()",
        "returnLeaseAfterConfirmedStop",
        "Keep both the durable request and cross-process process lock",
        "authorizationRevoked",
    ):
        assert required in ACTIVATION
    for forbidden in (
        "NSEvent",
        "AXUIElement",
        "NSWorkspace",
        "NSPasteboard",
        "URLSession",
        "TranslationSession",
        "SecItem",
    ):
        assert forbidden not in ACTIVATION
    for required_test in (
        "testEffectCannotStartBeforeExactYield",
        "testStartAndStopOrderingProtectsRequest",
        "testUncertainStartMustStopBeforeReturn",
        "testUncertainActiveStopNeverReturnsEarly",
        "testDuplicateActivationAndLateStatusAreIgnored",
    ):
        assert required_test in ACTIVATION_TESTS


def test_protocol_tests_cover_every_negative_and_are_in_all_build_paths():
    for reason in (
        "requestInvalid",
        "statusMissing",
        "statusTooLarge",
        "statusMalformed",
        "protocolMismatch",
        "moduleNotLoaded",
        "acknowledgementMismatch",
        "legacyInstanceInvalid",
        "stateNotYielded",
        "watcherStillActive",
        "requestStillActive",
        "popupStillVisible",
        "sequenceInvalid",
        "timestampInvalid",
        "statusStale",
    ):
        assert reason in SWIFT_TESTS
    for source in (PROJECT, LEGACY, CI):
        assert "NativeOwnerHandoffProtocol.swift" in source
        assert "NativeOwnerHandoffStore.swift" in source
        assert "NativeOwnerHandoffWorkflow.swift" in source
        assert "NativeOwnerHandoffStatusReader.swift" in source
        assert "NativeOwnerHandoffLabModel.swift" in source
        assert "NativeOwnerHandoffLabHost.swift" in source
        assert "NativeOwnerActivationCoordinator.swift" in source
    assert "NativeOwnerHandoffProtocolTests.swift" in CI
    assert "NativeOwnerHandoffStoreTests.swift" in CI
    assert "NativeOwnerHandoffWorkflowTests.swift" in CI
    assert "NativeOwnerHandoffStatusReaderTests.swift" in CI
    assert "NativeOwnerHandoffLabModelTests.swift" in CI
    assert "NativeOwnerActivationCoordinatorTests.swift" in CI
    assert "hammerspoon_runtime_test.lua" in CI


def test_documentation_records_the_production_owner_boundary():
    normalized_doc = " ".join(DOC.split())
    for required in (
        "used by the production Apple offline translation MVP",
        "never intentionally monitor double Option at the same time",
        "NativeProductionTranslationCoordinator",
        "cross-process lock",
        "zero-or-one trigger owner",
        "signed macOS 15 builds",
    ):
        assert required in normalized_doc
    user_script = "start_service" + ".command"
    for source in (
        PROJECT, LEGACY, CI, DOC, POLICY, STORE, STORE_TESTS, WORKFLOW,
        WORKFLOW_TESTS,
        STATUS_READER, STATUS_READER_TESTS,
        LAB_MODEL, LAB_HOST, LAB_TESTS, APP,
        ACTIVATION, ACTIVATION_TESTS,
    ):
        assert user_script not in source
