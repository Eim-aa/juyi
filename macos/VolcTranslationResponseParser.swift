#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN
import Foundation

enum VolcTranslationResponseParser {
    private static let maximumPayloadBytes = 1_048_576

    static func parse(statusCode: Int, data: Data) -> Result<String, NativeTranslationFailure> {
        guard (200...299).contains(statusCode) else {
            switch statusCode {
            case 401, 403:
                return .failure(.volcCredential)
            case 408, 504:
                return .failure(.volcTimeout)
            case 429:
                return .failure(.volcQuota)
            case 500...599:
                return .failure(.volcService)
            default:
                return .failure(.volcHTTP)
            }
        }

        guard data.count <= maximumPayloadBytes else {
            return .failure(.volcMalformedResponse)
        }

        let envelope: Envelope
        do {
            envelope = try JSONDecoder().decode(Envelope.self, from: data)
        } catch {
            return .failure(.volcMalformedResponse)
        }

        if let upstreamError = envelope.responseMetadata?.error {
            return .failure(classify(upstreamError.code))
        }

        guard let translation = envelope.translationList?.first?.translation,
              !translation.unicodeScalars.allSatisfy({ $0.properties.isWhitespace })
        else {
            return .failure(.volcMalformedResponse)
        }
        return .success(translation)
    }

    private static func classify(_ code: String?) -> NativeTranslationFailure {
        switch code {
        case "AccessDenied", "Forbidden", "InvalidAccessKey", "InvalidAccessKeyId",
             "InvalidCredential", "PermissionDenied", "SignatureDoesNotMatch", "Unauthorized":
            return .volcCredential
        case "RequestTimeout", "RequestTimeoutException", "Timeout":
            return .volcTimeout
        case "FlowLimitExceeded", "LimitExceeded", "QuotaExceeded", "Throttling",
             "TooManyRequests":
            return .volcQuota
        default:
            return .volcService
        }
    }

    private struct Envelope: Decodable {
        let translationList: [TranslationItem]?
        let responseMetadata: ResponseMetadata?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: CodingKeys.self)
            responseMetadata = try container.decodeIfPresent(
                ResponseMetadata.self,
                forKey: .responseMetadata
            )
            if responseMetadata?.error != nil {
                translationList = nil
            } else {
                translationList = try container.decodeIfPresent(
                    [TranslationItem].self,
                    forKey: .translationList
                )
            }
        }

        enum CodingKeys: String, CodingKey {
            case translationList = "TranslationList"
            case responseMetadata = "ResponseMetadata"
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
#endif
