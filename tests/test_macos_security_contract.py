"""Static contracts for native API authentication and Keychain handling."""
from pathlib import Path


SWIFT = (
    Path(__file__).parents[1] / "macos" / "JuyiMenuBar.swift"
).read_text(encoding="utf-8")


def _body(after, before):
    return SWIFT.split(after, 1)[1].split(before, 1)[0]


def test_every_service_request_reads_install_token_and_uses_bearer_header():
    helper = _body(
        "private func authenticatedRequest", "func refresh() async"
    )
    assert 'appendingPathComponent("auth-token")' in SWIFT
    assert 'String(contentsOf: authTokenFile' in helper
    assert "token.utf8.count == 64" in helper
    assert '"Bearer \\(token)"' in helper
    assert 'forHTTPHeaderField: "Authorization"' in helper

    # The helper itself is the only direct URLRequest constructor.
    assert SWIFT.count("URLRequest(url:") == 1
    for endpoint in ("health", "translate", "validate/volc-pending"):
        request_line = next(
            line for line in SWIFT.splitlines() if f'appendingPathComponent("{endpoint}")' in line
        )
        assert "authenticatedRequest" in request_line

    # Cloud credentials are never serialized into a loopback HTTP request.
    assert 'appendingPathComponent("validate/volc")' not in SWIFT
    assert '["access_key": accessKey, "secret_key": secretKey]' not in SWIFT


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
    assert 'URL(fileURLWithPath: "/usr/bin/security")' in runner
    assert "process.standardInput = inputPipe" in runner
    assert "inputPipe.fileHandleForWriting.write(input)" in runner
    assert "process.standardError = FileHandle.nullDevice" in runner


def test_keychain_is_preferred_and_legacy_credentials_are_migrated_safely():
    read = _body(
        "private func readCloudCredentials", "private func credentialFingerprint"
    )
    assert "switch AppModel.readKeychainCloudCredentials()" in read
    assert "case .notFound: return readLegacyCloudCredentials()" in read
    assert "case .invalid, .unavailable: return nil" in read

    migration = _body(
        "private func migrateLegacyCloudCredentialsIfNeeded",
        "private func authenticatedRequest",
    )
    assert "saveKeychainCloudCredentials(legacy)" in migration
    assert "readKeychainCloudCredentials() == .found(legacy)" in migration
    assert "case .invalid, .unavailable" in migration
    assert migration.index("saveKeychainCloudCredentials") < migration.index(
        "writeEnvironmentWithoutSecrets"
    )
    assert "migrateLegacyCloudCredentialsIfNeeded()" in _body(
        "init() {", "var hammerspoonInstalled"
    )


def test_new_cloud_save_never_writes_keys_to_env_and_has_rollback():
    configure = _body("func configureCloud", "private func restoreCloudRemoval")
    assert "CloudCredentials(accessKey: access, secretKey: secret)" in configure
    assert 'writeEnvironmentWithoutSecrets(engine: "volc")' in configure
    assert "VOLC_ACCESS_KEY=" not in configure
    assert "VOLC_SECRET_KEY=" not in configure
    assert "keychainBackup" in configure
    assert "environmentBackup" in configure
    assert "restoreKeychainCloudCredentials(keychainBackup)" in configure
    assert "restoreEnvironment(environmentBackup)" in configure
    assert configure.index("savePendingCloudCredentials(candidate)") < configure.index(
        "validatePendingCloud()"
    ) < configure.index("saveKeychainCloudCredentials(candidate)")
    assert "activeWriteAttempted" in configure
    assert "runtimeRestored" in configure


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


def test_remove_cloud_deletes_keychain_and_strips_legacy_keys():
    remove = _body("func removeCloud", "func testTranslation")
    assert "restoreCloudRemoval(" in remove
    assert "createCloudRemovalMarker()" in remove
    assert "completeCloudRemoval(allowAlreadyStopped: false)" in remove
    assert remove.index("createCloudRemovalMarker()") < remove.index('setEngine("apple")')

    complete = _body("private func completeCloudRemoval", "private func finishInterruptedCloudRemoval")
    assert "deleteKeychainCloudCredentials()" in complete
    assert "startServiceAndWait(expectCloud: false)" in complete
    assert 'writeEnvironmentWithoutSecrets(engine: "apple")' in complete
    assert complete.index("stopServiceAndConfirm") < complete.index(
        "deleteKeychainCloudCredentials()"
    )
    sanitizer = _body(
        "private func writeEnvironmentWithoutSecrets",
        "private func restoreEnvironment",
    )
    assert 'key == "VOLC_ACCESS_KEY" || key == "VOLC_SECRET_KEY"' in sanitizer


