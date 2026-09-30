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
        testAmbiguousEnvelopesFailClosed()
        testHTTPClassification()
        testUpstreamCodes()
        testEmptyResults()
        testMalformedPayloads()
        testCanaryRedaction()
        print("VolcTranslationResponseParserTests: \(passed) passed")
    }

    private static func parse(_ json: String) -> Result<String, VolcTranslationError> {
        parse(200, json)
    }

    private static func parse(_ status: Int, _ json: String) -> Result<String, VolcTranslationError> {
        VolcTranslationResponseParser.parse(statusCode: status, data: Data(json.utf8))
    }

    private static func testSuccess() {
        expect(
            parse(#"{"TranslationList":[{"Translation":"你好\n世界"}]}"#) == .success("你好\n世界"),
            "legacy top-level TranslationList succeeds exactly"
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

    private static func testAmbiguousEnvelopesFailClosed() {
        expect(
            parse(
                #"{"TranslationList":[{"Translation":"旧结构"}],"Result":{"TranslationList":[{"Translation":"新结构"}]}}"#
            ) == .failure(.malformedResponse),
            "simultaneous legacy and official envelopes fail closed"
        )
        expect(
            parse(#"{"TranslationList":[{"Translation":"first"},{"Translation":"second"}]}"#)
                == .failure(.malformedResponse),
            "a single-text request never accepts several translations"
        )
    }

    private static func testHTTPClassification() {
        let cases: [(Int, VolcTranslationError)] = [
            (401, .credential),
            (403, .credential),
            (408, .timeout),
            (504, .timeout),
            (429, .httpFailure),
            (500, .httpFailure),
            (599, .httpFailure),
            (300, .httpFailure),
            (400, .httpFailure),
        ]
        for (status, failure) in cases {
            expect(
                parse(status, #"{"TranslationList":[{"Translation":"must not leak"}]}"#)
                    == .failure(failure),
                "HTTP \(status) is classified without returning a result"
            )
        }
        expect(
            parse(400, #"{"ResponseMetadata":{"Error":{"Code":"SignatureDoesNotMatch","Message":"x"}}}"#)
                == .failure(.credential),
            "a credential code on another 4xx status is a credential problem"
        )
        expect(
            parse(400, #"{"ResponseMetadata":{"Error":{"Code":"InvalidParameter"}}}"#)
                == .failure(.httpFailure),
            "other 4xx codes stay HTTP failures"
        )
    }

    private static func testUpstreamCodes() {
        for code in VolcTranslationResponseParser.credentialCodes {
            expect(
                parse(
                    "{\"ResponseMetadata\":{\"Error\":{\"Code\":\"\(code)\",\"Message\":\"secret\"}},\"TranslationList\":[{\"Translation\":\"echo\"}]}"
                ) == .failure(.credential),
                "\(code) maps to the credential failure"
            )
        }
        for code in VolcTranslationResponseParser.timeoutCodes {
            expect(
                parse("{\"ResponseMetadata\":{\"Error\":{\"Code\":\"\(code)\"}}}") == .failure(.timeout),
                "\(code) maps to the timeout failure"
            )
        }
        for code in ["FlowLimitExceeded", "QuotaExceeded", "InternalError", "FutureCode"] {
            expect(
                parse("{\"ResponseMetadata\":{\"Error\":{\"Code\":\"\(code)\"}}}") == .failure(.httpFailure),
                "\(code) is a generic HTTP failure"
            )
        }
        expect(
            parse(#"{"ResponseMetadata":{"Error":{}}}"#) == .failure(.httpFailure),
            "missing upstream code is a generic HTTP failure"
        )
        expect(
            parse(#"{"ResponseMetadata":{"Error":{"Code":"Unauthorized"}},"TranslationList":"wrong"}"#)
                == .failure(.credential),
            "typed upstream error wins without decoding unrelated payload"
        )
    }

    private static func testEmptyResults() {
        for json in [
            #"{"TranslationList":[]}"#,
            #"{"Result":{"TranslationList":[]}}"#,
            #"{"TranslationList":[{}]}"#,
            #"{"TranslationList":[{"Translation":null}]}"#,
            #"{"TranslationList":[{"Translation":""}]}"#,
            #"{"TranslationList":[{"Translation":" \n\t"}]}"#,
        ] {
            expect(parse(json) == .failure(.emptyResult), "empty list or translation is emptyResult: \(json)")
        }
    }

    private static func testMalformedPayloads() {
        let malformed = [
            "",
            "null",
            "[]",
            "{}",
            #"{"Result":{}}"#,
            #"{"TranslationList":[{"Translation":7}]}"#,
            #"{"TranslationList":"wrong"}"#,
            #"{"ResponseMetadata":"wrong","TranslationList":[{"Translation":"echo"}]}"#,
            #"{"ResponseMetadata":{"Error":"wrong"},"TranslationList":[{"Translation":"echo"}]}"#,
            #"{"ResponseMetadata":{"Error":{"Code":7}},"TranslationList":[{"Translation":"echo"}]}"#,
        ]
        for json in malformed {
            expect(parse(json) == .failure(.malformedResponse), "malformed response has no result: \(json)")
        }
        let oversized = Data(repeating: 0x20, count: VolcTranslationResponseParser.maximumPayloadBytes + 1)
        expect(
            VolcTranslationResponseParser.parse(statusCode: 200, data: oversized) == .failure(.malformedResponse),
            "oversized success payload is rejected before decode"
        )
        expect(
            VolcTranslationResponseParser.parse(
                statusCode: 200,
                data: Data([0x7B, 0x22, 0xFF, 0x22, 0x3A, 0x31, 0x7D])
            ) == .failure(.malformedResponse),
            "invalid UTF-8 is rejected"
        )
    }

    private static func testCanaryRedaction() {
        let secret = "AKFAKE123-SKFAKE456-upstream-message"
        let outcome = parse(
            "{\"ResponseMetadata\":{\"Error\":{\"Code\":\"\(secret)\",\"Message\":\"\(secret)\"}},\"TranslationList\":[{\"Translation\":\"\(secret)\"}]}"
        )
        expect(outcome == .failure(.httpFailure), "unknown secret-bearing API error is generic")
        expect(!String(describing: outcome).contains(secret), "typed outcome does not retain raw text")
        let httpOutcome = parse(403, "{\"TranslationList\":[{\"Translation\":\"\(secret)\"}]}")
        expect(httpOutcome == .failure(.credential), "HTTP failure ignores the translation")
        expect(!String(describing: httpOutcome).contains(secret), "HTTP outcome does not retain the body")
        for error in [VolcTranslationError.credential, .network, .timeout, .httpFailure, .malformedResponse, .emptyResult] {
            expect(error.description.hasPrefix("volc_"), "error description is a stable token")
        }
    }
}
