"""Static contracts for the cooperative legacy/native trigger-owner protocol."""

from pathlib import Path


ROOT = Path(__file__).parents[1]
LUA = (ROOT / "hammerspoon/argos-translator.lua").read_text(encoding="utf-8")
RUNTIME = (ROOT / "tests/hammerspoon_runtime_test.lua").read_text(encoding="utf-8")
POLICY = (ROOT / "macos/NativeOwnerHandoffProtocol.swift").read_text(
    encoding="utf-8"
)
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
    assert "future activation layer" in POLICY
    macos_sources = "\n".join(
        path.read_text(encoding="utf-8") for path in (ROOT / "macos").glob("*.swift")
    )
    assert "owner-request.json" not in macos_sources


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
    assert "NativeOwnerHandoffProtocolTests.swift" in CI
    assert "hammerspoon_runtime_test.lua" in CI


def test_documentation_keeps_activation_and_production_no_go_explicit():
    normalized_doc = " ".join(DOC.split())
    for required in (
        "native activation is still **NO-GO**",
        "Hammerspoon continues to be the only production trigger",
        "No current App action creates `owner-request.json`",
        "cross-process native-owner lock",
        "zero or one trigger owner, never two",
        "Signed macOS 15.0/latest 15.x",
    ):
        assert required in normalized_doc
    user_script = "start_service" + ".command"
    for source in (PROJECT, LEGACY, CI, DOC, POLICY):
        assert user_script not in source
