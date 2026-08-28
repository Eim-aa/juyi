#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN
import Foundation

public let nativeTranslationDomainBuildSentinel =
    "juyi-native-translation-domain-v1|VolcV4RequestBuilder|VolcTranslationResponseParser|translate.volcengineapi.com"

enum NativeTranslationEngine: String, Equatable, Sendable {
    case apple
    case volc
}

struct NativeTranslationLanguagePair: Equatable, Sendable {
    let source = "en"
    let target = "zh"
}

struct NativeTranslationInput: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    let text: String
    let wasTruncated: Bool
    let scalarCount: Int
    let languages = NativeTranslationLanguagePair()

    var description: String {
        "NativeTranslationInput(scalars: \(scalarCount), truncated: \(wasTruncated))"
    }

    var debugDescription: String { description }
}

enum NativeTranslationInputDecision: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    case ready(NativeTranslationInput)
    case failure(NativeTranslationFailure)
    case skipped(NativeTranslationSkipReason)

    var description: String {
        switch self {
        case let .ready(input): return "ready(\(input.description))"
        case let .failure(failure): return "failure(\(failure.description))"
        case .skipped(.tooShort): return "skipped(too_short)"
        }
    }

    var debugDescription: String { description }
}

enum NativeTranslationSkipReason: Equatable, Sendable {
    case tooShort
}

enum NativeTranslationInputPolicy {
    static let scalarLimit = 5_000

    static func prepare(_ rawText: String?) -> NativeTranslationInputDecision {
        let lineNormalized = (rawText ?? "")
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let trimmed = trimScalarWhitespace(lineNormalized)

        guard !trimmed.isEmpty else {
            return .failure(.emptyInput)
        }

        let allScalars = trimmed.unicodeScalars
        let wasTruncated = allScalars.count > scalarLimit
        let limited = String(allScalars.prefix(scalarLimit))
        let limitedScalars = limited.unicodeScalars

        if cjkRatio(limited) > 0.5 {
            return .failure(.sourceLanguageMismatch)
        }

        let alphabeticCount = alphabeticScalarCount(limited)
        guard alphabeticCount >= 2 else {
            return .skipped(.tooShort)
        }

        return .ready(
            NativeTranslationInput(
                text: limited,
                wasTruncated: wasTruncated,
                scalarCount: limitedScalars.count
            )
        )
    }

    private static func trimScalarWhitespace(_ text: String) -> String {
        let scalars = text.unicodeScalars
        guard var lower = scalars.indices.first else { return "" }
        var upper = scalars.endIndex

        while lower != upper, scalars[lower].properties.isWhitespace {
            scalars.formIndex(after: &lower)
        }
        while lower != upper {
            let candidate = scalars.index(before: upper)
            guard scalars[candidate].properties.isWhitespace else { break }
            upper = candidate
        }
        return String(scalars[lower..<upper])
    }

    static func cjkRatio(_ text: String) -> Double {
        var nonWhitespaceCount = 0
        var cjkCount = 0
        for scalar in text.unicodeScalars where !scalar.properties.isWhitespace {
            nonWhitespaceCount += 1
            if isCJKPolicyScalar(scalar.value) {
                cjkCount += 1
            }
        }
        guard nonWhitespaceCount > 0 else { return 0 }
        return Double(cjkCount) / Double(nonWhitespaceCount)
    }

    static func alphabeticScalarCount(_ text: String) -> Int {
        text.unicodeScalars.reduce(into: 0) { count, scalar in
            if scalar.properties.isAlphabetic {
                count += 1
            }
        }
    }

    private static func isCJKPolicyScalar(_ value: UInt32) -> Bool {
        (0x4E00...0x9FFF).contains(value)
            || (0x3000...0x303F).contains(value)
            || (0xFF00...0xFFEF).contains(value)
    }
}

enum NativeAppleTranslationReadiness: Equatable, Sendable {
    case installed
    case supportedNeedsPreparation
    case unsupported
    case temporarilyUnavailable
}

