"""Static contracts for Keychain handling and the absence of any loopback API.

Since phase 4A the cloud engine is native: the app validates a candidate in
memory, stores it in Keychain, and signs requests itself. Phase 4B removed the
loopback service, its bearer token and the plaintext `volc.env` mirror; the
pending-item / removal-marker / service-restart machinery must stay gone.
"""
import re
from pathlib import Path


ROOT = Path(__file__).parents[1]
SWIFT = (ROOT / "macos" / "JuyiMenuBar.swift").read_text(encoding="utf-8")
ENGINE = (ROOT / "macos" / "VolcTranslationEngine.swift").read_text(encoding="utf-8")
BUILDER = (ROOT / "macos" / "VolcV4RequestBuilder.swift").read_text(encoding="utf-8")
PARSER = (ROOT / "macos" / "VolcTranslationResponseParser.swift").read_text(encoding="utf-8")


def _body(after, before):
    return SWIFT.split(after, 1)[1].split(before, 1)[0]


def test_no_loopback_service_request_or_token_remains():
    for removed in (
        "127.0.0.1",
        "5432" + "1",
        "authenticatedRequest",
        "auth-token",
        "authTokenFile",
        'appendingPathComponent("health")',
        "Bearer",
        "struct Health",
        "HotkeyStatus",
        "hs-status" + ".json",
    ):
        assert removed not in SWIFT, removed
    # The only URLRequest in the app is built by the Volcengine signer.
    assert "URLRequest(url:" not in SWIFT
    for endpoint in ("translate", "validate/volc-pending", "validate/volc"):
        assert f'appendingPathComponent("{endpoint}")' not in SWIFT
    # Cloud credentials are never serialized into a local HTTP request.
    assert '["access_key": accessKey, "secret_key": secretKey]' not in SWIFT


def test_transaction_machinery_for_the_service_transport_is_removed():
    for removed in (
        "volc.pending",
        "volcPendingKeychainService",
        "savePendingCloudCredentials",
        "deletePendingCloudCredentials",
        "validatePendingCloud",
        "cloud-removal-pending",
        "CloudRemovalMarker",
        "restoreCloudRemoval",
        "finishInterruptedCloudRemoval",
        "recoverInterruptedCloudConfiguration",
        "completeCloudRemoval",
        "startServiceAndWait",
        "stopServiceAndConfirm",
        "waitForService",
        "restoreKeychainCloudCredentials",
        "restoreEnvironment",
        "TranslationResponse",
        "friendlyError",
        "writeEnvironmentWithoutSecrets",
        "readEnvironmentValues",
        "readLegacyCloudCredentials",
        "migrateLegacyCloudCredentialsIfNeeded",
        "envFile",
        "engineFile",
    ):
        assert removed not in SWIFT, removed


def test_keychain_item_is_single_json_payload_written_via_stdin():
    assert 'volcKeychainService = "io.github.Eim-aa.juyi.volc"' in SWIFT
    assert 'volcKeychainAccount = "volc"' in SWIFT
    assert 'case accessKey = "access_key"' in SWIFT
    assert 'case secretKey = "secret_key"' in SWIFT

    save = _body(
        "nonisolated private static func saveKeychainCloudCredentials",
        "nonisolated private static func deleteKeychainCloudCredentials",
    )
    assert "JSONEncoder().encode(credentials)" in save
    assert '"add-generic-password", "-U", "-s"' in save
    assert '"-a", account, "-w"' in save
    assert "], input: payload)" in save
    assert "credentials.accessKey" not in save
    assert "credentials.secretKey" not in save

    runner = _body(
        "nonisolated private static func runSecurity",
        "nonisolated private static func readKeychainCloudCredentials",
    )
    assert "runBoundedProcess(" in runner
    assert 'executablePath: "/usr/bin/security"' in runner
    assert "arguments: arguments" in runner
    assert "input: input" in runner
    assert "mergeStandardError:" not in runner

    process = _body(
        "nonisolated private static func runBoundedProcess",
        "nonisolated private static func launchctl",
    )
    assert "URL(fileURLWithPath: executablePath)" in process
    assert "process.standardInput = pipe" in process
    assert "pipe.fileHandleForWriting.write(contentsOf: input)" in process
    assert "mergeStandardError: Bool = false" in process
    assert (
        "process.standardError = mergeStandardError ? outputPipe : FileHandle.nullDevice"
        in " ".join(process.split())
    )
    # Security.framework is never imported; Keychain goes through the CLI.
    for source in (SWIFT, ENGINE, BUILDER, PARSER):
        assert "import Security" not in source
        assert "SecItem" not in source


