#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN && JUYI_NATIVE_VOLC_TRANSLATION_ADAPTER
import CryptoKit
import Foundation
import LocalAuthentication
import Security

enum NativeVolcDebugProfile {
    static let identifier = "translate-2020-06-01-cn-north-1-en-zh-v1"
}

enum NativeVolcDebugKeychainSlot: CaseIterable, Equatable, Sendable {
    case active
    case pending
    case verified
    case transaction

    var service: String {
        switch self {
        case .active: return "io.github.Eim-aa.Juyi.debug.native-volc.active"
        case .pending: return "io.github.Eim-aa.Juyi.debug.native-volc.pending"
        case .verified: return "io.github.Eim-aa.Juyi.debug.native-volc.verified"
        case .transaction: return "io.github.Eim-aa.Juyi.debug.native-volc.transaction"
        }
    }

    var account: String {
        switch self {
        case .active: return "active"
        case .pending: return "pending"
        case .verified: return "verified"
        case .transaction: return "promotion"
        }
    }
}

struct NativeVolcDebugCredentials: Codable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    let accessKey: String
    let secretKey: String

    enum CodingKeys: String, CodingKey {
        case accessKey = "access_key"
        case secretKey = "secret_key"
    }

    init?(accessKey: String, secretKey: String) {
        guard VolcV4RequestBuilder.credentialsAreValid(
            accessKey: accessKey,
            secretKey: secretKey
        ) else { return nil }
        self.accessKey = accessKey
        self.secretKey = secretKey
    }

    var fingerprint: String {
        var material = Data(accessKey.utf8)
        material.append(0)
        material.append(contentsOf: secretKey.utf8)
        return VolcV4RequestBuilder.sha256Hex(material)
    }

    var v4Credentials: VolcV4Credentials {
        VolcV4Credentials(
            accessKey: accessKey,
            secretKey: secretKey,
            fingerprint: fingerprint
        )
    }

    var description: String { "NativeVolcDebugCredentials([REDACTED])" }
    var debugDescription: String { description }
}

struct NativeVolcDebugVerifiedRecord: Codable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    let version: Int
    let fingerprint: String
    let profile: String

    init?(fingerprint: String, profile: String = NativeVolcDebugProfile.identifier) {
        guard Self.validFingerprint(fingerprint), profile == NativeVolcDebugProfile.identifier else {
            return nil
        }
        version = 1
        self.fingerprint = fingerprint
        self.profile = profile
    }

    var description: String { "NativeVolcDebugVerifiedRecord([REDACTED])" }
    var debugDescription: String { description }

    static func validFingerprint(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy {
            (0x30...0x39).contains($0) || (0x61...0x66).contains($0)
        }
    }
}

enum NativeVolcPromotionPhase: String, Codable, Equatable, Sendable {
    case staged
    case validated
    case activeWritten = "active_written"
    case verifiedWritten = "verified_written"
    case rollbackRequested = "rollback_requested"
    case rollbackActiveRestored = "rollback_active_restored"
    case rollbackVerifiedRestored = "rollback_verified_restored"
    case rollbackPendingRemoved = "rollback_pending_removed"
}

