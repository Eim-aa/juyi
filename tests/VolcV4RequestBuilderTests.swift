import Foundation

/// Golden vectors for the Volcengine AK/SK V4 signer. Every pin from the
/// legacy `tests/test_volc_signing.py` (URL, body bytes, payload hash, x-date,
/// headers, Authorization, empty-source omission) is reproduced here.
@main
@MainActor
enum VolcV4RequestBuilderTests {
    private static var passed = 0

    private static func expect(
        _ condition: @autoclosure () -> Bool,
        _ message: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard condition() else {
            fatalError("\(message) (\(file):\(line))")
        }
        passed += 1
    }

    private static let credentials = VolcV4Credentials(accessKey: "AKTEST", secretKey: "SKTEST")

    private static func build(
        _ text: String = "hello",
        credentials: VolcV4Credentials = credentials,
        source: String? = "en",
        target: String = "zh",
        now: Date
    ) throws -> VolcV4SignedRequest {
        try VolcV4RequestBuilder.build(
            credentials: credentials,
            text: text,
            source: source,
            target: target,
            now: now
        )
    }

    static func main() throws {
        let fixed = try date("2026-01-02T03:04:05Z")
        let request = try build("Hello, world.", now: fixed)

        testPythonGoldenVectors(request)
        testIntermediateSigningValues(request)
        try testEmptySource(fixed)
        try testPythonCompatibleJSON(fixed)
        testRFC3986Query()
        try testTimePolicy()
        try testCredentialHardening(fixed)
        try testLanguageIdentifierHardening(fixed)
        try testRedactionAndSecretAbsence(fixed)
        print("VolcV4RequestBuilderTests: \(passed) passed")
    }

    /// Ported one-for-one from tests/test_volc_signing.py.
    private static func testPythonGoldenVectors(_ request: VolcV4SignedRequest) {
        // test_url_and_body
        expect(
            request.url.absoluteString
                == "https://translate.volcengineapi.com/?Action=TranslateText&Version=2020-06-01",
            "URL is exact"
        )
        let body = "{\"TargetLanguage\": \"zh\", \"TextList\": [\"Hello, world.\"], \"SourceLanguage\": \"en\"}"
        expect(request.body == Data(body.utf8), "body exactly matches Python json.dumps bytes")

        // test_payload_hash_matches_body
        expect(
            request.headers["X-Content-Sha256"] == VolcV4RequestBuilder.sha256Hex(request.body),
            "payload hash is the SHA-256 of the body"
        )
        expect(
            request.headers["X-Content-Sha256"]
                == "c167fb9959bc1d87ccec51dfea1250da630a0163a1a0e89854c91aef467bc75a",
            "payload hash is pinned"
        )
        expect(request.headers["X-Date"] == "20260102T030405Z", "UTC x-date is pinned")
        expect(
            request.headers["Content-Type"] == "application/json; charset=utf-8",
            "content type is signed exactly"
        )
        expect(request.headers["Host"] == "translate.volcengineapi.com", "host header is exact")

        // test_signature_golden_pin
        expect(
            request.headers["Authorization"]
                == "HMAC-SHA256 Credential=AKTEST/20260102/cn-north-1/translate/request, SignedHeaders=content-type;host;x-content-sha256;x-date, Signature=7265ac5fe98b6ff62155737ef2dd0ec68d07dbb472c0aba1b527b7e9715302a7",
            "authorization signature is pinned"
        )
        expect(
            Set(request.headers.keys)
                == ["Content-Type", "Host", "X-Date", "X-Content-Sha256", "Authorization"],
            "exactly the signed headers plus Authorization are produced"
        )
        expect(request.method == "POST", "method is POST")
        expect(request.host == "translate.volcengineapi.com", "host is exact")
        expect(
            request.canonicalQuery == "Action=TranslateText&Version=2020-06-01",
            "canonical query is exact and sorted"
        )
    }

