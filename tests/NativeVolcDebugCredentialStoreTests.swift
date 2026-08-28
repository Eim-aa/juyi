#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER
import Foundation
import LocalAuthentication
import Security

private final class NativeVolcFakeSecItems: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [String: Data] = [:]
    private var unavailableReads: Set<String> = []
    private(set) var calls: [String] = []
    var failWrites = false
    var failDeletes = false

    var client: NativeVolcSecItemClient {
        NativeVolcSecItemClient(
            read: { [weak self] service, account in
                self?.read(service: service, account: account) ?? .unavailable
            },
            write: { [weak self] service, account, data in
                self?.write(service: service, account: account, data: data) ?? false
            },
            delete: { [weak self] service, account in
                self?.delete(service: service, account: account) ?? false
            }
        )
    }

    func seed(_ data: Data, slot: NativeVolcDebugKeychainSlot) {
        lock.withLock { items[key(slot.service, slot.account)] = data }
    }

    func setUnavailable(_ slot: NativeVolcDebugKeychainSlot) {
        _ = lock.withLock { unavailableReads.insert(key(slot.service, slot.account)) }
    }

    func stored(_ slot: NativeVolcDebugKeychainSlot) -> Data? {
        lock.withLock { items[key(slot.service, slot.account)] }
    }

    private func read(service: String, account: String) -> NativeVolcRawItemRead {
        lock.withLock {
            let itemKey = key(service, account)
            calls.append("read:\(service):\(account)")
            if unavailableReads.contains(itemKey) { return .unavailable }
            guard let data = items[itemKey] else { return .notFound }
            return .found(data)
        }
    }

    private func write(service: String, account: String, data: Data) -> Bool {
        lock.withLock {
            calls.append("write:\(service):\(account)")
            guard !failWrites else { return false }
            items[key(service, account)] = data
            return true
        }
    }

    private func delete(service: String, account: String) -> Bool {
        lock.withLock {
            calls.append("delete:\(service):\(account)")
            guard !failDeletes else { return false }
            items.removeValue(forKey: key(service, account))
            return true
        }
    }

    private func key(_ service: String, _ account: String) -> String {
        "\(service)\u{0}\(account)"
    }
}

private extension NSLock {
    func withLock<T>(_ operation: () -> T) -> T {
        lock()
        defer { unlock() }
        return operation()
    }
}

@main
@MainActor
enum NativeVolcDebugCredentialStoreTests {
    private static var passed = 0

    private static func expect(
        _ condition: Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard condition else { fatalError("\(message) (\(file):\(line))") }
        passed += 1
    }

    static func main() async {
        testNamespaceAndValidation()
        testLegacyKeychainFailsWithoutAuthenticationUI()
        await testRoundTripsAndReadback()
        await testInvalidAndUnavailableItems()
        testJournalTransitionsAndRedaction()
        await testStrictJournalPayload()
        print("NativeVolcDebugCredentialStoreTests: \(passed) passed")
    }

    private static func testNamespaceAndValidation() {
        let slots = NativeVolcDebugKeychainSlot.allCases
        expect(Set(slots.map(\.service)).count == 4, "four separate Debug services")
        expect(
            slots.allSatisfy { $0.service.hasPrefix("io.github.Eim-aa.Juyi.debug.native-volc.") },
            "all services use the isolated Debug namespace"
        )
        expect(slots.map(\.account) == ["active", "pending", "verified", "promotion"],
               "accounts are fixed")

        let credentials = NativeVolcDebugCredentials(accessKey: "AKTEST", secretKey: "SKTEST")
        expect(credentials != nil, "valid credentials accepted")
        expect(
            credentials?.fingerprint
                == VolcV4RequestBuilder.sha256Hex(Data("AKTEST\u{0}SKTEST".utf8)),
            "fingerprint is SHA256(AK NUL SK)"
        )
        expect(NativeVolcDebugCredentials(accessKey: "", secretKey: "SK") == nil,
               "invalid AK rejected")
        expect(NativeVolcDebugCredentials(accessKey: "AK", secretKey: "bad\nsecret") == nil,
               "invalid SK rejected")
        expect(String(describing: credentials!).contains("AKTEST") == false,
               "credential description is redacted")
        expect(String(reflecting: credentials!).contains("SKTEST") == false,
               "credential reflection is redacted")
    }

