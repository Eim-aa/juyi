import Foundation

/// Stable, secret-free failure categories of the native Volcengine engine.
/// No case carries upstream text, so a failure can never echo a credential,
/// the selection, or a server message.
enum VolcTranslationError: Error, Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    /// No stored credential, or Volcengine rejected the signature/permission.
    case credential
    case network
    case timeout
    /// Any other non-2xx status or upstream error code.
    case httpFailure
    case malformedResponse
    /// A well-formed response without a usable translation.
    case emptyResult

    var description: String {
        switch self {
        case .credential: return "volc_credential"
        case .network: return "volc_network"
        case .timeout: return "volc_timeout"
        case .httpFailure: return "volc_http"
        case .malformedResponse: return "volc_malformed_response"
        case .emptyResult: return "volc_empty_result"
        }
    }

    var debugDescription: String { description }
}

enum VolcTranslationResponseParser {
    static let maximumPayloadBytes = 1_048_576

    static let credentialCodes: Set<String> = [
        "AccessDenied", "Forbidden", "InvalidAccessKey", "InvalidAccessKeyId",
        "InvalidCredential", "InvalidAuthorization", "MissingAuthenticationToken",
        "PermissionDenied", "SignatureDoesNotMatch", "Unauthorized",
    ]
    static let timeoutCodes: Set<String> = [
        "RequestTimeout", "RequestTimeoutException", "Timeout",
    ]

    static func parse(statusCode: Int, data: Data) -> Result<String, VolcTranslationError> {
        guard (200...299).contains(statusCode) else {
            switch statusCode {
            case 401, 403:
                return .failure(.credential)
            case 408, 504:
                return .failure(.timeout)
            default:
                // A rejected signature may arrive with another 4xx status;
                // only an allowlisted credential code changes the category.
                if upstreamErrorCode(in: data).map(credentialCodes.contains) == true {
                    return .failure(.credential)
                }
                return .failure(.httpFailure)
            }
        }

        guard data.count <= maximumPayloadBytes else {
            return .failure(.malformedResponse)
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            return .failure(.malformedResponse)
        }

        if let upstreamError = envelope.responseMetadata?.error {
            return .failure(classify(upstreamError.code))
        }

        guard let translationList = envelope.resolvedTranslationList else {
            return .failure(.malformedResponse)
        }
        guard translationList.count <= 1 else {
            return .failure(.malformedResponse)
        }
        guard let translation = translationList.first?.translation,
              !translation.unicodeScalars.allSatisfy({ $0.properties.isWhitespace })
        else {
            return .failure(.emptyResult)
        }
        return .success(translation)
    }

    private static func classify(_ code: String?) -> VolcTranslationError {
        guard let code else { return .httpFailure }
        if credentialCodes.contains(code) { return .credential }
        if timeoutCodes.contains(code) { return .timeout }
        return .httpFailure
    }

    private static func upstreamErrorCode(in data: Data) -> String? {
        guard data.count <= maximumPayloadBytes,
              let envelope = try? JSONDecoder().decode(ErrorOnlyEnvelope.self, from: data)
        else { return nil }
        return envelope.responseMetadata?.error?.code
    }

    private struct ErrorOnlyEnvelope: Decodable {
        let responseMetadata: ResponseMetadata?

        enum CodingKeys: String, CodingKey {
            case responseMetadata = "ResponseMetadata"
        }
    }

    private struct Envelope: Decodable {
        let translationList: [TranslationItem]?
        let result: ResultEnvelope?
        let hasBothEnvelopes: Bool
        let responseMetadata: ResponseMetadata?

        /// The legacy top-level list and the official `Result` wrapper are
        /// both accepted, but never at once: an ambiguous payload fails closed.
        var resolvedTranslationList: [TranslationItem]? {
            guard !hasBothEnvelopes else { return nil }
            return translationList ?? result?.translationList
        }

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            responseMetadata = try container.decodeIfPresent(
                ResponseMetadata.self,
                forKey: .responseMetadata
            )
            if responseMetadata?.error != nil {
                translationList = nil
                result = nil
                hasBothEnvelopes = false
            } else {
                translationList = try container.decodeIfPresent(
                    [TranslationItem].self,
                    forKey: .translationList
                )
                result = try container.decodeIfPresent(
                    ResultEnvelope.self,
                    forKey: .result
                )
                hasBothEnvelopes = translationList != nil && result?.translationList != nil
            }
        }

        enum CodingKeys: String, CodingKey {
            case translationList = "TranslationList"
            case result = "Result"
            case responseMetadata = "ResponseMetadata"
        }
    }

    private struct ResultEnvelope: Decodable {
        let translationList: [TranslationItem]?

        enum CodingKeys: String, CodingKey {
            case translationList = "TranslationList"
        }
    }

    private struct TranslationItem: Decodable {
        let translation: String?

        enum CodingKeys: String, CodingKey {
            case translation = "Translation"
        }
    }

    private struct ResponseMetadata: Decodable {
        let error: UpstreamError?

        enum CodingKeys: String, CodingKey {
            case error = "Error"
        }
    }

    private struct UpstreamError: Decodable {
        let code: String?

        enum CodingKeys: String, CodingKey {
            case code = "Code"
        }
    }
}