    private static func testIntermediateSigningValues(_ request: VolcV4SignedRequest) {
        expect(
            VolcV4RequestBuilder.sha256Hex(Data(request.canonicalRequest.utf8))
                == "814aa7fad71d321ee842b0218748890659588cb1fb4c96a63d8df651e04acc47",
            "canonical request hash is pinned"
        )
        expect(
            request.canonicalRequest.contains("x-date:20260102T030405Z\n\ncontent-type;host"),
            "canonical headers retain their required trailing newline"
        )
        expect(
            request.stringToSign
                == "HMAC-SHA256\n20260102T030405Z\n20260102/cn-north-1/translate/request\n814aa7fad71d321ee842b0218748890659588cb1fb4c96a63d8df651e04acc47",
            "string to sign is pinned"
        )

        let dateKey = VolcV4RequestBuilder.hmacSHA256(key: Data("SKTEST".utf8), message: "20260102")
        let regionKey = VolcV4RequestBuilder.hmacSHA256(key: dateKey, message: "cn-north-1")
        let serviceKey = VolcV4RequestBuilder.hmacSHA256(key: regionKey, message: "translate")
        let signingKey = VolcV4RequestBuilder.hmacSHA256(key: serviceKey, message: "request")
        expect(
            VolcV4RequestBuilder.hex(dateKey)
                == "a3a97705d641ff8f459b6eb0a60fc97b78d79f842673e88f8c9f7bb168301679",
            "date HMAC uses raw Data"
        )
        expect(
            VolcV4RequestBuilder.hex(regionKey)
                == "9627e8c2899aeee4de77f51b9726db2fed485f5b0dad0256e63b413a01fcc84f",
            "region HMAC derives from raw date key"
        )
        expect(
            VolcV4RequestBuilder.hex(serviceKey)
                == "e5a6fd30e2956ac9508d68257595f5f0b44f4b533291b7a17e3bb9be7775fccd",
            "service HMAC derives from raw region key"
        )
        expect(
            VolcV4RequestBuilder.hex(signingKey)
                == "ebec0bd3ef082aa6edceb31f85704e2a99fabc4e4e49714c14864234c6ab875a",
            "signing HMAC derives from raw service key"
        )
    }

    /// test_empty_source_omits_source_language. The native engine never
    /// relies on this (it always sends `en`); the builder keeps Python parity.
    private static func testEmptySource(_ fixed: Date) throws {
        let request = try build("hi", source: "", now: fixed)
        expect(
            request.body == Data("{\"TargetLanguage\": \"zh\", \"TextList\": [\"hi\"]}".utf8),
            "empty source language is omitted byte-for-byte"
        )
        expect(
            request.headers["Authorization"]?.hasSuffix(
                "Signature=5deb25744b6cbe5f0be4b12dec00275274fa2a70be248bd054b9474180f854c6"
            ) == true,
            "empty-source signature is pinned"
        )
        let nilSource = try build("hi", source: nil, now: fixed)
        expect(nilSource.body == request.body, "nil and empty source produce identical bodies")
        expect(
            nilSource.headers["Authorization"] == request.headers["Authorization"],
            "nil and empty source produce identical signatures"
        )
        let english = try build("hi", now: fixed)
        expect(
            String(decoding: english.body, as: UTF8.self).hasSuffix(", \"SourceLanguage\": \"en\"}"),
            "an explicit source is always sent"
        )
    }

    private static func testPythonCompatibleJSON(_ fixed: Date) throws {
        let text = "路径/“quote” \\ line\n\u{2028}\u{2029}😀"
        let request = try build(text, now: fixed)
        let expected = "{\"TargetLanguage\": \"zh\", \"TextList\": [\"路径/“quote” \\\\ line\\n\u{2028}\u{2029}😀\"], \"SourceLanguage\": \"en\"}"
        expect(request.body == Data(expected.utf8), "Unicode, slash, quotes, backslash and separators match Python")
        expect(
            request.headers["X-Content-Sha256"]
                == "aa332520341b6552c77c0c96b3f86f84ac05f01e4d30c5f7f6da62cdfabbc569",
            "special-character payload hash is pinned"
        )
        expect(
            request.headers["Authorization"]?.hasSuffix(
                "Signature=d77f4b44d75595136e7bb81c37f04208cc93d648a72afc518910f9a2c0247c1f"
            ) == true,
            "special-character signature is pinned"
        )

        let controlBody = try VolcV4RequestBuilder.deterministicBody(
            text: "\u{0000}\u{0001}\u{0008}\u{0009}\u{000C}\u{000D}\"\\",
            source: nil,
            target: "zh"
        )
        expect(
            controlBody
                == Data(
                    "{\"TargetLanguage\": \"zh\", \"TextList\": [\"\\u0000\\u0001\\b\\t\\f\\r\\\"\\\\\"]}".utf8
                ),
            "control-character body exactly matches Python bytes"
        )
    }