    private static func testLegacyKeychainFailsWithoutAuthenticationUI() {
        let query = NativeVolcSecurityClient.baseQuery(
            service: NativeVolcDebugKeychainSlot.active.service,
            account: NativeVolcDebugKeychainSlot.active.account
        )
        expect(query[kSecUseAuthenticationUI as String] as? String == "u_AuthUIF",
               "legacy macOS Keychain query explicitly fails instead of showing auth UI")
        let context = query[kSecUseAuthenticationContext as String] as? LAContext
        expect(context != nil,
               "each legacy query also carries a fresh LocalAuthentication context")
        expect(query[kSecAttrSynchronizable as String] as? Bool == false,
               "Debug credential item is never synchronizable")
        expect(query[kSecUseDataProtectionKeychain as String] == nil,
               "ad-hoc baseline does not silently switch Keychain implementation")
        expect(query[kSecAttrAccessible as String] == nil,
               "legacy nonsynchronizable item does not claim unsupported accessibility class")
    }

    private static func testRoundTripsAndReadback() async {
        let fake = NativeVolcFakeSecItems()
        let store = NativeVolcDebugCredentialStore(client: fake.client)
        let credentials = NativeVolcDebugCredentials(accessKey: "AKTEST", secretKey: "SKTEST")!
        let verified = NativeVolcDebugVerifiedRecord(fingerprint: credentials.fingerprint)!

        expect(await store.readCredentials(.active) == .notFound, "missing active is explicit")
        expect(await store.writeCredentials(credentials, to: .pending), "pending write readback")
        expect(await store.readCredentials(.pending) == .found(credentials), "pending round trip")
        expect(await store.writeCredentials(credentials, to: .active), "active write readback")
        expect(await store.writeVerified(verified), "verified write readback")
        expect(await store.readVerified() == .found(verified), "verified round trip")
        expect(await store.delete(.pending), "delete confirms absence")
        expect(await store.readCredentials(.pending) == .notFound, "pending absent after delete")
        expect(await store.writeCredentials(credentials, to: .verified) == false,
               "credentials cannot enter metadata slot")
        expect(fake.calls.contains { $0.hasPrefix("write:") }, "writes use injected client")

        fake.failWrites = true
        expect(await store.writeCredentials(credentials, to: .pending) == false,
               "write failure is fail closed")
        fake.failWrites = false
        fake.failDeletes = true
        expect(await store.delete(.active) == false, "delete failure is fail closed")
    }