def test_pending_item_is_kept_until_commit_and_recovered_after_a_crash():
    configure = _body("func configureCloud", "private func restoreCloudRemoval")
    validation = configure.index('translate("Good tools should feel effortless.", engine: "volc")')
    delete_pending = configure.index("deletePendingCloudCredentials(matching: candidate)", validation)
    assert validation < delete_pending
    assert "pendingStillMatches" in configure
    assert "committedStateMatches" in configure

    recovery = _body(
        "private func recoverInterruptedCloudConfiguration",
        "func validateExistingCloud",
    )
    assert "activeCredentials != candidate" in recovery
    assert 'writeEnvironmentWithoutSecrets(engine: "volc")' in recovery
    assert "startServiceAndWait(expectCloud: true)" in recovery
    assert recovery.index('translate("Good tools should feel effortless.", engine: "volc")') < recovery.index(
        "deletePendingCloudCredentials(matching: candidate)",
        recovery.index('translate("Good tools should feel effortless.", engine: "volc")'),
    )
    assert "await recoverInterruptedCloudConfiguration()" in SWIFT

    failed_transaction = configure.split("} catch {", 1)[1]
    assert failed_transaction.index("restoreKeychainCloudCredentials(keychainBackup)") < failed_transaction.index(
        "deletePendingCloudCredentials(matching: candidate)"
    )


def test_cloud_operations_share_one_lock_and_removal_confirms_service_exit():
    init = _body("init() {", "var hammerspoonInstalled")
    assert init.index("cloudBusy = true") < init.index("Task {")
    validate = _body("func validateExistingCloud", "func configureCloud")
    assert "guard !testing, !cloudBusy else" in validate
    assert "cloudBusy = true" in validate
    assert "defer" in validate and "cloudBusy = false" in validate
    for operation, end in (
        ("func chooseApple", "func chooseCloud"),
        ("func chooseCloud", "@discardableResult private func setEngine"),
        ("func testTranslation", "private func translate"),
    ):
        assert "cloudBusy" in _body(operation, end)

    stop = _body("private func stopServiceAndConfirm", "func removeCloud")
    assert "guard requested == 0 else { return false }" in stop
    assert "Could not find service" in stop
    assert "for _ in 0..<40" in stop
    assert "launchctlPID(from: snapshot.1)" in stop
    assert "processExists(oldPID)" in stop
    assert "for _ in 0..<80" in stop


def test_cloud_removal_marker_is_owner_only_and_recovered_before_migration():
    marker_reader = _body("private func readCloudRemovalMarker", "private func createCloudRemovalMarker")
    assert "destinationOfSymbolicLink" in marker_reader
    assert "permissions & 0o077 == 0" in marker_reader
    assert "owner == getuid()" in marker_reader
    assert 'data == Data("1\\n".utf8)' in marker_reader

    marker_creator = _body("private func createCloudRemovalMarker", "private func deleteCloudRemovalMarker")
    assert "O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC" in marker_creator
    assert "mode_t(0o600)" in marker_creator
    assert "Darwin.fchmod" in marker_creator
    assert "Darwin.fsync" in marker_creator

    init = _body("init() {", "var hammerspoonInstalled")
    assert init.index("readCloudRemovalMarker() == .notFound") < init.index(
        "migrateLegacyCloudCredentialsIfNeeded()"
    )
    recovery = _body(
        "private func recoverInterruptedCloudConfiguration",
        "func validateExistingCloud",
    )
    assert recovery.index("readCloudRemovalMarker()") < recovery.index(
        "readKeychainCloudCredentials("
    )
    finish = _body("private func finishInterruptedCloudRemoval", "func removeCloud")
    assert "completeCloudRemoval(allowAlreadyStopped: true)" in finish
    assert "deleteCloudRemovalMarker()" in finish
    engine_failure = finish.split('guard setEngine("apple") else {', 1)[1].split("}", 1)[0]
    assert "stopServiceAndConfirm(allowAlreadyStopped: true)" in engine_failure


def test_environment_backup_distinguishes_absent_from_unreadable():
    reader = _body("private func readEnvironmentFile", "@discardableResult private func restoreEnvironment")
    assert "case found" not in reader  # result cases are constructed, not consumed
    assert "? .unavailable : .notFound" in reader
    assert "EnvironmentFileRead" in SWIFT
    assert "environmentBackup != .unavailable" in SWIFT