def test_keychain_is_the_only_credential_source_and_legacy_keys_move_once():
    read = _body(
        "private func readCloudCredentialsOffMainActor", "private func credentialFingerprint"
    )
    assert "await Task.detached {" in read
    assert "AppModel.readKeychainCloudCredentials()" in read
    assert "case .notFound, .invalid, .unavailable: return nil" in read
    assert "volc.env" not in read

    # A plaintext pre-native pair is moved into Keychain only by the explicit
    # early-component removal, before any file is deleted.
    migration = SWIFT.split(
        "nonisolated private static func migrateLegacyCloudCredentials", 1
    )[1].split("\n    }\n", 1)[0]
    assert "case .found:\n            return true" in migration
    assert "saveKeychainCloudCredentials(candidate)" in migration
    assert "readKeychainCloudCredentials() == .found(candidate)" in migration
    assert "case .invalid, .unavailable:\n            return false" in migration
    removal = _body("private func removeLegacyComponents()", "// Presentation only")
    assert removal.index("AppModel.migrateLegacyCloudCredentials(legacy)") < removal.index(
        "LegacyComponentCleanup.perform("
    )
    guard = removal[removal.index("guard migrated else {"):removal.index("LegacyComponentCleanup.perform(")]
    assert "return" in guard
    init = _body("init() {", "private var refreshContext")
    assert "migrateLegacyCloudCredentials" not in init
    assert init.index("cloudBusy = true") < init.index("Task {")


def test_engine_reads_keychain_off_main_actor_through_the_cli_wrapper():
    reader = _body(
        "nonisolated static func readVolcEngineCredentials",
        "nonisolated private static func migrateLegacyCloudCredentials",
    )
    assert "readKeychainCloudCredentials()" in reader
    assert "VolcV4Credentials(accessKey: credentials.accessKey, secretKey: credentials.secretKey)" in reader
    # Keychain only: the engine never reads plaintext legacy files.
    assert "readLegacyCloudCredentials" not in reader
    init = _body("init() {", "private var refreshContext")
    assert "VolcTranslationEngine.shared.credentialProvider = {" in init
    assert "await Task.detached { AppModel.readVolcEngineCredentials() }.value" in init


def test_new_cloud_save_validates_in_memory_before_any_keychain_write():
    configure = _body("func configureCloud", "func removeCloud")
    assert "CloudCredentials(accessKey: access, secretKey: secret)" in configure
    assert "VOLC_ACCESS_KEY=" not in configure
    assert "VOLC_SECRET_KEY=" not in configure
    assert "writeEnvironmentWithoutSecrets" not in configure
    validate = configure.index("VolcTranslationEngine.shared.validate(")
    guard = configure.index("guard case .translated = outcome else")
    save = configure.index("AppModel.saveKeychainCloudCredentials(candidate)")
    assert validate < guard < save
    # A failed candidate returns before anything is written.
    failed = configure[guard:save]
    assert "return" in failed
    assert "saveKeychainCloudCredentials" not in failed
    assert "AppModel.readKeychainCloudCredentials() == .found(candidate)" in configure
    assert configure.index("saveKeychainCloudCredentials(candidate)") < configure.index(
        'setEngine("volc")'
    )
    assert "cloudCredentialsDidChange()" in configure


def test_cloud_operations_never_wait_for_security_on_the_main_actor():
    """`security` and launchctl run in bounded child processes that block on a
    DispatchSemaphore; that wait must never happen on the main actor."""
    blocking = (
        "readKeychainCloudCredentials(",
        "saveKeychainCloudCredentials(",
        "deleteKeychainCloudCredentials(",
        "readVolcEngineCredentials(",
        "runSecurity(",
        "runBoundedProcess(",
        "AppModel.launchctl(",
    )
    for start, end in (
        ("func chooseApple", "func repairCurrentTranslation"),
        ("func chooseCloud", "private func setEngine"),
        ("private func setEngine", "func validateExistingCloud"),
        ("func validateExistingCloud", "func configureCloud"),
        ("func configureCloud", "func removeCloud"),
        ("func removeCloud", "func testTranslation"),
        ("func testTranslation", "private static func cloudFailureMessage"),
        ("private func removeLegacyComponents()", "// Presentation only"),
        ("func refreshLegacyComponents()", "func performLegacyComponentAction()"),
        ("init() {", "private var refreshContext"),
    ):
        body = _body(start, end)
        off_main = re.sub(r"Task\.detached \{.*?\}\.value", "", body, flags=re.DOTALL)
        for call in blocking:
            assert call not in off_main, f"{start} calls {call} on the main actor"
    process = _body(
        "nonisolated private static func runBoundedProcess",
        "nonisolated private static func launchctl",
    )
    assert SWIFT.count("DispatchSemaphore") == process.count("DispatchSemaphore") == 2
    for source in (ENGINE, BUILDER, PARSER):
        assert "DispatchSemaphore" not in source

    remove = _body("func removeCloud", "func testTranslation")
    assert remove.index("cloudBusy = true") < remove.index("deleteKeychainCloudCredentials()")
    configure = _body("func configureCloud", "func removeCloud")
    assert configure.index("cloudBusy = true") < configure.index("saveKeychainCloudCredentials(")


