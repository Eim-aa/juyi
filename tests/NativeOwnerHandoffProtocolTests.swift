import Foundation

@main
enum NativeOwnerHandoffProtocolTests {
    private static var passed = 0
    private static let epoch = UUID(
        uuidString: "11111111-2222-3333-4444-555555555555"
    )!
    private static let nativeInstance = UUID(
        uuidString: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    )!
    private static let legacyInstance = UUID(
        uuidString: "99999999-8888-7777-6666-555555555555"
    )!
    private static let now: TimeInterval = 1_700_000_010

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String
    ) {
        precondition(condition(), message)
        passed += 1
    }

    private static func statusJSON(
        protocolVersion: Int? = 1,
        moduleLoaded: Bool = true,
        ownerState: String? = "yielded",
        watcherActive: Bool = false,
        activeRequest: Bool? = false,
        popupVisible: Bool? = false,
        acknowledgedEpoch: String? = epoch.uuidString.lowercased(),
        acknowledgedNativeInstance: String? = nativeInstance.uuidString.lowercased(),
        legacyInstanceID: String? = legacyInstance.uuidString.lowercased(),
        sequence: Int? = 7,
        updatedAt: TimeInterval? = now - 1
    ) -> Data {
        var value: [String: Any] = [
            "module_loaded": moduleLoaded,
            "watcher_active": watcherActive,
        ]
        value["active_request"] = activeRequest
        value["popup_visible"] = popupVisible
        value["owner_protocol_version"] = protocolVersion
        value["legacy_instance_id"] = legacyInstanceID
        value["owner_state"] = ownerState
        value["owner_request_epoch"] = acknowledgedEpoch
        value["owner_request_native_instance_id"] = acknowledgedNativeInstance
        value["status_sequence"] = sequence
        value["updated_at"] = updatedAt
        return try! JSONSerialization.data(
            withJSONObject: value,
            options: [.sortedKeys]
        )
    }

    private static var request: NativeOwnerHandoffProtocol.Request {
        NativeOwnerHandoffProtocol.makeRequest(
            nativeInstanceID: nativeInstance,
            epoch: epoch
        )
    }

    private static func testDeterministicRequest() {
        let data = try! NativeOwnerHandoffProtocol.encodedRequest(request)
        let text = String(decoding: data, as: UTF8.self)
        expect(text.hasSuffix("\n"), "request must end in one newline")
        expect(text.contains("\"version\":1"), "request version missing")
        expect(text.contains("\"requested_owner\":\"native\""), "owner missing")
        expect(text.contains(epoch.uuidString.lowercased()), "epoch missing")
        expect(text.contains(nativeInstance.uuidString.lowercased()), "instance missing")
        expect(!request.description.contains(request.epoch), "description leaked epoch")
    }

    private static func testExactSafeAcknowledgement() {
        let decision = NativeOwnerHandoffProtocol.evaluate(
            request: request,
            statusData: statusJSON(),
            now: now
        )
        guard case let .safeToClaim(lease) = decision else {
            preconditionFailure("valid acknowledgement was rejected: \(decision)")
        }
        expect(lease.epoch == epoch, "lease epoch mismatch")
        expect(lease.nativeInstanceID == nativeInstance, "native instance mismatch")
        expect(lease.legacyInstanceID == legacyInstance, "legacy instance mismatch")
        expect(lease.statusSequence == 7, "sequence mismatch")
    }

    private static func expectUnsafe(
        _ reason: NativeOwnerHandoffProtocol.UnsafeReason,
        data: Data?,
        now customNow: TimeInterval = now,
        _ message: String
    ) {
        expect(
            NativeOwnerHandoffProtocol.evaluate(
                request: request,
                statusData: data,
                now: customNow
            ) == .unsafe(reason),
            message
        )
    }

    private static func testEnvelopeFailures() {
        let invalidRequestData = Data(
            "{\"epoch\":\"bad\",\"native_instance_id\":\"bad\",\"requested_owner\":\"legacy\",\"version\":2}"
                .utf8
        )
        let invalidRequest = try! JSONDecoder().decode(
            NativeOwnerHandoffProtocol.Request.self,
            from: invalidRequestData
        )
        expect(
            NativeOwnerHandoffProtocol.evaluate(
                request: invalidRequest,
                statusData: statusJSON(),
                now: now
            ) == .unsafe(.requestInvalid),
            "invalid request capability accepted"
        )
        expectUnsafe(.statusMissing, data: nil, "missing status accepted")
        expectUnsafe(.statusMalformed, data: Data("[]".utf8), "array accepted")
        expectUnsafe(
            .statusTooLarge,
            data: Data(repeating: 0x20, count: 4_097),
            "oversized status accepted"
        )
        expectUnsafe(
            .protocolMismatch,
            data: statusJSON(protocolVersion: 2),
            "new protocol accepted"
        )
        expectUnsafe(
            .moduleNotLoaded,
            data: statusJSON(moduleLoaded: false),
            "unloaded module accepted"
        )
    }

    private static func testEveryLegacyEffectMustBeAbsent() {
        expectUnsafe(
            .stateNotYielded,
            data: statusJSON(ownerState: "legacy_active"),
            "active owner accepted"
        )
        expectUnsafe(
            .watcherStillActive,
            data: statusJSON(watcherActive: true),
            "watcher accepted"
        )
        expectUnsafe(
            .requestStillActive,
            data: statusJSON(activeRequest: true),
            "request accepted"
        )
        expectUnsafe(
            .requestStillActive,
            data: statusJSON(activeRequest: nil),
            "missing request state accepted"
        )
        expectUnsafe(
            .popupStillVisible,
            data: statusJSON(popupVisible: true),
            "popup accepted"
        )
        expectUnsafe(
            .popupStillVisible,
            data: statusJSON(popupVisible: nil),
            "missing popup state accepted"
        )
    }

    private static func testIdentityAndSequenceAreBound() {
        expectUnsafe(
            .acknowledgementMismatch,
            data: statusJSON(acknowledgedEpoch: UUID().uuidString),
            "wrong epoch accepted"
        )
        expectUnsafe(
            .acknowledgementMismatch,
            data: statusJSON(acknowledgedNativeInstance: UUID().uuidString),
            "wrong native instance accepted"
        )
        expectUnsafe(
            .legacyInstanceInvalid,
            data: statusJSON(legacyInstanceID: "not-a-uuid"),
            "invalid legacy instance accepted"
        )
        expectUnsafe(
            .sequenceInvalid,
            data: statusJSON(sequence: 0),
            "zero sequence accepted"
        )
        expectUnsafe(
            .sequenceInvalid,
            data: statusJSON(sequence: nil),
            "missing sequence accepted"
        )
    }

    private static func testFreshnessIsFailClosed() {
        expectUnsafe(
            .statusStale,
            data: statusJSON(updatedAt: now - 2.5001),
            "stale status accepted"
        )
        expectUnsafe(
            .statusStale,
            data: statusJSON(updatedAt: now + 1.0001),
            "far-future status accepted"
        )
        expectUnsafe(
            .timestampInvalid,
            data: statusJSON(updatedAt: nil),
            "missing timestamp accepted"
        )
        expect(
            {
                guard case .safeToClaim = NativeOwnerHandoffProtocol.evaluate(
                    request: request,
                    statusData: statusJSON(updatedAt: now - 2.5),
                    now: now
                ) else { return false }
                return true
            }(),
            "freshness boundary rejected"
        )
    }

    static func main() {
        testDeterministicRequest()
        testExactSafeAcknowledgement()
        testEnvelopeFailures()
        testEveryLegacyEffectMustBeAbsent()
        testIdentityAndSequenceAreBound()
        testFreshnessIsFailClosed()
        print("NativeOwnerHandoffProtocolTests: \(passed) passed")
    }
}