    private static func testInvalidAndUnavailableItems() async {
        let fake = NativeVolcFakeSecItems()
        let store = NativeVolcDebugCredentialStore(client: fake.client)
        fake.seed(Data(#"{"access_key":"AKTEST","secret_key":"SKTEST","extra":1}"#.utf8),
                  slot: .active)
        expect(await store.readCredentials(.active) == .invalid, "extra credential key rejected")
        fake.seed(Data(#"{"version":1,"fingerprint":"ABC","profile":"wrong"}"#.utf8),
                  slot: .verified)
        expect(await store.readVerified() == .invalid, "invalid verified record rejected")
        fake.setUnavailable(.pending)
        expect(await store.readCredentials(.pending) == .unavailable,
               "Keychain access failure remains unavailable")
        expect(String(describing: await store.readCredentials(.pending)).contains("SKTEST") == false,
               "read status description carries no credential")
    }

    private static func testJournalTransitionsAndRedaction() {
        let old = NativeVolcDebugCredentials(accessKey: "OLDKEY", secretKey: "OLDSECRET")!
        let oldVerified = NativeVolcDebugVerifiedRecord(fingerprint: old.fingerprint)!
        let candidate = NativeVolcDebugCredentials(accessKey: "NEWKEY", secretKey: "NEWSECRET")!
        let staged = NativeVolcPromotionJournal(
            identifier: "4A28DA80-5FA1-4E69-A58D-D2CF901D2F70",
            phase: .staged,
            candidateFingerprint: candidate.fingerprint,
            oldActive: old,
            oldVerified: oldVerified
        )!
        let validated = staged.advancing(to: .validated)
        let active = validated?.advancing(to: .activeWritten)
        let verified = active?.advancing(to: .verifiedWritten)
        expect(validated?.phase == .validated, "journal advances staged to validated")
        expect(active?.phase == .activeWritten, "journal advances validated to active")
        expect(verified?.phase == .verifiedWritten, "journal advances active to verified")
        expect(staged.advancing(to: .activeWritten) == nil, "journal cannot skip phase")
        expect(validated?.advancing(to: .staged) == nil, "journal cannot move backward")
        expect(verified?.advancing(to: .verifiedWritten) == nil, "journal cannot repeat phase")
        let rollback = verified?.beginningRollback()
        let rollbackActive = rollback?.advancingRollback(to: .rollbackActiveRestored)
        let rollbackVerified = rollbackActive?.advancingRollback(to: .rollbackVerifiedRestored)
        let rollbackPending = rollbackVerified?.advancingRollback(to: .rollbackPendingRemoved)
        expect(rollback?.phase == .rollbackRequested, "failure persists rollback intent first")
        expect(rollbackActive?.phase == .rollbackActiveRestored,
               "rollback records active restoration")
        expect(rollbackVerified?.phase == .rollbackVerifiedRestored,
               "rollback records verified restoration")
        expect(rollbackPending?.phase == .rollbackPendingRemoved,
               "rollback records candidate deletion")
        expect(rollback?.advancingRollback(to: .rollbackVerifiedRestored) == nil,
               "rollback cannot skip a durable phase")
        let display = String(describing: staged) + String(reflecting: staged)
        expect(!display.contains("OLDSECRET"), "journal description hides backup secret")
        expect(!display.contains("NEWKEY"), "journal description hides candidate identity")
    }

    private static func testStrictJournalPayload() async {
        let fake = NativeVolcFakeSecItems()
        let store = NativeVolcDebugCredentialStore(client: fake.client)
        let credentials = NativeVolcDebugCredentials(accessKey: "AKTEST", secretKey: "SKTEST")!
        let journal = NativeVolcPromotionJournal(
            identifier: "4A28DA80-5FA1-4E69-A58D-D2CF901D2F70",
            phase: .validated,
            candidateFingerprint: credentials.fingerprint,
            oldActive: nil,
            oldVerified: nil
        )!
        expect(await store.writeJournal(journal), "journal write readback")
        expect(await store.readJournal() == .found(journal), "journal exact round trip")

        var object = try! JSONSerialization.jsonObject(with: fake.stored(.transaction)!) as! [String: Any]
        object["unexpected"] = "value"
        fake.seed(try! JSONSerialization.data(withJSONObject: object), slot: .transaction)
        expect(await store.readJournal() == .invalid, "journal extra key rejected")

        let staged = NativeVolcPromotionJournal(
            identifier: "4A28DA80-5FA1-4E69-A58D-D2CF901D2F70",
            phase: .staged,
            candidateFingerprint: credentials.fingerprint,
            oldActive: nil,
            oldVerified: nil
        )!
        expect(await store.writeJournal(staged) == false, "unvalidated journal is never persisted")

        object.removeValue(forKey: "unexpected")
        object["oldActiveWasPresent"] = true
        object["oldActive"] = ["access_key": "AKTEST", "secret_key": "bad\nsecret"]
        fake.seed(try! JSONSerialization.data(withJSONObject: object), slot: .transaction)
        expect(await store.readJournal() == .invalid, "invalid nested backup is rejected")
    }
}
#endif
