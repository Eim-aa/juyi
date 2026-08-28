#if DEBUG && JUYI_NATIVE_TRANSLATION_DOMAIN
import Foundation

@main
@MainActor
enum VolcTranslationResponseParserTests {
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

    static func main() {
        testSuccess()
        testOfficialResultSuccess()
        testDuplicateEnvelopeFailsClosed()
        testConflictingEnvelopeFailsClosed()
        testHTTPClassification()
        testUpstreamAllowlist()
        testMalformedPayloads()
        testCanaryRedaction()
        print("VolcTranslationResponseParserTests: \(passed) passed")
    }

    private static func parse(_ json: String) -> Result<String, NativeTranslationFailure> {
        parse(200, json)
    }

    private static func parse(_ status: Int, _ json: String) -> Result<String, NativeTranslationFailure> {
        VolcTranslationResponseParser.parse(statusCode: status, data: Data(json.utf8))
    }

    private static func testSuccess() {
        expect(
            parse(#"{"TranslationList":[{"Translation":"你好\n世界"}]}"#) == .success("你好\n世界"),
            "first nonempty translation succeeds exactly"
        )
        expect(
            parse(#"{"ResponseMetadata":{},"TranslationList":[{"Translation":" 译文 "}]}"#)
                == .success(" 译文 "),
            "successful result content is not normalized"
        )
    }

    private static func testOfficialResultSuccess() {
        expect(
            parse(
                #"{"Result":{"TranslationList":[{"Translation":"好工具应该让人感觉毫不费力。"}]},"ResponseMetadata":{"Error":null}}"#
            ) == .success("好工具应该让人感觉毫不费力。"),
            "official Result.TranslationList succeeds"
        )
    }

    private static func testDuplicateEnvelopeFailsClosed() {
        expect(
            parse(
                #"{"TranslationList":[{"Translation":"一致"}],"Result":{"TranslationList":[{"Translation":"一致"}]}}"#
            ) == .failure(.volcMalformedResponse),
            "simultaneous legacy and official envelopes fail closed"
        )
    }

    private static func testConflictingEnvelopeFailsClosed() {
        expect(
            parse(
                #"{"TranslationList":[{"Translation":"旧结构"}],"Result":{"TranslationList":[{"Translation":"新结构"}]}}"#
            ) == .failure(.volcMalformedResponse),
            "conflicting response envelopes fail closed"
        )
    }

    private static func testHTTPClassification() {
        let cases: [(Int, NativeTranslationFailure)] = [
            (401, .volcCredential),
            (403, .volcCredential),
            (408, .volcTimeout),
            (504, .volcTimeout),
            (429, .volcQuota),
            (500, .volcService),
            (599, .volcService),
            (300, .volcHTTP),
            (400, .volcHTTP),
        ]
        for (status, failure) in cases {
            expect(
                parse(status, #"{"TranslationList":[{"Translation":"must not leak"}]}"#)
                    == .failure(failure),
                "HTTP \(status) is classified without parsing a result"
            )
        }
        expect(
            parse(
                400,
                #"{"ResponseMetadata":{"Error":{"Code":"Unauthorized","Message":"secret"}}}"#
            ) == .failure(.volcHTTP),
            "non-2xx classification intentionally ignores body code"
        )
    }

    private static func testUpstreamAllowlist() {
        let credentialCodes = [
            "AccessDenied", "Forbidden", "InvalidAccessKey", "InvalidAccessKeyId",
            "InvalidCredential", "PermissionDenied", "SignatureDoesNotMatch", "Unauthorized",
        ]
        let timeoutCodes = ["RequestTimeout", "RequestTimeoutException", "Timeout"]
        let quotaCodes = [
            "FlowLimitExceeded", "LimitExceeded", "QuotaExceeded", "Throttling", "TooManyRequests",
            "-429",
        ]
        for (codes, expected): ([String], NativeTranslationFailure) in [
            (credentialCodes, .volcCredential),
            (timeoutCodes, .volcTimeout),
            (quotaCodes, .volcQuota),
        ] {
            for code in codes {
                expect(
                    parse(
                        "{\"ResponseMetadata\":{\"Error\":{\"Code\":\"\(code)\",\"Message\":\"secret\"}},\"TranslationList\":[{\"Translation\":\"echo\"}]}"
                    ) == .failure(expected),
                    "allowlisted \(code) maps to stable typed failure"
                )
            }
        }
        expect(
            parse(#"{"ResponseMetadata":{"Error":{"Code":"FutureSecretCode","Message":"secret"}}}"#)
                == .failure(.volcService),
            "unknown upstream code fails as generic service"
        )
        expect(
            parse(#"{"ResponseMetadata":{"Error":{}}}"#) == .failure(.volcService),
            "missing upstream code fails as generic service"
        )
        expect(
            parse(#"{"ResponseMetadata":{"Error":{"Code":"Unauthorized"}},"TranslationList":"wrong"}"#)
                == .failure(.volcCredential),
            "typed upstream error wins without retaining unrelated payload shape"
        )
    }

    private static func testMalformedPayloads() {
        let malformed = [
            "",
            "null",
            "[]",
            "{}",
            #"{"TranslationList":[]}"#,
            #"{"TranslationList":[{"Translation":"first"},{"Translation":"second"}]}"#,
            #"{"Result":{"TranslationList":[]}}"#,
            #"{"Result":{"TranslationList":[{"Translation":"first"},{"Translation":"second"}]}}"#,
            #"{"TranslationList":[{}]}"#,
            #"{"TranslationList":[{"Translation":null}]}"#,
            #"{"TranslationList":[{"Translation":7}]}"#,
            #"{"TranslationList":[{"Translation":""}]}"#,
            #"{"TranslationList":[{"Translation":" \n\t"}]}"#,
            #"{"TranslationList":"wrong"}"#,
            #"{"ResponseMetadata":"wrong","TranslationList":[{"Translation":"echo"}]}"#,
            #"{"ResponseMetadata":{"Error":"wrong"},"TranslationList":[{"Translation":"echo"}]}"#,
            #"{"ResponseMetadata":{"Error":{"Code":7}},"TranslationList":[{"Translation":"echo"}]}"#,
            #"{"TranslationList":[{}, {"Translation":"second"}]}"#,
        ]
        for json in malformed {
            expect(
                parse(json) == .failure(.volcMalformedResponse),
                "malformed response has no result"
            )
        }

        let oversized = Data(repeating: 0x20, count: 1_048_577)
        expect(
            VolcTranslationResponseParser.parse(statusCode: 200, data: oversized)
                == .failure(.volcMalformedResponse),
            "oversized success payload is rejected before decode"
        )
        let oversizedSecret = Data(
            ("AKFAKE-oversized-secret" + String(repeating: "x", count: 1_048_577)).utf8
        )
        let oversizedSecretOutcome = VolcTranslationResponseParser.parse(
            statusCode: 200,
            data: oversizedSecret
        )
        expect(
            oversizedSecretOutcome == .failure(.volcMalformedResponse),
            "oversized secret payload fails closed"
        )
        expect(
            !String(describing: oversizedSecretOutcome).contains("AKFAKE"),
            "oversized body is not retained by the typed failure"
        )
        expect(
            VolcTranslationResponseParser.parse(
                statusCode: 200,
                data: Data([0x7B, 0x22, 0xFF, 0x22, 0x3A, 0x31, 0x7D])
            ) == .failure(.volcMalformedResponse),
            "invalid UTF-8 is rejected"
        )
    }

    private static func testCanaryRedaction() {
        let secret = "AKFAKE123-SKFAKE456-upstream-message-source-result"
        let outcome = parse(
            "{\"ResponseMetadata\":{\"Error\":{\"Code\":\"\(secret)\",\"Message\":\"\(secret)\"}},\"TranslationList\":[{\"Translation\":\"\(secret)\"}]}"
        )
        expect(outcome == .failure(.volcService), "unknown secret-bearing API error is generic")
        expect(!String(describing: outcome).contains(secret), "typed parser outcome does not retain raw secret")
        expect(!NativeTranslationFailure.volcService.description.contains(secret), "failure description is stable")

        let httpOutcome = parse(
            403,
            "{\"TranslationList\":[{\"Translation\":\"\(secret)\"}]}"
        )
        expect(httpOutcome == .failure(.volcCredential), "HTTP failure ignores body")
        expect(!String(describing: httpOutcome).contains(secret), "HTTP outcome does not retain raw body")
    }
}
#endif