    private static func testRFC3986Query() {
        let query = VolcV4RequestBuilder.canonicalQueryString([
            VolcV4QueryItem(name: "z key", value: "a+b/c"),
            VolcV4QueryItem(name: "é", value: "中 文"),
            VolcV4QueryItem(name: "a", value: "~._-"),
            VolcV4QueryItem(name: "a", value: "!"),
        ])
        expect(
            query == "%C3%A9=%E4%B8%AD%20%E6%96%87&a=%21&a=~._-&z%20key=a%2Bb%2Fc",
            "RFC3986 encoding uses uppercase percent, percent-sort, and never plus-for-space"
        )
    }

    private static func testTimePolicy() throws {
        let beforeNewYear = try build(now: date("2025-12-31T23:59:59Z"))
        let newYear = try build(now: date("2026-01-01T00:00:00Z"))
        expect(beforeNewYear.headers["X-Date"] == "20251231T235959Z", "calendar year uses yyyy at boundary")
        expect(newYear.headers["X-Date"] == "20260101T000000Z", "UTC day rolls at the absolute instant")
        expect(
            newYear.headers["Authorization"]?.contains("Credential=AKTEST/20260101/") == true,
            "credential short date comes from the same UTC x-date"
        )
        let weekYearBoundary = try build(now: date("2018-12-31T12:00:00Z"))
        expect(
            weekYearBoundary.headers["X-Date"] == "20181231T120000Z",
            "calendar year never changes to the ISO week-based year"
        )

        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.locale = Locale(identifier: "en_US_POSIX")
        localCalendar.timeZone = TimeZone(secondsFromGMT: 14 * 3_600)!
        let localDate = localCalendar.date(
            from: DateComponents(year: 2026, month: 1, day: 1, hour: 13, minute: 4, second: 5)
        )!
        let utc = try build(now: localDate)
        expect(utc.headers["X-Date"] == "20251231T230405Z", "formatter ignores local timezone")
    }

    private static func testCredentialHardening(_ fixed: Date) throws {
        let invalidAccessKeys = [
            "", "AK TEST", "AK+TEST", "AKéTEST", "AK\u{0000}TEST", "AK\rTEST", "AK\nTEST",
            "AK\u{007F}TEST", String(repeating: "A", count: 257),
        ]
        for accessKey in invalidAccessKeys {
            expectBuilderError(
                credentials: VolcV4Credentials(accessKey: accessKey, secretKey: "SKTEST"),
                now: fixed,
                expected: .invalidCredentials,
                message: "invalid or oversized AK fails closed"
            )
        }
        let invalidSecretKeys = [
            "", "SK\u{0000}TEST", "SK\rTEST", "SK\nTEST", "SK\u{007F}TEST", "SK TEST", "SKéTEST",
            String(repeating: "S", count: 257),
        ]
        for secretKey in invalidSecretKeys {
            expectBuilderError(
                credentials: VolcV4Credentials(accessKey: "AKTEST", secretKey: secretKey),
                now: fixed,
                expected: .invalidCredentials,
                message: "invalid or oversized SK fails closed"
            )
        }

        let maximumAccessKey = String(repeating: "A", count: 256)
        let maximumAK = try build(
            credentials: VolcV4Credentials(accessKey: maximumAccessKey, secretKey: "SKTEST"),
            now: fixed
        )
        expect(
            maximumAK.headers["Authorization"]?.contains(maximumAccessKey) == true,
            "256-byte AK is the accepted boundary"
        )
        let maximumSK = try build(
            credentials: VolcV4Credentials(
                accessKey: "AKTEST",
                secretKey: String(repeating: "S", count: 256)
            ),
            now: fixed
        )
        expect(maximumSK.headers["Authorization"]?.contains("Signature=") == true, "256-byte SK is accepted")
        let asciiGraphicSecret = (0x21...0x7E).map { String(UnicodeScalar($0)!) }.joined()
        let graphic = try build(
            credentials: VolcV4Credentials(accessKey: "AKTEST", secretKey: asciiGraphicSecret),
            now: fixed
        )
        expect(graphic.headers["Authorization"]?.contains("Signature=") == true, "all ASCII graphic SK bytes are accepted")
    }