def test_keychain_read_distinguishes_absent_invalid_and_unavailable():
    reader = _body(
        "nonisolated private static func readKeychainCloudCredentials",
        "nonisolated private static func saveKeychainCloudCredentials",
    )
    assert "result.0 == 44" in reader
    assert "return .notFound" in reader
    assert "return .unavailable" in reader
    assert "return .invalid" in reader
    assert "return .found(credentials)" in reader


def test_remove_cloud_deletes_keychain_switches_to_apple_and_forgets_memory():
    remove = _body("func removeCloud", "func testTranslation")
    assert "AppModel.deleteKeychainCloudCredentials()" in remove
    assert remove.index("deleteKeychainCloudCredentials()") < remove.index('setEngine("apple")')
    assert "cloudCredentialsDidChange()" in remove
    assert "cloudVerified = false" in remove
    set_engine = _body("private func setEngine", "func validateExistingCloud")
    assert "VolcTranslationEngine.shared.forgetCredentials()" in set_engine
    assert "UserDefaults.standard.set(choice.rawValue, forKey: selectedEngineDefaultsKey)" in set_engine
    assert "NativeProductionTranslationCoordinator.shared.setEngine(choice)" in set_engine
    # UserDefaults is the only engine store: no legacy file mirror remains.
    for mirror in ("hs-engine", "volc.env", "write(to:", "FileManager"):
        assert mirror not in set_engine


def test_cloud_operations_share_one_lock():
    validate = _body("func validateExistingCloud", "func configureCloud")
    assert "guard !testing, !cloudBusy else" in validate
    assert "cloudBusy = true" in validate
    assert "defer" in validate and "cloudBusy = false" in validate
    for operation, end in (
        ("func chooseApple", "func repairCurrentTranslation"),
        ("func chooseCloud", "private func setEngine"),
        ("func testTranslation", "private static func cloudFailureMessage"),
        ("func configureCloud", "func removeCloud"),
        ("func removeCloud", "func testTranslation"),
    ):
        assert "cloudBusy" in _body(operation, end)


def test_volc_engine_never_logs_or_persists_credentials():
    for source in (ENGINE, BUILDER, PARSER):
        for forbidden in (
            "UserDefaults",
            "FileManager",
            "write(to:",
            "print(",
            "NSLog",
            "os_log",
            "Logger",
            "localizedDescription",
            "httpCookieStorage = HTTPCookieStorage",
        ):
            assert forbidden not in source, forbidden
    # The engine never touches the secret itself; only the signer does, and
    # only to derive the HMAC key. The request carries the signature.
    assert "secretKey" not in ENGINE
    assert BUILDER.count("credentials.secretKey") == 2
    assert "Data(credentials.secretKey.utf8)" in BUILDER
    headers = BUILDER.split("            headers: [\n", 1)[1].split("],", 1)[0]
    assert "secretKey" not in headers
    assert '"Authorization": authorization' in headers
    authorization = BUILDER.split("let authorization =", 1)[1].split("return VolcV4SignedRequest", 1)[0]
    assert "secretKey" not in authorization
    for redacted in ("VolcV4Credentials([REDACTED])", "headers: [REDACTED]", "translated([REDACTED])"):
        assert redacted in BUILDER + ENGINE
    # Cached only in memory, dropped on removal or Apple selection.
    assert "private var cachedCredentials: VolcV4Credentials?" in ENGINE
    assert "func forgetCredentials()" in ENGINE
    assert "configuration.urlCredentialStorage = nil" in ENGINE
    assert "configuration.urlCache = nil" in ENGINE
    assert "configuration.httpCookieStorage = nil" in ENGINE
    assert "configuration.waitsForConnectivity = false" in ENGINE
    assert "completionHandler(nil)" in ENGINE  # redirects are refused
