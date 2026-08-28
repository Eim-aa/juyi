#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN
import Foundation

enum VolcTranslationResponseParser {
    static let maximumPayloadBytes = 1_048_576

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

        guard let translationList = envelope.resolvedTranslationList,
              translationList.count == 1,
              let translation = translationList[0].translation,
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
             "TooManyRequests", "-429":
            return .volcQuota
        default:
            return .volcService
        }
    }

    private struct Envelope: Decodable {
        let translationList: [TranslationItem]?
        let result: ResultEnvelope?
        let responseMetadata: ResponseMetadata?

        var resolvedTranslationList: [TranslationItem]? {
            let official = result?.translationList
            switch (translationList, official) {
            case (_?, _?):
                return nil
            case let (legacy?, nil):
                return legacy
            case let (nil, current?):
                return current
            case (nil, nil):
                return nil
            }
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
            } else {
                translationList = try container.decodeIfPresent(
                    [TranslationItem].self,
                    forKey: .translationList
                )
                result = try container.decodeIfPresent(
                    ResultEnvelope.self,
                    forKey: .result
                )
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

    private struct TranslationItem: Decodable, Equatable {
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
