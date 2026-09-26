import Foundation

/// Pure protocol policy for transferring the double-Option owner from the
/// legacy Hammerspoon module to the native app. This file performs no I/O and
/// starts no monitor; the production activation layer must satisfy this policy while
/// holding its own cross-process native-owner lock.
enum NativeOwnerHandoffProtocol {
    static let version = 1
    static let maximumRequestBytes = 1_024
    static let maximumStatusBytes = 4_096
    static let maximumStatusAge: TimeInterval = 2.5
    static let maximumFutureClockSkew: TimeInterval = 1.0

    struct Request: Codable, Equatable, Sendable, CustomStringConvertible {
        let version: Int
        let requestedOwner: String
        let epoch: String
        let nativeInstanceID: String

        enum CodingKeys: String, CodingKey {
            case version
            case requestedOwner = "requested_owner"
            case epoch
            case nativeInstanceID = "native_instance_id"
        }

        fileprivate init(nativeInstanceID: UUID, epoch: UUID) {
            version = NativeOwnerHandoffProtocol.version
            requestedOwner = "native"
            self.epoch = epoch.uuidString.lowercased()
            self.nativeInstanceID = nativeInstanceID.uuidString.lowercased()
        }

        fileprivate init(
            version: Int,
            requestedOwner: String,
            epoch: String,
            nativeInstanceID: String
        ) {
            self.version = version
            self.requestedOwner = requestedOwner
            self.epoch = epoch
            self.nativeInstanceID = nativeInstanceID
        }

        var description: String {
            "NativeOwnerHandoffProtocol.Request(version: \(version), identifiers: [REDACTED])"
        }
    }

    struct LegacyStatus: Decodable, Equatable, Sendable {
        let moduleLoaded: Bool
        let watcherActive: Bool
        let activeRequest: Bool?
        let popupVisible: Bool?
        let ownerProtocolVersion: Int?
        let legacyInstanceID: String?
        let ownerState: String?
        let ownerRequestEpoch: String?
        let ownerRequestNativeInstanceID: String?
        let statusSequence: Int?
        let updatedAt: TimeInterval?

        enum CodingKeys: String, CodingKey {
            case moduleLoaded = "module_loaded"
            case watcherActive = "watcher_active"
            case activeRequest = "active_request"
            case popupVisible = "popup_visible"
            case ownerProtocolVersion = "owner_protocol_version"
            case legacyInstanceID = "legacy_instance_id"
            case ownerState = "owner_state"
            case ownerRequestEpoch = "owner_request_epoch"
            case ownerRequestNativeInstanceID = "owner_request_native_instance_id"
            case statusSequence = "status_sequence"
            case updatedAt = "updated_at"
        }
    }

    struct LegacyYieldLease: Equatable, Sendable {
        let epoch: UUID
        let nativeInstanceID: UUID
        let legacyInstanceID: UUID
        let statusSequence: Int
    }

    enum UnsafeReason: Equatable, Sendable {
        case requestInvalid
        case statusMissing
        case statusTooLarge
        case statusMalformed
        case protocolMismatch
        case moduleNotLoaded
        case acknowledgementMismatch
        case legacyInstanceInvalid
        case stateNotYielded
        case watcherStillActive
        case requestStillActive
        case popupStillVisible
        case sequenceInvalid
        case timestampInvalid
        case statusStale
    }

    enum Decision: Equatable, Sendable {
        case safeToClaim(LegacyYieldLease)
        case unsafe(UnsafeReason)
    }

    static func makeRequest(nativeInstanceID: UUID, epoch: UUID) -> Request {
        Request(nativeInstanceID: nativeInstanceID, epoch: epoch)
    }