enum NativeVolcRemovalMarkerState: Equatable, Sendable {
    case confirmedAbsent
    case present
    case unavailable
}

enum NativeVolcCredentialReadiness: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    case missing
    case pendingOnly
    case active(fingerprint: String)

    var description: String {
        switch self {
        case .missing: return "missing"
        case .pendingOnly: return "pending_only"
        case .active: return "active([REDACTED])"
        }
    }

    var debugDescription: String { description }
}

struct NativeVolcPrivacyContext: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    let hasExplicitConsent: Bool
    let removalMarker: NativeVolcRemovalMarkerState
    let credentialReadiness: NativeVolcCredentialReadiness
    let verifiedFingerprint: String?

    var description: String { "NativeVolcPrivacyContext([REDACTED])" }
    var debugDescription: String { description }
}

struct NativeTranslationRequestContext: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    let appleReadiness: NativeAppleTranslationReadiness
    let volcPrivacy: NativeVolcPrivacyContext

    var description: String {
        "NativeTranslationRequestContext(appleReadiness: \(appleReadiness), volcPrivacy: [REDACTED])"
    }

    var debugDescription: String { description }
}

enum NativeTranslationRoute: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    case apple
    case volc(expectedFingerprint: String)

    var description: String {
        switch self {
        case .apple: return "apple"
        case .volc: return "volc([REDACTED])"
        }
    }

    var debugDescription: String { description }
}

enum NativeTranslationRouteDecision: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    case execute(NativeTranslationRoute)
    case failure(NativeTranslationFailure)

    var description: String {
        switch self {
        case let .execute(route): return "execute(\(route.description))"
        case let .failure(failure): return "failure(\(failure.description))"
        }
    }

    var debugDescription: String { description }
}

enum NativeTranslationPrivacyRouter {
    static func decide(
        requestedEngine: NativeTranslationEngine,
        context: NativeTranslationRequestContext
    ) -> NativeTranslationRouteDecision {
        switch requestedEngine {
        case .apple:
            switch context.appleReadiness {
            case .installed:
                return .execute(.apple)
            case .supportedNeedsPreparation:
                return .failure(.appleNeedsPreparation)
            case .unsupported:
                return .failure(.appleUnsupported)
            case .temporarilyUnavailable:
                return .failure(.appleTemporarilyUnavailable)
            }

        case .volc:
            guard context.volcPrivacy.hasExplicitConsent else {
                return .failure(.cloudConsentRequired)
            }
            switch context.volcPrivacy.removalMarker {
            case .confirmedAbsent:
                break
            case .present:
                return .failure(.cloudRemovalPresent)
            case .unavailable:
                return .failure(.cloudRemovalStateUnavailable)
            }

            switch context.volcPrivacy.credentialReadiness {
            case .missing:
                return .failure(.cloudCredentialsMissing)
            case .pendingOnly:
                return .failure(.cloudCredentialsPending)
            case let .active(fingerprint):
                guard !fingerprint.isEmpty,
                      let verified = context.volcPrivacy.verifiedFingerprint,
                      !verified.isEmpty,
                      fingerprint == verified
                else {
                    return .failure(.cloudCredentialUnverified)
                }
                return .execute(.volc(expectedFingerprint: fingerprint))
            }
        }
    }
}