    private static func testLanguageIdentifierHardening(_ fixed: Date) throws {
        let invalidIdentifiers = [
            "\u{0000}", "en US", "en\rUS", "en\nUS", "en\u{007F}US", "en_US", "中文",
            String(repeating: "e", count: 33),
        ]
        for identifier in invalidIdentifiers {
            expectBuilderError(source: identifier, now: fixed, expected: .invalidLanguage,
                               message: "invalid or oversized source language fails closed")
            expectBuilderError(target: identifier, now: fixed, expected: .invalidLanguage,
                               message: "invalid or oversized target language fails closed")
        }
        expectBuilderError(target: "", now: fixed, expected: .invalidLanguage,
                           message: "empty target language fails closed")
        let boundary = String(repeating: "e", count: 32)
        let boundaryRequest = try build(source: boundary, target: boundary, now: fixed)
        expect(
            String(decoding: boundaryRequest.body, as: UTF8.self).contains(boundary),
            "32-byte language identifiers are accepted"
        )
    }

    private static func testRedactionAndSecretAbsence(_ fixed: Date) throws {
        let secret = "SK-should-never-appear"
        let canaryCredentials = VolcV4Credentials(accessKey: "AKCANARY", secretKey: secret)
        expect(!canaryCredentials.description.contains("AKCANARY"), "credential description hides access key")
        expect(!String(reflecting: canaryCredentials).contains(secret), "credential reflection hides secret key")

        let request = try build("source-canary", credentials: canaryCredentials, now: fixed)
        for canary in ["AKCANARY", secret, "source-canary"] {
            expect(!request.description.contains(canary), "request description redacts \(canary)")
            expect(!String(reflecting: request).contains(canary), "request reflection redacts \(canary)")
        }
        // Only the signature derived from the secret is transmitted.
        for (name, value) in request.headers {
            expect(!value.contains(secret), "header \(name) never carries the secret key")
        }
        expect(!String(decoding: request.body, as: UTF8.self).contains(secret), "body never carries the secret key")
        expect(!request.url.absoluteString.contains(secret), "URL never carries the secret key")

        let secretCanary = "SK-CANARY-NEVER-LEAK\n"
        do {
            _ = try build(
                credentials: VolcV4Credentials(accessKey: "AKTEST\r\nInjected: yes", secretKey: secretCanary),
                now: fixed
            )
            fatalError("header injection must fail")
        } catch let error as VolcV4RequestBuilderError {
            expect(error == .invalidCredentials, "header injection access key is rejected")
            expect(!String(reflecting: error).contains(secretCanary), "builder error is redacted")
            expect(!error.description.contains("Injected"), "builder error omits the input")
        }
    }

    private static func expectBuilderError(
        credentials: VolcV4Credentials = credentials,
        source: String? = "en",
        target: String = "zh",
        now: Date,
        expected: VolcV4RequestBuilderError,
        message: String
    ) {
        do {
            _ = try build(credentials: credentials, source: source, target: target, now: now)
            fatalError("\(message): expected error")
        } catch let error as VolcV4RequestBuilderError {
            expect(error == expected, message)
        } catch {
            fatalError("\(message): unexpected error \(error)")
        }
    }

    private static func date(_ string: String) throws -> Date {
        guard let value = ISO8601DateFormatter().date(from: string) else {
            throw VolcV4RequestBuilderError.invalidTimestamp
        }
        return value
    }
}