struct NativeVolcPromotionJournal: Codable, Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    let version: Int
    let identifier: String
    let phase: NativeVolcPromotionPhase
    let candidateFingerprint: String
    let oldActiveWasPresent: Bool
    let oldActive: NativeVolcDebugCredentials?
    let oldVerifiedWasPresent: Bool
    let oldVerified: NativeVolcDebugVerifiedRecord?

    init?(
        identifier: String,
        phase: NativeVolcPromotionPhase,
        candidateFingerprint: String,
        oldActive: NativeVolcDebugCredentials?,
        oldVerified: NativeVolcDebugVerifiedRecord?
    ) {
        guard UUID(uuidString: identifier) != nil,
              NativeVolcDebugVerifiedRecord.validFingerprint(candidateFingerprint)
        else { return nil }
        version = 1
        self.identifier = identifier
        self.phase = phase
        self.candidateFingerprint = candidateFingerprint
        oldActiveWasPresent = oldActive != nil
        self.oldActive = oldActive
        oldVerifiedWasPresent = oldVerified != nil
        self.oldVerified = oldVerified
    }

    func advancing(to phase: NativeVolcPromotionPhase) -> Self? {
        let allowed: Bool
        switch (self.phase, phase) {
        case (.staged, .validated),
             (.validated, .activeWritten),
             (.activeWritten, .verifiedWritten):
            allowed = true
        default:
            allowed = false
        }
        guard allowed else { return nil }
        return Self(
            identifier: identifier,
            phase: phase,
            candidateFingerprint: candidateFingerprint,
            oldActive: oldActive,
            oldVerified: oldVerified
        )
    }

    func beginningRollback() -> Self? {
        switch phase {
        case .validated, .activeWritten, .verifiedWritten:
            return replacingPhase(with: .rollbackRequested)
        case .rollbackRequested, .rollbackActiveRestored,
             .rollbackVerifiedRestored, .rollbackPendingRemoved:
            return self
        case .staged:
            return nil
        }
    }

    func advancingRollback(to phase: NativeVolcPromotionPhase) -> Self? {
        let allowed: Bool
        switch (self.phase, phase) {
        case (.rollbackRequested, .rollbackActiveRestored),
             (.rollbackActiveRestored, .rollbackVerifiedRestored),
             (.rollbackVerifiedRestored, .rollbackPendingRemoved):
            allowed = true
        default:
            allowed = false
        }
        return allowed ? replacingPhase(with: phase) : nil
    }

    var isRollingBack: Bool {
        switch phase {
        case .rollbackRequested, .rollbackActiveRestored,
             .rollbackVerifiedRestored, .rollbackPendingRemoved:
            return true
        case .staged, .validated, .activeWritten, .verifiedWritten:
            return false
        }
    }

    private func replacingPhase(with phase: NativeVolcPromotionPhase) -> Self? {
        Self(
            identifier: identifier,
            phase: phase,
            candidateFingerprint: candidateFingerprint,
            oldActive: oldActive,
            oldVerified: oldVerified
        )
    }

    var description: String {
        "NativeVolcPromotionJournal(phase: \(phase.rawValue), [REDACTED])"
    }
    var debugDescription: String { description }
}

enum NativeVolcDebugItemRead<Value: Equatable & Sendable>: Equatable, Sendable,
    CustomStringConvertible, CustomDebugStringConvertible
{
    case found(Value)
    case notFound
    case invalid
    case unavailable

    var description: String {
        switch self {
        case .found: return "found([REDACTED])"
        case .notFound: return "not_found"
        case .invalid: return "invalid"
        case .unavailable: return "unavailable"
        }
    }
    var debugDescription: String { description }
}

enum NativeVolcRawItemRead: Equatable, Sendable {
    case found(Data)
    case notFound
    case unavailable
}

struct NativeVolcSecItemClient: Sendable {
    let read: @Sendable (String, String) -> NativeVolcRawItemRead
    let write: @Sendable (String, String, Data) -> Bool
    let delete: @Sendable (String, String) -> Bool

    static let live = NativeVolcSecItemClient(
        read: { service, account in
            NativeVolcSecurityClient.read(service: service, account: account)
        },
        write: { service, account, data in
            NativeVolcSecurityClient.write(service: service, account: account, data: data)
        },
        delete: { service, account in
            NativeVolcSecurityClient.delete(service: service, account: account)
        }
    )
}

enum NativeVolcSecurityClient {
    private static let maximumItemBytes = 4_096

    static func read(service: String, account: String) -> NativeVolcRawItemRead {
        var query = baseQuery(service: service, account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return .notFound }
        guard status == errSecSuccess else { return .unavailable }

        let values: [Data]
        if let array = result as? [Data] {
            values = array
        } else if let value = result as? Data {
            values = [value]
        } else {
            return .unavailable
        }
        guard values.count == 1, values[0].count <= maximumItemBytes else {
            return .unavailable
        }
        return .found(values[0])
    }

