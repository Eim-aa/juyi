#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN
import Foundation

@main
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

    private static let credentials = VolcV4Credentials(
        accessKey: "AKTEST",
        secretKey: "SKTEST",
        fingerprint: "verified"
    )

    static func main() throws {
        let fixed = try date("2026-01-02T03:04:05Z")
        let request = try VolcV4RequestBuilder.build(
            text: "Hello, world.",
            credentials: credentials,
            sourceLanguage: "en",
            targetLanguage: "zh",
            instant: fixed
        )

        testGolden(request)
        try testEmptySource(fixed)
        try testPythonCompatibleJSON(fixed)
        testRFC3986Query()
        try testTimePolicy()
        try testCredentialHardening(fixed)
        try testLanguageIdentifierHardening(fixed)
        testRedactionAndValidation(fixed)
        print("VolcV4RequestBuilderTests: \(passed) passed")
    }

    private static func testGolden(_ request: VolcV4SignedRequest) {
        let body = "{\"TargetLanguage\": \"zh\", \"TextList\": [\"Hello, world.\"], \"SourceLanguage\": \"en\"}"
        expect(request.method == "POST", "method is POST")
        expect(request.scheme == "https", "scheme is HTTPS")
        expect(request.host == "translate.volcengineapi.com", "host is exact")
        expect(request.canonicalURI == "/", "canonical URI is slash")
        expect(
            request.canonicalQuery == "Action=TranslateText&Version=2020-06-01",
            "canonical query is exact and sorted"
        )
        expect(
            request.endpoint == "https://translate.volcengineapi.com/?Action=TranslateText&Version=2020-06-01",
            "endpoint path and query match the signed values"
        )
        expect(request.body == Data(body.utf8), "body exactly matches Python json.dumps bytes")
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
        expect(request.headers["Host"] == request.host, "sent and signed host are identical")
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

        let dateKey = VolcV4RequestBuilder.hmacSHA256(
            key: Data("SKTEST".utf8),
            message: "20260102"
        )
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
        expect(
            request.headers["Authorization"]
                == "HMAC-SHA256 Credential=AKTEST/20260102/cn-north-1/translate/request, SignedHeaders=content-type;host;x-content-sha256;x-date, Signature=7265ac5fe98b6ff62155737ef2dd0ec68d07dbb472c0aba1b527b7e9715302a7",
            "authorization signature is pinned"
        )
    }

    private static func testEmptySource(_ fixed: Date) throws {
        let request = try VolcV4RequestBuilder.build(
            text: "hi",
            credentials: credentials,
            sourceLanguage: "",
            targetLanguage: "zh",
            instant: fixed
        )
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

        let nilSourceRequest = try VolcV4RequestBuilder.build(
            text: "hi",
            credentials: credentials,
            sourceLanguage: nil,
            targetLanguage: "zh",
            instant: fixed
        )
        expect(
            nilSourceRequest.body == request.body,
            "nil and empty source language produce identical body bytes"
        )
        expect(
            nilSourceRequest.headers["Authorization"] == request.headers["Authorization"],
            "nil and empty source language produce identical signatures"
        )
    }

    private static func testPythonCompatibleJSON(_ fixed: Date) throws {
        let text = "路径/“quote” \\ line\n\u{2028}\u{2029}😀"
        let request = try VolcV4RequestBuilder.build(
            text: text,
            credentials: credentials,
            sourceLanguage: "en",
            targetLanguage: "zh",
            instant: fixed
        )
        let expected = "{\"TargetLanguage\": \"zh\", \"TextList\": [\"路径/“quote” \\\\ line\\n\u{2028}\u{2029}😀\"], \"SourceLanguage\": \"en\"}"
        expect(request.body == Data(expected.utf8), "Unicode slash quotes backslash newline and separators match Python")
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
            sourceLanguage: nil,
            targetLanguage: "zh"
        )
        let controlString = String(decoding: controlBody, as: UTF8.self)
        expect(
            controlBody
                == Data(
                    "{\"TargetLanguage\": \"zh\", \"TextList\": [\"\\u0000\\u0001\\b\\t\\f\\r\\\"\\\\\"]}".utf8
                ),
            "control-character body exactly matches Python bytes"
        )
        expect(controlString.hasSuffix("\\\"\\\\\"]}"), "quote and backslash escape positions are exact")
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
            "RFC3986 encoding uses percent uppercase, percent-sort, and never plus-for-space"
        )
    }

    private static func testTimePolicy() throws {
        let beforeNewYear = try VolcV4RequestBuilder.build(
            text: "hello",
            credentials: credentials,
            sourceLanguage: "en",
            targetLanguage: "zh",
            instant: date("2025-12-31T23:59:59Z")
        )
        let newYear = try VolcV4RequestBuilder.build(
            text: "hello",
            credentials: credentials,
            sourceLanguage: "en",
            targetLanguage: "zh",
            instant: date("2026-01-01T00:00:00Z")
        )
        expect(beforeNewYear.headers["X-Date"] == "20251231T235959Z", "calendar year uses yyyy at boundary")
        expect(newYear.headers["X-Date"] == "20260101T000000Z", "UTC day rolls at the absolute instant")
        expect(
            newYear.headers["Authorization"]?.contains("Credential=AKTEST/20260101/") == true,
            "credential short date comes from the same UTC x-date"
        )
        let weekYearBoundary = try VolcV4RequestBuilder.build(
            text: "hello",
            credentials: credentials,
            sourceLanguage: "en",
            targetLanguage: "zh",
            instant: date("2018-12-31T12:00:00Z")
        )
        expect(
            weekYearBoundary.headers["X-Date"] == "20181231T120000Z",
            "calendar year never changes to the ISO week-based 2019 year"
        )

        var localCalendar = Calendar(identifier: .gregorian)
        localCalendar.locale = Locale(identifier: "en_US_POSIX")
        localCalendar.timeZone = TimeZone(secondsFromGMT: 14 * 3_600)!
        let localDate = localCalendar.date(
            from: DateComponents(year: 2026, month: 1, day: 1, hour: 13, minute: 4, second: 5)
        )!
        let utc = try VolcV4RequestBuilder.build(
            text: "hello",
            credentials: credentials,
            sourceLanguage: "en",
            targetLanguage: "zh",
            instant: localDate
        )
        expect(utc.headers["X-Date"] == "20251231T230405Z", "formatter ignores local timezone")
    }

    private static func testRedactionAndValidation(_ fixed: Date) {
        let secret = "SK-should-never-appear"
        let canaryCredentials = VolcV4Credentials(
            accessKey: "AKCANARY",
            secretKey: secret,
            fingerprint: "fingerprint-canary"
        )
        expect(!canaryCredentials.description.contains("AKCANARY"), "credential description hides access key")
        expect(!canaryCredentials.debugDescription.contains(secret), "credential debug description hides secret key")

        let request = try! VolcV4RequestBuilder.build(
            text: "source-canary",
            credentials: canaryCredentials,
            sourceLanguage: "en",
            targetLanguage: "zh",
            instant: fixed
        )
        for canary in ["AKCANARY", secret, "source-canary", "fingerprint-canary"] {
            expect(!request.description.contains(canary), "request description redacts \(canary)")
            expect(!request.debugDescription.contains(canary), "request debug description redacts \(canary)")
            expect(!String(reflecting: request).contains(canary), "request reflection redacts \(canary)")
        }

        let unsafe = VolcV4Credentials(
            accessKey: "AKTEST\r\nInjected: yes",
            secretKey: "SKTEST",
            fingerprint: "f"
        )
        do {
            _ = try VolcV4RequestBuilder.build(
                text: "hello",
                credentials: unsafe,
                sourceLanguage: "en",
                targetLanguage: "zh",
                instant: fixed
            )
            fatalError("unsafe access key must fail")
        } catch let error as VolcV4RequestBuilderError {
            expect(error == .invalidCredentials, "header injection access key is rejected")
            expect(!error.description.contains("Injected"), "builder error is redacted")
        } catch {
            fatalError("unexpected error: \(error)")
        }
    }

    private static func testCredentialHardening(_ fixed: Date) throws {
        let invalidAccessKeys = [
            "",
            "AK TEST",
            "AK+TEST",
            "AKéTEST",
            "AK\u{0000}TEST",
            "AK\rTEST",
            "AK\nTEST",
            "AK\u{007F}TEST",
            String(repeating: "A", count: 257),
        ]
        for accessKey in invalidAccessKeys {
            expectBuilderError(
                credentials: VolcV4Credentials(
                    accessKey: accessKey,
                    secretKey: "SKTEST",
                    fingerprint: "f"
                ),
                instant: fixed,
                expected: .invalidCredentials,
                message: "invalid or oversized AK fails closed"
            )
        }

        let invalidSecretKeys = [
            "",
            "SK\u{0000}TEST",
            "SK\rTEST",
            "SK\nTEST",
            "SK\u{007F}TEST",
            "SK TEST",
            "SKéTEST",
            String(repeating: "S", count: 257),
        ]
        for secretKey in invalidSecretKeys {
            expectBuilderError(
                credentials: VolcV4Credentials(
                    accessKey: "AKTEST",
                    secretKey: secretKey,
                    fingerprint: "f"
                ),
                instant: fixed,
                expected: .invalidCredentials,
                message: "invalid or oversized SK fails closed"
            )
        }

        let maximumAccessKey = String(repeating: "A", count: 256)
        let maximumSecretKey = String(repeating: "S", count: 256)
        let maximumAKRequest = try VolcV4RequestBuilder.build(
            text: "hello",
            credentials: VolcV4Credentials(
                accessKey: maximumAccessKey,
                secretKey: "SKTEST",
                fingerprint: "f"
            ),
            sourceLanguage: "en",
            targetLanguage: "zh",
            instant: fixed
        )
        expect(
            maximumAKRequest.headers["Authorization"]?.contains(maximumAccessKey) == true,
            "256-byte AK is the accepted boundary"
        )
        let maximumSKRequest = try VolcV4RequestBuilder.build(
            text: "hello",
            credentials: VolcV4Credentials(
                accessKey: "AKTEST",
                secretKey: maximumSecretKey,
                fingerprint: "f"
            ),
            sourceLanguage: "en",
            targetLanguage: "zh",
            instant: fixed
        )
        expect(
            maximumSKRequest.headers["Authorization"]?.contains("Signature=") == true,
            "256-byte SK is the accepted boundary"
        )

        let asciiGraphicSecret = (0x21...0x7E)
            .map { String(UnicodeScalar($0)!) }
            .joined()
        let graphicRequest = try VolcV4RequestBuilder.build(
            text: "hello",
            credentials: VolcV4Credentials(
                accessKey: "AKTEST",
                secretKey: asciiGraphicSecret,
                fingerprint: "f"
            ),
            sourceLanguage: "en",
            targetLanguage: "zh",
            instant: fixed
        )
        expect(
            graphicRequest.headers["Authorization"]?.contains("Signature=") == true,
            "all ASCII graphic SK bytes are accepted"
        )

        let secretCanary = "SK-CANARY-NEVER-LEAK\n"
        do {
            _ = try VolcV4RequestBuilder.build(
                text: "hello",
                credentials: VolcV4Credentials(
                    accessKey: "AKTEST",
                    secretKey: secretCanary,
                    fingerprint: "f"
                ),
                sourceLanguage: "en",
                targetLanguage: "zh",
                instant: fixed
            )
            fatalError("control-bearing secret must fail")
        } catch let error as VolcV4RequestBuilderError {
            expect(error == .invalidCredentials, "secret canary is rejected")
            expect(!error.description.contains(secretCanary), "credential error does not disclose secret")
            expect(!String(reflecting: error).contains(secretCanary), "credential reflection is redacted")
        } catch {
            fatalError("unexpected error: \(error)")
        }
    }

    private static func testLanguageIdentifierHardening(_ fixed: Date) throws {
        let invalidIdentifiers = [
            "\u{0000}",
            "en US",
            "en\rUS",
            "en\nUS",
            "en\u{007F}US",
            "en_US",
            "中文",
            String(repeating: "e", count: 33),
        ]
        for identifier in invalidIdentifiers {
            expectBuilderError(
                credentials: credentials,
                sourceLanguage: identifier,
                instant: fixed,
                expected: .invalidLanguage,
                message: "invalid or oversized source language fails closed"
            )
            expectBuilderError(
                credentials: credentials,
                targetLanguage: identifier,
                instant: fixed,
                expected: .invalidLanguage,
                message: "invalid or oversized target language fails closed"
            )
        }
        expectBuilderError(
            credentials: credentials,
            targetLanguage: "",
            instant: fixed,
            expected: .invalidLanguage,
            message: "empty target language fails closed"
        )

        let boundary = String(repeating: "e", count: 32)
        let boundaryRequest = try VolcV4RequestBuilder.build(
            text: "hello",
            credentials: credentials,
            sourceLanguage: boundary,
            targetLanguage: boundary,
            instant: fixed
        )
        expect(
            String(decoding: boundaryRequest.body, as: UTF8.self).contains(boundary),
            "32-byte language identifiers are accepted"
        )
        let hyphenated = try VolcV4RequestBuilder.build(
            text: "hello",
            credentials: credentials,
            sourceLanguage: "en-US",
            targetLanguage: "zh-CN",
            instant: fixed
        )
        expect(
            String(decoding: hyphenated.body, as: UTF8.self).contains("en-US"),
            "hyphenated ASCII language identifiers are accepted"
        )
    }

    private static func expectBuilderError(
        credentials: VolcV4Credentials,
        sourceLanguage: String? = "en",
        targetLanguage: String = "zh",
        instant: Date,
        expected: VolcV4RequestBuilderError,
        message: String
    ) {
        do {
            _ = try VolcV4RequestBuilder.build(
                text: "hello",
                credentials: credentials,
                sourceLanguage: sourceLanguage,
                targetLanguage: targetLanguage,
                instant: instant
            )
            fatalError("\(message): expected error")
        } catch let error as VolcV4RequestBuilderError {
            expect(error == expected, message)
        } catch {
            fatalError("\(message): unexpected error \(error)")
        }
    }

    private static func date(_ string: String) throws -> Date {
        let formatter = ISO8601DateFormatter()
        guard let value = formatter.date(from: string) else {
            throw VolcV4RequestBuilderError.invalidTimestamp
        }
        return value
    }
}
#endif