enum NativeTranslationFailure: Error, Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    case emptyInput
    case sourceLanguageMismatch
    case appleNeedsPreparation
    case appleUnsupported
    case appleTemporarilyUnavailable
    case appleExecutionFailed
    case cloudConsentRequired
    case cloudRemovalPresent
    case cloudRemovalStateUnavailable
    case cloudCredentialsMissing
    case cloudCredentialsPending
    case cloudCredentialUnverified
    case cloudCredentialSnapshotMismatch
    case volcCredential
    case volcNetwork
    case volcTransportSecurity
    case volcTimeout
    case volcQuota
    case volcService
    case volcHTTP
    case volcMalformedResponse

    var description: String {
        switch self {
        case .emptyInput: return "empty_input"
        case .sourceLanguageMismatch: return "source_language_mismatch"
        case .appleNeedsPreparation: return "apple_needs_preparation"
        case .appleUnsupported: return "apple_unsupported"
        case .appleTemporarilyUnavailable: return "apple_temporarily_unavailable"
        case .appleExecutionFailed: return "apple_execution_failed"
        case .cloudConsentRequired: return "cloud_consent_required"
        case .cloudRemovalPresent: return "cloud_removal_present"
        case .cloudRemovalStateUnavailable: return "cloud_removal_state_unavailable"
        case .cloudCredentialsMissing: return "cloud_credentials_missing"
        case .cloudCredentialsPending: return "cloud_credentials_pending"
        case .cloudCredentialUnverified: return "cloud_credential_unverified"
        case .cloudCredentialSnapshotMismatch: return "cloud_credential_snapshot_mismatch"
        case .volcCredential: return "volc_credential"
        case .volcNetwork: return "volc_network"
        case .volcTransportSecurity: return "volc_transport_security"
        case .volcTimeout: return "volc_timeout"
        case .volcQuota: return "volc_quota"
        case .volcService: return "volc_service"
        case .volcHTTP: return "volc_http"
        case .volcMalformedResponse: return "volc_malformed_response"
        }
    }

    var debugDescription: String { description }
}

struct NativeTranslationSuccess: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    let engine: NativeTranslationEngine
    let text: String
    let inputWasTruncated: Bool

    var description: String {
        "NativeTranslationSuccess(engine: \(engine.rawValue), truncated: \(inputWasTruncated))"
    }

    var debugDescription: String { description }
}

enum NativeTranslationOutcome: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    case success(NativeTranslationSuccess)
    case failure(NativeTranslationFailure)
    case skipped(NativeTranslationSkipReason)
    case cancelled

    var description: String {
        switch self {
        case let .success(success): return "success(\(success.description))"
        case let .failure(failure): return "failure(\(failure.description))"
        case .skipped(.tooShort): return "skipped(too_short)"
        case .cancelled: return "cancelled"
        }
    }

    var debugDescription: String { description }
}

enum NativeTranslationEffectResult: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    case success(text: String)
    case failure(NativeTranslationFailure)
    case cancelled

    var description: String {
        switch self {
        case .success: return "success([REDACTED])"
        case let .failure(failure): return "failure(\(failure.description))"
        case .cancelled: return "cancelled"
        }
    }

    var debugDescription: String { description }
}

struct NativeTranslationEffectRequest: Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    let engine: NativeTranslationEngine
    let input: NativeTranslationInput
    let volcCredentials: VolcV4Credentials?

    var description: String {
        "NativeTranslationEffectRequest(engine: \(engine.rawValue), scalars: \(input.scalarCount), credentials: [REDACTED])"
    }

    var debugDescription: String { description }
}

struct NativeTranslationExecutor: Sendable {
    let run: @Sendable (NativeTranslationEffectRequest) async -> NativeTranslationEffectResult

    func execute(_ request: NativeTranslationEffectRequest) async -> NativeTranslationEffectResult {
        await run(request)
    }
}

enum NativeTranslationInvalidationReason: Equatable, Sendable {
    case newRequest
    case pause
    case stop
    case accessibilityRevoked
    case engineChanged
    case credentialsChanged
    case removalStateChanged
    case ownerChanged
}