    static func write(service: String, account: String, data: Data) -> Bool {
        guard data.count <= maximumItemBytes else { return false }
        let query = baseQuery(service: service, account: account)
        let update = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if updateStatus == errSecSuccess { return true }
        guard updateStatus == errSecItemNotFound else { return false }

        var attributes = query
        attributes[kSecValueData as String] = data
        let addStatus = SecItemAdd(attributes as CFDictionary, nil)
        if addStatus == errSecSuccess { return true }
        if addStatus == errSecDuplicateItem {
            return SecItemUpdate(query as CFDictionary, update as CFDictionary) == errSecSuccess
        }
        return false
    }

    static func delete(service: String, account: String) -> Bool {
        let status = SecItemDelete(baseQuery(service: service, account: account) as CFDictionary)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    static func baseQuery(service: String, account: String) -> [String: Any] {
        let authenticationContext = LAContext()
        authenticationContext.interactionNotAllowed = true
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrSynchronizable as String: false,
            // `kSecUseAuthenticationUIFail` is the legacy-keychain fail-without-UI
            // policy. Its Swift declaration is deprecated (the suggested LAContext
            // replacement only suppresses UI for Data Protection items on macOS),
            // so use the Security.framework CFString value without referencing the
            // deprecated declaration. Keep this paired with the LAContext defense.
            kSecUseAuthenticationUI as String: "u_AuthUIF",
            kSecUseAuthenticationContext as String: authenticationContext,
        ]
    }
}

