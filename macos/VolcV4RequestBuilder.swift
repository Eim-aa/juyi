#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN
import CryptoKit
import Foundation

struct VolcV4Credentials: Equatable, Sendable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    let accessKey: String
    let secretKey: String
    let fingerprint: String

    var description: String { "VolcV4Credentials([REDACTED])" }
    var debugDescription: String { description }
}

struct VolcV4QueryItem: Equatable, Sendable {
    let name: String
    let value: String
}

enum VolcV4RequestBuilderError: Error, Equatable, CustomStringConvertible,
    CustomDebugStringConvertible
{
    case invalidCredentials
    case invalidLanguage
    case invalidTimestamp
    case invalidUTF8

    var description: String {
        switch self {
        case .invalidCredentials: return "invalid_credentials"
        case .invalidLanguage: return "invalid_language"
        case .invalidTimestamp: return "invalid_timestamp"
        case .invalidUTF8: return "invalid_utf8"
        }
    }

    var debugDescription: String { description }
}

struct VolcV4SignedRequest: Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let method: String
    let scheme: String
    let host: String
    let canonicalURI: String
    let canonicalQuery: String
    let headers: [String: String]
    let body: Data
    let canonicalRequest: String
    let stringToSign: String

    var endpoint: String { "\(scheme)://\(host)\(canonicalURI)?\(canonicalQuery)" }

    var description: String {
        "VolcV4SignedRequest(method: \(method), endpoint: [REDACTED], headers: [REDACTED], bodyBytes: \(body.count))"
    }

    var debugDescription: String { description }
}

enum VolcV4RequestBuilder {
    static let maximumCredentialBytes = 256
    static let maximumLanguageIdentifierBytes = 32

    static func build(
        text: String,
        credentials: VolcV4Credentials,
        sourceLanguage: String?,
        targetLanguage: String,
        instant: Date
    ) throws -> VolcV4SignedRequest {
        guard validAccessKey(credentials.accessKey), validSecretKey(credentials.secretKey) else {
            throw VolcV4RequestBuilderError.invalidCredentials
        }
        guard validLanguageIdentifier(targetLanguage, allowsEmpty: false),
              sourceLanguage.map({ validLanguageIdentifier($0, allowsEmpty: true) }) ?? true
        else {
            throw VolcV4RequestBuilderError.invalidLanguage
        }

        let method = "POST"
        let scheme = "https"
        let host = "translate.volcengineapi.com"
        let canonicalURI = "/"
        let region = "cn-north-1"
        let service = "translate"
        let contentType = "application/json; charset=utf-8"
        let signedHeaders = "content-type;host;x-content-sha256;x-date"
        let canonicalQuery = canonicalQueryString([
            VolcV4QueryItem(name: "Action", value: "TranslateText"),
            VolcV4QueryItem(name: "Version", value: "2020-06-01"),
        ])
        let body = try deterministicBody(
            text: text,
            sourceLanguage: sourceLanguage,
            targetLanguage: targetLanguage
        )
        let timestamp = try utcTimestamp(for: instant)
        let xDate = timestamp.xDate
        let shortDate = timestamp.shortDate
        let payloadHash = sha256Hex(body)
        let canonicalHeaders = "content-type:\(contentType)\n"
            + "host:\(host)\n"
            + "x-content-sha256:\(payloadHash)\n"
            + "x-date:\(xDate)\n"
        let canonicalRequest = [
            method,
            canonicalURI,
            canonicalQuery,
            canonicalHeaders,
            signedHeaders,
            payloadHash,
        ].joined(separator: "\n")
        let credentialScope = "\(shortDate)/\(region)/\(service)/request"
        let stringToSign = [
            "HMAC-SHA256",
            xDate,
            credentialScope,
            sha256Hex(Data(canonicalRequest.utf8)),
        ].joined(separator: "\n")

        let dateKey = hmacSHA256(key: Data(credentials.secretKey.utf8), message: shortDate)
        let regionKey = hmacSHA256(key: dateKey, message: region)
        let serviceKey = hmacSHA256(key: regionKey, message: service)
        let signingKey = hmacSHA256(key: serviceKey, message: "request")
        let signature = hex(hmacSHA256(key: signingKey, message: stringToSign))
        let authorization = "HMAC-SHA256 Credential=\(credentials.accessKey)/\(credentialScope), "
            + "SignedHeaders=\(signedHeaders), Signature=\(signature)"

        return VolcV4SignedRequest(
            method: method,
            scheme: scheme,
            host: host,
            canonicalURI: canonicalURI,
            canonicalQuery: canonicalQuery,
            headers: [
                "Content-Type": contentType,
                "Host": host,
                "X-Date": xDate,
                "X-Content-Sha256": payloadHash,
                "Authorization": authorization,
            ],
            body: body,
            canonicalRequest: canonicalRequest,
            stringToSign: stringToSign
        )
    }