actor NativeTranslationDomainCoordinator {
    typealias CredentialLoader = @Sendable (String) -> VolcV4Credentials?
    typealias Publisher = @Sendable (UInt64, NativeTranslationOutcome) -> Void

    private let credentialLoader: CredentialLoader
    private let executor: NativeTranslationExecutor
    private let publisher: Publisher

    private var generation: UInt64 = 0
    private var activeTask: Task<Void, Never>?
    private var retainedInput: NativeTranslationInput?

    init(
        credentialLoader: @escaping CredentialLoader,
        executor: NativeTranslationExecutor,
        publisher: @escaping Publisher
    ) {
        self.credentialLoader = credentialLoader
        self.executor = executor
        self.publisher = publisher
    }

    @discardableResult
    func begin(
        sourceText: String?,
        requestedEngine: NativeTranslationEngine,
        context: NativeTranslationRequestContext
    ) -> UInt64 {
        invalidateCurrent(reason: .newRequest)
        let requestGeneration = generation

        activeTask = Task { [weak self] in
            await self?.run(
                generation: requestGeneration,
                sourceText: sourceText,
                requestedEngine: requestedEngine,
                context: context
            )
        }
        return requestGeneration
    }

    func invalidate(_ reason: NativeTranslationInvalidationReason) {
        invalidateCurrent(reason: reason)
    }

    func currentGeneration() -> UInt64 { generation }

    func hasRetainedInput() -> Bool { retainedInput != nil }

    private func invalidateCurrent(reason _: NativeTranslationInvalidationReason) {
        generation &+= 1
        activeTask?.cancel()
        activeTask = nil
        retainedInput = nil
    }

    private func run(
        generation requestGeneration: UInt64,
        sourceText: String?,
        requestedEngine: NativeTranslationEngine,
        context: NativeTranslationRequestContext
    ) async {
        guard isCurrent(requestGeneration) else { return }

        switch NativeTranslationInputPolicy.prepare(sourceText) {
        case let .failure(failure):
            publishIfCurrent(.failure(failure), generation: requestGeneration)
            return
        case let .skipped(reason):
            publishIfCurrent(.skipped(reason), generation: requestGeneration)
            return
        case let .ready(input):
            retainedInput = input
        }

        guard isCurrent(requestGeneration), let input = retainedInput else { return }

        let routeDecision = NativeTranslationPrivacyRouter.decide(
            requestedEngine: requestedEngine,
            context: context
        )

        let effectRequest: NativeTranslationEffectRequest
        switch routeDecision {
        case let .failure(failure):
            publishIfCurrent(.failure(failure), generation: requestGeneration)
            return
        case .execute(.apple):
            effectRequest = NativeTranslationEffectRequest(
                engine: .apple,
                input: input,
                volcCredentials: nil
            )
        case let .execute(.volc(expectedFingerprint)):
            guard isCurrent(requestGeneration) else { return }
            guard let credentials = credentialLoader(expectedFingerprint),
                  credentials.fingerprint == expectedFingerprint,
                  !credentials.accessKey.isEmpty,
                  !credentials.secretKey.isEmpty
            else {
                publishIfCurrent(
                    .failure(.cloudCredentialSnapshotMismatch),
                    generation: requestGeneration
                )
                return
            }
            effectRequest = NativeTranslationEffectRequest(
                engine: .volc,
                input: input,
                volcCredentials: credentials
            )
        }

        guard isCurrent(requestGeneration) else { return }
        let effectResult = await executor.execute(effectRequest)
        guard isCurrent(requestGeneration) else { return }

        let outcome: NativeTranslationOutcome
        switch effectResult {
        case let .success(text):
            guard !text.unicodeScalars.allSatisfy({ $0.properties.isWhitespace }) else {
                let failure: NativeTranslationFailure = requestedEngine == .volc
                    ? .volcMalformedResponse : .appleExecutionFailed
                publishIfCurrent(.failure(failure), generation: requestGeneration)
                return
            }
            outcome = .success(
                NativeTranslationSuccess(
                    engine: requestedEngine,
                    text: text,
                    inputWasTruncated: input.wasTruncated
                )
            )
        case let .failure(failure):
            outcome = .failure(failure)
        case .cancelled:
            outcome = .cancelled
        }

        guard isCurrent(requestGeneration) else { return }
        publishIfCurrent(outcome, generation: requestGeneration)
    }

    private func publishIfCurrent(
        _ outcome: NativeTranslationOutcome,
        generation requestGeneration: UInt64
    ) {
        guard isCurrent(requestGeneration) else { return }
        retainedInput = nil
        activeTask = nil
        publisher(requestGeneration, outcome)
    }

    private func isCurrent(_ requestGeneration: UInt64) -> Bool {
        requestGeneration == generation && !Task.isCancelled
    }
}
#endif