actor NativeVolcDebugCredentialStore {
    private static let maximumDecodedBytes = 4_096
    private let client: NativeVolcSecItemClient

    init(client: NativeVolcSecItemClient = .live) {
        self.client = client
    }

    func readCredentials(
        _ slot: NativeVolcDebugKeychainSlot
    ) -> NativeVolcDebugItemRead<NativeVolcDebugCredentials> {
        guard slot == .active || slot == .pending else { return .invalid }
        return decodeCredentials(readRaw(slot))
    }

    func readVerified() -> NativeVolcDebugItemRead<NativeVolcDebugVerifiedRecord> {
        decodeVerified(readRaw(.verified))
    }

    func readJournal() -> NativeVolcDebugItemRead<NativeVolcPromotionJournal> {
        decodeJournal(readRaw(.transaction))
    }

    func writeCredentials(
        _ credentials: NativeVolcDebugCredentials,
        to slot: NativeVolcDebugKeychainSlot
    ) -> Bool {
        guard slot == .active || slot == .pending,
              let data = try? JSONEncoder().encode(credentials),
              client.write(slot.service, slot.account, data)
        else { return false }
        return readCredentials(slot) == .found(credentials)
    }

    func writeVerified(_ record: NativeVolcDebugVerifiedRecord) -> Bool {
        guard let data = try? JSONEncoder().encode(record),
              client.write(
                  NativeVolcDebugKeychainSlot.verified.service,
                  NativeVolcDebugKeychainSlot.verified.account,
                  data
              )
        else { return false }
        return readVerified() == .found(record)
    }

    func writeJournal(_ journal: NativeVolcPromotionJournal) -> Bool {
        guard journal.phase != .staged,
              let data = try? JSONEncoder().encode(journal),
              client.write(
                  NativeVolcDebugKeychainSlot.transaction.service,
                  NativeVolcDebugKeychainSlot.transaction.account,
                  data
              )
        else { return false }
        return readJournal() == .found(journal)
    }

    func delete(_ slot: NativeVolcDebugKeychainSlot) -> Bool {
        guard client.delete(slot.service, slot.account) else { return false }
        if case .notFound = readRaw(slot) { return true }
        return false
    }

    private func readRaw(_ slot: NativeVolcDebugKeychainSlot) -> NativeVolcRawItemRead {
        client.read(slot.service, slot.account)
    }

    private func decodeCredentials(
        _ raw: NativeVolcRawItemRead
    ) -> NativeVolcDebugItemRead<NativeVolcDebugCredentials> {
        switch raw {
        case .notFound: return .notFound
        case .unavailable: return .unavailable
        case let .found(data):
            guard validObjectKeys(data, expected: ["access_key", "secret_key"]),
                  let decoded = try? JSONDecoder().decode(
                      NativeVolcDebugCredentials.self,
                      from: data
                  ),
                  let validated = NativeVolcDebugCredentials(
                      accessKey: decoded.accessKey,
                      secretKey: decoded.secretKey
                  )
            else { return .invalid }
            return .found(validated)
        }
    }

    private func decodeVerified(
        _ raw: NativeVolcRawItemRead
    ) -> NativeVolcDebugItemRead<NativeVolcDebugVerifiedRecord> {
        switch raw {
        case .notFound: return .notFound
        case .unavailable: return .unavailable
        case let .found(data):
            guard validObjectKeys(data, expected: ["version", "fingerprint", "profile"]),
                  let decoded = try? JSONDecoder().decode(
                      NativeVolcDebugVerifiedRecord.self,
                      from: data
                  ),
                  decoded.version == 1,
                  let validated = NativeVolcDebugVerifiedRecord(
                      fingerprint: decoded.fingerprint,
                      profile: decoded.profile
                  )
            else { return .invalid }
            return .found(validated)
        }
    }

    private func decodeJournal(
        _ raw: NativeVolcRawItemRead
    ) -> NativeVolcDebugItemRead<NativeVolcPromotionJournal> {
        switch raw {
        case .notFound: return .notFound
        case .unavailable: return .unavailable
        case let .found(data):
            guard validJournalObjectKeys(data),
                  let decoded = try? JSONDecoder().decode(
                      NativeVolcPromotionJournal.self,
                      from: data
                  ),
                  decoded.version == 1,
                  decoded.oldActiveWasPresent == (decoded.oldActive != nil),
                  decoded.oldVerifiedWasPresent == (decoded.oldVerified != nil),
                  decoded.phase != .staged,
                  let validatedOldActive = validatedCredentials(decoded.oldActive),
                  let validatedOldVerified = validatedVerified(decoded.oldVerified),
                  let validated = NativeVolcPromotionJournal(
                      identifier: decoded.identifier,
                      phase: decoded.phase,
                      candidateFingerprint: decoded.candidateFingerprint,
                      oldActive: validatedOldActive,
                      oldVerified: validatedOldVerified
                  )
            else { return .invalid }
            return .found(validated)
        }
    }

    private func validObjectKeys(_ data: Data, expected: Set<String>) -> Bool {
        guard data.count <= Self.maximumDecodedBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else { return false }
        return Set(dictionary.keys) == expected
    }

    private func validJournalObjectKeys(_ data: Data) -> Bool {
        guard data.count <= Self.maximumDecodedBytes,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any]
        else { return false }
        let required: Set<String> = [
            "version", "identifier", "phase", "candidateFingerprint",
            "oldActiveWasPresent", "oldVerifiedWasPresent",
        ]
        let permitted = required.union(["oldActive", "oldVerified"])
        let keys = Set(dictionary.keys)
        guard required.isSubset(of: keys), keys.isSubset(of: permitted) else { return false }
        if let active = dictionary["oldActive"] as? [String: Any],
           Set(active.keys) != ["access_key", "secret_key"]
        { return false }
        if dictionary["oldActive"] != nil && !(dictionary["oldActive"] is [String: Any]) {
            return false
        }
        if let verified = dictionary["oldVerified"] as? [String: Any],
           Set(verified.keys) != ["version", "fingerprint", "profile"]
        { return false }
        if dictionary["oldVerified"] != nil && !(dictionary["oldVerified"] is [String: Any]) {
            return false
        }
        return true
    }

    private func validatedCredentials(
        _ value: NativeVolcDebugCredentials?
    ) -> NativeVolcDebugCredentials?? {
        guard let value else { return .some(nil) }
        guard let validated = NativeVolcDebugCredentials(
            accessKey: value.accessKey,
            secretKey: value.secretKey
        ) else { return nil }
        return .some(validated)
    }

    private func validatedVerified(
        _ value: NativeVolcDebugVerifiedRecord?
    ) -> NativeVolcDebugVerifiedRecord?? {
        guard let value else { return .some(nil) }
        guard value.version == 1,
              let validated = NativeVolcDebugVerifiedRecord(
                  fingerprint: value.fingerprint,
                  profile: value.profile
              )
        else { return nil }
        return .some(validated)
    }
}
#endif
