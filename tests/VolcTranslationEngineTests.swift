import Foundation

/// Drives `VolcTranslationEngine` against a URLProtocol stub: request shape,
/// error mapping, credential caching, cancellation and timeout. No network.
@main
@MainActor
enum VolcTranslationEngineTests {
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

    private static let secretKey = "SKTEST"
    private static let credentials = VolcV4Credentials(accessKey: "AKTEST", secretKey: secretKey)
    private static let success = Data(#"{"Result":{"TranslationList":[{"Translation":"好工具应该让人感觉毫不费力。"}]}}"#.utf8)

    static func main() async {
        await testSignedRequestShapeAndSuccess()
        await testMissingCredentialSendsNothing()
        await testErrorMapping()
        await testCredentialCacheAndForget()
        await testValidateUsesCandidateOnly()
        await testCancelCurrentStopsTheInFlightTask()
        await testTaskCancellationStopsTheInFlightTask()
        await testTimeoutMapping()
        testOverlayMappingAndRedaction()
        testSessionConfiguration()
        print("VolcTranslationEngineTests: \(passed) passed")
    }

    private static func makeEngine(
        provider: CredentialCounter? = nil
    ) -> VolcTranslationEngine {
        let provider = provider ?? CredentialCounter(credentials)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return VolcTranslationEngine(
            session: VolcTranslationEngine.makeSession(configuration: configuration),
            credentialProvider: { await provider.read() },
            now: { Date(timeIntervalSince1970: 1_767_323_045) }  // 2026-01-02T03:04:05Z
        )
    }

    private static func testSignedRequestShapeAndSuccess() async {
        StubURLProtocol.state.reset(.respond(status: 200, body: success))
        let outcome = await makeEngine().translate("Hello, world.")
        expect(outcome == .translated("好工具应该让人感觉毫不费力。"), "a 200 response is translated")
        let requests = StubURLProtocol.state.requests
        expect(requests.count == 1, "exactly one request is sent")
        guard let request = requests.first else { return }
        expect(request.method == "POST", "request is POST")
        expect(
            request.url == "https://translate.volcengineapi.com/?Action=TranslateText&Version=2020-06-01",
            "request targets the signed endpoint"
        )
        expect(
            request.body == "{\"TargetLanguage\": \"zh\", \"TextList\": [\"Hello, world.\"], \"SourceLanguage\": \"en\"}",
            "body always carries SourceLanguage en"
        )
        expect(
            request.headers["Authorization"]
                == "HMAC-SHA256 Credential=AKTEST/20260102/cn-north-1/translate/request, SignedHeaders=content-type;host;x-content-sha256;x-date, Signature=7265ac5fe98b6ff62155737ef2dd0ec68d07dbb472c0aba1b527b7e9715302a7",
            "the engine sends the pinned signature"
        )
        expect(request.headers["X-Date"] == "20260102T030405Z", "x-date is sent")
        expect(
            request.headers["Content-Type"] == "application/json; charset=utf-8",
            "content type is sent as signed"
        )
        let everything = request.headers.values.joined() + request.url + request.body
        expect(!everything.contains(secretKey), "the secret key is never transmitted")
        expect(request.headers["Cookie"] == nil, "no cookies are attached")
    }

    private static func testMissingCredentialSendsNothing() async {
        StubURLProtocol.state.reset(.respond(status: 200, body: success))
        let engine = makeEngine(provider: CredentialCounter(nil))
        let translated = await engine.translate("hello")
        expect(translated == .failed(.credential), "no credential is a credential failure")
        let hasCredentials = await engine.hasCredentials()
        expect(hasCredentials == false, "hasCredentials reports absence")
        let diagnostics = await engine.validateStoredCredentials()
        expect(diagnostics == .failed(.credential), "diagnostics without a credential fail as credential")
        expect(StubURLProtocol.state.requests.isEmpty, "nothing is sent without a credential")
    }

    private static func testErrorMapping() async {
        let cases: [(StubURLProtocol.Behavior, VolcTranslationOutcome)] = [
            (.respond(status: 401, body: Data()), .failed(.credential)),
            (.respond(status: 403, body: Data()), .failed(.credential)),
            (
                .respond(
                    status: 200,
                    body: Data(#"{"ResponseMetadata":{"Error":{"Code":"SignatureDoesNotMatch"}}}"#.utf8)
                ),
                .failed(.credential)
            ),
            (.respond(status: 500, body: Data()), .failed(.httpFailure)),
            (.respond(status: 429, body: Data()), .failed(.httpFailure)),
            (.respond(status: 504, body: Data()), .failed(.timeout)),
            (.respond(status: 200, body: Data("not json".utf8)), .failed(.malformedResponse)),
            (.respond(status: 200, body: Data(#"{"TranslationList":[]}"#.utf8)), .failed(.emptyResult)),
            (.respond(status: 200, body: Data(#"{"TranslationList":[{"Translation":" "}]}"#.utf8)), .failed(.emptyResult)),
            (.fail(.notConnectedToInternet), .failed(.network)),
            (.fail(.cannotFindHost), .failed(.network)),
            (.fail(.networkConnectionLost), .failed(.network)),
            (.fail(.secureConnectionFailed), .failed(.network)),
        ]
        for (behavior, expected) in cases {
            StubURLProtocol.state.reset(behavior)
            let outcome = await makeEngine().translate("hello")
            expect(outcome == expected, "\(behavior) maps to \(expected)")
        }
    }

    private static func testCredentialCacheAndForget() async {
        StubURLProtocol.state.reset(.respond(status: 200, body: success))
        let provider = CredentialCounter(credentials)
        let engine = makeEngine(provider: provider)
        _ = await engine.translate("one")
        _ = await engine.translate("two")
        expect(provider.reads == 1, "a successful read is cached in memory")
        engine.forgetCredentials()
        _ = await engine.translate("three")
        expect(provider.reads == 2, "forgetCredentials forces a fresh Keychain read")

        StubURLProtocol.state.reset(.respond(status: 401, body: Data()))
        let rejected = await engine.translate("four")
        expect(rejected == .failed(.credential), "rejected credential")
        StubURLProtocol.state.reset(.respond(status: 200, body: success))
        _ = await engine.translate("five")
        expect(provider.reads == 3, "a rejected credential is dropped from memory")
    }

    private static func testValidateUsesCandidateOnly() async {
        StubURLProtocol.state.reset(.respond(status: 200, body: success))
        let provider = CredentialCounter(nil)
        let engine = makeEngine(provider: provider)
        let candidate = VolcV4Credentials(accessKey: "AKCANDIDATE", secretKey: "SKCANDIDATE")
        let validation = await engine.validate(credentials: candidate)
        expect(validation == .translated("好工具应该让人感觉毫不费力。"), "a valid candidate validates")
        expect(provider.reads == 0, "validation never reads the stored credential")
        let request = StubURLProtocol.state.requests.first
        expect(
            request?.body.contains(VolcTranslationEngine.validationText) == true,
            "validation sends the fixed English sentence"
        )
        expect(
            request?.headers["Authorization"]?.contains("Credential=AKCANDIDATE/") == true,
            "validation signs with the candidate"
        )
        let afterValidation = await engine.translate("hello")
        expect(afterValidation == .failed(.credential), "a validated candidate is not cached")
    }

    private static func testCancelCurrentStopsTheInFlightTask() async {
        StubURLProtocol.state.reset(.hang)
        let engine = makeEngine()
        let pending = Task { await engine.translate("hello") }
        await waitUntilStarted()
        engine.cancelCurrent()
        let outcome = await pending.value
        expect(outcome == .cancelled, "cancelCurrent resolves the translation as cancelled")
        await waitUntilStopped()
        expect(StubURLProtocol.state.stopped, "cancelCurrent stops the URLSession task")
    }

    private static func testTaskCancellationStopsTheInFlightTask() async {
        StubURLProtocol.state.reset(.hang)
        let engine = makeEngine()
        let pending = Task { await engine.translate("hello") }
        await waitUntilStarted()
        pending.cancel()
        let cancelled = await pending.value
        expect(cancelled == .cancelled, "Swift task cancellation resolves as cancelled")
        await waitUntilStopped()
        expect(StubURLProtocol.state.stopped, "task cancellation stops the URLSession task")
    }

    private static func testTimeoutMapping() async {
        StubURLProtocol.state.reset(.fail(.timedOut))
        let timedOut = await makeEngine().translate("hello")
        expect(timedOut == .failed(.timeout), "URLError.timedOut is a timeout")
        expect(
            VolcTranslationEngine.outcome(data: nil, response: nil, error: URLError(.timedOut))
                == .failed(.timeout),
            "timeout classification is direct"
        )
        expect(
            VolcTranslationEngine.outcome(data: nil, response: nil, error: URLError(.cancelled))
                == .cancelled,
            "cancellation classification is direct"
        )
        expect(
            VolcTranslationEngine.outcome(data: Data(), response: URLResponse(), error: nil)
                == .failed(.malformedResponse),
            "a non-HTTP response is malformed"
        )
    }

    private static func testOverlayMappingAndRedaction() {
        let mapping: [(VolcTranslationError, NativeTranslationOverlayBackendError)] = [
            (.credential, .volcCredential),
            (.network, .volcNetwork),
            (.timeout, .volcTimeout),
            (.httpFailure, .httpFailure),
            (.malformedResponse, .malformedResponse),
            (.emptyResult, .emptyResult),
        ]
        for (error, overlay) in mapping {
            expect(error.overlayError == overlay, "\(error) uses the overlay's cloud copy")
        }
        let credentialState = NativeTranslationOverlayReducer.reduce(
            .response(.init(
                requestedEngine: .volc,
                actualEngine: nil,
                result: nil,
                elapsedMilliseconds: 1,
                error: VolcTranslationError.credential.overlayError
            ))
        )
        expect(credentialState.cta == .checkCloudSettings, "credential failure offers cloud settings")
        let success = NativeTranslationOverlayReducer.reduce(
            .response(.init(requestedEngine: .volc, actualEngine: .volc, result: "译文", elapsedMilliseconds: 42))
        )
        expect(success.metadata == "火山云端 · 42 毫秒", "success metadata names the cloud engine")
        expect(
            !String(describing: VolcTranslationOutcome.translated("secret-selection")).contains("secret-selection"),
            "outcome description redacts the translation"
        )
    }

    private static func testSessionConfiguration() {
        let configuration = VolcTranslationEngine.makeSession().configuration
        expect(configuration.waitsForConnectivity == false, "never waits for connectivity")
        expect(configuration.timeoutIntervalForRequest == 12, "request timeout matches the coordinator")
        expect(configuration.urlCache == nil, "no response cache")
        expect(configuration.httpCookieStorage == nil, "no cookie storage")
        expect(configuration.urlCredentialStorage == nil, "no credential storage")
        expect(VolcTranslationEngine.requestTimeout == 12, "request timeout constant is 12 s")
    }

    private static func waitUntilStarted() async {
        for _ in 0..<500 where !StubURLProtocol.state.started {
            try? await Task.sleep(for: .milliseconds(10))
        }
        expect(StubURLProtocol.state.started, "the stub received the request")
    }

    private static func waitUntilStopped() async {
        for _ in 0..<500 where !StubURLProtocol.state.stopped {
            try? await Task.sleep(for: .milliseconds(10))
        }
    }
}

private final class CredentialCounter: @unchecked Sendable {
    private let lock = NSLock()
    private let credentials: VolcV4Credentials?
    private var count = 0

    init(_ credentials: VolcV4Credentials?) { self.credentials = credentials }

    var reads: Int { lock.withLock { count } }

    func read() async -> VolcV4Credentials? {
        lock.withLock { count += 1 }
        return credentials
    }
}

private struct RecordedRequest: Sendable {
    let method: String
    let url: String
    let headers: [String: String]
    let body: String
}

private final class StubState: @unchecked Sendable {
    private let lock = NSLock()
    private var behavior: StubURLProtocol.Behavior = .hang
    private var recorded: [RecordedRequest] = []
    private var didStart = false
    private var didStop = false

    func reset(_ behavior: StubURLProtocol.Behavior) {
        lock.withLock {
            self.behavior = behavior
            recorded = []
            didStart = false
            didStop = false
        }
    }

    func record(_ request: RecordedRequest) -> StubURLProtocol.Behavior {
        lock.withLock {
            recorded.append(request)
            didStart = true
            return behavior
        }
    }

    func markStopped() { lock.withLock { didStop = true } }
    var requests: [RecordedRequest] { lock.withLock { recorded } }
    var started: Bool { lock.withLock { didStart } }
    var stopped: Bool { lock.withLock { didStop } }
}

private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
    enum Behavior: Sendable, CustomStringConvertible {
        case respond(status: Int, body: Data)
        case fail(URLError.Code)
        case hang

        var description: String {
            switch self {
            case let .respond(status, _): return "HTTP \(status)"
            case let .fail(code): return "URLError \(code.rawValue)"
            case .hang: return "hang"
            }
        }
    }

    static let state = StubState()

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let behavior = Self.state.record(RecordedRequest(
            method: request.httpMethod ?? "",
            url: request.url?.absoluteString ?? "",
            headers: request.allHTTPHeaderFields ?? [:],
            body: String(decoding: Self.bodyData(of: request), as: UTF8.self)
        ))
        switch behavior {
        case let .respond(status, body):
            let response = HTTPURLResponse(
                url: request.url!,
                statusCode: status,
                httpVersion: "HTTP/1.1",
                headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: body)
            client?.urlProtocolDidFinishLoading(self)
        case let .fail(code):
            client?.urlProtocol(self, didFailWithError: URLError(code))
        case .hang:
            break
        }
    }

    override func stopLoading() {
        Self.state.markStopped()
    }

    private static func bodyData(of request: URLRequest) -> Data {
        if let body = request.httpBody { return body }
        guard let stream = request.httpBodyStream else { return Data() }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 4_096)
        while stream.hasBytesAvailable {
            let count = stream.read(&buffer, maxLength: buffer.count)
            guard count > 0 else { break }
            data.append(buffer, count: count)
        }
        return data
    }
}
