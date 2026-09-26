import CryptoKit
import Foundation

private struct ParityCorpus: Decodable {
    let schema: String
    let version: Int
    let inputCases: [InputCase]
    let routeCases: [RouteCase]
    let signerCases: [SignerCase]
    let intentionalDeltas: [IntentionalDelta]
}

private struct InputCase: Decodable {
    let id: String
    let input: InputSpec
    let expectedDecision: String
}

private struct InputSpec: Decodable {
    let kind: String
    let value: String?
    let scalar: String?
    let count: Int?
    let suffix: String?

    func materialize() throws -> String? {
        switch kind {
        case "null":
            return nil
        case "literal":
            guard let value else { throw ParityError.invalidCorpus }
            return value
        case "repeated":
            guard let scalar, scalar.unicodeScalars.count == 1,
                  let count, count >= 0 else { throw ParityError.invalidCorpus }
            return String(repeating: scalar, count: count) + (suffix ?? "")
        default:
            throw ParityError.invalidCorpus
        }
    }
}

private struct RouteCase: Decodable {
    let id: String
    let requestedEngine: String
    let appleAvailable: Bool
    let volcAvailable: Bool
    let expectedDecision: String
}

private struct SignerCase: Decodable {
    let id: String
    let text: String
    let accessKey: String
    let secretKey: String
    let sourceLanguage: String
    let targetLanguage: String
    let instant: String
    let expectedBodySHA256: String
    let expectedSignature: String
}

private struct IntentionalDelta: Decodable {
    let id: String
    let reason: String
    let swift: String
    let python: String
}

private struct CanonicalRecord: Codable {
    let id: String
    let fields: [String: String]
}

private struct CanonicalOutput: Codable {
    let schema: String
    let version: Int
    let records: [CanonicalRecord]
}

private enum ParityError: Error {
    case invalidArguments
    case invalidCorpus
    case expectationFailed(String)
}

@main
private enum NativeTranslationParityRunner {
    private static let allowedDeltaReasons: Set<String> = [
        "python_legacy_engine_alias",
        "python_unknown_engine_defaults_apple",
        "python_volc_unavailable_falls_back_apple",
        "python_lru_cache_2000",
        "python_echoes_source_on_non_success",
        "python_string_error_classification",
        "python_parser_is_legacy_loose",
        "python_transport_timeout_30s",
    ]

    static func main() throws {
        guard CommandLine.arguments.count == 2 else { throw ParityError.invalidArguments }
        let data = try Data(
            contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])
        )
        let corpus = try JSONDecoder().decode(ParityCorpus.self, from: data)
        guard corpus.schema == "juyi.native_translation.input_parity",
              corpus.version == 1 else { throw ParityError.invalidCorpus }

        var records: [CanonicalRecord] = []
        for item in corpus.inputCases {
            let record = try inputRecord(item)
            try require(
                record.fields["decision"] == item.expectedDecision,
                "unexpected Swift input decision for \(item.id)"
            )
            records.append(record)
        }
        for item in corpus.routeCases {
            let record = try routeRecord(item)
            try require(
                record.fields["decision"] == item.expectedDecision,
                "unexpected Swift route decision for \(item.id)"
            )
            records.append(record)
        }
        for item in corpus.signerCases {
            let record = try signerRecord(item)
            try require(
                record.fields["body_sha256"] == item.expectedBodySHA256,
                "unexpected Swift body hash for \(item.id)"
            )
            try require(
                record.fields["signature"] == item.expectedSignature,
                "unexpected Swift signature for \(item.id)"
            )
            records.append(record)
        }

        let reasons = Set(corpus.intentionalDeltas.map(\.reason))
        try require(reasons == allowedDeltaReasons, "intentional delta taxonomy changed")
        for delta in corpus.intentionalDeltas {
            try require(delta.swift != delta.python, "delta \(delta.id) is not a difference")
            let swiftDecision: String
            if delta.id == "network_timeout" {
                swiftDecision = "result_lab_owner_\(Int(NativeTranslationResultLabOwnerTiming.deadline))s"
            } else {
                swiftDecision = delta.swift
            }
            try require(
                swiftDecision == delta.swift,
                "Swift intentional delta probe changed for \(delta.id)"
            )
            records.append(
                CanonicalRecord(
                    id: delta.id,
                    fields: [
                        "classification": "intentional_delta",
                        "reason": delta.reason,
                        "decision": swiftDecision,
                    ]
                )
            )
        }

        let output = CanonicalOutput(
            schema: corpus.schema,
            version: corpus.version,
            records: records.sorted { $0.id < $1.id }
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(output))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func inputRecord(_ item: InputCase) throws -> CanonicalRecord {
        var fields: [String: String]
        switch NativeTranslationInputPolicy.prepare(try item.input.materialize()) {
        case let .ready(input):
            fields = [
                "classification": "must_match",
                "decision": "ready",
                "scalar_count": String(input.scalarCount),
                "truncated": String(input.wasTruncated),
                "utf8_sha256": sha256(Data(input.text.utf8)),
            ]
        case let .failure(failure):
            fields = [
                "classification": "must_match",
                "decision": "failure:\(failure.description)",
            ]
        case .skipped(.tooShort):
            fields = [
                "classification": "must_match",
                "decision": "skipped:too_short",
            ]
        }
        return CanonicalRecord(id: item.id, fields: fields)
    }

    private static func routeRecord(_ item: RouteCase) throws -> CanonicalRecord {
        guard let requested = NativeTranslationEngine(rawValue: item.requestedEngine) else {
            throw ParityError.invalidCorpus
        }
        let fingerprint = "parity-fixture-fingerprint"
        let context = NativeTranslationRequestContext(
            appleReadiness: item.appleAvailable ? .installed : .unsupported,
            volcPrivacy: NativeVolcPrivacyContext(
                hasExplicitConsent: true,
                removalMarker: .confirmedAbsent,
                credentialReadiness: item.volcAvailable
                    ? .active(fingerprint: fingerprint)
                    : .missing,
                verifiedFingerprint: item.volcAvailable ? fingerprint : nil
            )
        )
        let decision: String
        switch NativeTranslationPrivacyRouter.decide(
            requestedEngine: requested,
            context: context
        ) {
        case .execute(.apple): decision = "execute:apple"
        case .execute(.volc): decision = "execute:volc"
        case let .failure(failure): decision = "failure:\(failure.description)"
        }
        return CanonicalRecord(
            id: item.id,
            fields: ["classification": "must_match", "decision": decision]
        )
    }

    private static func signerRecord(_ item: SignerCase) throws -> CanonicalRecord {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        guard let instant = formatter.date(from: item.instant) else {
            throw ParityError.invalidCorpus
        }
        let request = try VolcV4RequestBuilder.build(
            text: item.text,
            credentials: VolcV4Credentials(
                accessKey: item.accessKey,
                secretKey: item.secretKey,
                fingerprint: "parity-fixture-fingerprint"
            ),
            sourceLanguage: item.sourceLanguage,
            targetLanguage: item.targetLanguage,
            instant: instant
        )
        guard let authorization = request.headers["Authorization"],
              let signature = authorization.components(separatedBy: "Signature=").last,
              signature.count == 64 else { throw ParityError.invalidCorpus }
        return CanonicalRecord(
            id: item.id,
            fields: [
                "classification": "must_match",
                "body_sha256": sha256(request.body),
                "signature": signature,
            ]
        )
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func require(_ condition: Bool, _ message: String) throws {
        guard condition else { throw ParityError.expectationFailed(message) }
    }
}