    static func canonicalQueryString(_ items: [VolcV4QueryItem]) -> String {
        items.enumerated()
            .map { index, item in
                (index, percentEncode(item.name), percentEncode(item.value))
            }
            .sorted { lhs, rhs in
                if lhs.1 != rhs.1 { return lhs.1 < rhs.1 }
                if lhs.2 != rhs.2 { return lhs.2 < rhs.2 }
                return lhs.0 < rhs.0
            }
            .map { "\($0.1)=\($0.2)" }
            .joined(separator: "&")
    }

    static func deterministicBody(
        text: String,
        sourceLanguage: String?,
        targetLanguage: String
    ) throws -> Data {
        var body = "{\"TargetLanguage\": \(jsonString(targetLanguage)), "
            + "\"TextList\": [\(jsonString(text))]"
        if let sourceLanguage, !sourceLanguage.isEmpty {
            body += ", \"SourceLanguage\": \(jsonString(sourceLanguage))"
        }
        body += "}"
        guard let data = body.data(using: .utf8) else {
            throw VolcV4RequestBuilderError.invalidUTF8
        }
        return data
    }

    static func hmacSHA256(key: Data, message: String) -> Data {
        let authenticationCode = HMAC<SHA256>.authenticationCode(
            for: Data(message.utf8),
            using: SymmetricKey(data: key)
        )
        return Data(authenticationCode)
    }

    static func sha256Hex(_ data: Data) -> String {
        hex(Data(SHA256.hash(data: data)))
    }

    static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }

    private static func validAccessKey(_ value: String) -> Bool {
        validUTF8Length(value, maximum: maximumCredentialBytes)
            && value.unicodeScalars.allSatisfy { scalar in
                switch scalar.value {
                case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F:
                    return true
                default:
                    return false
                }
            }
    }

    private static func validSecretKey(_ value: String) -> Bool {
        validUTF8Length(value, maximum: maximumCredentialBytes)
            && value.unicodeScalars.allSatisfy { (0x21...0x7E).contains($0.value) }
    }

    private static func validLanguageIdentifier(_ value: String, allowsEmpty: Bool) -> Bool {
        if value.isEmpty { return allowsEmpty }
        guard validUTF8Length(value, maximum: maximumLanguageIdentifierBytes) else {
            return false
        }
        return value.unicodeScalars.allSatisfy { scalar in
            switch scalar.value {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D:
                return true
            default:
                return false
            }
        }
    }

    private static func validUTF8Length(_ value: String, maximum: Int) -> Bool {
        (1...maximum).contains(value.utf8.count)
    }

    private static func percentEncode(_ value: String) -> String {
        var encoded = ""
        for byte in value.utf8 {
            switch byte {
            case 0x30...0x39, 0x41...0x5A, 0x61...0x7A, 0x2D, 0x2E, 0x5F, 0x7E:
                encoded.append(Character(UnicodeScalar(byte)))
            default:
                encoded += String(format: "%%%02X", byte)
            }
        }
        return encoded
    }

    private static func jsonString(_ value: String) -> String {
        var encoded = "\""
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x08: encoded += "\\b"
            case 0x09: encoded += "\\t"
            case 0x0A: encoded += "\\n"
            case 0x0C: encoded += "\\f"
            case 0x0D: encoded += "\\r"
            case 0x22: encoded += "\\\""
            case 0x5C: encoded += "\\\\"
            case 0x00...0x1F:
                encoded += String(format: "\\u%04x", scalar.value)
            default:
                encoded.unicodeScalars.append(scalar)
            }
        }
        encoded += "\""
        return encoded
    }

    private static func utcTimestamp(for instant: Date) throws -> (xDate: String, shortDate: String) {
        guard instant.timeIntervalSinceReferenceDate.isFinite else {
            throw VolcV4RequestBuilderError.invalidTimestamp
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
        let xDate = formatter.string(from: instant)
        guard xDate.utf8.count == 16 else {
            throw VolcV4RequestBuilderError.invalidTimestamp
        }
        return (xDate, String(xDate.prefix(8)))
    }
}
#endif