    static func encodedRequest(_ request: Request) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(request)
        data.append(0x0A)
        return data
    }

    /// Decodes only the canonical four-key request emitted by
    /// `encodedRequest`. Alternate whitespace, unknown keys, malformed UUIDs,
    /// and non-native requests fail closed so a recovery path never adopts a
    /// capability that this process did not write.
    static func decodeCanonicalRequest(_ data: Data) -> Request? {
        guard !data.isEmpty,
              data.count <= maximumRequestBytes,
              data.last == 0x0A,
              let object = try? JSONSerialization.jsonObject(with: data),
              let dictionary = object as? [String: Any],
              Set(dictionary.keys) == Set([
                  "version",
                  "requested_owner",
                  "epoch",
                  "native_instance_id",
              ]),
              let version = dictionary["version"] as? Int,
              version == self.version,
              let owner = dictionary["requested_owner"] as? String,
              owner == "native",
              let epochText = dictionary["epoch"] as? String,
              let epoch = UUID(uuidString: epochText),
              let instanceText = dictionary["native_instance_id"] as? String,
              let instance = UUID(uuidString: instanceText)
        else { return nil }
        let request = Request(
            version: version,
            requestedOwner: owner,
            epoch: epoch.uuidString.lowercased(),
            nativeInstanceID: instance.uuidString.lowercased()
        )
        guard (try? encodedRequest(request)) == data else { return nil }
        return request
    }

    static func evaluate(
        request: Request,
        statusData: Data?,
        now: TimeInterval
    ) -> Decision {
        guard let statusData else { return .unsafe(.statusMissing) }
        guard statusData.count <= maximumStatusBytes else {
            return .unsafe(.statusTooLarge)
        }
        guard let status = try? JSONDecoder().decode(
            LegacyStatus.self,
            from: statusData
        ) else {
            return .unsafe(.statusMalformed)
        }
        return evaluate(request: request, status: status, now: now)
    }

    static func evaluate(
        request: Request,
        status: LegacyStatus,
        now: TimeInterval
    ) -> Decision {
        guard request.version == version,
              request.requestedOwner == "native",
              UUID(uuidString: request.epoch) != nil,
              UUID(uuidString: request.nativeInstanceID) != nil else {
            return .unsafe(.requestInvalid)
        }
        guard status.ownerProtocolVersion == version else {
            return .unsafe(.protocolMismatch)
        }
        guard status.moduleLoaded else { return .unsafe(.moduleNotLoaded) }
        guard status.ownerState == "yielded" else {
            return .unsafe(.stateNotYielded)
        }
        guard status.watcherActive == false else {
            return .unsafe(.watcherStillActive)
        }
        guard status.activeRequest == false else {
            return .unsafe(.requestStillActive)
        }
        guard status.popupVisible == false else {
            return .unsafe(.popupStillVisible)
        }
        guard let sequence = status.statusSequence, sequence > 0 else {
            return .unsafe(.sequenceInvalid)
        }
        guard let updatedAt = status.updatedAt,
              updatedAt.isFinite,
              now.isFinite else {
            return .unsafe(.timestampInvalid)
        }
        let age = now - updatedAt
        guard age >= -maximumFutureClockSkew,
              age <= maximumStatusAge else {
            return .unsafe(.statusStale)
        }

        guard let requestEpoch = UUID(uuidString: request.epoch),
              let requestNativeInstance = UUID(
                  uuidString: request.nativeInstanceID
              ),
              let acknowledgedEpoch = status.ownerRequestEpoch.flatMap(
                  UUID.init(uuidString:)
              ),
              let acknowledgedNativeInstance = status
                  .ownerRequestNativeInstanceID
                  .flatMap(UUID.init(uuidString:)),
              requestEpoch == acknowledgedEpoch,
              requestNativeInstance == acknowledgedNativeInstance else {
            return .unsafe(.acknowledgementMismatch)
        }
        guard let legacyInstance = status.legacyInstanceID.flatMap(
            UUID.init(uuidString:)
        ) else {
            return .unsafe(.legacyInstanceInvalid)
        }

        return .safeToClaim(
            LegacyYieldLease(
                epoch: requestEpoch,
                nativeInstanceID: requestNativeInstance,
                legacyInstanceID: legacyInstance,
                statusSequence: sequence
            )
        )
    }
}
